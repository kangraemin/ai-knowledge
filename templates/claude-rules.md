## Library 시스템

참조: `~/.claude/.claude-library/GUIDE.md`

### 읽기
- 새 실험/전략 제안 전, 막히는 상황에서 `~/.claude/.claude-library/LIBRARY.md`를 읽는다
- 관련 항목이 있으면 해당 파일만 읽는다
- 참조한 항목이 있으면 한 줄로 알린다: `📚 library 참조: [파일명]`
- 이미 기록된 방향은 재제안하지 않는다

### 쓰기
아래 경우 library에 기록한다:
- 실험/백테스트 결론이 났을 때
- 링크/아티클에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때

기록 방법:
1. `~/.claude/.claude-library/library/YYYY-MM-DD-[주제]-[결론].md` 파일 생성
2. `~/.claude/.claude-library/LIBRARY.md` index에 한 줄 추가
3. 한 줄로 알린다: `📚 library에 추가: [파일명]`

미결 상태는 기록하지 않는다.
