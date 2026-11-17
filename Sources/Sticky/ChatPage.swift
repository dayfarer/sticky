// The chat sticky's page: HTML, CSS and JS in one string, loaded with loadHTMLString (no network, no files).
//
// Swift talks to it with `chat.receive({op, …})`; the page answers through the "sticky" message handler.
// The protocol is described in the design notes; the JS below keeps one keyed DOM node per item, so an
// update to one message never redraws the others. Edit it like a normal web page: it's plain ES2020.

enum ChatPage {
    static let html: String = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chat</title>
<style>
/* MARK: - Colors (light, then dark) */
:root {
  color-scheme: light dark;
  --bg: #faf9f5;
  --raised: #ffffff;
  --text: #1f1e1d;
  --text-2: #5e5d58;
  --text-3: #8c8a83;
  --bubble: #f0eee6;
  --tint: rgba(31, 30, 29, 0.05);
  --tint-2: rgba(31, 30, 29, 0.085);
  --line: rgba(31, 30, 29, 0.1);
  --line-2: rgba(31, 30, 29, 0.17);
  --code: #f4f2ec;
  --icode: #9c4527;
  --link: #2e64a6;
  --accent: #c6613f;
  --accent-hover: #b4532f;
  --on-accent: #ffffff;
  --danger: #b2382e;
  --danger-tint: rgba(178, 56, 46, 0.075);
  --add: rgba(42, 150, 76, 0.13);
  --add-text: #20703a;
  --del: rgba(205, 60, 48, 0.12);
  --del-text: #a5352b;
  --shadow: 0 1px 2px rgba(31, 30, 29, 0.05), 0 3px 12px rgba(31, 30, 29, 0.05);
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
  --gutter: 14px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #262624;
    --raised: #30302e;
    --text: #efeee9;
    --text-2: #bdbbb1;
    --text-3: #8f8d85;
    --bubble: #1a1918;
    --tint: rgba(255, 255, 255, 0.05);
    --tint-2: rgba(255, 255, 255, 0.085);
    --line: rgba(255, 255, 255, 0.085);
    --line-2: rgba(255, 255, 255, 0.15);
    --code: #1e1d1c;
    --icode: #e8a68a;
    --link: #8db6ec;
    --accent: #d97757;
    --accent-hover: #e3876a;
    --on-accent: #ffffff;
    --danger: #f08478;
    --danger-tint: rgba(240, 132, 120, 0.09);
    --add: rgba(80, 190, 110, 0.15);
    --add-text: #86d49c;
    --del: rgba(240, 100, 88, 0.15);
    --del-text: #f2998f;
    --shadow: 0 1px 2px rgba(0, 0, 0, 0.25), 0 4px 16px rgba(0, 0, 0, 0.25);
  }
}

/* MARK: - Page */
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body {
  display: flex; flex-direction: column; overflow: hidden;
  background: var(--bg); color: var(--text);
  font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
  -webkit-font-smoothing: antialiased; -webkit-text-size-adjust: none;
}
button { font: inherit; color: inherit; }
[hidden] { display: none !important; }
svg.i { width: 14px; height: 14px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.35; stroke-linecap: round; stroke-linejoin: round; }
::-webkit-scrollbar { width: 9px; height: 9px; }
::-webkit-scrollbar-thumb { background: var(--tint-2); border-radius: 9px; border: 2px solid transparent; background-clip: padding-box; }
::-webkit-scrollbar-thumb:hover { background-color: var(--line-2); }
::-webkit-scrollbar-track, ::-webkit-scrollbar-corner { background: transparent; }

#pane { position: relative; flex: 1; min-height: 0; }
#scroll {
  position: absolute; inset: 0; overflow-y: auto; overflow-x: hidden; overflow-anchor: none;
  -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 12px), transparent);
}
#log { max-width: 760px; margin: 0 auto; padding: 12px var(--gutter) 14px; }
#center {
  position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
  padding: 24px; text-align: center; color: var(--text-3); pointer-events: none;
}
#center .empty { display: flex; flex-direction: column; align-items: center; gap: 10px; max-width: 260px; font-size: 13.5px; color: var(--text-2); }
#center .loading { display: flex; align-items: center; gap: 8px; }
#center .spark { width: 30px; height: 30px; }

#earlier { display: flex; justify-content: center; margin: 0 0 6px; }
#earlier button {
  border: 1px solid var(--line); background: transparent; border-radius: 99px;
  padding: 3px 12px; font-size: 11.5px; color: var(--text-2); cursor: pointer;
}
#earlier button:hover { background: var(--tint); color: var(--text); }
#earlier button:disabled { opacity: 0.6; cursor: default; }

/* MARK: Spacing between rows */
#items > *, #pending > *, #ghost > *, #queued > *, #working { margin-top: 10px; }
#items > .user, #pending > .user, #queued > .user { margin-top: 16px; }
#items > :first-child { margin-top: 2px; }
#items > .fold + .fold, #ghost > .fold + .fold { margin-top: 1px; }

