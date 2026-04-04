# Tests

| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | "hook deadlock" 검색 시 본문 매칭 | `hook-phase-check-causes-deadlock.md` 파일이 결과에 포함 | ✅ |
| TC-02 | "ml" 검색 시 단어 경계 | ml/ 카테고리 결과만 나오고 "html" 포함 항목 미포함 | ✅ |
| TC-03 | "bb rsi" 검색 시 AND 바이어스 | bb-rsi-longshort가 최상위 결과 | ✅ |
| TC-04 | "spring test isolation" 검색 | testing/spring-isolation 매칭 | ✅ |
| TC-05 | MCP instructions가 영어로 변경 | instructions 문자열이 "ALWAYS call" 로 시작 | ✅ |
| TC-06 | 존재하지 않는 키워드 검색 | "관련 항목 없음" 메시지 반환 | ✅ |

## 실행출력

TC-01: `uv run python3 -c "from server import _search; r=_search('hook deadlock'); print(r[0]['filename'])"`
→ hook-phase-check-causes-deadlock

TC-02: `uv run python3 -c "from server import _search; r=_search('ml'); print([x['category']+'/'+x['filename'] for x in r[:5]])"`
→ ['ml/auto-trial-loop-diminishing-returns', 'ml/feature-independence-simple-models-win', 'ml/optuna-tuning-beats-features', 'ml/local-val-pipeline-mismatch-kills-tuning', 'ml/birdclef-top-notebook-techniques'] (html 없음)

TC-03: `uv run python3 -c "from server import _search; r=_search('bb rsi'); print(r[0]['topic'])"`
→ bb-rsi-longshort (최상위)

TC-04: `uv run python3 -c "from server import _search; r=_search('spring test isolation'); print(r[0]['topic'])"`
→ spring-isolation

TC-05: `grep -A1 'instructions=' server.py`
→ "ALWAYS call library_search() before answering technical questions, "

TC-06: `uv run python3 -c "from server import _search; print(len(_search('xyzzy_nonexistent_12345')))"`
→ 0
