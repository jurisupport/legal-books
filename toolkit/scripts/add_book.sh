#!/usr/bin/env bash
# Add a book to legal-books DB.
#
# Usage:
#   add_book.sh --pdf /path/to/scan.pdf \
#               --author "곽윤직" --title "민법총칙" \
#               --edition "제9판" --year 2018 --publisher "박영사"

set -euo pipefail

ROOT="$HOME/legal-books"
# OS 감지 → venv activate 경로 (Windows venv는 Scripts/, 그 외는 bin/)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) VENV="$ROOT/.venv/Scripts/activate"; PY=python; PLATFORM=windows ;;
  Darwin*)              VENV="$ROOT/.venv/bin/activate";     PY=python3; PLATFORM=mac ;;
  *)                    VENV="$ROOT/.venv/bin/activate";     PY=python3; PLATFORM=linux ;;
esac

# shellcheck disable=SC1090
source "$VENV"

# OCR 의존성 사전 점검 (책 추가 시점에 필요)
missing=""
command -v ocrmypdf  >/dev/null 2>&1 || missing+="ocrmypdf "
command -v tesseract >/dev/null 2>&1 || missing+="tesseract "
if [[ -n "$missing" ]]; then
  echo "[add_book] 다음 도구가 필요합니다: $missing" >&2
  echo "" >&2
  case "$PLATFORM" in
    mac)
      echo "  설치: brew install ocrmypdf tesseract tesseract-lang" >&2 ;;
    linux)
      echo "  설치: sudo apt install ocrmypdf tesseract-ocr tesseract-ocr-kor" >&2 ;;
    windows)
      echo "  설치 (PowerShell):" >&2
      echo "    winget install UB-Mannheim.TesseractOCR" >&2
      echo "    winget install ArtifexSoftware.GhostScript.AGPL" >&2
      echo "    winget install qpdf.qpdf       # 없으면 https://github.com/qpdf/qpdf/releases" >&2
      echo "    그리고 venv 안에서:" >&2
      echo "      source ~/legal-books/.venv/Scripts/activate" >&2
      echo "      pip install ocrmypdf" >&2
      echo "  설치 후 새 Git Bash 창에서 본 스크립트 재실행" >&2
      ;;
  esac
  exit 1
fi

# 한국어 언어팩 확인
if ! tesseract --list-langs 2>&1 | grep -q "kor"; then
  echo "[add_book] Tesseract 한국어 언어팩(kor) 없음." >&2
  echo "  Mac:    brew install tesseract-lang" >&2
  echo "  Linux:  sudo apt install tesseract-ocr-kor" >&2
  echo "  Windows: UB-Mannheim 빌드 재설치(설치 마법사에서 'Korean' 체크)" >&2
  exit 1
fi

expand_user_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

sanitize_path_segment() {
  printf '%s' "$1" | tr -d '/\\:*?"<>|'
}

PDF=""; AUTHOR=""; TITLE=""; EDITION=""; YEAR="0"; PUBLISHER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pdf)        PDF="$2"; shift 2 ;;
    --author)     AUTHOR="$2"; shift 2 ;;
    --title)      TITLE="$2"; shift 2 ;;
    --edition)    EDITION="$2"; shift 2 ;;
    --year)       YEAR="$2"; shift 2 ;;
    --publisher)  PUBLISHER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

for v in PDF AUTHOR TITLE; do
  if [[ -z "${!v}" ]]; then
    echo "Required: --pdf, --author, --title" >&2
    exit 1
  fi
done

PDF="$(expand_user_path "$PDF")"
if [[ ! -f "$PDF" ]]; then
  echo "PDF not found: $PDF" >&2; exit 1
fi

# Sanitize for folder name
SAFE_TITLE=$(sanitize_path_segment "$TITLE")
SAFE_AUTHOR=$(sanitize_path_segment "$AUTHOR")
SAFE_EDITION=$(sanitize_path_segment "$EDITION")

