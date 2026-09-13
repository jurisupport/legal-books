#!/usr/bin/env python3
"""
legal-books search API (port 8766)

Endpoints:
  GET  /health              → {"status":"ok", "books":N, "chunks":N}
  POST /search              → hybrid search (FTS5 30% + cosine 70%)
    body: {"query": str, "top_k": int=5}
"""

import os
import re
import sqlite3
import sys
from pathlib import Path

import numpy as np
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from dotenv import load_dotenv

LIB_DIR = Path(__file__).resolve().parents[1] / "lib"
if LIB_DIR.exists():
    sys.path.insert(0, str(LIB_DIR))

from legal_books_db import DB_PATH, ensure_db  # noqa: E402 -- installed sibling lib

SECRETS = Path(os.path.expanduser("~/.jurisupport/secrets.env"))
load_dotenv(SECRETS)

FTS_CANDIDATE_LIMIT = 100
RRF_K = 60
TOKEN_RE = re.compile(r"[0-9A-Za-z가-힣_]+")
EMBEDDING_MODEL = "gemini-embedding-2"
EMBEDDING_DIM = 768


def get_db():
    ensure_db(DB_PATH)
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con


def embed_query(q: str) -> np.ndarray:
    """Get single embedding from Gemini."""
    from google import genai
    from google.genai import types as genai_types
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise HTTPException(500, "GEMINI_API_KEY not set")
    client = genai.Client(api_key=api_key)
    result = client.models.embed_content(
        model=EMBEDDING_MODEL,
        contents=[q],
        config=genai_types.EmbedContentConfig(
            task_type="RETRIEVAL_QUERY",
            output_dimensionality=EMBEDDING_DIM,
        ),
    )
    if not result.embeddings:
        raise ValueError("Gemini returned no query embedding")
    return np.array(result.embeddings[0].values, dtype=np.float32)


def build_fts_query(query: str) -> str:
    """Build a safe high-recall FTS5 query from user text.

    TOKEN_RE drops punctuation, which matters: a raw query containing "?" or
    "(" is not valid FTS5 syntax and previously surfaced as
    `fts5: syntax error near "?"`. Ordinary questions ("...대항요건은
    무엇인가?", "...보호법(GDPR)...") therefore failed outright.

    Each token is a quoted prefix query ("소멸시효"*) so that Korean words with
    a trailing particle in the indexed text (e.g. "소멸시효를") still match.
    """
    tokens = TOKEN_RE.findall(query)
    # 따옴표는 FTS5 문자열 리터럴에서 두 번 써서 이스케이프한다.
    return " OR ".join(f'"{t.replace(chr(34), chr(34) * 2)}"*' for t in tokens[:32])


# In-memory embedding cache, reloaded only when the DB file changes.
_EMB_CACHE = {"mtime": None, "chunk_ids": [], "matrix": None, "rows": {}, "skipped": 0}


def load_embedding_cache(con: sqlite3.Connection) -> dict:
    try:
        mtime = os.path.getmtime(DB_PATH)
    except OSError:
        mtime = None
    if _EMB_CACHE["mtime"] == mtime and _EMB_CACHE["matrix"] is not None:
        return _EMB_CACHE
    chunk_ids, vectors, rows, skipped = [], [], {}, 0
    for row in con.execute(
        "SELECT chunk_id, book_id, page, page_end, chunk_text, embedding "
        "FROM chunks WHERE embedding IS NOT NULL"
    ):
        blob = row["embedding"]
        if not isinstance(blob, bytes) or len(blob) != EMBEDDING_DIM * 4:
            skipped += 1
            continue
        emb = np.frombuffer(blob, dtype=np.float32)
        norm = np.linalg.norm(emb)
        if not np.isfinite(norm) or norm <= 0:
            skipped += 1
            continue
        chunk_ids.append(row["chunk_id"])
        vectors.append(emb / norm)
        rows[row["chunk_id"]] = dict(row)
    matrix = np.vstack(vectors) if vectors else np.empty((0, EMBEDDING_DIM), dtype=np.float32)
    _EMB_CACHE.update(
        mtime=mtime, chunk_ids=chunk_ids, matrix=matrix, rows=rows, skipped=skipped
    )
    return _EMB_CACHE


def rrf_fuse(rankings: list[list[str]], k: int = RRF_K) -> dict[str, float]:
    """Reciprocal Rank Fusion.

    Replaces the previous `FTS_WEIGHT * bm25 + COSINE_WEIGHT * cosine` blend.
    That blend min-max normalized bm25 over the candidate set, so the best
    keyword hit always scored exactly 1.0 no matter how poorly it matched,
    while cosine similarity occupies a narrow band (~0.6-0.9 in practice).
    The scales did not line up, and keyword-dense chunks (tables of contents,
    indexes, case-number lists) displaced substantive prose.

    RRF only uses rank position, so the two scales never have to agree.
    """
    scores: dict[str, float] = {}
    for ranking in rankings:
        for rank, chunk_id in enumerate(ranking, start=1):
            scores[chunk_id] = scores.get(chunk_id, 0.0) + 1.0 / (k + rank)
    return scores


