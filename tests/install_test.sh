#!/usr/bin/env bash
# Static checks for toolkit/install.sh (jurisupport-plugins에서 이관).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/toolkit/install.sh"

failures=0

fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$((failures + 1))
}

expect_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    printf 'ok - %s\n' "$label"
  else
    fail "$label"
  fi
}

expect_contains \
  "Gemini API key URL is defined" \
  "$INSTALL" \
  'GEMINI_API_KEY_URL="https://aistudio.google.com/apikey"'

expect_contains \
  "Gemini key flow opens browser" \
  "$INSTALL" \
  'open_url "$GEMINI_API_KEY_URL"'

expect_contains \
  "installer copies shared schema lib" \
  "$INSTALL" \
  'cp "$TOOLKIT_DIR/lib/legal_books_db.py" "$ROOT/lib/legal_books_db.py"'

expect_contains \
  "skill copy is opt-in for non-plugin installs" \
  "$INSTALL" \
  '--with-skill) WITH_SKILL=1 ;;'

# dry-run이 실제 변경 없이 끝까지 도는지
if bash "$INSTALL" --dry-run >/dev/null 2>&1; then
  printf 'ok - install.sh --dry-run completes\n'
else
  fail "install.sh --dry-run completes"
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