/* MARK: - User bubble */
.user { display: flex; flex-direction: column; align-items: flex-end; }
.bubble {
  max-width: min(85%, 560px); background: var(--bubble); border-radius: 15px;
  padding: 7px 12px; overflow-wrap: anywhere;
}
.utext { white-space: pre-wrap; }
.utext.clip, .out.clip, .mono.clip { max-height: 19em; overflow: hidden; -webkit-mask-image: linear-gradient(#000 70%, transparent); }
.more {
  display: block; margin: 2px 0 0; padding: 0; border: 0; background: none; cursor: pointer;
  font-size: 11.5px; color: var(--text-3);
}
.more:hover { color: var(--text); }
.user .more { margin-left: auto; }
.imgs { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; max-width: 85%; }
.imgs + .bubble { margin-top: 6px; }
.thumb {
  display: block; max-width: min(200px, 100%); max-height: 150px; border-radius: 10px; cursor: zoom-in;
  background: var(--tint); min-width: 40px; min-height: 40px; object-fit: cover; border: 1px solid var(--line);
}
.thumb.wait { width: 120px; height: 84px; }
.thumb.gone { display: flex; align-items: center; justify-content: center; width: 90px; height: 60px; font-size: 11px; color: var(--text-3); cursor: default; }
.ustate { font-size: 11px; color: var(--text-3); margin: 3px 4px 0; display: flex; align-items: center; gap: 5px; }
.user.queued .bubble, .user.queued .imgs { opacity: 0.55; }
.user.sending .bubble, .user.sending .imgs { opacity: 0.85; }
.user.cancelled .bubble, .user.cancelled .imgs { opacity: 0.5; }
.user.cancelled .bubble { text-decoration: line-through; text-decoration-color: var(--text-3); }
.user.cancelled .ustate { color: var(--danger); }

/* MARK: - Assistant text (markdown) */
.asst { position: relative; }
.acopy {
  position: absolute; top: -4px; right: -4px; display: flex; align-items: center; gap: 4px;
  padding: 3px 7px; border: 1px solid var(--line); border-radius: 7px; background: var(--raised);
  color: var(--text-3); font-size: 11px; cursor: pointer; opacity: 0; transition: opacity 0.12s;
  box-shadow: var(--shadow);
}
.asst:hover .acopy { opacity: 1; }
.acopy:hover { color: var(--text); }
.md { line-height: 1.58; overflow-wrap: anywhere; }
.md > :first-child { margin-top: 0; }
.md > :last-child { margin-bottom: 0; }
.md p { margin: 0 0 0.62em; }
.md h1, .md h2, .md h3, .md h4, .md h5, .md h6 { margin: 1.05em 0 0.4em; line-height: 1.3; font-weight: 600; }
.md h1 { font-size: 1.27em; }
.md h2 { font-size: 1.15em; }
.md h3 { font-size: 1.04em; }
.md h4, .md h5, .md h6 { font-size: 1em; }
.md h5, .md h6 { color: var(--text-2); }
.md ul, .md ol { margin: 0 0 0.62em; padding-left: 1.45em; }
.md li { margin: 0.16em 0; }
.md li > ul, .md li > ol { margin: 0.16em 0 0.2em; }
.md li > p { margin: 0.3em 0; }
.md li::marker { color: var(--text-3); }
.md ul.tasks { padding-left: 0.2em; }
.md li.task { list-style: none; }
.md li.task > input { margin: 0 7px 0 0; vertical-align: -2px; }
.md blockquote { margin: 0 0 0.62em; padding: 0 0 0 0.85em; border-left: 3px solid var(--line-2); color: var(--text-2); }
.md hr { border: 0; border-top: 1px solid var(--line); margin: 1em 0; }
.md code { font-family: var(--mono); font-size: 0.87em; background: var(--tint-2); padding: 0.1em 0.36em; border-radius: 4px; color: var(--icode); }
.md a, .utext a { color: var(--link); text-decoration: underline; text-decoration-color: color-mix(in srgb, var(--link) 40%, transparent); text-underline-offset: 2px; cursor: pointer; }
.md a:hover, .utext a:hover { text-decoration-color: currentColor; }
.md .xl { border-bottom: 1px dotted var(--text-3); }
.md strong { font-weight: 600; }
.code { margin: 0 0 0.7em; border: 1px solid var(--line); border-radius: 9px; background: var(--code); overflow: hidden; }
.code-h {
  display: flex; align-items: center; justify-content: space-between; gap: 8px;
  padding: 2px 4px 2px 10px; font-size: 11px; color: var(--text-3); border-bottom: 1px solid var(--line);
  -webkit-user-select: none; user-select: none;
}
.code-h span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.copy {
  display: flex; align-items: center; gap: 4px; border: 0; background: none; color: var(--text-3);
  font-size: 11px; padding: 2px 6px; border-radius: 5px; cursor: pointer;
}
.copy:hover { background: var(--tint); color: var(--text); }
.code pre { margin: 0; padding: 8px 11px; overflow-x: auto; font: 11.5px/1.5 var(--mono); tab-size: 4; }
.code pre code { background: none; padding: 0; color: var(--text); font-size: inherit; border-radius: 0; }
.tbl { overflow-x: auto; margin: 0 0 0.7em; }
.md table { border-collapse: collapse; font-size: 12.5px; line-height: 1.45; }
.md th, .md td { border: 1px solid var(--line-2); padding: 4px 9px; text-align: left; vertical-align: top; }
.md th { background: var(--tint); font-weight: 600; }
.md .al-c { text-align: center; }
.md .al-r { text-align: right; }

/* MARK: - Folding rows (tools, thoughts, groups) */
.fold-h {
  display: flex; align-items: center; gap: 7px; min-height: 26px; padding: 3px 7px; margin: 0 -7px;
  border-radius: 7px; color: var(--text-2); font-size: 12.5px; cursor: default; -webkit-user-select: none; user-select: none; outline: none;
}
.fold-h:hover { background: var(--tint); color: var(--text); }
.fold-h:focus-visible { box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 45%, transparent); }
.fold-h .i { color: var(--text-3); }
.fold-h:hover .i { color: var(--text-2); }
.fold-h .t { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.fold-h .t code { font: 11.5px var(--mono); background: var(--tint-2); padding: 1px 4px; border-radius: 4px; }
.fold-h .chev { width: 12px; height: 12px; transition: transform 0.15s; }
.fold.open > .fold-h .chev { transform: rotate(90deg); }
.fold-h .gap { flex: 1; }
.fold-h .sep { color: var(--text-3); margin: 0 1px; }
.fold-h .last { color: var(--text-3); }
.fold-h:hover .last { color: var(--text-2); }
.bad { color: var(--danger); font-size: 11.5px; white-space: nowrap; }
.tool.err > .fold-h .i:first-child { color: var(--danger); }
.fold-b { margin: 2px 0 8px 21px; }
.group > .fold-b { margin: 1px 0 6px 6px; padding-left: 11px; border-left: 1px solid var(--line); }
.think-b { color: var(--text-2); font-size: 12.5px; padding: 1px 0 2px 10px; border-left: 2px solid var(--line); }
.spin {
  display: none; width: 11px; height: 11px; flex: none; border-radius: 50%;
  border: 1.5px solid var(--line-2); border-top-color: var(--text-2); animation: spin 0.8s linear infinite;
}
.spin.on, body.busy .pending > .fold-h .spin, body.busy .tsec.waiting .spin { display: inline-block; }
.nores { display: none; font-size: 11px; color: var(--text-3); white-space: nowrap; }
body:not(.busy) .pending > .fold-h .nores, body:not(.busy) .tsec.waiting .nores { display: inline; }
body.busy .tsec.waiting .run { display: inline; }
.run { display: none; font-size: 11px; color: var(--text-3); }

/* MARK: Tool details */
.tbody { border: 1px solid var(--line); border-radius: 9px; overflow: hidden; background: var(--code); }
.tsec + .tsec { border-top: 1px solid var(--line); }
.tlab {
  display: flex; align-items: center; justify-content: space-between; padding: 4px 4px 0 10px;
  font-size: 10.5px; letter-spacing: 0.03em; text-transform: uppercase; color: var(--text-3); -webkit-user-select: none; user-select: none;
}
.tlab .copy { text-transform: none; letter-spacing: 0; padding: 1px 6px; }
.mono {
  margin: 0; padding: 4px 10px 8px; font: 11.5px/1.5 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere;
  max-height: 60vh; overflow-y: auto;
}
.mono.clip { max-height: 14.5em; overflow: hidden; }
.tsec > .more { margin: -4px 10px 6px; }
.mono .ps { color: var(--text-3); -webkit-user-select: none; user-select: none; }
.tsec.bad-sec .mono { color: var(--danger); }
.tsec.bad-sec { background: var(--danger-tint); }
.tsec.waiting { display: flex; align-items: center; gap: 7px; padding: 7px 10px; font-size: 11.5px; }
.diff > div { padding: 0 10px; margin: 0 -10px; }
.diff .a { background: var(--add); color: var(--add-text); }
.diff .d { background: var(--del); color: var(--del-text); }
.diff .hk { color: var(--text-3); }
.timgs { display: flex; flex-wrap: wrap; gap: 6px; padding: 6px 10px 10px; }

/* MARK: - Small rows */
.divider { display: flex; align-items: center; gap: 10px; color: var(--text-3); font-size: 11.5px; margin: 18px 0 !important; }
.divider::before, .divider::after { content: ""; flex: 1; border-top: 1px solid var(--line); }
.chiprow { display: flex; justify-content: center; }
.chiprow.mine { justify-content: flex-end; }
.chip {
  display: inline-flex; align-items: center; gap: 6px; max-width: 90%; padding: 2px 10px;
  border-radius: 99px; background: var(--tint); color: var(--text-2); font-size: 11.5px; cursor: default;
}
.chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chip.full span { white-space: normal; }
.chip .i { width: 12px; height: 12px; color: var(--text-3); }
.out { margin: 0; padding: 7px 10px; border-radius: 9px; background: var(--code); border: 1px solid var(--line); font: 11.5px/1.5 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; }
.out .ps { color: var(--text-3); }
.notice { text-align: center; color: var(--text-3); font-size: 11.5px; }
.error {
  display: flex; gap: 8px; align-items: flex-start; padding: 7px 10px; border-radius: 9px;
  background: var(--danger-tint); color: var(--danger); font-size: 12.5px; overflow-wrap: anywhere;
}
.error .i { margin-top: 2px; }
.error .txt { white-space: pre-wrap; flex: 1; min-width: 0; }
.meta { color: var(--text-3); font-size: 11px; }
.interrupted { display: flex; align-items: center; gap: 6px; color: var(--text-3); font-size: 11.5px; }
.interrupted .i { width: 12px; height: 12px; }

/* MARK: Live reply */
.ghost-text > p:last-child::after, .ghost-text > ul:last-child > li:last-child::after, .ghost-text > ol:last-child > li:last-child::after {
  content: ""; display: inline-block; width: 7px; height: 7px; margin-left: 5px; border-radius: 50%;
  background: var(--accent); vertical-align: 1px; animation: pulse 1.1s ease-in-out infinite;
}
.shimmer {
  background: linear-gradient(90deg, var(--text-3) 0%, var(--text-3) 35%, var(--text) 50%, var(--text-3) 65%, var(--text-3) 100%);
  background-size: 300% 100%; -webkit-background-clip: text; background-clip: text; color: transparent;
  animation: shimmer 2.2s linear infinite;
}
#working { display: flex; align-items: center; gap: 8px; color: var(--text-3); font-size: 12.5px; min-height: 26px; }
.spark { width: 15px; height: 15px; fill: none; stroke: var(--accent); stroke-width: 2.6; stroke-linecap: round; }
#working .spark { animation: twirl 2.4s ease-in-out infinite; }

/* MARK: - Jump button */
#jump {
  position: absolute; left: 50%; bottom: 10px; transform: translateX(-50%); width: 30px; height: 30px;
  display: flex; align-items: center; justify-content: center; border-radius: 50%; cursor: pointer;
  border: 1px solid var(--line-2); background: var(--raised); color: var(--text-2); box-shadow: var(--shadow);
}
#jump:hover { color: var(--text); }
#jump .i { width: 15px; height: 15px; }

/* MARK: - Dock: permission cards, banner, composer, footer */
#dock { flex: none; padding: 0 10px 7px; }
#dock > * { max-width: 760px; margin-left: auto; margin-right: auto; }
#perms { max-height: 58vh; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; }
#perms:not(:empty) { padding: 2px 0 8px; }
.perm {
  flex: none; border: 1px solid var(--line-2); border-radius: 12px; background: var(--raised);
  padding: 10px 12px; box-shadow: var(--shadow);
}
.perm.done { opacity: 0.5; pointer-events: none; }
.ph { display: flex; gap: 8px; align-items: flex-start; }
.ph .i { margin-top: 2px; color: var(--accent); }
.pt { font-weight: 600; font-size: 12.5px; line-height: 1.45; overflow-wrap: anywhere; }  /* never cut: it says what you approve */
.pt code { font: 500 11.5px var(--mono); background: var(--tint-2); padding: 1px 4px; border-radius: 4px; }
.pdetail {
  margin: 8px 0 0; padding: 6px 9px; max-height: 40vh; overflow: auto; border-radius: 8px; background: var(--code);
  border: 1px solid var(--line); font: 11.5px/1.5 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere;
}
.pdetail.diff > div { padding: 0 9px; margin: 0 -9px; }
.pplan { margin: 8px 0 0; padding: 8px 11px; max-height: 40vh; overflow: auto; border-radius: 8px; background: var(--code); border: 1px solid var(--line); font-size: 12.5px; }
.preason { margin: 6px 0 0; color: var(--text-3); font-size: 11.5px; }
.pbtns {
  position: sticky; bottom: -8px; display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 6px;
  /* a little wider and lower than the card's content, so when it sticks over a long card no option shows around it */
  margin: 6px -4px -8px; padding: 4px 4px 8px; background: var(--raised);
}
.b {
  display: inline-flex; align-items: center; gap: 6px; padding: 4px 11px; min-height: 26px; border-radius: 8px;
  border: 1px solid var(--line-2); background: transparent; font-size: 12px; cursor: pointer; max-width: 100%;
}
.b > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.b.always > span { white-space: normal; text-align: left; overflow-wrap: anywhere; }  /* it names all it grants: show it all */
.b code { font: 11px var(--mono); }
.b:hover { background: var(--tint); }
.b.pri { background: var(--accent); border-color: var(--accent); color: var(--on-accent); font-weight: 500; }
.b.pri:hover { background: var(--accent-hover); }
.b:disabled { opacity: 0.45; cursor: default; }
kbd { display: none; font: 10.5px -apple-system, sans-serif; opacity: 0.65; }
.perm:first-child kbd { display: inline; }
.q { border: 0; margin: 10px 0 0; padding: 0; min-width: 0; }
.qh { display: inline-block; font-size: 10.5px; letter-spacing: 0.03em; text-transform: uppercase; color: var(--text-3); margin-bottom: 2px; }
.qq { font-size: 12.5px; margin-bottom: 5px; }
.opt {
  display: flex; gap: 8px; align-items: flex-start; padding: 5px 8px; margin: 0 -2px 3px; border-radius: 8px;
  border: 1px solid var(--line); cursor: pointer; font-size: 12.5px;
}
.opt:hover { background: var(--tint); }
.opt:has(input:checked) { border-color: color-mix(in srgb, var(--accent) 60%, transparent); background: color-mix(in srgb, var(--accent) 7%, transparent); }
.opt input[type=radio], .opt input[type=checkbox] { margin: 2px 0 0; }
input[type=radio], input[type=checkbox] {
  -webkit-appearance: none; appearance: none; position: relative; display: inline-block; flex: none;
  width: 14px; height: 14px; border: 1.5px solid var(--line-2); background: var(--raised); opacity: 1;
}
input[type=radio] { border-radius: 50%; }
input[type=checkbox] { border-radius: 4px; }
input[type=radio]:checked { border-color: var(--accent); background: radial-gradient(circle, var(--accent) 0 3.4px, var(--raised) 3.9px); }
input[type=checkbox]:checked { border-color: var(--accent); background: var(--accent); }
input[type=checkbox]:checked::after {
  content: ""; position: absolute; left: 3.4px; top: 0.6px; width: 3.4px; height: 7px;
  border: solid var(--on-accent); border-width: 0 1.7px 1.7px 0; transform: rotate(45deg);
}
.opt > span { display: flex; flex-direction: column; min-width: 0; flex: 1; }
.opt i { font-style: normal; color: var(--text-3); font-size: 11.5px; }
.otext { width: 100%; border: 0; background: transparent; font: inherit; color: var(--text); outline: none; padding: 0; }

#banner {
  display: flex; align-items: center; gap: 6px; padding: 0 4px 6px; font-size: 11.5px; color: var(--text-2);
  overflow-wrap: anywhere;
}
#banner.bad { color: var(--danger); white-space: normal; }  /* not the tool badge's nowrap */
#banner > span { min-width: 0; }
#banner .i { width: 13px; height: 13px; flex: none; }
#banner code { font: 11px var(--mono); background: var(--tint-2); padding: 0 4px; border-radius: 4px; }

#composer {
  position: relative; border: 1px solid var(--line-2); border-radius: 15px; background: var(--raised);
  box-shadow: var(--shadow); padding: 5px 5px 5px 12px; transition: border-color 0.15s;
}
#composer:focus-within { border-color: color-mix(in srgb, var(--text) 28%, transparent); }
#composer.drop { border-color: var(--accent); border-style: dashed; }
#composer .row { display: flex; align-items: flex-end; gap: 6px; }
#input {
  flex: 1; min-width: 0; border: 0; outline: none; resize: none; background: transparent; color: var(--text);
  font: inherit; font-size: 13px; line-height: 1.45; padding: 4px 0; height: 27px; max-height: 40vh; overflow-y: hidden;
}
#input::placeholder { color: var(--text-3); }
#input:disabled { cursor: not-allowed; }
#send {
  flex: none; width: 27px; height: 27px; border-radius: 50%; border: 0; display: flex; align-items: center;
  justify-content: center; background: var(--accent); color: var(--on-accent); cursor: pointer; transition: opacity 0.12s, background 0.12s;
}
#send:hover { background: var(--accent-hover); }
#send:disabled { cursor: default; background: var(--tint-2); color: var(--text-3); }
#send .i { width: 15px; height: 15px; stroke-width: 1.8; }
#send.stop { background: var(--text); color: var(--bg); }
#send.stop .i { width: 10px; height: 10px; fill: currentColor; stroke: none; }
#thumbs { display: flex; flex-wrap: wrap; gap: 6px; padding: 3px 0 5px; }
.att { position: relative; }
.att img { display: block; width: 46px; height: 46px; object-fit: cover; border-radius: 8px; border: 1px solid var(--line); }
.att button {
  position: absolute; top: -5px; right: -5px; width: 17px; height: 17px; padding: 0; border-radius: 50%;
  border: 1px solid var(--line-2); background: var(--raised); color: var(--text-2); display: flex; align-items: center; justify-content: center; cursor: pointer;
}
.att button .i { width: 9px; height: 9px; stroke-width: 2; }

