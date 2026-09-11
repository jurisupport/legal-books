#!/usr/bin/env bash
# Regression tests for legal-books add_book.sh retry safety.
#
# 실패 시 OCR 결과를 보존하고, 재실행 시 OCR을 건너뛰고 이어서 진행하며,
# LEGAL_BOOKS_CLEAN_FAILED=1일 때만 실패 폴더를 삭제하는 동작을 검증한다.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/toolkit/scripts/add_book.sh"

failures=0

fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$((failures + 1))
}

setup_env() {
  tmpdir="$(mktemp -d)"
  bindir="$tmpdir/bin"
  mkdir -p "$bindir" "$tmpdir/legal-books/.venv/bin" "$tmpdir/legal-books/books" "$tmpdir/legal-books/db" "$tmpdir/legal-books/scripts"
  touch "$tmpdir/legal-books/.venv/bin/activate"
  printf 'scan\n' > "$tmpdir/scan.pdf"

  # ocrmypdf mock: 호출 횟수를 기록하고 입력을 출력으로 복사
  cat > "$bindir/ocrmypdf" <<SH
#!/usr/bin/env bash
echo run >> "$tmpdir/ocr_calls"
args=("\$@")
cp "\${args[\$#-2]}" "\${args[\$#-1]}"
SH
  chmod +x "$bindir/ocrmypdf"

  cat > "$bindir/tesseract" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "--list-langs" ]]; then
  printf 'List of available languages in "x" (2):\neng\nkor\n'
  exit 0
fi
exit 0
SH
  chmod +x "$bindir/tesseract"
}

set_ingest() {  # set_ingest fail|ok
  if [[ "$1" == "fail" ]]; then
    printf '#!/usr/bin/env python3\nraise SystemExit(9)\n' > "$tmpdir/legal-books/scripts/ingest.py"
  else
    cat > "$tmpdir/legal-books/scripts/ingest.py" <<'PY'
import argparse
import os
import sqlite3
from pathlib import Path

ap = argparse.ArgumentParser()
for name in ("book-id", "author", "title", "edition"):
    ap.add_argument(f"--{name}")
args, _ = ap.parse_known_args()
with sqlite3.connect(Path(os.environ["HOME"]) / "legal-books/db/books_fts.db") as con:
    con.execute("CREATE TABLE IF NOT EXISTS books (book_id TEXT PRIMARY KEY, author TEXT, title TEXT, edition TEXT)")
    con.execute("INSERT OR REPLACE INTO books VALUES (?,?,?,?)", (args.book_id, args.author, args.title, args.edition))
PY
  fi
}

run_add_book() {
  set +e
  output=$(
    env HOME="$tmpdir" PATH="$bindir:$PATH" LEGAL_BOOKS_CLEAN_FAILED="${CLEAN_FAILED:-0}" bash "$SCRIPT" \
      --pdf "$tmpdir/scan.pdf" \
      --author "저자" \
      --title "민법총칙" \
      --edition "제1판" \
      --year 2026 \
      --publisher "출판사" "$@" 2>&1
  )
  status=$?
  set -e
}

# ------------------------------------------------------------
# 1) ingest 실패 → 실패 종료 + incomplete 폴더와 OCR PDF 보존
# ------------------------------------------------------------
setup_env
set_ingest fail
run_add_book

if [[ "$status" -eq 0 ]]; then
  fail "add_book fails when ingest fails"
elif compgen -G "$tmpdir/legal-books/books/001_*" >/dev/null; then
  fail "add_book does not create completed folder on ingest failure"
  printf '%s\n' "$output" >&2
elif ! compgen -G "$tmpdir/legal-books/books/.001_*.incomplete" >/dev/null; then
  fail "add_book keeps incomplete folder after ingest failure"
  printf '%s\n' "$output" >&2
elif inc_pdf="$(compgen -G "$tmpdir/legal-books/books/.001_*.incomplete/001.pdf" | head -n 1)"; [[ -z "$inc_pdf" || ! -s "$inc_pdf" ]]; then
  fail "add_book keeps finished OCR pdf in incomplete folder"
  printf '%s\n' "$output" >&2
