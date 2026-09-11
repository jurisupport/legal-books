#!/usr/bin/env bash
# Static and dry-run checks for toolkit/install.sh.

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

install_home="$(mktemp -d)"
trap 'rm -rf "$install_home"' EXIT

check_skill_plan() {
  local claude="$1" codex="$2" output target expected found
  shift 2
  if ! output="$(HOME="$install_home" bash "$INSTALL" --dry-run "$@" 2>&1)"; then
    fail "skill dry-run completes: $*"
    printf '%s\n' "$output" >&2
    return
  fi
  for target in .claude .agents; do
    expected="$claude"
    [[ "$target" != .agents ]] || expected="$codex"
    found=0
    if grep -qF -- "PLAN: cp $ROOT/skills/legal-books/SKILL.md $install_home/$target/skills/legal-books/SKILL.md" <<< "$output"; then
      found=1
    fi
    if [[ "$found" == "$expected" ]]; then
      printf 'ok - %s skill target for [%s]\n' "$target" "$*"
    else
      fail "$target skill target for [$*]"
    fi
  done
}

check_skill_plan 0 0
check_skill_plan 1 0 --with-skill
check_skill_plan 0 1 --with-codex-skill
check_skill_plan 1 1 --with-skill --with-codex-skill --plan

if HOME="$install_home" bash "$INSTALL" --dry-run --unknown >/dev/null 2>&1; then
  fail "installer rejects unknown options"
else
  printf 'ok - installer rejects unknown options\n'
fi

if [[ -z "$(ls -A "$install_home")" ]]; then
  printf 'ok - dry-run leaves HOME unchanged\n'
else
  fail "dry-run leaves HOME unchanged"
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