#footer {
  display: flex; align-items: center; gap: 11px; padding: 6px 5px 0; font-size: 11.5px; color: var(--text-3);
  white-space: nowrap; -webkit-user-select: none; user-select: none; min-width: 0;
}
#footer .fi { display: flex; align-items: center; gap: 4px; min-width: 0; overflow: hidden; }
#footer .fi span { overflow: hidden; text-overflow: ellipsis; }
#footer .i { width: 12px; height: 12px; }
#footer #fFolder { flex: 0 3 auto; min-width: 12px; }   /* folder and branch give way before the menus */
#fBranch { flex: 0 4 auto; }
#fCost { margin-left: auto; flex: none; }
.menu { position: relative; display: flex; align-items: center; gap: 3px; padding: 1px 5px; margin: 0 -5px; border-radius: 6px; flex: 0 1 auto; min-width: 0; }
.menu .lbl { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.menu .dot, .menu .i { flex: none; }
.menu:hover { background: var(--tint); color: var(--text-2); }
.menu select { position: absolute; inset: 0; width: 100%; opacity: 0; cursor: pointer; font-size: 13px; }
.menu .i { width: 9px; height: 9px; stroke-width: 1.8; }
.dot { width: 6px; height: 6px; border-radius: 50%; background: var(--text-3); }
.dot.acceptEdits { background: #8b6fd6; }
.dot.plan { background: #3e9f8f; }
.dot.auto { background: var(--accent); }
.dot.bypassPermissions { background: var(--danger); }

#lightbox {
  position: fixed; inset: 0; z-index: 10; display: flex; align-items: center; justify-content: center; padding: 16px;
  background: color-mix(in srgb, var(--bg) 88%, transparent); cursor: zoom-out;
}
#lightbox img { max-width: 100%; max-height: 100%; border-radius: 8px; box-shadow: var(--shadow); }

/* MARK: Narrow windows */
@media (max-width: 360px) {
  :root { --gutter: 10px; }
  #dock { padding: 0 7px 6px; }
  .bubble { max-width: 92%; }
  #footer #fBranch { display: none; }
  #footer { gap: 9px; }
  .fold-b { margin-left: 12px; }
  .perm { padding: 9px 10px; }
}

@keyframes spin { to { transform: rotate(360deg); } }
@keyframes pulse { 0%, 100% { opacity: 0.35; transform: scale(0.8); } 50% { opacity: 1; transform: scale(1); } }
@keyframes shimmer { from { background-position: 100% 0; } to { background-position: 0 0; } }
@keyframes twirl { 0% { transform: rotate(0) scale(0.9); } 50% { transform: rotate(90deg) scale(1.08); } 100% { transform: rotate(180deg) scale(0.9); } }
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01s !important; animation-iteration-count: 1 !important; transition: none !important; }
}
</style>
</head>
<body>
<div id="pane">
  <main id="scroll">
    <div id="log">
      <div id="earlier" hidden><button id="earlierBtn" type="button">Load earlier messages</button></div>
      <div id="items"></div>
      <div id="pending"></div>
      <div id="ghost"></div>
      <div id="working" hidden></div>
      <div id="queued"></div>
    </div>
  </main>
  <div id="center" hidden></div>
  <button id="jump" type="button" title="Jump to the latest" hidden></button>
</div>
<div id="dock">
  <div id="perms"></div>
  <div id="banner" hidden></div>
  <div id="composer">
    <div id="thumbs" hidden></div>
    <div class="row">
      <textarea id="input" rows="1" placeholder="Message Claude" spellcheck="true"></textarea>
      <button id="send" type="button" title="Send (Return)" disabled></button>
    </div>
  </div>
  <div id="footer">
    <span id="fFolder" class="fi" hidden></span>
    <span id="fBranch" class="fi" hidden></span>
    <label id="fMode" class="menu" hidden><span class="dot"></span><span class="lbl"></span><select aria-label="Permission mode"></select></label>
    <label id="fModel" class="menu" hidden><span class="lbl"></span><select aria-label="Model"></select></label>
    <span id="fCost" class="fi" hidden></span>
  </div>
</div>
<div id="lightbox" hidden><img alt=""></div>
<script>
"use strict";

// MARK: - Basics