else
  printf 'ok - add_book keeps incomplete folder and OCR pdf after ingest failure\n'
fi

# ------------------------------------------------------------
# 2) 재실행 → 같은 book_id 재사용, OCR 건너뜀, 성공 시 완료 폴더로 이동
# ------------------------------------------------------------
set_ingest ok
run_add_book

ocr_calls=$(wc -l < "$tmpdir/ocr_calls" | tr -d ' ')
if [[ "$status" -ne 0 ]]; then
  fail "add_book rerun succeeds after fixing ingest"
  printf '%s\n' "$output" >&2
elif [[ "$ocr_calls" != "1" ]]; then
  fail "add_book rerun skips OCR (ocrmypdf called $ocr_calls times, expected 1)"
elif ! compgen -G "$tmpdir/legal-books/books/001_*" >/dev/null; then
  fail "add_book rerun completes book folder"
  printf '%s\n' "$output" >&2
elif compgen -G "$tmpdir/legal-books/books/.001_*.incomplete" >/dev/null; then
  fail "add_book rerun removes incomplete folder after success"
else
  printf 'ok - add_book rerun reuses book_id, skips OCR, completes\n'
fi
rm -rf "$tmpdir"

# ------------------------------------------------------------
# 3) LEGAL_BOOKS_CLEAN_FAILED=1 → 실패 폴더 삭제
# ------------------------------------------------------------
setup_env
set_ingest fail
CLEAN_FAILED=1 run_add_book

if [[ "$status" -eq 0 ]]; then
  fail "add_book fails when ingest fails (clean mode)"
elif compgen -G "$tmpdir/legal-books/books/.001_*.incomplete" >/dev/null; then
  fail "LEGAL_BOOKS_CLEAN_FAILED=1 removes incomplete folder"
  printf '%s\n' "$output" >&2
else
  printf 'ok - LEGAL_BOOKS_CLEAN_FAILED=1 removes incomplete folder\n'
fi
rm -rf "$tmpdir"

# An interrupted book reserves its ID while another book is added.
setup_env
set_ingest fail
run_add_book
set_ingest ok
run_add_book --title "다른 책"
if [[ "$status" -ne 0 ]] || ! compgen -G "$tmpdir/legal-books/books/002_*" >/dev/null; then
  fail "incomplete book reserves its ID for a later retry"
else
  printf 'ok - incomplete book reserves its ID\n'
fi
run_add_book
if [[ "$status" -ne 0 ]] || ! python3 - "$tmpdir/legal-books/db/books_fts.db" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as con:
    assert con.execute("SELECT book_id, title FROM books ORDER BY book_id").fetchall() == [("001", "민법총칙"), ("002", "다른 책")]
PY
then
  fail "retry preserves the other book's database rows"
else
  printf 'ok - retry preserves both books in the database\n'
fi
rm -rf "$tmpdir"

# Refuse a collision left by older versions instead of overwriting another book.
setup_env
set_ingest fail
run_add_book
mkdir "$tmpdir/legal-books/books/001_다른저자_다른책_"
set_ingest ok
run_add_book
if [[ "$status" -eq 0 ]]; then
  fail "retry rejects an ID already owned by a completed folder"
else
  printf 'ok - retry rejects an existing completed-folder ID collision\n'
fi
rmdir "$tmpdir/legal-books/books/001_다른저자_다른책_"
env HOME="$tmpdir" python3 "$tmpdir/legal-books/scripts/ingest.py" \
  --book-id 001 --author "other" --title "other" --edition ""
run_add_book
if [[ "$status" -eq 0 ]]; then
  fail "retry rejects an ID already owned by another database book"
else
  printf 'ok - retry rejects an existing database ID collision\n'
fi
env HOME="$tmpdir" python3 "$tmpdir/legal-books/scripts/ingest.py" \
  --book-id 001 --author "저자" --title "민법총칙" --edition "제1판"
