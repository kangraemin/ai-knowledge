## Library 시스템

참조: `~/claude-library/GUIDE.md`

### 목차
> 카테고리별 한 줄 요약. 주제별 상세 목록은 `~/claude-library/CATALOG.md`.

<!-- learnings-for-claude:rules start -->
### 읽기
- 기술 질문에 답하거나, 구현을 시작하거나, 에러가 나면 `library_search(query)`를 부른다. deferred tool이라 먼저 `ToolSearch("select:mcp__claude-library__library_search")`로 로드한다.
- 결과가 있으면 `📚 library 참조: [topic]`로 시작하고 저장된 내용을 따른다. 이미 기록된 방향은 재제안하지 않는다.
- 결정사항(`decisions/`)은 SessionStart에 자동 주입된다. 전문은 `decision_read`, 세션 중 추가분은 `decision_search`.

### 쓰기
- 기록 대상: 실험·백테스트 결론, 삽질로 알게 된 API·라이브러리 동작, 사용자 교정("그게 아니야"), 더 나은 방법. 묻지 말고 그 자리에서 기록한다.
- 먼저 가른다: 남의 프로젝트에도 참이면 지식 `library/<카테고리>/...`(TAXONOMY.md 먼저 확인), 우리가 정한 것이면 결정 `decisions/<레포|_global>/<architecture|stack|convention|process|scope>/<slug>.md`.
- 사용자가 정한 결정은 메모리에만 두지 않는다. 한 프로젝트 전용이어도 decisions/에 쓰고 메모리엔 포인터만 둔다.
- 형식(OKF v0.2 프론트매터, `type` 필수)은 `~/claude-library/GUIDE.md`를 따른다. 파일명은 교훈이 드러나게, 날짜 없이. `index.md`·`LIBRARY.md`는 자동 생성이라 손대지 않는다.
- 저장 후 `CATALOG.md`에 한 줄 추가 → `git -C ~/claude-library add -A && git -C ~/claude-library commit -m "feat: [주제] 추가" && git -C ~/claude-library push` → `📚 library에 추가: [경로]` 한 줄로 알린다.
- 미결 상태는 기록하지 않는다.
<!-- learnings-for-claude:rules end -->
