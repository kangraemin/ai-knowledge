# Library 검색 개선

## Context

library에 107개 파일, 60개+ 주제가 있지만 검색이 한 번도 유용한 결과를 반환한 적 없음.
원인: LIBRARY.md 인덱스만 검색하는데 57개 항목 중 56개가 description 없음. 본문 검색 없음. OR 매칭으로 노이즈만 많음.

## 변경 파일

`mcp-server/server.py` (단일 파일)

## 변경 내용

### 1. 인덱스 재구축 — index.md 파싱

LIBRARY.md 대신 각 topic의 `index.md`를 파싱하여 인메모리 인덱스 구축.

```python
# index.md에는 이런 라인이 있음:
# - [hook-input-stdin.md](hook-input-stdin.md) — Claude Code hook input은 stdin JSON

# Before: LIBRARY.md만 파싱 → topic 이름만 검색 가능
# After: index.md 파싱 → 각 지식 파일의 설명까지 검색 가능
```

- `_build_index()`: `library/` 디렉토리 walk → 모든 index.md 파싱 → 지식 파일별 description 수집
- 지식 파일 본문도 읽어서 word set으로 캐싱 (fallback 검색용)
- 첫 호출 시 lazy build, 모듈 레벨 캐시 (MCP 서버는 세션 간 재시작)

### 2. 스코어링 기반 검색

```python
# Before:
if any(q in searchable for q in query_lower.split()):  # OR, substring

# After: 티어별 점수 + AND 바이어스
# topic 이름 매칭: 10점
# 파일명 매칭: 8점  
# description 매칭: 6점
# category/subcategory: 4점
# 본문 매칭: 2점
# 최종 점수 × (매칭된 검색어 수 / 전체 검색어 수)
```

- 단어 경계 매칭: `re.search(r'\b' + term + r'\b', text)` → "ml"이 "html" 안 걸림
- AND 바이어스: "hook timing" → 둘 다 매칭되는 결과가 위로
- 점수 0인 결과 제외, 상위 5개 반환

### 3. MCP instructions 개선

```python
# Before (한국어, 긴 문장):
"도구, 프로젝트, 기술 키워드가 언급되거나 기술적 질문에 답하거나..."

# After (영어, 짧고 명확):
"ALWAYS call library_search() before answering technical questions, "
"suggesting approaches, or starting implementation. "
"Search for relevant keywords from the user's question. "
"This library contains past experiments, gotchas, and proven solutions — "
"ignoring it risks repeating known mistakes. "
"If results found: prefix with '📚 library 참조: [topic]' and follow stored guidance. "
"If no results: proceed normally without mentioning the search."
```

### 4. 결과 포맷 개선

```
# Before: index.md 60줄 덤프 (목차만 보임)
# After: 개별 지식 파일별 description + 본문 미리보기 (~200자)
```

## 검증

```bash
# MCP 서버 직접 테스트
cd mcp-server
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"library_search","arguments":{"query":"hook deadlock"}},"id":1}' | python3 -c "
import sys, json
# stdin/stdout MCP 테스트
"

# 실제 검색 테스트 케이스:
# "hook" → tooling/claude-code 하위 hook 관련 파일들 매칭
# "bb rsi" → finance/crypto/bb-rsi-longshort 매칭  
# "ml" → ml/ 카테고리만 매칭 (html 미매칭)
# "spring test isolation" → testing/spring-isolation 매칭
```