run_add_book
if [[ "$status" -ne 0 || "$(wc -l < "$tmpdir/ocr_calls" | tr -d ' ')" != 1 ]]; then
  fail "retry can finish a book already committed to the database"
else
  printf 'ok - retry can finish after the same book was committed\n'
fi
rm -rf "$tmpdir"

# Brackets in metadata are literal text, not a find glob pattern.
setup_env
set_ingest fail
run_add_book --title "민법[총칙]"
mkdir "$tmpdir/legal-books/books/002_previous"
set_ingest ok
run_add_book --title "민법[총칙]"
if [[ "$status" -ne 0 || "$(wc -l < "$tmpdir/ocr_calls" | tr -d ' ')" != 1 ]] || \
    [[ ! -d "$tmpdir/legal-books/books/001_저자_민법[총칙]_제1판" ]]; then
  fail "retry matches bracketed book titles literally"
else
  printf 'ok - retry matches bracketed titles literally\n'
fi
rm -rf "$tmpdir"

# IDs keep working after 999, including retry and reindex folder discovery.
setup_env
mkdir "$tmpdir/legal-books/books/999_previous"
set_ingest fail
run_add_book
mkdir "$tmpdir/legal-books/books/1001_previous"
set_ingest ok
env HOME="$tmpdir" python3 "$tmpdir/legal-books/scripts/ingest.py" \
  --book-id 1001 --author "other" --title "other" --edition ""
run_add_book
if [[ "$status" -ne 0 || "$(wc -l < "$tmpdir/ocr_calls" | tr -d ' ')" != 1 ]] || \
    [[ ! -d "$tmpdir/legal-books/books/1000_저자_민법총칙_제1판" ]]; then
  fail "four-digit book ID can be retried without repeating OCR"
else
  printf 'ok - four-digit book ID survives retry\n'
fi
mkdir -p "$tmpdir/legal-books/books/1000_저자_민법총칙_제1판"
touch "$tmpdir/legal-books/books/1000_저자_민법총칙_제1판/1000.pdf"
printf '{"author":"저자","title":"민법총칙","edition":"제1판"}\n' \
  > "$tmpdir/legal-books/books/1000_저자_민법총칙_제1판/1000.meta.json"
if env HOME="$tmpdir" PATH="$bindir:$PATH" bash "$ROOT/toolkit/scripts/reindex.sh" --book-id 1000 >/dev/null 2>&1; then
  printf 'ok - reindex discovers four-digit book IDs\n'
else
  fail "reindex discovers four-digit book IDs"
fi
rm -rf "$tmpdir"

# OCR installed only inside the venv must be discoverable before checks.
setup_env
mv "$bindir/ocrmypdf" "$tmpdir/legal-books/.venv/bin/ocrmypdf"
printf 'export PATH="%s:$PATH"\nexport OCR_VENV_ACTIVE=1\n' "$tmpdir/legal-books/.venv/bin" > "$tmpdir/legal-books/.venv/bin/activate"
cat > "$bindir/tesseract" <<'SH'
#!/usr/bin/env bash
if [[ "${OCR_VENV_ACTIVE:-0}" == 1 ]]; then printf 'eng\nkor\n'; else printf 'eng\n'; fi
SH
set_ingest ok
run_add_book
if [[ "$status" -ne 0 ]]; then
  fail "venv OCR is discovered before the dependency check"
  printf '%s\n' "$output" >&2
else
  printf 'ok - venv OCR is discovered before dependency checks\n'
fi
rm -rf "$tmpdir"

# A quoted tilde path must resolve against the user's home directory.
setup_env
set_ingest ok
run_add_book --pdf '~/scan.pdf'
if [[ "$status" -ne 0 ]]; then
  fail "quoted tilde PDF path resolves correctly"
  printf '%s\n' "$output" >&2
else
  printf 'ok - quoted tilde PDF path resolves correctly\n'
fi
rm -rf "$tmpdir"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
