## Library 시스템

참조: `~/claude-library/GUIDE.md`

### 목차
> 카테고리별 한 줄 요약. 주제별 상세 목록은 `~/claude-library/CATALOG.md`.

<!-- learnings-for-claude:rules start -->

### 읽기
- 툴: `library_search` `library_read` `library_list` / `decision_list(repo)` `decision_search` `decision_read`
- `library_search`는 **deferred tool** — 매 세션/작업 시작 시 반드시 먼저 `ToolSearch("select:mcp__claude-library__library_search")`로 로드한 뒤 사용한다
- 아래 상황에서 **반드시** `library_search(query)`를 호출한다:
  - 기술 질문에 답하거나 접근법을 제안할 때
  - 구현을 시작할 때
  - 에러/삽질이 발생했을 때 — 이미 기록된 해결책이 있을 수 있다
- 결과가 있으면 `📚 library 참조: [topic]`로 시작하고 저장된 내용을 따른다
- 결과가 없으면 별도 언급 없이 진행한다
- 관련 주제가 발견되면 `library_read(path)`로 index.md를 읽어 상세 확인
- 이미 기록된 방향은 재제안하지 않는다

### 쓰기
아래 경우 library에 기록한다:
- 실험/백테스트 결론이 났을 때
- 아티클/논문에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때
- **개발 중 삽질로 알게 된 API/라이브러리 동작** — 에러로 발견한 것, 문서에 없는 것, 다음에 또 삽질할 것 같은 것. 발견 즉시 기록한다. 사용자가 요청하기 전에.
- **틀린 내용을 교정받았을 때** — "그게 아니야"라고 교정받으면 그 자리에서 바로 저장. "저장할까요?" 묻지 않는다.


### 지식이냐 결정사항이냐 — 먼저 가른다

| | 지식 `library/` | 결정사항 `decisions/` |
|---|---|---|
| 판별 | **남의 프로젝트에도 그대로 참** | **우리가 이렇게 하기로 정한 것** |
| 예 | "Granite에 react-native-svg 이미 번들됨" | "우리는 통과조건을 셸로 표현한다" |
| 분류 | 카테고리/서브카테고리/주제 | **레포별 → 카테고리별** |
| 꺼내기 | `library_search` (pull) | SessionStart 자동 주입 (push) |

결정사항 카테고리 5개 고정: `architecture` `stack` `convention` `process` `scope`
경로: `~/claude-library/decisions/<레포명>/<카테고리>/<slug>.md` (레포명 = git remote basename)

### 형식 — OKF v0.2

모든 문서는 Open Knowledge Format v0.2 프론트매터를 갖는다. `type`이 유일한 필수 필드.
**상세 규칙·필드·이유는 `~/claude-library/GUIDE.md` 를 읽어라.** 여기에 중복 기술하지 않는다
(같은 규칙을 두 곳에 적어서 실제로 드리프트가 난 전례가 있다).

분류는 `~/claude-library/TAXONOMY.md`를 먼저 확인하고, 없으면 거기에 먼저 추가한다.

기록 방법:
1. **지식/결정사항 판별** → 저장소 결정
2. TAXONOMY.md 확인 (지식) 또는 레포·카테고리 확정 (결정사항)
3. 파일 생성 — OKF 프론트매터 + 교훈이 드러나는 파일명 (날짜 없음)
4. **`index.md` / `LIBRARY.md` 는 손대지 않는다.** 자동 생성 대상이다
5. **Synthesis 체크**: 같은 서브카테고리 3개 이상이면 종합 문서 검토 → `library/synthesis/`
6. `~/claude-library/CATALOG.md` 에 한 줄 요약 추가 (CLAUDE.md `### 목차`는 카테고리 요약만 — 새 카테고리·핵심 결론일 때만 갱신)
7. 즉시 commit/push:
   ```
   git -C ~/claude-library add -A
   git -C ~/claude-library commit -m "feat: [주제] 추가"
   git -C ~/claude-library push
   ```
8. 한 줄로 알린다: `📚 library에 추가: [경로]`

미결 상태는 기록하지 않는다.
<!-- learnings-for-claude:rules end -->
