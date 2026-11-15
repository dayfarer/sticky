-- For databases created before client IDs existed.
ALTER TABLE notes ADD COLUMN last_client TEXT NOT NULL DEFAULT '';
