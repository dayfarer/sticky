import type { EngineInterface, FsEntry, FsStat, Register, Timer } from 'claude-code'

// Sticky bridge. It lets the Sticky app send a message into the chat this
// claude process holds, as the person's own turn, and tells Sticky whether
// the chat is live and busy.
//
// It acts only in a chat the person runs: the Claude app's own chat process
// (CLAUDE_CODE_ENTRYPOINT "claude-desktop") or an interactive terminal claude
// ("cli" with a person at the prompt). A claude started from a chat's tools
// (a script's `claude -p`, say) inherits that entrypoint, so a process with
// CLAUDE_CODE_CHILD_SESSION set (Claude Code sets it for its tools' children)
// never counts. In any other process (Sticky's own `claude -p`, an SDK host)
// it writes and reads nothing, unless STICKY_BRIDGE_ALLOW_SDK=1 is set (test
// harnesses only).
//
// It reads and writes only inside the bridge folder: STICKY_BRIDGE_DIR, else
// ~/Library/Application Support/Sticky/bridge. Sticky makes that folder and
// the folders in it (mode 0700); the mod never makes a folder, so without
// Sticky it does nothing. It refuses links, caps what it reads, keeps no
// message text in its log, and makes no network, process or MCP call.
//
// Files (JSON, v 1):
//   leases/<sessionId>.json                  this chat is live (written here)
//   outbox/<sessionId>/<id>.json             a message from Sticky
//   outbox/<sessionId>/<id>.json.<loadId>.taken   a claim (written here)
//   acks/<id>.json                           what became of it (written here)
//   log.txt                                  one line per action (written here)
//
// $.fs has no rename, no delete and no exclusive create. So a load claims an
// outbox file by writing <file>.<loadId>.taken, waits CLAIM_SETTLE_MS and
// lists the folder again: the earliest claim (file time, then name) wins and
// only its load acts. Every other load (a reload, a second process with the
// same session id) sees that claim and leaves the file alone. A file with any
// claim is never claimed again, so a crash after the claim loses the message
// but never sends it twice. Sticky deletes the files it is done with, and
// deletes a message it takes back: a claimed message whose file is gone when
// its turn comes is acked ok:false and never sent. A prompt waits for the
// running turn to end before it is submitted, so a Stop in Sticky can still
// take it back.
//
// The lease names the running turn (turnId); an "interrupt" names the turn it
// means to stop, and stops nothing else.

const MOD_VERSION = '1.1.0'
const POLL_MS = 500
const HEARTBEAT_MS = 3000
// How often a claimed prompt looks whether the running turn has ended.
const TURN_WAIT_MS = 250
// How long a load waits after its claims before it reads who won.
const CLAIM_SETTLE_MS = 1000
// A file that does not parse yet may still be being written: wait this long.
const PARTIAL_GRACE_MS = 2000
// An outbox file older than this when first seen is acked ok:false and never
// sent: Sticky gave up on it (no ack within 10 s) and gave the draft back.
const MAX_AGE_MS = 8000
const MAX_OUTBOX_BYTES = 1024 * 1024
const MAX_LOG_BYTES = 256 * 1024
const MAX_PER_POLL = 16
const LOG_KEEP_LINES = 500
const MAX_TURN_ID = 200

const UUID_SRC = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
const UUID = new RegExp(`^${UUID_SRC}$`)
const OUTBOX_FILE = new RegExp(`^(${UUID_SRC})\\.json$`)
const CLAIM_FILE = new RegExp(`^(${UUID_SRC}\\.json)\\.(${UUID_SRC})\\.taken$`)
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/

type Engine = EngineInterface
type LeaseState = 'idle' | 'turn' | 'ended'
type Message = { kind: 'prompt'; text: string } | { kind: 'interrupt'; turnId: string | undefined }
// An outbox file read and ready to claim: a message, or why it is bad.
type Item = { name: string; id: string; message?: Message; problem?: string }
type Ack = { v: 1; id: string; ok: boolean; error?: string; at: number; stopped?: boolean }

