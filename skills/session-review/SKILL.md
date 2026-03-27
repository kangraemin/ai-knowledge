---
name: session-review
description: 세션에서 배울게있는지 정리하고 library에 저장. '배운 거 정리해줘', '이번 세션 정리', '세션 리뷰', 'session review', '오늘 배운 거', '이번 대화에서 건진 거' 같은 요청 시 반드시 이 스킬을 사용. 기술적 발견, 삽질 해결, API 동작, 설계 결정 등 다음에 또 쓸 만한 게 있는지 확인할 때도 트리거.
---

# Session Review

이번 세션 대화를 돌아보고 library에 저장할 가치가 있는 지식을 추출한다.

## 판단 기준

저장할 가치가 있는 것:
- 삽질로 알게 된 API/라이브러리 동작 (에러로 발견한 것, 문서에 없는 것)
- 설계 결정과 그 이유 (왜 A 대신 B를 선택했는지)
- 시도했다가 실패한 접근법과 이유
- 앞으로 같은 상황에서 다시 쓸 수 있는 패턴/인사이트

저장하지 않는 것:
- 이번 작업에만 해당하는 일회성 정보
- 코드 파일에 이미 반영된 내용
- git history에서 확인 가능한 것
- 오타/포맷 수정

**아무것도 없으면 "이번 세션에서 저장할 내용 없음"으로 끝낸다. 억지로 만들지 않는다.**

## 플로우

1. **스캔**: 이번 세션 대화 전체를 돌아보며 위 기준에 맞는 것 목록화
2. **저장**: 바로 library에 파일로 작성 (확인 없이)
3. **커밋**: git commit & push
4. **보고**: 저장한 내용 한 줄 요약으로 알림

확인 단계 없이 바로 저장한다. 사용자가 "정리해줘"라고 했으면 저장까지가 요청의 범위다.

## 저장 방법

Library 경로: `~/.claude/.claude-library/library/`

### 카테고리 판단
- `claude` — Claude/AI 도구 동작, 프롬프트 패턴, MCP, 스킬
- `equity` — 주식/ETF 전략
- `crypto` — 코인 전략
- `ml` — 머신러닝
- `macro` — 거시경제
- 없으면 새 카테고리 추가

### 파일 작성 순서
1. `~/.claude/.claude-library/library/[카테고리]/[주제]/[파일명].md` 생성
2. 주제 `index.md` 생성 또는 업데이트
3. `~/.claude/.claude-library/LIBRARY.md` 업데이트

### 지식 파일 형식
```markdown
# [제목]

- 날짜: YYYY-MM-DD
- 출처: [세션 설명 / 경험]

## 내용
핵심 내용. 구체적으로.

## 시사점
다음에 이 지식을 어떻게 쓸 수 있는지.
```

## 커밋
```bash
git -C ~/.claude/.claude-library add -A
git -C ~/.claude/.claude-library commit -m "feat: [주제] 추가"
git -C ~/.claude/.claude-library push
```

저장 후: `📚 library에 추가: [경로]` 한 줄로 알린다.
