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

### 카테고리 분류 원칙
**지식의 도메인 기준으로 분류한다. 도구명/플랫폼명 카테고리 금지.**
- 주식/ETF 전략 → `finance/equity`
- 코인 전략 → `finance/crypto`
- 머신러닝/대회 → `ml`
- 개발 도구 동작 → `dev/tooling`
- CI/CD, 환경 → `dev/infra`
- 외부 API 동작 → `dev/api`
- 테스팅 패턴 → `dev/testing`
- ❌ 금지: `kaggle/`, `spring/`, `claude/` 같은 도구명/플랫폼명 카테고리

기록 방법:
1. 카테고리 판단 — 목차에서 가장 가까운 카테고리 선택, 없으면 새로 생성
2. 주제 폴더 확인/생성: `~/.claude/.claude-library/library/[카테고리]/[주제]/`
3. 지식 파일 생성: 내용을 설명하는 이름 (날짜 없음)
4. 주제 `index.md` 생성/업데이트 + `관련:` 태그 추가 (관련 주제가 있으면)
5. `~/.claude/.claude-library/LIBRARY.md` 업데이트
6. CLAUDE.md 목차 업데이트
7. 즉시 commit/push:
   ```
   git -C ~/.claude/.claude-library add -A
   git -C ~/.claude/.claude-library commit -m "feat: [주제] 추가"
   git -C ~/.claude/.claude-library push
   ```
8. 한 줄로 알린다: `📚 library에 추가: [경로]`

미결 상태는 기록하지 않는다.
