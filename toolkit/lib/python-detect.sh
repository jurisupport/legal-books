#!/usr/bin/env bash
# Shared Python detection for installers.
#
# Windows Git Bash can run `py -3.12` even when `sys.executable` is empty or
# awkward to convert. Keep the selected command as an argv array instead of
# trying to collapse it into one executable path.

PY_CMD=()
PY_VERSION=""
PY_EXE=""
PY_DISPLAY=""

_try_python_candidate() {
  local min_version="$1"
  shift

  command -v "$1" >/dev/null 2>&1 || return 1

  local probe
  if ! probe="$("$@" - <<'PY' 2>/dev/null
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}\t{sys.executable or ''}")
PY
)"; then
    return 1
  fi

  if ! "$@" - "$min_version" <<'PY' >/dev/null 2>&1; then
import sys

want = tuple(int(part) for part in sys.argv[1].split("."))
have = sys.version_info[: len(want)]
raise SystemExit(0 if have >= want else 1)
PY
    return 1
  fi

  probe="${probe//$'\r'/}"
  [[ "$probe" == *$'\t'* ]] || return 1
  PY_VERSION="${probe%%$'\t'*}"
  PY_EXE="${probe#*$'\t'}"
  PY_CMD=("$@")
  PY_DISPLAY="${PY_EXE:-$*}"
  return 0
}

select_python() {
  local min_version="${1:-3.10}"
  PY_CMD=()
  PY_VERSION=""
  PY_EXE=""
  PY_DISPLAY=""

  if [[ "${PLATFORM:-}" == "windows" ]]; then
    _try_python_candidate "$min_version" py -3.12 ||
      _try_python_candidate "$min_version" py -3.11 ||
      _try_python_candidate "$min_version" py -3 ||
      _try_python_candidate "$min_version" python3 ||
      _try_python_candidate "$min_version" python
  else
    # macOS는 `python3`가 시스템 3.9인 경우가 흔하다. 버전이 붙은 이름을
    # 먼저(최신순) 훑지 않으면, Homebrew로 3.12/3.14를 깔아둔 맥에서도
    # "Python 3.10+ 필요"로 설치가 중단된다.
    local minor
    for minor in 14 13 12 11 10; do
      _try_python_candidate "$min_version" "python3.${minor}" && return 0
    done
    _try_python_candidate "$min_version" python3 ||
      _try_python_candidate "$min_version" python
  fi
}

run_python() {
  if [[ "${#PY_CMD[@]}" -eq 0 ]]; then
    echo "Python command not selected. Call select_python first." >&2
    return 127
  fi
  "${PY_CMD[@]}" "$@"
}