// What one load of the module holds; a reload starts a fresh one.
type Bridge = {
  // The gate passed at session.start and the session has not ended.
  isActive: boolean
  loadId: string
  loadedAt: number
  entrypoint: string
  // The bridge folder as configured, and its real path while it checks out
  // (undefined: missing or a link, so the mod writes nothing for now).
  dir: string
  base: string | undefined
  state: LeaseState
  // The main loop's running turn, for "interrupt".
  turnId: string | undefined
  timers: Timer[]
  isPolling: boolean
  // Outbox files this load has claimed.
  claimed: Set<string>
  // Session ids that ended in this process (a /clear goes on under a new id).
  ended: Set<string>
  lastProblem: string
  leaseChain: Promise<void>
  logChain: Promise<void>
  // Prompts go to the session one at a time, in the order they were claimed.
  promptChain: Promise<void>
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

const errorText = (err: unknown): string =>
  err instanceof Error ? `${err.name}: ${err.message}` : String(err)

const oneLine = (text: string, max: number): string => text.replace(/\s+/g, ' ').slice(0, max)

const byteLength = (text: string): number => new TextEncoder().encode(text).length

const short = (id: string): string => id.slice(0, 8)

const byAge = (a: FsEntry, b: FsEntry): number =>
  a.mtimeMs - b.mtimeMs || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)

// An absolute path with no empty, "." or ".." part, no trailing slash.
function cleanDir(path: string): string | undefined {
  const trimmed = path.replace(/\/+$/, '')
  if (!trimmed.startsWith('/') || trimmed.length > 1024 || /[\0\r\n]/.test(trimmed)) return undefined
  const parts = trimmed.split('/').slice(1)
  if (parts.some(part => part === '' || part === '.' || part === '..')) return undefined
  return trimmed
}

const statOf = ($: Engine, path: string): Promise<FsStat | undefined> =>
  $.fs.stat(path, { resolve: true }).catch(() => undefined)

// A path inside the bridge: `rel` is one to three plain names.
function inside(b: Bridge, rel: string): string {
  const parts = rel.split('/')
  if (b.base === undefined) throw new Error('the bridge folder is not there')
  if (parts.length > 3 || !parts.every(part => SEGMENT.test(part))) throw new Error(`bad path: ${oneLine(rel, 80)}`)
  return `${b.base}/${rel}`
}

// Checks the bridge folder: a real folder, not a link. Answers whether it is
// usable now.
async function checkBase($: Engine, b: Bridge): Promise<boolean> {
  const stat = await statOf($, b.dir)
  const real = stat !== undefined && !stat.isLink && stat.kind === 'dir' ? stat.realPath : undefined
  b.base = real
  return real !== undefined
}

// Reads a plain file inside the bridge; undefined when it is missing, a
// link, not a file or over `max` bytes.
async function readInside($: Engine, b: Bridge, rel: string, max: number): Promise<string | undefined> {
  const path = inside(b, rel)
  const stat = await statOf($, path)
  if (stat === undefined || stat.isLink || stat.kind !== 'file' || stat.realPath !== path || stat.size > max) {
    return undefined
  }
  const text = await $.fs.read(path).catch(() => undefined)
  return text !== undefined && byteLength(text) <= max ? text : undefined
}

// Writes a file inside the bridge. Refuses a file that is a link or not a
// plain file, and a folder that is missing or a link: Sticky makes every
// folder the mod writes into, and the mod never makes one. A missing folder
// may mean the bridge folder itself is gone: it is checked again, so nothing
// is written until it is back.
async function writeInside($: Engine, b: Bridge, rel: string, text: string): Promise<void> {
  const path = inside(b, rel)
  const folder = path.slice(0, path.lastIndexOf('/'))
  const [own, parent] = await Promise.all([statOf($, path), statOf($, folder)])
  if (own !== undefined && (own.isLink || own.kind !== 'file' || own.realPath !== path)) {
    throw new Error(`not a plain file: ${rel}`)
  }
  if (parent === undefined) {
    await checkBase($, b)
    throw new Error(`no folder for: ${rel}`)
  }
  if (parent.isLink || parent.kind !== 'dir' || parent.realPath !== folder) {
    throw new Error(`folder is a link or not a folder: ${rel}`)
  }
  await $.fs.write(path, text)
}

