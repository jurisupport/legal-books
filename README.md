# legal-books

사무소 보유 법률서적(교과서)을 스캔·OCR·임베딩하여 **로컬 하이브리드 검색**으로 출처와 함께 인용하는 Claude Code 플러그인.

```
"이 사건 시효 쟁점에 대해 교과서 바탕으로 정리해줘"
→ 곽윤직 『민법총칙』 제○판, pp.○○○~○○○ 인용 + 본문 발췌 + 적용
```

- **로컬 우선**: 책 PDF·텍스트·DB 모두 `~/legal-books/`에 저장 (SQLite FTS5)
- **하이브리드 검색**: 한국어 접두어 키워드 검색(FTS5) 30% + Gemini 임베딩 의미 검색 70%
- **정확한 인용**: 청크마다 시작·끝 페이지 기록, 직접인용은 원문 조각과 글자 단위 검증
- **점진 구축**: 책 0권에서 시작해 `add_book.sh`로 한 권씩 추가 (OCR→청킹→임베딩 자동)

## 설치

### 1) Claude Code 플러그인으로 (권장)

```
/plugin marketplace add jurisupport/jurisupport-plugins
/plugin install legal-books@jurisupport-plugins
```

플러그인 설치 후 검색 서버(로컬 인프라)를 준비합니다:

```bash
git clone https://github.com/jurisupport/legal-books ~/legal-books-src
bash ~/legal-books-src/toolkit/install.sh
```

### 2) 플러그인 없이 직접

```bash
git clone https://github.com/jurisupport/legal-books ~/legal-books-src
bash ~/legal-books-src/toolkit/install.sh --with-skill
```

`--with-skill`은 `~/.claude/skills/legal-books`에 스킬을 복사합니다 (플러그인과 중복 설치하지 마세요).

설치가 하는 일: `~/legal-books/` 구조 생성, Python venv + 의존성, SQLite DB 초기화, Gemini API 키 등록, 검색 서버(포트 8766) 가동. 자세한 절차·스캔 팁·문제 해결은 [docs/book-scanning.md](docs/book-scanning.md).

## 요구 사항

- Python 3.10+ / macOS·Linux·Windows(Git Bash)
- Gemini API 키 (임베딩 `gemini-embedding-2` 호출용 — [발급](https://aistudio.google.com/apikey))
- 책 스캔 시에만: `ocrmypdf` + `tesseract`(한국어 언어팩)

## 첫 책 추가

```bash
~/legal-books/scripts/add_book.sh \
  --pdf "~/scan/곽윤직_민법총칙_제9판.pdf" \
  --author "곽윤직" --title "민법총칙" \
  --edition "제9판" --year 2018 --publisher "박영사"
```

중간에 실패해도 OCR 결과는 보존되며, 같은 명령을 다시 실행하면 이어서 진행합니다.

## 데이터 보호·저작권

- 책 본문 청크와 검색 쿼리는 Gemini 임베딩 API로 전송됩니다. 학습 옵트인 OFF를 확인하세요.
- 저작권·계약상 외부 API 전송이 곤란한 서적은 추가하지 마세요.
- 본인 보유본의 사무소 내부 이용만. 외부 공유·재배포 금지.

## License

MIT — 코드에 한함. 사용자가 인덱싱하는 서적의 저작권은 각 저작권자에게 있습니다.