# Reserve IDs in completed and incomplete folders, and match retries literally.
# ponytail: sequential imports; lock allocation before supporting concurrent runs.
BOOK_ID=$(ROOT="$ROOT" BOOK_SUFFIX="${SAFE_AUTHOR}_${SAFE_TITLE}_${SAFE_EDITION}" \
  AUTHOR="$AUTHOR" TITLE="$TITLE" EDITION="$EDITION" "$PY" <<'PY'
import os
import re
import sqlite3
from pathlib import Path

root = Path(os.environ["ROOT"])
ids = set()
completed_ids = set()
retries = []
books_dir = root / "books"
if books_dir.exists():
    for child in books_dir.iterdir():
        if child.is_dir():
            match = re.match(r"^\.?(\d+)_", child.name)
            if match:
                book_id = match.group(1)
                ids.add(int(book_id))
                if not child.name.startswith("."):
                    completed_ids.add(int(book_id))
                if child.name == f".{book_id}_{os.environ['BOOK_SUFFIX']}.incomplete":
                    retries.append(book_id)

db_books = {}
db_path = root / "db" / "books_fts.db"
if db_path.exists():
    con = sqlite3.connect(db_path)
    try:
        for book_id, author, title, edition in con.execute("SELECT book_id, author, title, edition FROM books"):
            if re.fullmatch(r"\d+", str(book_id)):
                ids.add(int(book_id))
                db_books[int(book_id)] = (author or "", title or "", edition or "")
    finally:
        con.close()

if len(retries) > 1:
    raise SystemExit("[add_book] 여러 중단 폴더가 같은 책과 일치합니다. 폴더를 확인하세요.")
if retries:
    book_id = retries[0]
    metadata = tuple(os.environ[key] for key in ("AUTHOR", "TITLE", "EDITION"))
    if int(book_id) in completed_ids or (
        int(book_id) in db_books and db_books[int(book_id)] != metadata
    ):
        raise SystemExit(f"[add_book] Book ID {book_id}는 다른 책에서 사용 중입니다. 중단 폴더를 확인하세요.")
    print(book_id)
else:
    print(f"{max(ids, default=0) + 1:03d}")
PY
)

FINAL_BOOK_DIR="$ROOT/books/${BOOK_ID}_${SAFE_AUTHOR}_${SAFE_TITLE}_${SAFE_EDITION}"
BOOK_DIR="$ROOT/books/.${BOOK_ID}_${SAFE_AUTHOR}_${SAFE_TITLE}_${SAFE_EDITION}.incomplete"

if [[ -d "$BOOK_DIR" ]]; then
  echo "[add_book] 이전 중단 지점 발견, 이어서 진행: $BOOK_DIR"
fi

if [[ -e "$FINAL_BOOK_DIR" ]]; then
  echo "[add_book] target folder already exists: $FINAL_BOOK_DIR" >&2
  exit 1
fi
mkdir -p "$BOOK_DIR"

echo "[add_book] Book ID: $BOOK_ID"
echo "[add_book] Folder:  $FINAL_BOOK_DIR"

cleanup_failed_book_dir() {
  local status=$?
  if [[ "$status" -ne 0 && -n "${BOOK_DIR:-}" && -d "$BOOK_DIR" ]]; then
    if [[ "${LEGAL_BOOKS_CLEAN_FAILED:-0}" == "1" ]]; then
      echo "[add_book] failed; removing incomplete folder: $BOOK_DIR" >&2
      rm -rf "$BOOK_DIR"
    else
      echo "[add_book] 실패. OCR 결과는 보존됩니다: $BOOK_DIR" >&2
      echo "[add_book] 같은 명령을 다시 실행하면 OCR을 건너뛰고 이어서 진행합니다." >&2
    fi
  fi
}
trap cleanup_failed_book_dir EXIT

# Step 1: OCR (if PDF doesn't already have text layer)
OCR_PDF="$BOOK_DIR/${BOOK_ID}.pdf"
if [[ -s "$OCR_PDF" ]]; then
  echo "[add_book] Step 1/3: 이전 OCR 결과 재사용, OCR 건너뜀"
else
  echo "[add_book] Step 1/3: OCR (Korean + English, this may take 5–20 min)"
  ocrmypdf --skip-text --language kor+eng --output-type pdf "$PDF" "$OCR_PDF.tmp" || {
    echo "OCR failed. If the PDF already has text, try --force-ocr flag." >&2
    exit 1
  }
  mv "$OCR_PDF.tmp" "$OCR_PDF"
fi

# Step 2: Convert to markdown + chunk + embed
echo "[add_book] Step 2/3: Extracting text and chunking"
"$PY" "$ROOT/scripts/ingest.py" \
  --book-id "$BOOK_ID" \
  --pdf "$OCR_PDF" \
  --book-dir "$BOOK_DIR" \
  --author "$AUTHOR" \
  --title "$TITLE" \
  --edition "$EDITION" \
  --year "$YEAR" \
  --publisher "$PUBLISHER"

mv "$BOOK_DIR" "$FINAL_BOOK_DIR"
trap - EXIT

echo "[add_book] Step 3/3: Done. Book $BOOK_ID indexed."
echo "[add_book] Folder:  $FINAL_BOOK_DIR"
echo ""
echo "Search test:"
echo "  curl -X POST http://localhost:8766/search -H 'Content-Type: application/json' -d '{\"query\":\"$TITLE\",\"top_k\":3}'"