// One line per action. Never message text: ids, kinds, states and errors.
function log($: Engine, b: Bridge, line: string): Promise<void> {
  b.logChain = b.logChain
    .then(async () => {
      if (b.base === undefined) return
      const at = new Date(await $.clock.now()).toISOString()
      const sessionId = await $.session.id().catch(() => '?')
      const old = (await readInside($, b, 'log.txt', MAX_LOG_BYTES)) ?? ''
      const lines = `${old}${at} ${short(sessionId)} ${short(b.loadId)} ${line}\n`
        .split('\n')
        .filter(kept => kept !== '')
        .slice(-LOG_KEEP_LINES)
      await writeInside($, b, 'log.txt', `${lines.join('\n')}\n`)
    })
    .catch(() => undefined)
  return b.logChain
}

// Logs a recurring problem once, until it changes or clears.
async function logProblem($: Engine, b: Bridge, text: string): Promise<void> {
  if (text === b.lastProblem) return
  b.lastProblem = text
  if (text !== '') await log($, b, text)
}

// Writes are queued, and each reads `state` when it runs, so the newest write
// carries the newest state. $.fs.write overwrites in place (no rename), so a
// reader that finds the file torn reads it again.
function writeLease($: Engine, b: Bridge, endedId?: string): Promise<void> {
  b.leaseChain = b.leaseChain
    .then(async () => {
      if (b.base === undefined) return
      const sessionId = endedId ?? (await $.session.id())
      if (!UUID.test(sessionId)) return
      if (endedId === undefined && (!b.isActive || b.ended.has(sessionId))) return
      const state = endedId === undefined ? b.state : 'ended'
      const lease = {
        v: 1,
        sessionId,
        entrypoint: b.entrypoint,
        state,
        // The running main-loop turn: an "interrupt" must name it.
        turnId: state === 'turn' ? (b.turnId ?? null) : null,
        updatedAt: await $.clock.now(),
        loadedAt: b.loadedAt,
        loadId: b.loadId,
        canInterrupt: true,
        mod: MOD_VERSION,
      }
      await writeInside($, b, `leases/${sessionId}.json`, `${JSON.stringify(lease)}\n`)
    })
    .catch(err => logProblem($, b, `lease write failed: ${oneLine(errorText(err), 200)}`))
  return b.leaseChain
}

// Writes acks/<id>.json once; an ack already there is never replaced.
async function writeAck($: Engine, b: Bridge, id: string, ok: boolean, extra: { error?: string; stopped?: boolean }): Promise<void> {
  const rel = `acks/${id}.json`
  if (await $.fs.exists(inside(b, rel))) return log($, b, `ack ${short(id)} kept: one was there`)
  const ack: Ack = { v: 1, id, ok, at: await $.clock.now() }
  if (extra.error !== undefined) ack.error = oneLine(extra.error, 300)
  if (extra.stopped !== undefined) ack.stopped = extra.stopped
  await writeInside($, b, rel, `${JSON.stringify(ack)}\n`)
  const why = ack.error === undefined ? '' : ` error="${ack.error}"`
  const stopped = ack.stopped === undefined ? '' : ` stopped=${ack.stopped}`
  await log($, b, `ack ${short(id)} ok=${ok}${stopped}${why}`)
}

// Sticky deletes a message it takes back (Stop, or no claim seen in time) and
// gives the draft back. So a message whose file is gone is never sent, even
// after this load claimed it: it is acked ok:false instead.
async function isWithdrawn($: Engine, b: Bridge, sessionId: string, id: string): Promise<boolean> {
  try {
    return !(await $.fs.exists(inside(b, `outbox/${sessionId}/${id}.json`)))
  } catch {
    return true
  }
}

async function submitPrompt($: Engine, b: Bridge, sessionId: string, id: string, text: string): Promise<void> {
  // Not while a turn runs: the engine would queue it, and a Stop in Sticky
  // could no longer take it back. Once the turn ends it is checked again.
  while (b.isActive && b.state === 'turn') await $.clock.sleep(TURN_WAIT_MS)
  const current = await $.session.id().catch(() => '')
  if (!b.isActive || current !== sessionId) {
    return writeAck($, b, id, false, { error: 'not sent: the chat ended first' })
  }
  if (await isWithdrawn($, b, sessionId, id)) {
    return writeAck($, b, id, false, { error: 'not sent: Sticky took it back' })
  }
  await log($, b, `submit ${short(id)} (${text.length} chars)`)
  let error: string | undefined
  try {
    const submitted = await $.prompt.submit({ text, asUser: true })
    if (submitted.drop !== undefined) error = `dropped: ${submitted.drop}`
  } catch (err) {
    error = errorText(err)
  }
  await writeAck($, b, id, error === undefined, error === undefined ? {} : { error })
}