const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
/** Escapes text for HTML (also safe inside attribute values). */
function esc(s) { return String(s ?? "").replace(/[&<>"']/g, (c) => ESC[c]); }

const svg = (d, cls) => `<svg class="i${cls ? " " + cls : ""}" viewBox="0 0 16 16" aria-hidden="true">${d}</svg>`;
const I = {
  chev: svg('<path d="M6 4l4 4-4 4"/>', "chev"),
  down: svg('<path d="M4 6l4 4 4-4"/>'),
  term: svg('<rect x="2" y="2.8" width="12" height="10.4" rx="2"/><path d="M5 6.4l1.9 1.6L5 9.6M8.6 10h2.6"/>'),
  file: svg('<path d="M4.5 2h4.2L12 5.3v8.2a.5.5 0 0 1-.5.5h-7a.5.5 0 0 1-.5-.5v-11a.5.5 0 0 1 .5-.5z"/><path d="M8.5 2.2v3.3h3.3"/>'),
  pencil: svg('<path d="M10.6 2.9l2.5 2.5-7.4 7.4-3.1.6.6-3.1z"/><path d="M9.2 4.3l2.5 2.5"/>'),
  search: svg('<circle cx="7" cy="7" r="4.3"/><path d="M10.2 10.2l3.4 3.4"/>'),
  globe: svg('<circle cx="8" cy="8" r="5.8"/><path d="M2.3 8h11.4M8 2.2c1.8 2.1 1.8 9.5 0 11.6M8 2.2c-1.8 2.1-1.8 9.5 0 11.6"/>'),
  list: svg('<path d="M6.2 4.5h7.3M6.2 8h7.3M6.2 11.5h7.3"/><circle cx="3.2" cy="4.5" r=".6"/><circle cx="3.2" cy="8" r=".6"/><circle cx="3.2" cy="11.5" r=".6"/>'),
  agent: svg('<circle cx="8" cy="5.6" r="2.6"/><path d="M3 13.6c.9-2.4 2.8-3.7 5-3.7s4.1 1.3 5 3.7"/>'),
  plug: svg('<path d="M6 2v3M10 2v3M4.4 5h7.2v2.4a3.6 3.6 0 0 1-7.2 0zM8 11v3"/>'),
  ask: svg('<circle cx="8" cy="8" r="5.8"/><path d="M6.4 6.4a1.7 1.7 0 1 1 2.9 1.2c-.6.5-1.3.8-1.3 1.8"/><circle cx="8" cy="11.4" r=".4"/>'),
  tool: svg('<path d="M9.7 2.5a3.2 3.2 0 0 0-3.5 4.4L2.5 10.6a1.3 1.3 0 0 0 1.9 1.9l3.7-3.7a3.2 3.2 0 0 0 4.4-3.5l-1.9 1.9-1.8-.3-.3-1.8z"/>'),
  bulb: svg('<path d="M6 12h4M6.6 14h2.8M8 2a4.1 4.1 0 0 0-2.6 7.3c.5.4.7.9.7 1.5v.2h3.8v-.2c0-.6.2-1.1.7-1.5A4.1 4.1 0 0 0 8 2z"/>'),
  layers: svg('<path d="M8 2.3l5.7 3-5.7 3-5.7-3z"/><path d="M2.3 8.3l5.7 3 5.7-3"/><path d="M2.3 11.1l5.7 3 5.7-3"/>'),
  book: svg('<path d="M3 3.2c1.8-.5 3.5-.3 5 .8 1.5-1.1 3.2-1.3 5-.8v9.6c-1.8-.5-3.5-.3-5 .8-1.5-1.1-3.2-1.3-5-.8zM8 4v9.6"/>'),
  copy: svg('<rect x="5.5" y="5.5" width="8" height="8" rx="1.6"/><path d="M10.5 5.5V4a1.5 1.5 0 0 0-1.5-1.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5"/>'),
  check: svg('<path d="M3.5 8.4l2.9 2.9 6.1-6.6"/>'),
  up: svg('<path d="M8 13V3.6M3.8 7.6L8 3.4l4.2 4.2"/>'),
  stop: '<svg class="i" viewBox="0 0 10 10" aria-hidden="true"><rect width="10" height="10" rx="2"/></svg>',
  arrowDown: svg('<path d="M8 3v9.6M3.8 8.4L8 12.6l4.2-4.2"/>'),
  x: svg('<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>'),
  folder: svg('<path d="M2.2 4.4a1.2 1.2 0 0 1 1.2-1.2h2.9l1.5 1.5h4.8a1.2 1.2 0 0 1 1.2 1.2v5.9a1.2 1.2 0 0 1-1.2 1.2H3.4a1.2 1.2 0 0 1-1.2-1.2z"/>'),
  branch: svg('<circle cx="5" cy="3.8" r="1.5"/><circle cx="5" cy="12.2" r="1.5"/><circle cx="11" cy="5.4" r="1.5"/><path d="M5 5.3v5.4M11 6.9c0 2.6-6 1.7-6 3.8"/>'),
  stopCircle: svg('<circle cx="8" cy="8" r="5.8"/><rect x="6" y="6" width="4" height="4" rx=".6"/>'),
  warn: svg('<path d="M8 2.6l5.9 10.2H2.1z"/><path d="M8 6.6v3"/><circle cx="8" cy="11.2" r=".35"/>'),
  info: svg('<circle cx="8" cy="8" r="5.8"/><path d="M8 7.3v3.6"/><circle cx="8" cy="5.2" r=".35"/>'),
  lock: svg('<rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5.2a2.5 2.5 0 0 1 5 0V7"/>'),
  app: svg('<rect x="2.2" y="3" width="11.6" height="9.6" rx="2"/><path d="M2.2 6h11.6"/>'),
  slash: svg('<path d="M10.5 2.5l-5 11"/>'),
  bell: svg('<path d="M4.2 11V7.4a3.8 3.8 0 0 1 7.6 0V11l1 1.3H3.2zM6.6 13.6a1.5 1.5 0 0 0 2.8 0"/>'),
  people: svg('<circle cx="6" cy="6" r="2.2"/><path d="M2.2 13c.6-2 2-3 3.8-3s3.2 1 3.8 3"/><circle cx="11.2" cy="5.6" r="1.8"/><path d="M10.6 9.6c1.6 0 2.7.9 3.2 2.6"/>'),
  plan: svg('<rect x="3" y="2.5" width="10" height="11" rx="1.6"/><path d="M5.6 6h4.8M5.6 8.5h4.8M5.6 11h2.8"/>'),
};
const SPARK = '<svg class="spark" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v5.5M12 15.5V21M3 12h5.5M15.5 12H21M5.6 5.6l3.9 3.9M14.5 14.5l3.9 3.9M18.4 5.6l-3.9 3.9M9.5 14.5l-3.9 3.9"/></svg>';

// MARK: - Markdown
//
// Our own small renderer. Every bit of the source goes through esc() before it reaches the HTML,
// and the only tags in the output are ones written here, so a message can never inject markup.
// Blocks: headings, paragraphs, fenced code, lists (nested by indent, task items), quotes, tables, rules.
// Inline: code spans, links and autolinks, bold / italic / strike, backslash escapes, line breaks.

const RE = {
  fence: /^(\s*)(`{3,}|~{3,})(.*)$/,
  fenceEnd: /^\s*(`{3,}|~{3,})\s*$/,
  heading: /^ {0,3}(#{1,6})[ \t]+(.*)$/,   // closing #s are cut by headingText (a regex for them is slow on long space runs)
  hr: /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/,
  quote: /^ {0,3}>/,
  list: /^( *)([-*+]|\d{1,9}[.)])([ \t]+|$)(.*)$/,
  delim: /^\|? *:?-+:? *(?:\| *:?-+:? *)*\|?$/,   // on a trimmed line; no two " *" side by side, so it can't backtrack badly
  task: /^\[([ xX])\](?:[ \t]+|$)/,
};
const PH = /[]/g; // placeholder marks used by inline(); stripped from the source

/** Markdown → HTML. */
function md(src) {
  const lines = String(src ?? "").replace(PH, "").replace(/\r\n?/g, "\n").split("\n")
    .map((l) => l.replace(/^\t+/, (t) => "    ".repeat(t.length)));
  return blocks(lines, false);
}

function indentOf(l) { return l.length - l.trimStart().length; }
function dedent(l, n) { let k = 0; while (k < n && l[k] === " ") k++; return l.slice(k); }
function isFence(l) { const m = RE.fence.exec(l); return !!m && !(m[2][0] === "`" && m[3].includes("`")); }
function isTable(l, next) { return l.includes("|") && next != null && next.includes("|") && RE.delim.test(next.trim()); }
/** A heading's text without trailing spaces and the optional closing #s ("## Title ##"). */
function headingText(t) {
  t = t.trimEnd();
  let k = t.length;
  while (k > 0 && t[k - 1] === "#") k--;
  if (k > 0 && k < t.length && (t[k - 1] === " " || t[k - 1] === "\t")) t = t.slice(0, k).trimEnd();
  return t;
}
function startsBlock(l, next) {
  return isFence(l) || RE.heading.test(l) || RE.hr.test(l) || RE.quote.test(l) || RE.list.test(l) || isTable(l, next);
}

/** Renders a run of lines. `tight`: the first paragraph comes out without <p> (list items). */
function blocks(lines, tight) {
  let out = "", para = [], i = 0;
  const flush = () => {
    if (!para.length) return;
    const html = inline(para.join("\n"));
    out += tight && !out ? html : "<p>" + html + "</p>";
    para = [];
  };
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { flush(); i++; continue; }
    let m;
    if (isFence(line)) {
      flush();
      m = RE.fence.exec(line);
      const ind = m[1].length, mark = m[2], body = [];
      for (i++; i < lines.length; i++) {
        const e = RE.fenceEnd.exec(lines[i]);
        if (e && e[1][0] === mark[0] && e[1].length >= mark.length) { i++; break; }
        body.push(dedent(lines[i], ind));
      }
      out += codeBlock(body.join("\n"), m[3].trim().split(/\s+/)[0]);
      continue;
    }
    if ((m = RE.heading.exec(line))) {
      flush();
      const n = m[1].length;
      out += `<h${n}>${inline(headingText(m[2]))}</h${n}>`;
      i++; continue;
    }
    if (RE.hr.test(line)) { flush(); out += "<hr>"; i++; continue; }
    if (RE.quote.test(line)) {
      flush();
      const q = [];
      while (i < lines.length && RE.quote.test(lines[i])) { q.push(lines[i].replace(/^ {0,3}> ?/, "")); i++; }
      out += "<blockquote>" + blocks(q, false) + "</blockquote>";
      continue;
    }
    if (isTable(line, lines[i + 1])) {
      const head = cells(line), al = cells(lines[i + 1]).map(alignOf);
      if (head.length === al.length) {
        flush();
        const row = (cs, tag) => "<tr>" + al.map((a, k) => `<${tag}${a ? ` class="${a}"` : ""}>${inline(cs[k] ?? "")}</${tag}>`).join("") + "</tr>";
        let t = "<thead>" + row(head, "th") + "</thead><tbody>";
        for (i += 2; i < lines.length && lines[i].trim() && lines[i].includes("|"); i++) t += row(cells(lines[i]), "td");
        out += `<div class="tbl"><table>${t}</tbody></table></div>`;
        continue;
      }
    }
    if (RE.list.test(line)) {
      flush();
      const r = list(lines, i);
      out += r.html; i = r.i;
      continue;
    }
    para.push(line.trim());
    i++;
  }
  flush();
  return out;
}

/** One list starting at line i, with its nested content. Returns the HTML and the next line. */
function list(lines, i) {
  const m0 = RE.list.exec(lines[i]);
  const base = m0[1].length, ordered = /\d/.test(m0[2]);
  const items = [];
  let cur = null, blank = false;
  while (i < lines.length) {
    const l = lines[i], ind = indentOf(l), m = RE.list.exec(l);
    if (m && ind <= base) {
      if (/\d/.test(m[2]) !== ordered) break;          // another kind of list starts here
      const ci = m[1].length + m[2].length + (m[4] ? Math.min(m[3].length, 4) : 1);
      cur = { ci, body: [m[4]] };
      items.push(cur); blank = false; i++;
      continue;
    }
    if (!l.trim()) { cur.body.push(""); blank = true; i++; continue; }
    if (ind > base) { cur.body.push(dedent(l, cur.ci)); blank = false; i++; continue; }
    if (!blank && !startsBlock(l, lines[i + 1])) { cur.body.push(l.trim()); i++; continue; }  // lazy continuation
    break;
  }
  const tag = ordered ? "ol" : "ul";
  const start = ordered ? parseInt(m0[2], 10) : 1;
  let html = "", tasks = false;
  for (const it of items) {
    while (it.body.length && !it.body[it.body.length - 1].trim()) it.body.pop();
    const t = RE.task.exec(it.body[0] || "");
    if (t) {
      tasks = true;
      it.body[0] = it.body[0].slice(t[0].length);
      html += `<li class="task"><input type="checkbox" disabled${t[1] === " " ? "" : " checked"}>${blocks(it.body, true)}</li>`;
    } else {
      html += `<li>${blocks(it.body, true)}</li>`;
    }
  }
  const attrs = (ordered && start !== 1 ? ` start="${start}"` : "") + (tasks ? ' class="tasks"' : "");
  return { html: `<${tag}${attrs}>${html}</${tag}>`, i };
}

/** Splits a table row on unescaped pipes (like GitHub, even inside backticks). */
function cells(row) {
  let s = row.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
  const out = [];
  let cur = "";
  for (let k = 0; k < s.length; k++) {
    if (s[k] === "\\" && s[k + 1] === "|") { cur += "|"; k++; continue; }
    if (s[k] === "|") { out.push(cur.trim()); cur = ""; continue; }
    cur += s[k];
  }
  out.push(cur.trim());
  return out;
}
function alignOf(c) {
  const l = c.startsWith(":"), r = c.endsWith(":");
  return l && r ? "al-c" : r ? "al-r" : "";
}

function codeBlock(code, lang) {
  return `<div class="code"><div class="code-h"><span>${esc(lang || "")}</span>` +
    `<button class="copy" type="button" data-copy>${I.copy}<span>Copy</span></button></div>` +
    `<pre><code>${esc(code)}</code></pre></div>`;
}

/** Inline markdown → HTML. `noLinks` inside link text. */
function inline(src, noLinks) {
  const s = String(src ?? "").replace(PH, "");
  const keep = [];
  const hold = (html) => "" + (keep.push(html) - 1) + "";
  const special = /[`\\[<]|!\[|https?:\/\//g;
  let text = "", i = 0;
  let close = -1;  // next "]" at or after i (so a text with no "]" left skips the link scan)
  while (i < s.length) {
    special.lastIndex = i;
    const f = special.exec(s);
    if (!f) { text += s.slice(i); break; }
    text += s.slice(i, f.index);
    i = f.index;
    const c = s[i];
    if (c === "`") {
      let r = 1;
      while (s[i + r] === "`") r++;
      const close = findTicks(s, i + r, r);
      if (close < 0) { text += s.slice(i, i + r); i += r; continue; }
      let code = s.slice(i + r, close).replace(/\n/g, " ");
      if (code.length > 1 && code[0] === " " && code[code.length - 1] === " " && code.trim()) code = code.slice(1, -1);
      text += hold("<code>" + esc(code) + "</code>");
      i = close + r;
      continue;
    }
    if (c === "\\") {
      const n = s[i + 1];
      if (n === "\n") { text += "\n"; i += 2; continue; }
      if (n && /[!-\/:-@\[-`{-~]/.test(n)) { text += hold(esc(n)); i += 2; continue; }
      text += c; i++;
      continue;
    }
    if (!noLinks && (c === "[" || c === "!")) {
      const img = c === "!";
      if (close !== Infinity && close < i) { close = s.indexOf("]", i); if (close < 0) close = Infinity; }
      const L = close === Infinity ? null : linkAt(s, img ? i + 1 : i);
      if (L) {
        const label = L.text.trim() ? inline(L.text, true) : esc(L.url);
        text += hold(linkHtml(L.url, label));
        i = L.end;
        continue;
      }
      text += c; i++;
      continue;
    }
    if (c === "<") {
      const m = /^<((?:https?:\/\/|mailto:)[^\s<>]+)>/i.exec(s.slice(i, i + 2100));
      if (m && !noLinks) { text += hold(linkHtml(m[1], esc(m[1]))); i += m[0].length; continue; }
      text += c; i++;
      continue;
    }
    if (c === "h") {
      const prev = s[i - 1];
      const m = /^https?:\/\/[^\s<>"]+/.exec(s.slice(i, i + 2100));
      if (m && !noLinks && !(prev && /[\w\/]/.test(prev))) {
        const u = trimUrl(m[0]);
        if (u.length > 8) { text += hold(linkHtml(u, esc(u))); i += u.length; continue; }
      }
      text += c; i++;
      continue;
    }
    text += c; i++;
  }
  // line breaks; trimEnd (not a regex) so a long run of spaces can't take quadratic time
  let h = emphasis(esc(text)).split("\n").map((l) => l.trimEnd()).join("<br>");
  return h.replace(/(\d+)/g, (_, n) => keep[+n]);
}

function findTicks(s, from, r) {
  const end = Math.min(s.length, from + 20000);
  for (let k = from; k < end; k++) {
    if (s[k] !== "`") continue;
    let n = 1;
    while (s[k + n] === "`") n++;
    if (n === r) return k;
    k += n - 1;
  }
  return -1;
}

/** `[text](url "title")` starting at s[i] === "[". Parentheses in the URL may nest. */
function linkAt(s, i) {
  if (s[i] !== "[") return null;
  let depth = 0, j = i;
  for (; j < s.length; j++) {
    if (j - i > 2000) return null;   // before the bracket checks, so a run of "[" can't scan the whole text
    const c = s[j];
    if (c === "\\") { j++; continue; }
    if (c === "[") depth++;
    else if (c === "]" && --depth === 0) break;
  }
  if (j >= s.length || s[j + 1] !== "(") return null;
  let k = j + 2;
  while (s[k] === " ") k++;
  let url;
  if (s[k] === "<") {
    const e = s.indexOf(">", k);
    if (e < 0) return null;
    url = s.slice(k + 1, e);
    k = e + 1;
  } else {
    const st = k;
    let d = 0;
    for (; k < s.length; k++) {
      const c = s[k];
      if (c === "\\") { k++; continue; }
      if (c === "(") d++;
      else if (c === ")") { if (d === 0) break; d--; }
      else if (c === " " || c === "\n" || k - st > 4000) break;
    }
    url = s.slice(st, k);
  }
  while (s[k] === " ") k++;
  if (s[k] === '"' || s[k] === "'") {
    const e = s.indexOf(s[k], k + 1);
    if (e < 0) return null;
    k = e + 1;
    while (s[k] === " ") k++;
  }
  if (s[k] !== ")") return null;
  return { text: s.slice(i + 1, j), url: url.trim(), end: k + 1 };
}

/** Only http(s) and mailto links are clickable; anything else (files, javascript:) is shown as plain text. */
function linkHtml(url, inner) {
  if (/^(https?:\/\/|mailto:)/i.test(url)) return `<a href="${esc(url)}" title="${esc(url)}">${inner}</a>`;
  return `<span class="xl" title="${esc(url)}">${inner}</span>`;
}

/** Drops trailing punctuation and unbalanced closing brackets from a bare URL. */
function trimUrl(u) {
  const count = (ch) => u.split(ch).length - 1;
  while (u.length > 8) {
    const c = u[u.length - 1];
    if (/[.,:;!?'"*_~]/.test(c)) u = u.slice(0, -1);
    else if (c === ")" && count("(") < count(")")) u = u.slice(0, -1);
    else if (c === "]" && count("[") < count("]")) u = u.slice(0, -1);
    else break;
  }
  return u;
}

/** Bold, italic and strike on already-escaped text. Spans are capped in length so odd text can't stall the page. */
function emphasis(h) {
  return h
    .replace(/\*\*\*(?=\S)([\s\S]{0,1500}?\S)\*\*\*/g, "<strong><em>$1</em></strong>")
    .replace(/\*\*(?=\S)([\s\S]{0,1500}?\S)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^\w])__(?=\S)([\s\S]{0,1500}?\S)__(?!\w)/g, "$1<strong>$2</strong>")
    .replace(/~~(?=\S)([\s\S]{0,1500}?\S)~~/g, "<del>$1</del>")
    .replace(/(^|[^\w*])\*(?=[^\s*])([^*\n]{0,800}?[^\s*])\*(?![\w*])/g, "$1<em>$2</em>")
    .replace(/(^|[^\w])_(?=[^\s_])([^_\n]{0,800}?[^\s_])_(?!\w)/g, "$1<em>$2</em>");
}

/** A user's message: plain text, kept as typed, with bare links clickable. Newlines are kept by CSS. */
function userText(src) {
  const s = String(src ?? "");
  const re = /https?:\/\/[^\s<>"]+/g;
  let out = "", last = 0, m;
  while ((m = re.exec(s))) {
    const u = trimUrl(m[0]);
    if (u.length <= 8) continue;
    out += esc(s.slice(last, m.index)) + linkHtml(u, esc(u));
    last = m.index + u.length;
    re.lastIndex = last;
  }
  return out + esc(s.slice(last));
}

/** One-line titles: plain text with `code` spans. */
function titleHtml(src) {
  const s = String(src ?? "");
  const re = /`([^`\n]+)`/g;
  let out = "", last = 0, m;
  while ((m = re.exec(s))) {
    out += esc(s.slice(last, m.index)) + "<code>" + esc(m[1]) + "</code>";
    last = re.lastIndex;
  }
  return out + esc(s.slice(last));
}

// MARK: - Page
//
// Everything below needs a DOM. It starts at the bottom of this script (start()).

const $ = (id) => document.getElementById(id);
function el(tag, cls, html) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
}

/** Puts `els` into `box` in this order, moving only what has to move: a node that stays keeps its focus
 *  (a half-typed "Other…" answer) and its text selection. */
function syncChildren(box, els) {
  const keep = new Set(els);
  for (const c of [...box.childNodes]) if (!keep.has(c)) c.remove();
  let cur = box.firstChild;
  for (const e of els) {
    if (cur === e) cur = cur.nextSibling;
    else box.insertBefore(e, cur);
  }
}

/** Sends a message to Swift. Resolves with Swift's reply (or null when there is no Swift, e.g. in a browser).
 *  If Swift answers with an error, resolves with {ok:false, error}, so a failed send isn't taken for a sent one. */
function bridge(msg) {
  const fail = (e) => ({ ok: false, error: String((e && e.message) || e || "") });
  try {
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sticky;
    if (h) return Promise.resolve(h.postMessage(msg)).catch(fail);
  } catch (e) { return Promise.resolve(fail(e)); }
  return Promise.resolve(null);
}

const S = {
  items: [],
  index: new Map(),        // item id → position in items
  hasEarlier: false,
  pending: [],
  ghost: [],
  perms: [],
  status: { title: "", folder: "", running: false, busyElsewhere: false, liveElsewhere: false, mode: "default", modes: [], models: [], loading: false },
  open: new Set(),         // keys of expanded rows (survives re-renders)
};

let sc, ta;                // the scroller and the composer's textarea

// MARK: Messages from Swift

function receive(m) {
  if (!m || typeof m !== "object") return;
  switch (m.op) {
    case "reset": {
      S.hasEarlier = !!m.hasEarlier;
      setItems(m.items || []);
      itemEls.clear(); blockEls.clear();
      images.clear();  // image keys are byte offsets: after a reset (new file, rewrite) they can mean other images
      $("items").replaceChildren();
      renderItems();
      resetEarlierButton();
      jumpToEnd();
      break;
    }
    case "prepend": {
      const fresh = (m.items || []).filter((it) => it && !S.index.has(it.id));
      S.hasEarlier = !!m.hasEarlier;
      const keep = sc.scrollHeight - sc.scrollTop;
      setItems(fresh.concat(S.items));
      renderItems();
      resetEarlierButton();
      setTop(sc.scrollHeight - keep);
      break;
    }
    case "upsert": {
      for (const it of m.items || []) {
        if (!it || it.id == null) continue;
        const k = S.index.get(it.id);
        if (k != null) S.items[k] = it;
        else { S.index.set(it.id, S.items.length); S.items.push(it); }
      }
      renderItems();
      grew();
      break;
    }
    case "pending": S.pending = m.items || []; renderPending(); grew(); break;
    case "ghost": S.ghost = m.blocks || []; renderGhost(); grew(); break;
    case "permissions": S.perms = m.requests || []; renderPerms(); renderWorking(); break;
    case "status": setStatus(m.s || {}); break;
    case "focus": ta.focus(); break;
  }
}

function setItems(list) {
  S.items = list.filter((it) => it && it.id != null);
  S.index = new Map(S.items.map((it, k) => [it.id, k]));
}

// MARK: - Items (keyed DOM)
//
// Consecutive tool / thinking items between texts become one "group" row. Each item keeps one
// element (rebuilt only when Swift sends a new version of it); each group keeps one element too.

const itemEls = new Map();   // id → { it, el }
const blockEls = new Map();  // group key → { members, el }
const GROUPED = new Set(["tool", "thinking"]);

function makeBlocks(items) {
  const out = [];
  let g = null;
  for (const it of items) {
    if (GROUPED.has(it.kind)) {
      if (!g) { g = { key: "g:" + it.id, members: [] }; out.push(g); }
      g.members.push(it);
    } else {
      g = null;
      out.push({ key: it.id, item: it });
    }
  }
  return out.map((b) => (b.members && b.members.length === 1 ? { key: b.members[0].id, item: b.members[0] } : b));
}

function elFor(it) {
  const c = itemEls.get(it.id);
  if (c && c.it === it) return c.el;
  let e;
  try { e = buildItem(it); } catch (err) { console.error(err); e = el("div", "notice", esc(it.text || "")); }
  itemEls.set(it.id, { it, el: e });
  return e;
}

function blockEl(b) {
  if (b.item) return elFor(b.item);
  let c = blockEls.get(b.key);
  if (!c) {
    // a row you opened (a running tool, say) that now joins a group: the group opens too, so it stays in view
    if (b.members.some((m) => S.open.has(m.id))) S.open.add(b.key);
    const e = el("div", "fold group");
    e.dataset.k = b.key;
    e.append(el("div", "fold-h"));
    c = { members: null, el: e };
    blockEls.set(b.key, c);
  }
  const same = c.members && c.members.length === b.members.length && c.members.every((m, k) => m === b.members[k]);
  if (!same) {
    c.members = b.members.slice();
    const members = c.members;
    c.el._body = () => members.map(elFor);
    fillGroupHead(c.el, members);  // reopens it if it was open
  }
  return c.el;
}

function renderItems() {
  const box = $("items");
  const blocks = makeBlocks(S.items);
  const els = blocks.map(blockEl);  // first, so groups can claim their members
  let cur = box.firstChild;
  for (const e of els) {
    if (cur === e) cur = cur.nextSibling;
    else box.insertBefore(e, cur);
  }
  while (cur) { const n = cur.nextSibling; cur.remove(); cur = n; }
  const keys = new Set(blocks.map((b) => b.key));
  for (const k of blockEls.keys()) if (!keys.has(k)) blockEls.delete(k);
  if (itemEls.size > S.items.length) for (const k of itemEls.keys()) if (!S.index.has(k)) itemEls.delete(k);
  $("earlier").hidden = !S.hasEarlier;
  renderCenter();
  renderWorking();
}

function resetEarlierButton() {
  const b = $("earlierBtn");
  b.disabled = false;
  b.textContent = "Load earlier messages";
}

function buildItem(it) {
  switch (it.kind) {
    case "user": return buildUser(it.text, (it.images || []).map((k) => ({ key: k })), it.time);
    case "assistant": return buildAssistant(it);
    case "tool": return buildTool(it);
    case "thinking": return buildFold(it.id, "thought", I.bulb, "Thought" + (it.meta ? ` <span class="sep">·</span> <span class="last">${esc(it.meta)}</span>` : ""), () => mdBody(it.text));
    case "summary": return buildFold(it.id, "summary", I.book, "Summary of earlier conversation", () => mdBody(it.text));
    case "divider": return el("div", "divider", esc(it.text || "Conversation compacted") + (it.meta ? ` · ${esc(it.meta)}` : ""));
    case "chip": return buildChip(it);
    case "output": return buildOutput(it.text);
    case "error": {
      const e = el("div", "error", I.warn + `<div class="txt">${esc(it.text || "Something went wrong.")}${it.meta ? ` <span class="meta">${esc(it.meta)}</span>` : ""}</div>`);
      return e;
    }
    case "interrupted": return el("div", "interrupted", I.stopCircle + "Interrupted");
    default: return el("div", "notice", esc(it.text || "") + (it.meta ? ` · ${esc(it.meta)}` : ""));
  }
}

// MARK: Item builders

function buildUser(text, images, time, state) {
  const e = el("div", "user" + (state ? " " + state : ""));
  if (images && images.length) {
    const g = el("div", "imgs");
    for (const im of images) g.append(imgEl(im));
    e.append(g);
  }
  const t = String(text ?? "");
  if (t.trim()) {
    const b = el("div", "bubble");
    const u = el("div", "utext", userText(t));
    b.append(u);
    if (t.length > 1400 || t.split("\n").length > 16) clip(u, b, "Show more", "Show less");
    if (time) b.title = fmtTime(time);
    e.append(b);
  }
  if (state) {
    const label = { sending: "Sending…", queued: "Queued", cancelled: "Not sent" }[state] || "";
    if (label) e.append(el("div", "ustate", (state === "sending" ? '<span class="spin on"></span>' : "") + label));
  }
  return e;
}

function buildAssistant(it) {
  const e = el("div", "asst");
  e.append(el("div", "md", md(it.text)));
  const c = el("button", "acopy", I.copy + "<span>Copy</span>");
  c.type = "button";
  c.title = "Copy this message";
  c.addEventListener("click", () => copyText(it.text || "", c));
  e.append(c);
  return e;
}

function mdBody(text) { return el("div", "think-b md", md(text)); }

function buildFold(key, cls, icon, label, body) {
  const e = el("div", "fold " + cls);
  e.dataset.k = key;
  e.append(el("div", "fold-h", `${icon}<span class="t">${label}</span>${I.chev}`));
  e._body = () => [body()];
  prepFold(e);
  return e;
}

function toolIcon(name) {
  const n = String(name || "");
  if (/^(Bash|BashOutput|KillShell|KillBash)$/.test(n)) return I.term;
  if (/^(Read|NotebookRead)$/.test(n)) return I.file;
  if (/^(Edit|MultiEdit|Write|NotebookEdit)$/.test(n)) return I.pencil;
  if (/^(Grep|Glob|LS|ToolSearch)$/.test(n)) return I.search;
  if (/^(WebFetch|WebSearch)$/.test(n)) return I.globe;
  if (/^(TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet)$/.test(n)) return I.list;
  if (/^(Agent|Task)$/.test(n)) return I.agent;
  if (n === "AskUserQuestion") return I.ask;
  if (n === "ExitPlanMode" || n === "EnterPlanMode") return I.plan;
  if (n.startsWith("mcp__")) return I.plug;
  return I.tool;
}

/** "mcp__notion__search" → "notion: search". */
function toolName(name) {
  const n = String(name || "Tool");
  const m = /^mcp__(.+?)__(.+)$/.exec(n);
  return m ? `${m[1].replace(/_/g, " ")}: ${m[2].replace(/_/g, " ")}` : n;
}

function buildTool(it) {
  const t = it.tool || { name: "", title: it.text || "Tool", input: "" };
  const pending = t.result == null;
  const e = el("div", "fold tool" + (pending ? " pending" : "") + (t.isError ? " err" : ""));
  e.dataset.k = it.id;
  const status = pending ? '<span class="gap"></span><span class="spin"></span><span class="nores">No result</span>'
    : t.isError ? '<span class="gap"></span><span class="bad">Error</span>' : "";
  e.append(el("div", "fold-h", `${toolIcon(t.name)}<span class="t">${titleHtml(t.title || toolName(t.name))}</span>${I.chev}${status}`));
  e._body = () => [toolBody(t)];
  prepFold(e);
  return e;
}

function toolBody(t) {
  const b = el("div", "tbody");
  if (t.diff) b.append(section("Changes", diffEl(t.diff, "mono diff"), t.diff));
  else if (t.input) {
    const bash = t.name === "Bash";
    const pre = el("pre", "mono", (bash ? '<span class="ps">$ </span>' : "") + esc(t.input));
    b.append(section(bash ? "Command" : "Input", pre, t.input));
  }
  if (t.result == null) {
    b.append(el("div", "tsec waiting", '<span class="spin"></span><span class="run">Running…</span><span class="nores">No result</span>'));
  } else if (String(t.result).trim() || !(t.images && t.images.length)) {
    const pre = el("pre", "mono", esc(String(t.result).trim() ? t.result : "(no output)"));
    const s = section(t.isError ? "Error" : "Result", pre, t.result);
    if (t.isError) s.classList.add("bad-sec");
    b.append(s);
  }
  if (t.images && t.images.length) {
    const g = el("div", "tsec timgs");
    for (const k of t.images) g.append(imgEl({ key: k }));
    b.append(g);
  }
  return b;
}

/** A labelled block in a tool's details, clipped with "Show all" when long. */
function section(label, body, copy) {
  const s = el("div", "tsec");
  const lab = el("div", "tlab", `<span>${esc(label)}</span>`);
  if (copy) {
    const c = el("button", "copy", I.copy + "<span>Copy</span>");
    c.type = "button";
    c.addEventListener("click", (ev) => { ev.stopPropagation(); copyText(copy, c); });
    lab.append(c);
  }
  s.append(lab, body);
  const text = String(copy ?? body.textContent);
  const n = text.split("\n").length;
  if (n > 12 || text.length > 1600) clip(body, s, `Show all ${n} lines`, "Show less");
  return s;
}

function diffEl(d, cls) {
  const e = el("div", cls);
  e.innerHTML = String(d).replace(/\n$/, "").split("\n").map((l) => {
    const k = l.startsWith("@@") ? "hk" : l[0] === "+" ? "a" : l[0] === "-" ? "d" : "";
    return `<div${k ? ` class="${k}"` : ""}>${esc(l) || " "}</div>`;
  }).join("");
  return e;
}

function buildChip(it) {
  const t = String(it.text || "");
  const mine = t.startsWith("/");
  const icon = mine ? I.slash : /another session/i.test(t) ? I.people : I.bell;
  const row = el("div", "chiprow" + (mine ? " mine" : ""));
  const c = el("div", "chip", `${icon}<span>${esc(t)}${it.meta ? ` · ${esc(it.meta)}` : ""}</span>`);
  c.title = t;
  c.addEventListener("click", () => c.classList.toggle("full"));
  row.append(c);
  return row;
}

function buildOutput(text) {
  const t = String(text ?? "");
  const nl = t.indexOf("\n");
  const first = nl < 0 ? t : t.slice(0, nl);
  const html = first.startsWith("! ")
    ? `<span class="ps">!</span> ${esc(first.slice(2))}${nl < 0 ? "" : esc(t.slice(nl))}`
    : esc(t);
  const box = el("div", "outbox");
  const pre = el("pre", "out", html);
  box.append(pre);
  if (t.split("\n").length > 14 || t.length > 1600) clip(pre, box, "Show all", "Show less");
  return box;
}

/** Clips a long block, with a button under it that shows the rest. */
function clip(target, parent, more, less) {
  target.classList.add("clip");
  const b = el("button", "more", more);
  b.type = "button";
  b.addEventListener("click", (ev) => {
    ev.stopPropagation();
    const open = target.classList.toggle("clip");
    b.textContent = open ? more : less;
  });
  parent.append(b);
}

// MARK: Images (fetched lazily from Swift by key)

const images = new Map();  // key → Promise<dataURL|null>
function imgEl(im) {
  const img = el("img", "thumb");
  img.alt = "";
  const show = (u) => {
    const row = holdRow(img);
    if (typeof u === "string" && /^data:image\//.test(u)) {
      // the placeholder keeps its size until the picture is ready, then the row grows and is made up for at once
      const done = () => { img.classList.remove("wait"); rowResized(row); };
      img.addEventListener("load", done, { once: true });
      img.addEventListener("error", done, { once: true });
      img.src = u;
    } else { const g = el("div", "thumb gone", "No image"); img.replaceWith(g); rowResized(row); }
  };
  if (im.url) show(im.url);
  else {
    img.classList.add("wait");
    let p = images.get(im.key);
    if (!p) {
      p = bridge({ type: "image", key: im.key });
      images.set(im.key, p);
      p.then((u) => { if (typeof u !== "string" && images.get(im.key) === p) images.delete(im.key); }, () => images.delete(im.key));
    }
    p.then(show, () => show(null));
  }
  img.addEventListener("click", (ev) => { ev.stopPropagation(); if (img.src) openLightbox(img.src); });
  return img;
}

/** An image is about to change size (its placeholder gets the picture). Notes its row's height first. */
function holdRow(img) {
  const row = img.isConnected ? img.closest("#items > *") : null;
  if (!row) return null;
  if (!row._wait) { row._wait = 0; row._h = row.getBoundingClientRect().height; }
  row._wait++;
  return row;
}
/** It did: if the row starts above what's on screen, scroll by as much, so what you're reading stays put
 *  (Load earlier messages, then the older images arrive). */
function rowResized(row) {
  if (!row) return;
  row._wait = Math.max(0, row._wait - 1);
  if (!row.isConnected) return;
  const h = row.getBoundingClientRect().height, d = h - row._h;
  row._h = h;
  if (d && !stick && row.getBoundingClientRect().top < sc.getBoundingClientRect().top) {
    const want = sc.scrollTop + d + rowCarry;
    setTop(want);
    rowCarry = Math.abs(want - sc.scrollTop) < 2 ? want - sc.scrollTop : 0;  // scrollTop is rounded: keep the rest for the next one
  }
}
let rowCarry = 0;

function openLightbox(src) {
  const lb = $("lightbox");
  lb.querySelector("img").src = src;
  lb.hidden = false;
}

// MARK: Folding

function prepFold(e) {
  const h = e.querySelector(":scope > .fold-h");
  h.setAttribute("role", "button");
  h.tabIndex = 0;
  h.setAttribute("aria-expanded", "false");
  if (S.open.has(e.dataset.k)) setFold(e, true);
}

function setFold(e, open) {
  const k = e.dataset.k;
  e.classList.toggle("open", open);
  const h = e.querySelector(":scope > .fold-h");
  if (h) h.setAttribute("aria-expanded", String(open));
  if (k) { if (open) S.open.add(k); else S.open.delete(k); }
  let b = e.querySelector(":scope > .fold-b");
  if (!open) { if (b) b.remove(); return; }
  if (!b) { b = el("div", "fold-b"); e.append(b); }
  // syncChildren, not replaceChildren: a member that stays keeps its inner scroll and text selection
  try { syncChildren(b, e._body ? e._body() : []); } catch (err) { console.error(err); }
}

/** A click on a row: opens or closes it and keeps the row where it was on screen. */
function toggleFold(e) {
  if (!e._body) return;  // a live tool row has nothing to show yet
  const h = e.querySelector(":scope > .fold-h");
  const top = h.getBoundingClientRect().top;
  setFold(e, !e.classList.contains("open"));
  const d = h.getBoundingClientRect().top - top;
  if (d) setTop(sc.scrollTop + d);
  stick = atBottom();
  updateJump();
}

function fillGroupHead(e, members) {
  const tools = members.filter((m) => m.kind === "tool");
  const n = tools.length;
  const last = tools[n - 1];
  const pending = tools.some((m) => !m.tool || m.tool.result == null);
  const errs = tools.filter((m) => m.tool && m.tool.isError).length;
  const label = n ? `Used ${n} tool${n === 1 ? "" : "s"}` : "Thought";
  const lastTitle = last && last.tool ? last.tool.title || toolName(last.tool.name) : "";
  const h = e.querySelector(":scope > .fold-h");
  h.innerHTML = `${n ? I.layers : I.bulb}<span class="t">${label}` +
    (lastTitle ? `<span class="sep"> · </span><span class="last">${titleHtml(lastTitle)}</span>` : "") +
    `</span>${I.chev}<span class="gap"></span>` +
    (errs ? `<span class="bad">${errs} failed</span>` : "") + '<span class="spin"></span>';
  e.classList.toggle("pending", pending);
  prepFold(e);
}

// MARK: - Pending messages and the live reply

const pendEls = new Map();  // id → { sig, el }
const restored = new Set(); // ids of not-sent messages already put back in the composer
function renderPending() {
  const seen = new Set(), now = [], later = [], back = [];
  for (const p of S.pending) {
    if (!p || p.id == null) continue;
    seen.add(p.id);
    const imgs = (p.images || []).filter((u) => typeof u === "string");
    const sig = `${p.state}\u0001${p.text}\u0001${imgs.length}`;
    let c = pendEls.get(p.id);
    if (!c || c.sig !== sig) {
      c = { sig, el: buildUser(p.text, imgs.map((u) => ({ url: u })), null, p.state || "sending") };
      pendEls.set(p.id, c);
    }
    // a message waiting its turn goes below the reply being written now, where it will land
    (p.state === "queued" ? later : now).push(c.el);
    if (p.state === "cancelled" && !restored.has(p.id)) { restored.add(p.id); back.push({ text: p.text, imgs }); }
  }
  for (const k of pendEls.keys()) if (!seen.has(k)) pendEls.delete(k);
  for (const k of restored) if (!seen.has(k)) restored.delete(k);
  syncChildren($("pending"), now);
  syncChildren($("queued"), later);
  renderCenter();
  // a message that was never sent (Stop, claude quit) goes back in the empty composer, so it isn't lost
  if (back.length && !ta.value.trim() && !atts.length) {
    ta.value = back.map((b) => b.text).filter((t) => t).join("\n\n");
    for (const b of back) for (const u of b.imgs) {
      const m = /^data:([^;,]+);base64,/.exec(u);
      if (m) atts.push({ mime: m[1], data: u.slice(m[0].length), url: u });
    }
    renderThumbs(); autosize(); updateSend();
  }
}

const ghostEls = new Map(); // key → { sig, el }
function renderGhost() {
  const box = $("ghost");
  const seen = new Set();
  const list = S.ghost.filter((g) => g && g.key != null);
  const els = list.map((g, k) => {
    seen.add(g.key);
    const lastText = g.kind === "text" && k === list.length - 1;
    const sig = `${g.kind}\u0001${g.name || ""}\u0001${g.text || ""}\u0001${lastText}`;
    let c = ghostEls.get(g.key);
    if (c && c.sig === sig) return c.el;
    let e;
    if (g.kind === "text") {
      e = c && c.el.classList.contains("asst") ? c.el : el("div", "asst", '<div class="md"></div>');
      const box = e.firstChild;
      box.innerHTML = md(g.text);
      box.classList.toggle("ghost-text", lastText);
    } else if (g.kind === "thinking") {
      // keep the row while it streams (a new row every tick would eat the user's clicks on it)
      if (c && c.el.classList.contains("thought")) {
        e = c.el;
        e._body = () => [mdBody(g.text || "")];
        if (e.classList.contains("open")) setFold(e, true);
      } else {
        e = buildFold("ghost:" + g.key, "thought", I.bulb, '<span class="shimmer">Thinking…</span>', () => mdBody(g.text || ""));
      }
    } else {
      e = el("div", "fold tool", `<div class="fold-h">${toolIcon(g.name)}<span class="t">${esc(toolName(g.name))}…</span><span class="gap"></span><span class="spin on"></span></div>`);
    }
    ghostEls.set(g.key, { sig, el: e });
    return e;
  });
  for (const k of ghostEls.keys()) if (!seen.has(k)) ghostEls.delete(k);
  syncChildren(box, els);
  renderCenter();
  renderWorking();
}

function renderWorking() {
  const w = $("working");
  const on = !!S.status.running && !S.ghost.length && !S.perms.length && !S.status.loading;
  if (on && !w.childElementCount) w.innerHTML = SPARK + '<span class="shimmer">Working…</span>';
  w.hidden = !on;
}

function renderCenter() {
  const c = $("center");
  const empty = !S.items.length && !S.pending.length && !S.ghost.length;
  let html = "";
  if (empty && S.status.loading) html = '<div class="loading"><span class="spin on"></span>Loading…</div>';
  else if (empty && S.status.empty) html = `<div class="empty">${SPARK}<div>${esc(S.status.empty)}</div></div>`;
  if (c._html !== html) { c.innerHTML = html; c._html = html; }
  c.hidden = !html;
}

// MARK: - Permission cards

const permEls = new Map();  // id → el
let permSeq = 0;

function renderPerms() {
  const box = $("perms");
  const seen = new Set();
  const els = S.perms.filter((p) => p && p.id != null).map((p) => {
    seen.add(p.id);
    let e = permEls.get(p.id);
    if (!e) { e = buildPerm(p); permEls.set(p.id, e); }
    return e;
  });
  for (const k of permEls.keys()) if (!seen.has(k)) permEls.delete(k);
  syncChildren(box, els);
  if (stick) requestAnimationFrame(() => toBottom(false));
}

function permKind(p) {
  if (Array.isArray(p.question) && p.question.length) return "question";
  if (p.plan != null) return "plan";
  return "tool";
}

function buildPerm(p) {
  const kind = permKind(p);
  const e = el("div", "perm");
  e.dataset.id = p.id;
  e._p = p;
  e._kind = kind;
  const icon = kind === "question" ? I.ask : kind === "plan" ? I.plan : p.trust ? I.lock : toolIcon(p.tool);
  let html = `<div class="ph">${icon}<div class="pt">${titleHtml(p.title || "Claude wants to use a tool")}</div></div>`;
  if (kind === "plan") html += `<div class="pplan md">${md(p.plan)}</div>`;
  else if (kind === "question") html += questionsHtml(p.question, ++permSeq);
  else if (p.detail) {
    const d = String(p.detail);
    html += looksLikeDiff(p.tool, d) ? diffEl(d, "pdetail diff").outerHTML : `<pre class="pdetail">${esc(d)}</pre>`;
  }
  if (p.reason) html += `<div class="preason">${esc(p.reason)}</div>`;
  const btn = (a, label, cls, key) => `<button type="button" class="b${cls ? " " + cls : ""}" data-a="${a}"><span>${label}</span>${key ? `<kbd>${key}</kbd>` : ""}</button>`;
  html += '<div class="pbtns">';
  if (kind === "question") html += btn("deny", "Skip", "", "esc") + btn("submit", "Submit", "pri", "⏎");
  else if (kind === "plan") html += btn("deny", "Keep planning", "", "esc") + btn("allow", "Approve", "pri", "⏎");
  else if (p.trust) html += btn("deny", "Cancel", "", "esc") + btn("allow", "Trust and start", "pri", "");  // a click, never Return
  else {
    // "Always" first, so Deny and Allow stay side by side when a narrow card wraps the row
    if (p.always) html += btn("always", titleHtml(p.always), "always", "");
    html += btn("deny", "Deny", "", "esc") + btn("allow", "Allow", "pri", "⏎");
  }
  e.innerHTML = html + "</div>";
  for (const b of e.querySelectorAll(".pbtns .b")) b.title = b.textContent.replace(/(esc|⏎)$/, "").trim();
  e.addEventListener("click", (ev) => {
    const b = ev.target.closest("button[data-a]");
    if (b && !b.disabled) answer(e, b.dataset.a);
  });
  if (kind === "question") {
    e.addEventListener("input", (ev) => {
      if (ev.target.classList.contains("otext")) {
        const box = ev.target.closest(".opt").querySelector("input[type=radio],input[type=checkbox]");
        box.checked = !!ev.target.value.trim();
      }
      validate(e);
    });
    e.addEventListener("change", () => validate(e));
    e.addEventListener("keydown", (ev) => {
      // keyCode 229: the Return that ends an input-method conversion comes after compositionend
      if (ev.key === "Enter" && !ev.shiftKey && !ev.isComposing && ev.keyCode !== 229 && ev.target.tagName !== "BUTTON") {  // a focused Skip keeps its own Return
        ev.preventDefault(); ev.stopPropagation(); answer(e, "submit");
      }
    });
    validate(e);
  }
  return e;
}

function looksLikeDiff(tool, d) {
  if (!/^(Edit|MultiEdit|Write|NotebookEdit)$/.test(String(tool || ""))) return false;
  return d.split("\n").some((l) => /^[+-]/.test(l));
}

function questionsHtml(qs, seq) {
  return qs.map((q, qi) => {
    const type = q.multiSelect ? "checkbox" : "radio";
    const name = `q${seq}-${qi}`;
    const opts = (q.options || []).map((o, oi) =>
      `<label class="opt"><input type="${type}" name="${name}" value="${oi}"><span><b>${esc(o.label)}</b>` +
      (o.description ? `<i>${esc(o.description)}</i>` : "") + "</span></label>").join("");
    const other = `<label class="opt"><input type="${type}" name="${name}" value="other"><span><input class="otext" type="text" placeholder="Other…" aria-label="Other answer"></span></label>`;
    return `<fieldset class="q" data-qi="${qi}">` + (q.header ? `<div class="qh">${esc(q.header)}</div>` : "") +
      `<div class="qq">${titleHtml(q.question)}</div>${opts}${other}</fieldset>`;
  }).join("");
}

function collectAnswers(e) {
  const out = {};
  e._p.question.forEach((q, qi) => {
    const fs = e.querySelector(`.q[data-qi="${qi}"]`);
    const picked = [...fs.querySelectorAll("input[type=radio]:checked, input[type=checkbox]:checked")]
      .map((i) => (i.value === "other" ? fs.querySelector(".otext").value.trim() : (q.options[+i.value] || {}).label))
      .filter((x) => x);
    if (picked.length) out[q.question] = picked.join(", ");
  });
  return out;
}

function validate(e) {
  const ok = Object.keys(collectAnswers(e)).length === e._p.question.length;
  const b = e.querySelector('[data-a="submit"]');
  if (b) b.disabled = !ok;
  return ok;
}

function answer(e, a) {
  if (e.classList.contains("done")) return;
  const p = e._p, kind = e._kind;
  let msg;
  if (a === "submit") {
    if (!validate(e)) return;
    msg = { type: "answer", id: p.id, behavior: "allow", answers: collectAnswers(e) };
  } else if (a === "allow") msg = { type: "answer", id: p.id, behavior: "allow" };
  else if (a === "always") msg = { type: "answer", id: p.id, behavior: "allow", always: true };
  else {
    // the CLI rejects a deny without a message, so always send one
    msg = { type: "answer", id: p.id, behavior: "deny", message: "The user denied this." };
    if (kind === "plan") msg.message = "Keep planning.";
    else if (kind === "question") msg.message = "The user skipped the question.";
  }
  e.classList.add("done");
  for (const b of e.querySelectorAll("button")) b.disabled = true;
  bridge(msg);
  ta.focus();
}

/** The card the keyboard acts on: the first one that is still waiting. */
function activePerm() {
  for (const e of $("perms").children) if (!e.classList.contains("done")) return e;
  return null;
}
function primaryAction(e) {
  if (e._p.trust) return;  // trusting a folder takes a click
  answer(e, e._kind === "question" ? "submit" : "allow");
}
/** A Return that may only be the tail of the one that just sent a message (a key repeat, a second press):
 *  it must not approve the card that's waiting. */
function returnTooSoon(e) { return e.repeat || performance.now() - lastSubmit < 1000; }

// MARK: - Status: banner, composer, footer

function setStatus(s) {
  S.status = Object.assign({ modes: [], models: [] }, s);
  const st = S.status;
  document.title = st.title || "Chat";
  document.body.classList.toggle("busy", !!(st.running || st.busyElsewhere));
  document.body.classList.toggle("running", !!st.running);
  renderBanner();
  ta.disabled = !!st.readOnly;
  ta.placeholder = st.readOnly || "Message Claude";
  updateSend();
  renderFooter();
  renderCenter();
  renderWorking();
}

let flashText = "", flashTimer = 0;
/** Shows a short-lived error above the composer. */
function flash(t) {
  flashText = t;
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => { flashText = ""; renderBanner(); }, 6000);
  renderBanner();
}

function renderBanner() {
  const s = S.status, b = $("banner");
  let html = "", bad = false;
  if (flashText) { html = I.warn + `<span>${titleHtml(flashText)}</span>`; bad = true; }
  else if (s.error) { html = I.warn + `<span>${titleHtml(s.error)}</span>`; bad = true; }
  else if (s.readOnly) html = I.lock + `<span>${titleHtml(s.readOnly)}</span>`;
  else if (s.notice) html = I.info + `<span>${titleHtml(s.notice)}</span>`;
  else if (s.trustWait) html = I.lock + "<span>Your message waits until you answer the card above</span>";
  else if (s.busyElsewhere) html = '<span class="spin on"></span><span>Claude is working on this chat in another Claude (the app or a terminal)…</span>';
  else if (s.liveElsewhere && s.running) html = I.app + "<span>Also open in another Claude — after this reply, sending makes a copy here</span>";
  else if (s.liveElsewhere) html = I.app + "<span>Open in another Claude (the app or a terminal) — sending makes a copy here</span>";
  b.classList.toggle("bad", bad);
  if (b._html !== html) { b.innerHTML = html; b._html = html; }
  b.hidden = !html;
}

function updateSend() {
  const b = $("send");
  const running = !!S.status.running;
  const has = !!ta.value.trim() || atts.length > 0;
  const want = running ? "stop" : "send";
  if (b._mode !== want) { b.innerHTML = running ? I.stop : I.up; b._mode = want; }
  b.classList.toggle("stop", running);
  b.disabled = !running && (!has || !!S.status.readOnly);
  b.title = running ? "Stop (Esc)" : "Send (Return)";
}

function renderFooter() {
  const s = S.status;
  const folder = String(s.folder || "");
  const name = folder.replace(/\/+$/, "").split("/").pop() || folder;
  const f = $("fFolder");
  f.hidden = !name;
  if (name) { f.innerHTML = I.folder + `<span>${esc(name)}</span>`; f.title = folder; }
  const br = $("fBranch");
  br.hidden = !s.branch;
  if (s.branch) { br.innerHTML = I.branch + `<span>${esc(s.branch)}</span>`; br.title = s.branch; }
  menu($("fMode"), s.modes || [], s.mode, "setMode");
  menu($("fModel"), s.models || [], s.model, "setModel");
  $("fMode").querySelector(".dot").className = "dot " + String(s.mode || "").replace(/[^\w-]/g, "");
  const c = $("fCost");
  c.hidden = !s.cost;
  c.textContent = s.cost || "";
}

/** A footer menu: shows the current label; a native <select> on top opens the macOS menu. */
function menu(box, options, value, type) {
  const sel = box.querySelector("select");
  const opts = options.filter((o) => o && o.value != null).map((o) => ({ value: String(o.value), label: String(o.label ?? o.value) }));
  if (value && !opts.some((o) => o.value === value)) opts.unshift({ value: String(value), label: String(value) });
  box.hidden = !options.length;
  const sig = JSON.stringify(opts);
  if (sel._sig !== sig) {
    sel.replaceChildren(...opts.map((o) => { const op = document.createElement("option"); op.value = o.value; op.textContent = o.label; return op; }));
    sel._sig = sig;
  }
  if (value != null) sel.value = String(value);
  const cur = opts.find((o) => o.value === sel.value);
  box.querySelector(".lbl").textContent = cur ? cur.label : "";
  box.title = cur ? cur.label : "";
  if (!sel._wired) {
    sel._wired = true;
    sel.addEventListener("change", () => {
      const o = sel.options[sel.selectedIndex];
      box.querySelector(".lbl").textContent = o ? o.textContent : "";
      if (type === "setMode") box.querySelector(".dot").className = "dot " + sel.value.replace(/[^\w-]/g, "");
      bridge({ type, value: sel.value });
    });
  }
  if (!box.querySelector(".i")) box.insertAdjacentHTML("beforeend", I.down);
}

// MARK: - Composer

let atts = [];          // images to send: { mime, data (base64), url }
let sending = false;
let lastSubmit = -1e9;  // when a message was last sent (performance.now())

function autosize() {
  ta.style.height = "auto";
  const max = Math.max(54, Math.round(window.innerHeight * 0.4));
  const h = Math.min(ta.scrollHeight, max);
  ta.style.height = h + "px";
  ta.style.overflowY = ta.scrollHeight > max ? "auto" : "hidden";
}

function renderThumbs() {
  const box = $("thumbs");
  box.replaceChildren(...atts.map((a, k) => {
    const d = el("div", "att");
    const img = el("img");
    img.src = a.url; img.alt = "";
    const x = el("button", "", I.x);
    x.type = "button"; x.title = "Remove";
    x.addEventListener("click", () => { atts.splice(k, 1); renderThumbs(); updateSend(); ta.focus(); });
    d.append(img, x);
    return d;
  }));
  box.hidden = !atts.length;
}

function addFiles(files) {
  for (const f of files) {
    if (!f || !/^image\/(png|jpeg|gif|webp)$/.test(f.type)) continue;
    const rd = new FileReader();
    rd.onload = () => {
      const u = String(rd.result || "");
      const comma = u.indexOf(",");
      if (comma < 0) return;
      atts.push({ mime: f.type, data: u.slice(comma + 1), url: u });
      renderThumbs();
      updateSend();
    };
    rd.readAsDataURL(f);
  }
}

async function submit() {
  if (sending || S.status.readOnly) return;
  const text = ta.value.trimEnd();
  const sent = atts.slice();
  if (!text.trim() && !sent.length) return;
  ta.value = ""; atts = [];
  lastSubmit = performance.now();
  renderThumbs(); autosize(); updateSend();
  stick = true; unseen = false; updateJump(); toBottom(true);
  sending = true;
  let r = null;
  try { r = await bridge({ type: "send", text, images: sent.map((a) => ({ mime: a.mime, data: a.data })) }); }
  catch (e) { r = { ok: false, error: String(e) }; }
  sending = false;
  if (r && r.ok === false) {
    if (!ta.value && !atts.length) { ta.value = text; atts = sent; renderThumbs(); autosize(); updateSend(); }
    flash(r.error || "Couldn't send that.");
  }
}

function stop() { bridge({ type: "stop" }); }

// MARK: - Scrolling: stick to the bottom while new content arrives

let stick = true;     // follow new content
let unseen = false;   // new content arrived while scrolled up
let userAt = -1e9;    // last time the user touched the scroller (wheel, click, keys)
let ourTop = -1;      // the scrollTop we set last, so our own scrolling isn't taken for the user's
let anim = 0;

function atBottom() { return sc.scrollHeight - sc.scrollTop - sc.clientHeight < 24; }
function setTop(top) { sc.scrollTop = top; ourTop = sc.scrollTop; }

function toBottom(smooth) {
  const max = () => sc.scrollHeight - sc.clientHeight;
  if (!smooth || matchMedia("(prefers-reduced-motion: reduce)").matches) {
    cancelAnimationFrame(anim); anim = 0;
    setTop(max());
    return;
  }
  if (anim) return;
  const step = () => {
    anim = 0;
    if (!stick) return;
    const d = max() - sc.scrollTop;
    if (d <= 0.5) return;
    setTop(sc.scrollTop + (d < 3 ? d : Math.ceil(Math.max(2, d * 0.24))));
    anim = requestAnimationFrame(step);
  };
  anim = requestAnimationFrame(step);
}

function jumpToEnd() {
  stick = true; unseen = false;
  cancelAnimationFrame(anim); anim = 0;
  setTop(sc.scrollHeight);
  updateJump();
}

/** Call after new content: follow it, or remember there's something new below. */
function grew() {
  if (stick) toBottom(true);
  else unseen = true;
  updateJump();
}

function updateJump() { $("jump").hidden = stick || !unseen; }

// MARK: - Small helpers

function fmtTime(t) {
  try { return new Date(t * 1000).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }); }
  catch (e) { return ""; }
}

function copyText(text, button) {
  bridge({ type: "copy", text: String(text) });
  if (!button) return;
  const label = button.querySelector("span");
  const was = label ? label.textContent : "";
  button.classList.add("did");
  if (label) label.textContent = "Copied";
  clearTimeout(button._t);
  button._t = setTimeout(() => { button.classList.remove("did"); if (label) label.textContent = was; }, 1300);
}

// MARK: - Start

function start() {
  sc = $("scroll");
  ta = $("input");
  $("jump").innerHTML = I.arrowDown;
  window.chat = { receive(m) { try { receive(m); } catch (e) { console.error(e); } } };

  // Scrolling
  const touch = () => { userAt = performance.now(); };
  for (const t of ["wheel", "touchstart", "mousedown"]) sc.addEventListener(t, touch, { passive: true });
  // only when it can really scroll up: a flick on a short chat must not turn off following
  sc.addEventListener("wheel", (e) => { if (e.deltaY < 0 && sc.scrollTop > 0) stick = false; }, { passive: true });
  document.addEventListener("keydown", (e) => {
    if (/^(PageUp|PageDown|ArrowUp|ArrowDown|Home|End| )$/.test(e.key)) touch();
  }, true);
  sc.addEventListener("scroll", () => {
    if (Math.abs(sc.scrollTop - ourTop) < 2) return;  // our own scrolling
    if (performance.now() - userAt > 900) return;     // layout moved it, not the user
    stick = atBottom();
    if (stick) unseen = false;
    updateJump();
  }, { passive: true });
  const follow = () => { if (stick) toBottom(true); };
  new ResizeObserver(follow).observe($("log"));
  new ResizeObserver(() => { if (stick) toBottom(false); autosize(); }).observe(sc);
  $("jump").addEventListener("click", () => { stick = true; unseen = false; updateJump(); toBottom(true); });
  $("earlierBtn").addEventListener("click", (e) => {
    const b = e.currentTarget;
    b.disabled = true; b.textContent = "Loading…";
    bridge({ type: "loadEarlier" });
  });

  // Rows, links and copy buttons
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (a) { e.preventDefault(); bridge({ type: "openLink", url: a.getAttribute("href") }); return; }
    const cp = e.target.closest("[data-copy]");
    if (cp) { const pre = cp.closest(".code").querySelector("pre"); copyText(pre ? pre.textContent : "", cp); return; }
    const h = e.target.closest(".fold-h");
    if (!h || !h.parentElement.classList.contains("fold")) return;
    // ignore the click that ends a text selection over this row, but not one made somewhere else
    // (a click on a non-selectable row doesn't clear the page's selection)
    const sel = getSelection();
    if (sel && !sel.isCollapsed && sel.containsNode(h, true)) return;
    toggleFold(h.parentElement);
  });
  $("lightbox").addEventListener("click", () => { $("lightbox").hidden = true; });

  // Composer
  ta.addEventListener("input", () => { autosize(); updateSend(); });
  ta.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;
    if (e.shiftKey || e.altKey || e.metaKey || e.ctrlKey) return;
    e.preventDefault();
    if (ta.value.trim() || atts.length) { submit(); return; }
    if (returnTooSoon(e)) return;
    const p = activePerm();
    if (p) primaryAction(p);
  });
  ta.addEventListener("paste", (e) => {
    const dt = e.clipboardData;
    if (!dt) return;
    const files = [...dt.items].filter((i) => i.kind === "file" && /^image\//.test(i.type)).map((i) => i.getAsFile());
    if (!files.length) return;
    const text = dt.getData("text/plain").trim();
    if (text && !/^[^\n]*\.(png|jpe?g|gif|webp)$/i.test(text)) return;  // real text (its image is just a picture of it)
    e.preventDefault();
    addFiles(files);
  });
  $("send").addEventListener("click", () => { if (S.status.running) stop(); else submit(); ta.focus(); });
  const comp = $("composer");
  document.addEventListener("dragover", (e) => {
    e.preventDefault();
    if (e.dataTransfer && [...e.dataTransfer.types].includes("Files")) comp.classList.add("drop");
  });
  document.addEventListener("dragleave", (e) => { if (!e.relatedTarget) comp.classList.remove("drop"); });
  document.addEventListener("drop", (e) => {
    comp.classList.remove("drop");
    const files = e.dataTransfer ? [...e.dataTransfer.files] : [];
    if (!files.length && e.target === ta) return;  // dropped text goes into the composer as usual
    e.preventDefault();                            // anything else must not navigate the page
    if (files.length && !S.status.readOnly) { addFiles(files); ta.focus(); }
  });

  // Keys: Esc denies a card, else stops a turn, else leaves the composer. Return allows a card.
  document.addEventListener("keydown", (e) => {
    const t = e.target;
    if (e.isComposing || e.keyCode === 229) return;  // Esc / Return that only end an input-method composition
    if (e.key === "Escape") {
      e.preventDefault();  // else it goes on to the window, and an Esc that closes an image or leaves the box hides the sticky
      if (!$("lightbox").hidden) { $("lightbox").hidden = true; return; }
      const p = activePerm();
      if (p) { e.preventDefault(); answer(p, "deny"); return; }
      if (S.status.running) { e.preventDefault(); stop(); return; }
      if (t === ta) ta.blur();
      return;
    }
    if (e.key === "Enter" && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey && !e.isComposing) {
      if (t === ta) return;
      if (t.classList && t.classList.contains("fold-h")) { e.preventDefault(); toggleFold(t.parentElement); return; }
      if (t.tagName === "BUTTON" || t.tagName === "INPUT" || t.tagName === "SELECT") return;
      const p = activePerm();
      if (p && !returnTooSoon(e)) { e.preventDefault(); primaryAction(p); }
      return;
    }
    if (e.key === " " && t.classList && t.classList.contains("fold-h")) { e.preventDefault(); toggleFold(t.parentElement); return; }
    if (t === document.body && e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey && !ta.disabled) ta.focus();
  });

  setStatus(S.status);
  autosize();
  bridge({ type: "ready" });
}

if (typeof document !== "undefined") start();
</script>
</body>
</html>
"""#
}
