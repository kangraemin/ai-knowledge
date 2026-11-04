# Changelog

## 0.5.11
- 안내문·도구 설명에 새 말마다 다시 검색하라고 적고, `library_search` 결과 끝에도 같은 말을 붙였다.

## 0.5.10
- `library_search` 결과의 관련 결정 머리말을 "답하기 전에 decision_read로 먼저 연다"로 바꿨다.

## 0.5.9
- 안내문과 `library_search` 설명에서 검색어로 사용자 문장을 줄이지 말고 그대로 넣게 했다.

## 0.5.8
- `library_search`가 보여 주는 관련 결정을 3건에서 5건으로 늘렸다.

## 0.5.7
- 결정 범위를 원격 이름과 로컬 폴더 이름 둘 다로 넓혔다.
- 지시 기록 검색이 같은 뜻의 줄임말(스샷·스크린샷 등)도 찾는다.

## 0.5.6
- 짧은 말과 말머리 붙은 말도 사용자 발화로 기록한다.

## 0.5.5
- 안내문·도구 설명을 위키를 먼저 찾고 읽게 고쳤다.
- 결정 검색이 frontmatter 제목을 쓴다.
- 사용자 발화를 모으는 `instruction_search`를 추가했다.

## 0.5.4

- `library_search`: 1위 점수의 40% 미만인 4위 이하 결과를 뺀다(응답 크기 축소).
- `usage-log`: 사람 발화가 없는 transcript는 parse_error로 남기지 않고 건너뛴다(10월 로그 parse_error 1679행 중 924행이 이것).

## 0.5.0

- 파일·Postgres 검색/읽기/자동주입 JSONL 관측과 `stats --days` 집계 추가. 로그 실패 격리, `LIBRARY_LOG=0`, 세션별 inject→read 연결 지원.
- 자동주입에 정규화된 관련도 임계값과 `LIBRARY_AUTOINJECT_MIN_SCORE` 추가.
- 파일 검색에 한국어 조사·어미 정규화, 제목·설명·태그·경로 가중치, 문서 IDF 적용.
- deprecated 문서 기본 검색 제외와 대체 경로 읽기 안내. Postgres supersedes 관계도 `superseded_by` 저장.
- 공개 무관 프롬프트 30개와 dev/test 평가·회귀 테스트 추가. 기존 MCP 툴 시그니처 유지.
