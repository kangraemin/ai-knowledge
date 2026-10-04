# Changelog

## 0.5.0

- 파일·Postgres 검색/읽기/자동주입 JSONL 관측과 `stats --days` 집계 추가. 로그 실패 격리, `LIBRARY_LOG=0`, 세션별 inject→read 연결 지원.
- 자동주입에 정규화된 관련도 임계값과 `LIBRARY_AUTOINJECT_MIN_SCORE` 추가.
- 파일 검색에 한국어 조사·어미 정규화, 제목·설명·태그·경로 가중치, 문서 IDF 적용.
- deprecated 문서 기본 검색 제외와 대체 경로 읽기 안내. Postgres supersedes 관계도 `superseded_by` 저장.
- 공개 무관 프롬프트 30개와 dev/test 평가·회귀 테스트 추가. 기존 MCP 툴 시그니처 유지.