// Stops the turn the message names, if it is the main loop's running turn.
// Any other turn (the named one ended, and another started meanwhile) runs on:
// ok, stopped false. A message that names no turn is refused.
async function interrupt($: Engine, b: Bridge, sessionId: string, id: string, wanted: string | undefined): Promise<void> {
  const current = await $.session.id().catch(() => '')
  if (!b.isActive || current !== sessionId) {
    return writeAck($, b, id, false, { error: 'not stopped: the chat ended first' })
  }
  if (wanted === undefined) return writeAck($, b, id, false, { error: 'stale stop: it names no turn' })
  const turnId = b.turnId
  if (turnId === undefined || turnId !== wanted) return writeAck($, b, id, true, { stopped: false })
  await log($, b, `abort ${short(id)} turn ${short(turnId)}`)
  try {
    await $.turn.abort({ turnId })
    await writeAck($, b, id, true, { stopped: true })
  } catch (err) {
    // The turn may have ended while the claim settled.
    if (b.turnId !== turnId) await writeAck($, b, id, true, { stopped: false })
    else await writeAck($, b, id, false, { error: errorText(err) })
  }
}

async function act($: Engine, b: Bridge, sessionId: string, item: Item): Promise<void> {
  const { id, message, problem } = item
  // An id already acked is never acted on again, nor is its ack replaced.
  if (await $.fs.exists(inside(b, `acks/${id}.json`))) {
    return log($, b, `skip ${short(id)}: already acked`)
  }
  if (message === undefined) {
    await log($, b, `refuse ${short(id)}: ${problem ?? 'bad file'}`)
    return writeAck($, b, id, false, { error: problem ?? 'bad file' })
  }
  if (message.kind === 'interrupt') {
    if (await isWithdrawn($, b, sessionId, id)) {
      return writeAck($, b, id, false, { error: 'not sent: Sticky took it back' })
    }
    return interrupt($, b, sessionId, id, message.turnId)
  }
  const { text } = message
  // Not awaited: the poll goes on (an interrupt must not wait behind a
  // prompt queued behind a running turn), and the chain keeps the order.
  b.promptChain = b.promptChain
    .then(() => submitPrompt($, b, sessionId, id, text))
    .catch(err => logProblem($, b, `submit ${short(id)} failed: ${oneLine(errorText(err), 200)}`))
}

// A message, or what is wrong with it.
function toMessage(value: unknown, id: string): Message | string {
  if (!isRecord(value)) return 'the file is not a JSON object'
  if (value.v !== 1) return 'v must be 1'
  if (value.id !== id) return 'id must be the file name without .json'
  if (value.kind === 'interrupt') {
    const turnId = value.turnId
    const named = typeof turnId === 'string' && turnId !== '' && turnId.length <= MAX_TURN_ID ? turnId : undefined
    return { kind: 'interrupt', turnId: named }
  }
  if (value.kind !== 'prompt') return `unknown kind: ${oneLine(String(value.kind), 40)}`
  if (typeof value.text !== 'string' || value.text.trim() === '') return 'text must be a non-empty string'
  return { kind: 'prompt', text: value.text }
}

