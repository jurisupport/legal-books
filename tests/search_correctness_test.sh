#!/usr/bin/env bash
# 검색 정확성 회귀 테스트.
#
# 웹 프레임워크 의존성(fastapi 등)은 스텁으로 대체한다. 검증 대상은
# build_fts_query()·rrf_fuse()와 스키마 트리거이며, 이들은 순수 로직이라
# 서버를 띄우지 않고도 확인할 수 있다.

set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$REPO_DIR/toolkit/lib/python-detect.sh"
select_python 3.10 || { echo "not ok - Python 3.10+ 없음"; exit 1; }

run_python - "$REPO_DIR" <<'PY'
import os, sqlite3, sys, tempfile, types

repo = sys.argv[1]
for name in ("fastapi", "pydantic", "dotenv"):
    sys.modules[name] = types.ModuleType(name)
sys.modules["fastapi"].FastAPI = lambda **k: types.SimpleNamespace(
    get=lambda *a, **k: (lambda f: f), post=lambda *a, **k: (lambda f: f))
sys.modules["fastapi"].HTTPException = Exception
sys.modules["pydantic"].BaseModel = object
sys.modules["pydantic"].Field = lambda *a, **k: None
sys.modules["dotenv"].load_dotenv = lambda *a, **k: None

sys.path.insert(0, os.path.join(repo, "toolkit", "lib"))
sys.path.insert(0, os.path.join(repo, "toolkit", "server"))
import legal_books_db as L
import server as S

failures = 0


def check(cond, label):
    global failures
    print(("ok - " if cond else "not ok - ") + label)
    if not cond:
        failures += 1


db = os.path.join(tempfile.mkdtemp(), "t.db")
L.ensure_db(db)
con = sqlite3.connect(db)
con.execute("INSERT INTO books VALUES('001','저자','서명','제1판',2020,'출판사',NULL)")
for i, text in enumerate([
        "임차보증금반환채권의 양도에 임대인의 동의를 요하지 않는다",
        "소멸시효 중단사유로서 재판상 청구의 범위",
        "개인정보 보호법 GDPR 의 목적 규정"]):
    con.execute("INSERT INTO chunks VALUES(?,?,?,?,?,NULL)",
                (f"001_{i:05d}", "001", 10 + i, 10 + i, text))
con.commit()

# 외부 콘텐츠 FTS는 트리거가 없으면 rebuild 전까지 색인이 어긋난다.
n = con.execute("SELECT count(*) FROM chunks_fts").fetchone()[0]
check(n == 3, f"INSERT가 FTS에 자동 반영된다 (행 {n}개)")
con.execute("DELETE FROM chunks WHERE chunk_id='001_00000'")
con.commit()
n = con.execute("SELECT count(*) FROM chunks_fts").fetchone()[0]
check(n == 2, f"DELETE가 FTS에 자동 반영된다 (행 {n}개)")

# 구두점이 든 평범한 질문이 FTS5 구문 오류를 내면 안 된다.
# 서버가 실제로 타는 경로(fetch_fts_candidates)로 확인한다 —
# 토큰이 하나도 안 남는 질의는 그 안에서 걸러져야 한다.
con.row_factory = sqlite3.Row
for q in ['대항요건은 무엇인가?', '개인정보 보호법(GDPR)의 목적',
          '소멸시효 중단 - 재판상 청구', '따옴표 "포함" 질의',
          'AND OR NOT 예약어', '*', '???', '']:
    try:
        S.fetch_fts_candidates(con, q)
        ok = True
    except Exception as exc:
        ok = False
        print(f"#   {q!r} → {exc}")
    check(ok, f"구두점 질의가 구문 오류를 내지 않는다: {q!r}")

# 실제로 걸리는지도 확인 (가드가 전부 삼켜버리면 의미가 없다)
hits = S.fetch_fts_candidates(con, "소멸시효 중단사유는 무엇인가?")
check(len(hits) > 0, f"구두점이 붙어도 본문이 검색된다 ({len(hits)}건)")

# RRF는 순위만 쓰므로 점수 스케일 차이에 영향받지 않는다.
fused = S.rrf_fuse([["a", "b", "c"], ["c", "a"]])
ranked = [cid for cid, _ in sorted(fused.items(), key=lambda x: -x[1])]
check(ranked[0] == "a", f"양쪽에서 상위인 문서가 1위 (순위: {ranked})")
check(ranked[-1] == "b", f"한쪽에만 있고 하위인 문서가 최하위 (순위: {ranked})")
check(S.rrf_fuse([]) == {}, "빈 입력에서 빈 결과")

con.close()
sys.exit(1 if failures else 0)
PY
