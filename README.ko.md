<div align="center">

# learnings-for-claude

**Claude는 세션이 끊기면 모든 걸 잊습니다. 이 시스템은 잊지 않습니다.**

Claude가 스스로 읽고 쓰는 파일 기반 지식 라이브러리 —
같은 내용을 두 번 다시 설명하지 않아도 됩니다.

[설치](#설치) · [작동 방식](#작동-방식) · [저장 관리 방식](#저장-관리-방식) · [구조](#구조)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[English](README.md) | **한국어**

</div>

---

## 문제

Claude와 반복 작업하다 보면 이런 일이 생깁니다:

- 실험을 돌림. Claude와 함께 안 된다는 걸 확인함.
- 다음 세션을 열면 Claude가 똑같은 실험을 다시 제안함.
- 또 돌림. 또 실패함.

결과는 파일 어딘가에 남지만, 거기서 배운 *원칙*은 남지 않습니다.

이 시스템은 원칙을 남깁니다.

---

## 작동 방식

**쓰기** — 아래 상황에서 Claude가 자동으로 기록합니다:

- 실험 / 백테스트 결론이 났을 때
- 접근법을 수정받았을 때
- 더 나은 방법을 발견했을 때
- 아티클 / 문서에서 유효한 인사이트를 얻었을 때
- 에러나 버그로 API 동작을 새로 알게 됐을 때

세션 종료 시 `SessionEnd` 훅이 실행되고, Claude가 기록할 것이 있는지 판단합니다. 있다면 파일을 쓰고 커밋합니다.

**읽기** — 새 접근법을 제안하기 전, 막히는 상황에서 Claude가 `LIBRARY.md` index를 먼저 보고 관련 항목을 읽습니다.

**흐름:**

```
세션 종료
    → SessionEnd 훅 실행
    → Claude 판단: 기록할 것 있나?
    → 있다면: library/[카테고리]/[주제]/ 아래에 파일 작성
    → LIBRARY.md index 업데이트
    → git commit + push (repo 관리 시)
```

---

## 설치

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/install.sh)
```

설치 중 `.claude-library/`를 git으로 어떻게 관리할지 선택합니다 ([저장 관리 방식](#저장-관리-방식) 참고).

## 제거

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/uninstall.sh)
```

---

## 저장 관리 방식

설치 시 선택:

| 방식 | 설명 |
|------|------|
| **로컬 파일만** | git 없이 `~/.claude/.claude-library/`에만 저장 |
| **~/.claude repo에 포함** | 기존 `~/.claude` git repo 안에서 함께 추적 |
| **별도 private repo** | library 전용 repo로 분리 관리. 기존 repo clone 또는 새로 생성 가능. 여러 기기 간 동기화 가능. |

---

## 구조

```
~/.claude/
  .claude-library/
    LIBRARY.md        ← 전체 index
    GUIDE.md          ← Claude용 작성 가이드
    library/
      equity/         ← 미국 주식 / ETF 전략
      crypto/         ← BTC, ETH 등
      ml/             ← 모델, 피처
      macro/          ← 거시경제 요인
      claude/         ← Claude 행동 패턴
      ...
```

모든 프로젝트의 학습이 한 곳에 쌓입니다.

각 항목 형식:

```markdown
# [제목]

- 날짜: YYYY-MM-DD
- 출처: [실험명 / 링크 / 경험]

## 내용
무슨 일이 있었는지. 데이터, 수치, 상황.

## 시사점
앞으로 어떻게 적용할지.
```

---

## 왜 만들었나

Claude는 좋은 사고 파트너입니다. 그런데 매 세션이 제로에서 시작됩니다.

과거의 실패, 수정했던 접근법, 반복되는 맥락 — 이걸 사용자가 직접 기억하고 매번 다시 설명해야 합니다. 그 오버헤드가 쌓입니다.

이 시스템은 그 기억을 사람이 아닌 시스템이 갖도록 합니다.

---

## 라이선스

MIT
