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
    printf '#!/usr/bin/env python3\nprint("ok")\n' > "$tmpdir/legal-books/scripts/ingest.py"
  fi
}

run_add_book() {
  set +e
  output=$(
    HOME="$tmpdir" PATH="$bindir:$PATH" ${CLEAN_FAILED:+LEGAL_BOOKS_CLEAN_FAILED=$CLEAN_FAILED} bash "$SCRIPT" \
      --pdf "$tmpdir/scan.pdf" \
      --author "저자" \
      --title "민법총칙" \
      --edition "제1판" \
      --year 2026 \
      --publisher "출판사" 2>&1
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

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
