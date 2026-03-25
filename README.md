# learnings-for-claude

AI와 반복 작업하는 프로젝트에서 같은 삽질을 반복하지 않기 위한 학습 관리 시스템.

## 왜 만들었나

Claude는 세션이 끊기면 이전 대화를 기억하지 못한다.

백테스트를 수십 번 돌리다 보면 이런 일이 생긴다:
- 저번 세션에서 피보나치 되돌림이 안 된다는 걸 확인했는데
- 새 세션을 열면 Claude가 또 "피보나치 전략 어떨까요?" 를 제안한다
- 또 돌려보고, 또 실패하고, 또 폐기한다

결과는 `analysis/INDEX.md` 같은 파일에 쌓이지만, **거기서 뭘 배웠는지는 남지 않는다.**

INDEX.md는 *what happened*를 기록하고, 이 시스템은 *what we learned*를 기록한다.

## 기존 방법의 한계

처음엔 CLAUDE.md에 "실험 전 INDEX.md 읽어라" 규칙 하나 추가하면 되지 않을까 싶었다.

문제는 두 가지:
1. **단회성** — 프로젝트마다 손으로 셋팅해야 한다
2. **결과와 원칙은 다르다** — INDEX.md를 읽는다고 Claude가 원칙을 추출하진 않는다

INDEX.md: `피보나치 되돌림 — 2,880건 중 82% 거래부족. 폐기`
LEARNINGS.md: `거래 횟수가 통계적으로 불충분한 전략은 어떤 지표를 써도 의미 없다`

전자는 사실이고, 후자는 원칙이다. 원칙이 있어야 비슷한 상황에서 일반화할 수 있다.

## 어떻게 작동하나

설치하면 프로젝트에 두 가지가 추가된다:

**LEARNINGS.md** — 실험에서 도출된 원칙 파일

```markdown
## 폐기된 방향
- **지표 기반 타이밍 (미장 대형주)**: 85.5K건 검증, 알파 없음 확정

## 유효한 원칙
- **폭락 방어**: 수익률은 B&H에 밀리지만 MDD 개선 효과는 실재함
```

**CLAUDE.md 규칙** — 실험 전 LEARNINGS.md 확인, 실험 후 업데이트 의무화

Claude는 새 실험을 제안하기 전 LEARNINGS.md를 읽고, 폐기된 방향은 재제안하지 않는다.
실험이 끝나면 새 원칙을 LEARNINGS.md에 추가한다.

## 글로벌 learnings

여러 프로젝트에서 반복 확인된 원칙은 프로젝트를 넘어 공유될 수 있다.

stock-bot에서 배운 것이 coinbot에도 적용되고, coinbot에서 배운 것이 다음 프로젝트에도 적용된다.

```
~/.claude/learnings/
  quant.md       # 퀀트/투자 공통 원칙
  claude.md      # AI와 작업할 때 반복되는 패턴
```

## 설치

```bash
git clone https://github.com/kangraemin/learnings-for-claude
cd learnings-for-claude

# 특정 프로젝트에 설치
./install.sh ~/path/to/your/project

# 현재 디렉토리에 설치
./install.sh
```

## 제거

```bash
./uninstall.sh ~/path/to/your/project
```

## 어떤 프로젝트에 적합한가

"실험하고 → 결과 쌓이고 → 같은 실수 반복" 하는 패턴이면 어디든 맞다.

- 퀀트/백테스트 프로젝트
- 프롬프트 튜닝 반복하는 AI 프로젝트
- API 조합 실험하는 프로젝트
- 장기로 Claude와 함께 개발하는 모든 프로젝트
