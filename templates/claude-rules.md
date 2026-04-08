## Library 시스템

참조: `~/.claude/.claude-library/GUIDE.md`

### 목차
> 설치 후 library에 지식이 쌓이면 여기에 카테고리별 주제 목록이 자동 추가됩니다.

### 읽기
- 목차를 보고 관련 주제를 직접 판단한 뒤 `library_read(path)`로 읽는다
- 키워드 매칭이 필요하면 `library_search(query)`도 보조로 사용
- 새 실험/전략 제안 전, 막히는 상황에서 관련 키워드로 검색한다
- 참조한 항목이 있으면 한 줄로 알린다: `📚 library 참조: [topic]`
- 이미 기록된 방향은 재제안하지 않는다

### 쓰기
아래 경우 library에 기록한다:
- 실험/백테스트 결론이 났을 때
- 아티클/논문에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때
- **개발 중 삽질로 알게 된 API/라이브러리 동작** — 에러로 발견한 것, 문서에 없는 것, 다음에 또 삽질할 것 같은 것. 발견 즉시 기록한다. 사용자가 요청하기 전에.
- **틀린 내용을 교정받았을 때** — "그게 아니야"라고 교정받으면 그 자리에서 바로 저장. "저장할까요?" 묻지 않는다.

### 분류 체계
**`~/.claude/TAXONOMY.md`를 먼저 확인한다.**
- 매칭되는 카테고리/서브카테고리가 있으면 그곳에 저장
- 없으면 TAXONOMY.md에 먼저 추가 후 저장
- ❌ 대회명, 프로젝트명, 도구명을 카테고리/서브카테고리로 사용 금지
- ✅ 기법/주제/도메인 기준으로 분류

### 파일명 원칙
- **"뭘 배웠는지"**가 파일명에 드러나야 한다
- ❌ `discovery.md`, `lessons.md`, `backtest.md` (뭔지 모름)
- ✅ `ar1-lag-is-dominant-signal.md`, `synthetic-data-distribution-overfit.md`
- 예외: finance/ 하위 전략별 `backtest.md`는 폴더가 전략명이므로 OK

### 지식 파일 메타데이터
- `source_session`: 어느 세션에서 발견했는지 (워크로그 날짜/시간 또는 세션 컨텍스트). 나중에 "이거 왜 이렇게 기록했지?" 역추적용.

기록 방법:
1. **TAXONOMY.md 확인** — 매칭되는 분류 찾기, 없으면 추가
2. 주제 폴더 확인/생성: `~/.claude/.claude-library/library/[카테고리]/[서브카테고리]/[주제]/`
3. 지식 파일 생성: 교훈이 드러나는 이름 (날짜 없음), `source_session` 포함
4. 주제 `index.md` 생성/업데이트 + `관련:` 태그 추가 (관련 주제가 있으면)
4.5. **관련 주제 자동 탐색**: `library_search()`로 새 파일의 핵심 키워드 검색 → 관련 주제 발견 시 양방향 `관련:` 태그 추가 (새 index.md + 기존 index.md 모두)
5. `~/.claude/.claude-library/LIBRARY.md` 업데이트
6. CLAUDE.md 목차 업데이트
6.5. **Synthesis 체크**: 같은 서브카테고리에 파일 3개 이상이면 "종합 문서 필요한가?" 자문 → 공통 패턴이 보이면 `library/synthesis/`에 작성
7. 즉시 commit/push:
   ```
   git -C ~/.claude/.claude-library add -A
   git -C ~/.claude/.claude-library commit -m "feat: [주제] 추가"
   git -C ~/.claude/.claude-library push
   ```
8. 한 줄로 알린다: `📚 library에 추가: [경로]`

미결 상태는 기록하지 않는다.