def fetch_fts_candidates(con: sqlite3.Connection, query: str):
    match_query = build_fts_query(query)
    if not match_query:
        return []
    try:
        return con.execute(
            """
            SELECT chunk_id, bm25(chunks_fts) AS score
            FROM chunks_fts
            WHERE chunks_fts MATCH ?
            ORDER BY score
            LIMIT ?
            """,
            (match_query, FTS_CANDIDATE_LIMIT),
        ).fetchall()
    except sqlite3.OperationalError:
        return []


app = FastAPI(title="legal-books search")


class SearchReq(BaseModel):
    query: str = Field(..., min_length=1, max_length=500)
    top_k: int = Field(default=5, ge=1, le=20)


@app.get("/health")
def health():
    con = get_db()
    books = con.execute("SELECT COUNT(*) FROM books").fetchone()[0]
    chunks = con.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    con.close()
    return {"status": "ok", "books": books, "chunks": chunks}


@app.post("/search")
def search(req: SearchReq):
    if not req.query.strip():
        raise HTTPException(400, "query is empty")
    con = get_db()
    if con.execute("SELECT 1 FROM chunks LIMIT 1").fetchone() is None:
        con.close()
        return {"query": req.query, "results": []}
    warnings = []

    # 1) FTS5 candidates. This path must work even when Gemini is unavailable.
    fts_rows = fetch_fts_candidates(con, req.query)
    fts_ranking = [r["chunk_id"] for r in fts_rows]     # already ORDER BY bm25

    # 2) Cosine similarity via the in-memory embedding cache.
    cos_ranking: list[str] = []
    chunk_map = {}
    try:
        qemb = np.asarray(embed_query(req.query), dtype=np.float32)
        qnorm = np.linalg.norm(qemb)
        if qemb.shape != (EMBEDDING_DIM,) or not np.isfinite(qnorm) or qnorm <= 0:
            raise ValueError(f"Invalid query embedding: expected {EMBEDDING_DIM} finite, nonzero dimensions")
        cache = load_embedding_cache(con)
        if cache["skipped"]:
            warnings.append(
                f"invalid embedding: {cache['skipped']} chunk(s) skipped; reindex needed"
            )
        if cache["chunk_ids"]:
            qunit = qemb / qnorm
            sims = cache["matrix"] @ qunit
            # Take top cosine candidates only; FTS-only hits are fetched below.
            n = min(FTS_CANDIDATE_LIMIT, sims.shape[0])
            top = np.argpartition(sims, -n)[-n:]        # full sort is wasted work
            for i in top[np.argsort(-sims[top])]:
                cid = cache["chunk_ids"][int(i)]
                cos_ranking.append(cid)
                chunk_map[cid] = cache["rows"][cid]
    except Exception as exc:
        qemb = None
        cos_score_map.clear()
        chunk_map.clear()
        warnings.append(f"semantic embedding unavailable; used FTS only: {exc}")

    # 3) Combine
    all_ids = set(fts_ranking) | set(cos_ranking)
    combined = []
    # Pull rows we do not have yet (usually FTS-only hits).
    missing = all_ids - set(chunk_map.keys())
    if missing:
        placeholders = ",".join("?" * len(missing))
        for r in con.execute(
            f"SELECT chunk_id, book_id, page, page_end, chunk_text FROM chunks WHERE chunk_id IN ({placeholders})",
            tuple(missing),
        ):
            chunk_map[r["chunk_id"]] = r

    fused = rrf_fuse([r for r in (fts_ranking, cos_ranking) if r])
    combined = sorted(fused.items(), key=lambda x: -x[1])

    # Lookup book metadata
    books = {b["book_id"]: dict(b) for b in con.execute("SELECT * FROM books")}

    results = []
    stale = 0
    for cid, score in combined:
        if len(results) >= req.top_k:
            break
        # A chunk_id can appear in the FTS index but no longer in `chunks`
        # (interrupted reindex, manual DELETE). Indexing chunk_map directly
        # raised KeyError and turned the whole search into a 500.
        row = chunk_map.get(cid)
        if row is None:
            stale += 1
            continue
        book = books.get(row["book_id"], {})
        results.append({
            "chunk_id": cid,
            "score": round(score, 4),
            "book_id": row["book_id"],
            "author": book.get("author"),
            "title": book.get("title"),
            "edition": book.get("edition"),
            "year": book.get("year"),
            "page": row["page"],
            "page_end": row["page_end"],
            "chunk_text": row["chunk_text"],
        })
    con.close()
    if stale:
        warnings.append(
            f"{stale} chunk(s) present in the FTS index but missing from `chunks`; "
            "run reindex.sh to rebuild")
    response = {"query": req.query, "results": results}
    if warnings:
        response["warnings"] = warnings[:5]
    return response


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8766)
