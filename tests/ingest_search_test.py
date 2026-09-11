"""Run with the toolkit Python environment; all books and embeddings are synthetic."""

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(REPO / "toolkit" / p) for p in ("lib", "server", "scripts")]
with patch("dotenv.load_dotenv"):
    import ingest
    import server
    from legal_books_db import ensure_db


class IngestSearchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.db = self.root / "books.db"
        ensure_db(self.db)
        for module in (ingest, server):
            patcher = patch.object(module, "DB_PATH", self.db)
            patcher.start()
            self.addCleanup(patcher.stop)
        cache = patch.object(server, "_EMB_CACHE", {"mtime": None, "matrix": None})
        cache.start()
        self.addCleanup(cache.stop)
        self.valid = np.ones(server.EMBEDDING_DIM, dtype=np.float32)
        self.bad_vectors = [np.ones(3), np.zeros(server.EMBEDDING_DIM),
                            np.full(server.EMBEDDING_DIM, np.nan),
                            np.full(server.EMBEDDING_DIM, np.inf)]
        self.add_chunks([self.valid.tobytes()])

    def add_chunks(self, blobs):
        with contextlib.closing(sqlite3.connect(self.db)) as con, con:
            con.execute("INSERT OR IGNORE INTO books(book_id, title) VALUES('001', '기존 책')")
            con.executemany(
                "INSERT OR REPLACE INTO chunks VALUES(?, '001', 1, 1, ?, ?)",
                [(f"001_{i:05d}", "소멸시효 기존 본문", blob) for i, blob in enumerate(blobs)],
            )
            con.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")

    def run_ingest(self):
        argv = ["ingest.py", "--book-id", "001", "--pdf", str(self.root / "book.pdf"),
                "--book-dir", str(self.root), "--author", "저자", "--title", "새 책"]
        with patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
            ingest.main()

    def test_partial_pdf_extraction_preserves_existing_book(self):
        for suffix in ("md", "meta.json", "chunks.jsonl"):
            (self.root / f"001.{suffix}").write_text("original", encoding="utf-8")
        pages = [SimpleNamespace(extract_text=lambda: "정상 페이지"),
                 SimpleNamespace(extract_text=Mock(side_effect=ValueError("damaged page")))]
        with patch.object(ingest, "PdfReader", return_value=SimpleNamespace(pages=pages)), \
             patch.object(ingest, "embed_batch", return_value=[self.valid]) as embed:
            with self.assertRaisesRegex(RuntimeError, "page 2"):
                self.run_ingest()
            embed.assert_not_called()
        for suffix in ("md", "meta.json", "chunks.jsonl"):
            self.assertEqual((self.root / f"001.{suffix}").read_text(), "original")
        with contextlib.closing(sqlite3.connect(self.db)) as con:
            self.assertEqual(con.execute("SELECT chunk_text FROM chunks").fetchone()[0],
                             "소멸시효 기존 본문")
        with patch.object(ingest, "PdfReader", return_value=SimpleNamespace(
                pages=[SimpleNamespace(extract_text=lambda: None)])):
            self.assertEqual(list(ingest.extract_pages(self.root / "blank.pdf")), [(1, "")])

    def test_invalid_document_embeddings_do_not_replace_database(self):
        for vector in self.bad_vectors:
            with self.subTest(vector=vector[:3]), \
                 patch.object(ingest, "extract_pages", return_value=[(1, "새 본문")]), \
                 patch.object(ingest, "embed_batch", return_value=[vector]):
                with self.assertRaisesRegex(ValueError, "embedding"):
                    self.run_ingest()
                with contextlib.closing(sqlite3.connect(self.db)) as con:
                    self.assertEqual(con.execute("SELECT title FROM books").fetchone()[0], "기존 책")
                    self.assertEqual(con.execute("SELECT chunk_text FROM chunks").fetchone()[0],
                                     "소멸시효 기존 본문")

    def test_invalid_stored_vectors_preserve_keyword_results(self):
        blobs = [self.valid.tobytes(), b"x"] + [
            v.astype(np.float32).tobytes() for v in self.bad_vectors]
        self.add_chunks(blobs)
        with patch.object(server, "embed_query", return_value=self.valid):
            result = server.search(server.SearchReq(query="소멸시효는? 소멸시효", top_k=20))
        self.assertEqual(len(result["results"]), len(blobs))
        self.assertIn("skipped", " ".join(result["warnings"]))
        json.dumps(result, allow_nan=False)

    def test_invalid_query_vectors_fall_back_to_keywords(self):
        for vector in self.bad_vectors:
            with self.subTest(vector=vector[:3]), patch.object(server, "embed_query", return_value=vector):
                result = server.search(server.SearchReq(query="소멸시효"))
                self.assertEqual(result["results"][0]["chunk_id"], "001_00000")
                self.assertIn("FTS only", " ".join(result["warnings"]))
                json.dumps(result, allow_nan=False)

    def test_valid_ingest_and_offline_search(self):
        with patch.object(ingest, "extract_pages", return_value=[(1, "소멸시효 새 본문")]), \
             patch.object(ingest, "embed_batch", return_value=[self.valid]):
            self.run_ingest()
        with patch.object(server, "embed_query", side_effect=RuntimeError("offline")):
            result = server.search(server.SearchReq(query="소멸시효?"))
        self.assertEqual(result["results"][0]["chunk_text"], "소멸시효 새 본문")
        self.assertEqual(result["results"][0]["title"], "새 책")
        self.assertIn("FTS only", " ".join(result["warnings"]))

    def test_missing_embedding_response_is_rejected(self):
        with patch("google.genai.Client") as client, patch.dict(os.environ, {
                "GEMINI_API_KEY": "synthetic-test-key", "LEGAL_BOOKS_EMBED_MAX_RETRIES": "1"}):
            client.return_value.models.embed_content.return_value = SimpleNamespace(embeddings=None)
            with self.assertRaisesRegex(ValueError, "no query embedding"):
                server.embed_query("synthetic query")
            with self.assertRaisesRegex(RuntimeError, "0 embeddings for 1 chunks"):
                ingest.embed_batch(["synthetic document"])


if __name__ == "__main__":
    unittest.main()
