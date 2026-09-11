# 코드 점검 및 Codex 호환성 — 2026-09-12

점검 기준: `main`의 `aa5bfbb`. 이 문서는 Codex 호환성 및 책 등록·검색 안정성 개선의 변경 내용과 검증 범위를 기록한다.

## 확인하고 수정한 문제

| 문제 | 수정 결과 | 파일 |
| --- | --- | --- |
| 중단된 책의 번호가 새 책에 재사용되어 재시도 시 다른 책의 DB 내용이 교체됨 | 중단 폴더도 번호를 예약하고, 기존 완료 폴더·DB와 충돌하는 재시도를 차단 | [add_book.sh](../toolkit/scripts/add_book.sh) |
| 제목의 대괄호가 검색 패턴으로 해석되고 1000번부터 재시도·재인덱싱이 누락됨 | 제목을 문자 그대로 비교하고 여러 자리 책 번호를 일관되게 처리 | [add_book.sh](../toolkit/scripts/add_book.sh), [reindex.sh](../toolkit/scripts/reindex.sh) |
| 가상환경에만 설치된 OCR을 찾지 못함, 따옴표로 감싼 `~/...` PDF 경로 실패 | 환경 활성화 후 도구 확인, 틸드 경로 확장 수정 | [add_book.sh](../toolkit/scripts/add_book.sh) |
| PDF 일부 페이지 추출 실패를 빈 페이지로 처리한 뒤 기존 책 데이터를 교체함 | 페이지 추출 오류 시 파일·DB 변경 전에 중단; 원래 빈 페이지는 허용 | [ingest.py](../toolkit/scripts/ingest.py) |
| 잘못된 차원·0 벡터·NaN·무한대 임베딩이 저장되거나 검색을 중단시킴 | 저장 전 검증, 잘못된 저장 벡터 제외, 의미 검색 실패 시 키워드 검색 유지 | [ingest.py](../toolkit/scripts/ingest.py), [server.py](../toolkit/server/server.py) |
| Codex 사용자 스킬 설치 경로와 전용 표시 정보가 없음 | 기존 스킬을 재사용하는 `--with-codex-skill` 옵션과 호환 매니페스트 추가; 기존 Claude 옵션 유지 | [install.sh](../toolkit/install.sh), [plugin.json](../.codex-plugin/plugin.json) |
| PDF 페이지 순서를 인쇄 쪽수로 인용할 수 있음 | 확인 전에는 PDF 페이지로 표시하도록 명시; 실제 인용으로 오인할 수 있는 예시를 자리표시자로 교체 | [SKILL.md](../skills/legal-books/SKILL.md) |
| 실패 폴더 삭제 테스트가 명령 실행 오류도 성공으로 처리함 | 환경변수 전달을 바로잡아 실제 삭제 동작 검사 | [책 등록 테스트](../tests/legal_books_add_book_test.sh) |

새 실행 의존성이나 별도 MCP 서버는 추가하지 않았다. Codex와 Claude Code는 같은 스킬과 검색 서버를 사용한다. Codex 사용자 스킬 경로와 호환 매니페스트는 [공식 스킬 문서](https://learn.chatgpt.com/docs/build-skills)와 [플러그인 문서](https://developers.openai.com/plugins/build/plugins)를 확인했다.

설치·사용 문서는 [README](../README.md)와 [스캔 안내](book-scanning.md)에 반영했다.

## 검증

- [설치 검사](../tests/install_test.sh): 15개 통과. Codex·Claude 개별/동시 선택, 잘못된 옵션 거부, dry-run 무변경 확인.
- [책 등록 검사](../tests/legal_books_add_book_test.sh): 13개 통과. 실패 후 재시도, 다른 책 데이터 보존, 기존 충돌, 네 자리 번호, OCR 환경, 틸드 경로 확인.
- [등록·검색 검사](../tests/ingest_search_test.py): 6개 통과. 임시 DB·합성 데이터·모의 API 응답으로 데이터 보존과 검색 복구 확인.
- API 응답 검사: health, 잘못된 저장 벡터가 있는 검색, 페이지 범위, 빈 검색어와 입력 상한 확인.
- Ruff의 오류·미정의 이름 등 기본 검사, Pyright 타입 검사, Python 3.10 문법 호환 검사, 셸 문법 검사, diff 공백 검사 통과.
- 제공된 Codex 플러그인 검사기와 스킬 검사기 통과.

주요 결함은 수정 전 실패를 먼저 확인했다. 테스트 실행 방법은 [개발 검증](../README.md#개발-검증)을 참조한다.

## 검증 범위와 남은 제한

- 실제 Gemini 호출, 실제 스캔 PDF의 OCR, Windows 실행, Codex 앱에서 실제 설치 후 호출은 검증하지 않았다. 개인 서적·API 키·실행 중인 검색 서버는 변경하지 않았다.
- 책 추가는 한 번에 하나씩 실행한다. 여러 프로세스의 동시 번호 배정은 잠금으로 보호하지 않는다.
- PDF 페이지와 인쇄 쪽수의 자동 대응 기능은 없다. 스킬은 이를 구분해 표기하도록 수정했다.
- 로컬 Codex 앱·CLI용 구성이다. 클라우드 작업에서 사용자 컴퓨터의 localhost에 직접 연결하는 기능은 없다.
- 기존 [PR #1](https://github.com/jurisupport/legal-books/pull/1)의 검색 순위 변경·Python 탐색·키 입력 수정은 이 브랜치에 병합하지 않았다. 이번 변경과 별도로 검토해야 한다.
