"""Shared SQLite schema helpers for the legal-books toolkit."""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path


ROOT = Path(os.path.expanduser("~/legal-books"))
DB_PATH = ROOT / "db" / "books_fts.db"

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS books (
  book_id TEXT PRIMARY KEY,
  author TEXT, title TEXT, edition TEXT, year INTEGER, publisher TEXT,
  added_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS chunks (
  chunk_id TEXT PRIMARY KEY,
  book_id TEXT NOT NULL REFERENCES books(book_id),
  page INTEGER,
  page_end INTEGER,
  chunk_text TEXT NOT NULL,
  embedding BLOB
);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
  chunk_text, chunk_id UNINDEXED, book_id UNINDEXED, page UNINDEXED,
  content='chunks', content_rowid='rowid', tokenize='unicode61',
  prefix='2 3 4'
);

-- External-content FTS5 tables are not maintained automatically. Without
-- these triggers any write that does not end in an explicit 'rebuild'
-- (an interrupted reindex, a manual DELETE) leaves the index pointing at
-- rows that no longer exist, and searches surface phantom chunk_ids.
CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
  INSERT INTO chunks_fts(rowid, chunk_text, chunk_id, book_id, page)
  VALUES (new.rowid, new.chunk_text, new.chunk_id, new.book_id, new.page);
END;
CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
  INSERT INTO chunks_fts(chunks_fts, rowid, chunk_text, chunk_id, book_id, page)
  VALUES ('delete', old.rowid, old.chunk_text, old.chunk_id, old.book_id, old.page);
END;
CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
  INSERT INTO chunks_fts(chunks_fts, rowid, chunk_text, chunk_id, book_id, page)
  VALUES ('delete', old.rowid, old.chunk_text, old.chunk_id, old.book_id, old.page);
  INSERT INTO chunks_fts(rowid, chunk_text, chunk_id, book_id, page)
  VALUES (new.rowid, new.chunk_text, new.chunk_id, new.book_id, new.page);
END;
"""


def ensure_db(db_path: Path = DB_PATH) -> Path:
    """Create the legal-books DB and FTS schema if they do not exist."""
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(db_path)
    try:
        con.executescript(SCHEMA_SQL)
        con.commit()
    finally:
        con.close()
    return db_path


if __name__ == "__main__":
    ensure_db()
    print("DB 초기화 완료:", DB_PATH)
