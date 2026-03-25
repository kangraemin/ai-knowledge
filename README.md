# learnings-for-claude

AI와 반복 작업하는 프로젝트에서 같은 삽질을 반복하지 않기 위한 학습 관리 시스템.

## 설치

```bash
# 현재 디렉토리에 설치
./install.sh

# 특정 프로젝트에 설치
./install.sh ~/programming/vibecoding/stock-bot
```

## 제거

```bash
./uninstall.sh ~/programming/vibecoding/stock-bot
```

## 동작

설치 시 프로젝트에 두 가지가 추가된다:

- `LEARNINGS.md` — 실험/작업에서 도출된 원칙 파일
- `CLAUDE.md` — 실험 전 LEARNINGS.md 확인, 실험 후 업데이트 규칙 추가

Claude는 새 실험을 제안하기 전 LEARNINGS.md를 읽고, 폐기된 방향은 재제안하지 않는다.

## 글로벌 learnings

여러 프로젝트에서 반복 확인된 원칙은 `~/.claude/learnings/`에 보관한다.

```
~/.claude/learnings/
  quant.md       # 퀀트/투자 공통 원칙
  claude.md      # AI 삽질 패턴
  ...
```
