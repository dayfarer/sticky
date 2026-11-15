CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY,
  body TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  last_client TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS notes_updated_at ON notes (updated_at);