// Reads the outbox files no load has claimed yet, oldest first.
async function readUnclaimed($: Engine, b: Bridge, rel: string, entries: readonly FsEntry[]): Promise<Item[]> {
  const hasClaim = new Set<string>()
  for (const entry of entries) {
    const match = CLAIM_FILE.exec(entry.name)
    if (match?.[1]) hasClaim.add(match[1])
  }
  const fresh = entries
    .filter(
      entry =>
        entry.kind !== 'dir' &&
        OUTBOX_FILE.test(entry.name) &&
        !hasClaim.has(entry.name) &&
        !b.claimed.has(entry.name),
    )
    .sort(byAge)
    .slice(0, MAX_PER_POLL)
  const now = await $.clock.now()
  const items: Item[] = []
  for (const entry of fresh) {
    const id = entry.name.slice(0, -'.json'.length)
    const item = { name: entry.name, id }
    if (entry.isLink || entry.kind !== 'file') {
      items.push({ ...item, problem: 'the file is a link or not a plain file' })
    } else if (entry.size > MAX_OUTBOX_BYTES) {
      items.push({ ...item, problem: `the file is over ${MAX_OUTBOX_BYTES} bytes` })
    } else if (now - entry.mtimeMs > MAX_AGE_MS) {
      items.push({ ...item, problem: `expired: older than ${MAX_AGE_MS / 1000} s when the app saw it, not sent` })
    } else {
      const text = await readInside($, b, `${rel}/${entry.name}`, MAX_OUTBOX_BYTES)
      if (text === undefined) continue
      let parsed: unknown
      try {
        parsed = JSON.parse(text)
      } catch {
        if (now - entry.mtimeMs < PARTIAL_GRACE_MS) continue
        items.push({ ...item, problem: 'the file is not JSON' })
        continue
      }
      const message = toMessage(parsed, id)
      items.push(typeof message === 'string' ? { ...item, problem: message } : { ...item, message })
    }
  }
  return items
}

// For each outbox file, the load id of its earliest claim. A claim still
// empty is being written; it is later than any claim it is compared with.
function claimWinners(entries: readonly FsEntry[]): Map<string, string> {
  const first = new Map<string, { entry: FsEntry; loadId: string }>()
  for (const entry of entries) {
    const match = CLAIM_FILE.exec(entry.name)
    if (!match?.[1] || !match[2] || entry.kind !== 'file' || entry.isLink || entry.size === 0) continue
    const best = first.get(match[1])
    if (best === undefined || byAge(entry, best.entry) < 0) first.set(match[1], { entry, loadId: match[2] })
  }
  return new Map([...first].map(([name, { loadId }]) => [name, loadId]))
}

async function poll($: Engine, b: Bridge): Promise<void> {
  if (!b.isActive || b.isPolling || b.base === undefined) return
  b.isPolling = true
  try {
    const sessionId = await $.session.id()
    if (!UUID.test(sessionId) || b.ended.has(sessionId)) return
    const rel = `outbox/${sessionId}`
    const dir = inside(b, rel)
    const place = await statOf($, dir)
    if (place === undefined) return
    if (place.isLink || place.kind !== 'dir' || place.realPath !== dir) {
      throw new Error('the outbox is a link or not a folder')
    }
    const entries = await $.fs.list(dir)
    const names = new Set(entries.map(entry => entry.name))
    for (const name of b.claimed) if (!names.has(name)) b.claimed.delete(name)

    const ready = await readUnclaimed($, b, rel, entries)
    if (ready.length === 0) return

    // Claim, wait, then act only on the files whose earliest claim is ours.
    const mine: Item[] = []
    for (const item of ready) {
      const claim = { v: 1, id: item.id, loadId: b.loadId, sessionId, takenAt: await $.clock.now() }
      b.claimed.add(item.name)
      try {
        await writeInside($, b, `${rel}/${item.name}.${b.loadId}.taken`, `${JSON.stringify(claim)}\n`)
      } catch (err) {
        await log($, b, `claim ${short(item.id)} failed: ${oneLine(errorText(err), 200)}`)
        break
      }
      mine.push(item)
    }
    if (mine.length === 0) return
    await $.clock.sleep(CLAIM_SETTLE_MS)
    const winners = claimWinners(await $.fs.list(dir))
    for (const item of mine) {
      if (winners.get(item.name) !== b.loadId) {
        await log($, b, `skip ${short(item.id)}: another load claimed it first`)
      } else if (b.isActive && b.base !== undefined) {
        await act($, b, sessionId, item)
      } else if (b.base !== undefined) {
        await writeAck($, b, item.id, false, { error: 'not sent: the chat ended first' })
      }
    }
    await logProblem($, b, '')
  } catch (err) {
    await logProblem($, b, `poll failed: ${oneLine(errorText(err), 200)}`)
  } finally {
    b.isPolling = false
  }
}

