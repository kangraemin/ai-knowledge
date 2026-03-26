# learnings-for-claude

Claude한테 장기 기억을 붙여주는 시스템.

Claude는 세션이 끊기면 기억을 잃는다. 이걸 설치하면 실험 결론, 수정받은 것, 발견한 원칙이 `~/.claude/.claude-library/`에 쌓이고, 다음 세션에서 Claude가 같은 걸 또 제안하지 않는다.

## 설치

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/install.sh)
```

설치 중 `.claude-library/`를 어떻게 git으로 관리할지 물어본다.

## 제거

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/uninstall.sh)
```

## 어떻게 작동하나

**쓰기** — 아래 상황에서 Claude가 조용히 library에 기록한다:
- 실험/백테스트 결론이 났을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때
- 링크/아티클에서 유효한 인사이트를 얻었을 때

세션 종료 / compact 시 놓친 것을 한 번 더 체크한다.

**읽기** — 실험 제안 전, 막히는 상황에서 Claude가 library index를 먼저 보고 관련 항목만 읽는다.

## 구조

```
~/.claude/
  .claude-library/
    LIBRARY.md       ← index
    GUIDE.md         ← 작성 가이드
    library/
      _template.md
      2026-03-07-피보나치-안됨.md
      2026-03-20-gld-방어-유효.md
      ...
```

모든 프로젝트의 학습이 한 곳에 쌓인다.

## 왜 만들었나

Claude와 반복 작업하다 보면 이런 일이 생긴다:
- 저번 세션에서 피보나치 전략이 안 된다는 걸 확인했는데
- 새 세션을 열면 Claude가 또 "피보나치 어떨까요?" 를 제안한다
- 또 돌려보고, 또 실패하고, 또 폐기한다

실험 결과(`what happened`)는 어딘가에 쌓이지만, 거기서 배운 원칙(`what we learned`)은 남지 않는다. 이 시스템은 원칙을 남긴다.
