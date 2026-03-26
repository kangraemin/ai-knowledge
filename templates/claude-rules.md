## Library 시스템

참조: `~/.claude/.claude-library/GUIDE.md`

### 읽기
- 새 실험/전략 제안 전, 막히는 상황에서 `~/.claude/.claude-library/LIBRARY.md`를 읽는다
- 관련 카테고리/주제 폴더의 `index.md`를 찾아 읽는다
- 참조한 항목이 있으면 한 줄로 알린다: `📚 library 참조: [경로]`
- 이미 기록된 방향은 재제안하지 않는다

### 쓰기
아래 경우 library에 기록한다:
- 실험/백테스트 결론이 났을 때
- 아티클/논문에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때

기록 방법:
1. 카테고리 판단 (quant, ml, claude, macro 등)
2. 주제 폴더 확인/생성: `~/.claude/.claude-library/library/[카테고리]/[주제]/`
3. 지식 파일 생성: 내용을 설명하는 이름 (날짜 없음)
4. 주제 `index.md` 생성/업데이트
5. `~/.claude/.claude-library/LIBRARY.md` 업데이트
6. 한 줄로 알린다: `📚 library에 추가: [경로]`

미결 상태는 기록하지 않는다.