async function heartbeat($: Engine, b: Bridge): Promise<void> {
  if (!b.isActive) return
  const wasThere = b.base !== undefined
  const isThere = await checkBase($, b)
  if (isThere && !wasThere) await log($, b, `bridge folder found mod=${MOD_VERSION} entrypoint=${b.entrypoint}`)
  if (isThere) await writeLease($, b)
}

function stopTimers(b: Bridge): void {
  for (const timer of b.timers) timer.cancel()
  b.timers = []
}

export const register: Register = on => {
  const b: Bridge = {
    isActive: false,
    loadId: crypto.randomUUID().toLowerCase(),
    loadedAt: 0,
    entrypoint: 'unknown',
    dir: '',
    base: undefined,
    state: 'idle',
    turnId: undefined,
    timers: [],
    isPolling: false,
    claimed: new Set(),
    ended: new Set(),
    lastProblem: '',
    leaseChain: Promise.resolve(),
    logChain: Promise.resolve(),
    promptChain: Promise.resolve(),
  }

  on('session.start', async ($, e, next) => {
    stopTimers(b)
    b.isActive = false
    try {
      const entrypoint = (await $.env.get('CLAUDE_CODE_ENTRYPOINT')) ?? ''
      const allowSdk = (await $.env.get('STICKY_BRIDGE_ALLOW_SDK')) === '1'
      // A child of a chat's tools inherits its entrypoint: it never counts.
      const isChild = ((await $.env.get('CLAUDE_CODE_CHILD_SESSION')) ?? '') !== ''
      const isChatHost = !isChild && (entrypoint === 'claude-desktop' || (entrypoint === 'cli' && e.isInteractive))
      if (!isChatHost && !allowSdk) return next(e)

      const override = (await $.env.get('STICKY_BRIDGE_DIR')) ?? ''
      const home = (await $.env.get('HOME')) ?? ''
      const configured = override !== '' ? override : `${home}/Library/Application Support/Sticky/bridge`
      const dir = cleanDir(configured)
      if (dir === undefined || (override === '' && cleanDir(home) === undefined)) return next(e)

      b.isActive = true
      b.dir = dir
      b.entrypoint = entrypoint === '' ? 'unknown' : entrypoint
      b.loadedAt = await $.clock.now()
      b.state = 'idle'
      b.turnId = undefined
      if (await checkBase($, b)) {
        await log($, b, `load mod=${MOD_VERSION} entrypoint=${b.entrypoint} interactive=${e.isInteractive}`)
        await writeLease($, b)
      }
      b.timers = [
        $.clock.every(HEARTBEAT_MS, () => void heartbeat($, b)),
        $.clock.every(POLL_MS, () => void poll($, b)),
      ]
    } catch (err) {
      stopTimers(b)
      b.isActive = false
      await log($, b, `load failed: ${oneLine(errorText(err), 200)}`)
    }
    return next(e)
  })

  on('turn.start', ($, e, next) => {
    if (b.isActive && e.agentId === undefined) {
      b.turnId = e.turnId
      b.state = 'turn'
      void writeLease($, b)
      void log($, b, `turn.start ${short(e.turnId)}`)
    }
    return next(e)
  })

  on('turn.complete', ($, e, next) => {
    if (b.isActive && e.agentId === undefined) {
      if (b.turnId === e.turnId) b.turnId = undefined
      b.state = b.turnId === undefined ? 'idle' : 'turn'
      void writeLease($, b)
      void log($, b, `turn.complete ${short(e.turnId)} reason=${e.reason}`)
    }
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (b.isActive) {
      b.ended.add(e.sessionId)
      b.turnId = undefined
      // After a /clear (or a resume) the process goes on under a new id: keep
      // going for it. Any other end stops this load.
      if (e.reason === 'clear' || e.reason === 'resume') {
        b.state = 'idle'
      } else {
        b.isActive = false
        b.state = 'ended'
        stopTimers(b)
      }
      await writeLease($, b, e.sessionId)
      await log($, b, `session.end reason=${e.reason}`)
    }
    return next(e)
  })
}
