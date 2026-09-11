# legal-books

사무소 보유 법률서적(교과서)을 스캔·OCR·임베딩하여 **로컬 하이브리드 검색**으로 출처와 함께 인용하는 Claude Code·Codex용 스킬과 로컬 검색 도구.

```
"이 사건 시효 쟁점에 대해 교과서 바탕으로 정리해줘"
→ 곽윤직 『민법총칙』 제○판, pp.○○○~○○○ 인용 + 본문 발췌 + 적용
```

- **로컬 우선**: 책 PDF·텍스트·DB 모두 `~/legal-books/`에 저장 (SQLite FTS5)
- **하이브리드 검색**: 한국어 접두어 키워드 검색(FTS5) 30% + Gemini 임베딩 의미 검색 70%
- **정확한 인용**: 청크마다 시작·끝 페이지 기록, 직접인용은 원문 조각과 글자 단위 검증
- **점진 구축**: 책 0권에서 시작해 `add_book.sh`로 한 권씩 추가 (OCR→청킹→임베딩 자동)

[v1.1.0 릴리스](https://github.com/jurisupport/legal-books/releases/tag/v1.1.0): Codex 설치 지원, 책 등록 데이터 보호, 빈 DB의 불필요한 API 호출 방지, 공통 스킬의 실패 처리·인용 기준 개선을 포함합니다.

## 설치

### 1) Claude Code 플러그인으로

```
/plugin marketplace add jurisupport/jurisupport-plugins
/plugin install legal-books@jurisupport-plugins
```

플러그인 설치 후 검색 서버(로컬 인프라)를 준비합니다:

```bash
git clone https://github.com/jurisupport/legal-books ~/legal-books-src
bash ~/legal-books-src/toolkit/install.sh
```

### 2) Claude Code 스킬 직접 설치

```bash
git clone https://github.com/jurisupport/legal-books ~/legal-books-src
bash ~/legal-books-src/toolkit/install.sh --with-skill
```

`--with-skill`은 `~/.claude/skills/legal-books`에 스킬을 복사합니다 (플러그인과 중복 설치하지 마세요).

### 3) 로컬 Codex 앱·CLI에서 사용

```bash
git clone https://github.com/jurisupport/legal-books ~/legal-books-src
bash ~/legal-books-src/toolkit/install.sh --with-codex-skill
```

`--with-codex-skill`은 동일한 스킬을 Codex 사용자 경로인 `~/.agents/skills/legal-books`에 복사합니다. Claude Code도 함께 쓰면 두 옵션을 함께 지정할 수 있습니다. 설치 후 Codex를 다시 열고 `$legal-books`로 호출합니다. 설치 계획만 확인하려면 `--dry-run`을 추가하세요. [Codex 스킬 문서](https://learn.chatgpt.com/docs/build-skills)

로컬 Codex 앱·CLI는 셸 명령으로 같은 컴퓨터의 `http://localhost:8766` 검색 서버를 호출합니다. 셸 실행과 로컬 네트워크 접근이 허용되어 있어야 합니다. Codex 클라우드 작업의 `localhost`는 사용자 컴퓨터가 아니므로 이 로컬 설치에 직접 연결할 수 없습니다.

저장소의 `.codex-plugin/plugin.json`은 기존 `skills/`를 공유하는 Codex 호환 매니페스트입니다. 위 명령은 스킬과 검색 서버를 설치하며, Codex 마켓플레이스에 플러그인을 등록하거나 배포하지 않습니다. [Codex 플러그인 문서](https://developers.openai.com/plugins/build/plugins)

설치가 하는 일: `~/legal-books/` 구조 생성, Python venv + 의존성, SQLite DB 초기화, Gemini API 키 등록, 검색 서버(포트 8766) 가동. 자세한 절차·스캔 팁·문제 해결은 [docs/book-scanning.md](docs/book-scanning.md).

## 모델 호환성과 실행 범위

`선택한 답변 모델 → 공통 legal-books 스킬 → 로컬 검색 서버 → 본문·출처를 읽고 답변`

| 사용 환경 | 지원 방식 | 검증 범위 |
| --- | --- | --- |
| Claude Code | 기존 플러그인 또는 `--with-skill` | 설치 경로·공통 검색 코드 검사 |
| 로컬 Codex + GPT-6 Astra | `--with-codex-skill`과 같은 검색 서버 | 스킬·플러그인 규격 및 공통 코드 검사 |
| 로컬 Codex + GPT-5.6 Sol | Astra와 동일한 설치·스킬 | 스킬·플러그인 규격 및 공통 코드 검사 |
| Codex 클라우드 | 사용자 컴퓨터의 localhost에 직접 연결되지 않음 | 이 로컬 설치 구성의 지원 범위 밖 |

Astra·Sol은 Codex에서 선택하는 답변 모델입니다. 이 툴킷은 OpenAI나 Anthropic의 답변 API를 직접 호출하지 않으며, 여기에 해당 API 키를 별도로 등록할 필요가 없습니다. 검색 임베딩은 계속 Gemini를 사용합니다. 답변 모델을 바꿔도 책 DB를 다시 만들지 않습니다. [공식 Codex 모델 안내](https://learn.chatgpt.com/docs/models?surface=app)

**두 모델 각각에서 실제 서적을 검색하고 인용하는 전체 과정은 아직 실사용 검증하지 않았습니다.** 공통 코드의 검사 통과가 모델별 답변 정확도를 보장하지는 않습니다. 실제 OCR·Gemini 호출·Windows 실행도 별도 확인이 필요합니다.

설치 후 Codex 앱에서 Astra 또는 Sol을 선택하거나, CLI에서 사용할 모델 하나를 선택해 실행합니다:

```bash
codex -m gpt-6-astra
# 또는
codex -m gpt-5.6-sol
```

다음 요청으로 동작을 확인합니다:

```text
$legal-books 내 교과서에서 소멸시효 근거를 찾아줘. 사용한 책·판·PDF 페이지와 원문을 함께 보여줘.
```

책이 없으면 추가 안내가 나오고, 서버 오류는 자료 없음과 구분되어야 합니다. 인용은 실제 검색된 본문과 일치해야 하며, 특정 판을 지정하면 그 판을 사용합니다. 검색 점수는 법적 결론의 확률이 아닙니다.

## 기존 설치 업데이트

작업 중인 책 등록이 끝난 뒤 소스와 설치 파일을 갱신합니다. 설치기는 검색 서버를 재시작하고 가상환경을 다시 만들므로 잠시 검색을 사용할 수 없습니다. `books/`와 DB는 삭제하지 않습니다.

```bash
git -C ~/legal-books-src pull --ff-only
bash ~/legal-books-src/toolkit/install.sh --with-codex-skill
# Claude 스킬도 직접 설치했다면 --with-skill을 함께 지정
```

플러그인으로 설치한 스킬은 사용하는 호스트의 플러그인 업데이트도 실행합니다. 직접 설치한 스킬과 플러그인을 중복 등록하지 마세요. GitHub 릴리스는 소스 배포이며, Codex 마켓플레이스 자동 등록이나 사용자 컴퓨터의 자동 업데이트는 수행하지 않습니다.

## 요구 사항

- Python 3.10+ / macOS·Linux·Windows(Git Bash)
- Gemini API 키 (임베딩 `gemini-embedding-2` 호출용 — [발급](https://aistudio.google.com/apikey))
- 책 스캔 시에만: `ocrmypdf` + `tesseract`(한국어 언어팩)

## 첫 책 추가

```bash
~/legal-books/scripts/add_book.sh \
  --pdf "$HOME/scan/곽윤직_민법총칙_제9판.pdf" \
  --author "곽윤직" --title "민법총칙" \
  --edition "제9판" --year 2018 --publisher "박영사"
```

중간에 실패해도 OCR 결과는 보존되며, 같은 명령을 다시 실행하면 이어서 진행합니다.

검색 결과의 `page`·`page_end`는 표지를 포함한 PDF 페이지 순서입니다. 인쇄된 책의 쪽수는 원본으로 확인하고, 확인 전에는 `PDF p. ...`로 인용합니다. 책 추가는 한 번에 한 작업씩 실행하세요.

## 개발 검증

저장소 루트에서 실행합니다. Python 검사는 설치된 toolkit 가상환경의 패키지를 사용하며, 임시 DB와 합성 텍스트로 검사합니다. 실제 서적이나 Gemini API를 호출하지 않습니다.

```bash
bash tests/install_test.sh
bash tests/legal_books_add_book_test.sh
PYTHONDONTWRITEBYTECODE=1 ~/legal-books/.venv/bin/python tests/ingest_search_test.py
```

Windows Git Bash에서는 마지막 명령의 Python 경로를 `~/legal-books/.venv/Scripts/python.exe`로 바꿉니다.

v1.1.0 검증: 설치 15개·책 등록 13개·등록/검색 7개 검사. 빈 DB에서는 Gemini를 호출하지 않으며, 검색 데이터가 있으면 기존 하이브리드 검색과 장애 시 키워드 검색을 유지합니다.

## 데이터 보호·저작권

- 책 본문 청크와 검색 쿼리는 Gemini 임베딩 API로 전송됩니다. 학습 옵트인 OFF를 확인하세요.
- 저작권·계약상 외부 API 전송이 곤란한 서적은 추가하지 마세요.
- 본인 보유본의 사무소 내부 이용만. 외부 공유·재배포 금지.

## License

MIT — 코드에 한함. 사용자가 인덱싱하는 서적의 저작권은 각 저작권자에게 있습니다.
