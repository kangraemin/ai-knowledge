#!/bin/bash
# decision-inject: SessionStart hook
# 현재 레포의 active 결정사항(Decision History)을 세션 컨텍스트에 주입한다.
# 정책은 pull(검색)이 아니라 push(자동 주입)여야 지켜진다.

command -v jq &>/dev/null || exit 0

INPUT=$(cat 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"

# 레포명 = git remote basename (없으면 디렉토리명)
REPO=$(git -C "$CWD" remote get-url origin 2>/dev/null | sed 's#.*/##; s#\.git$##')
if [ -z "$REPO" ]; then
  ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$ROOT" ] && REPO=$(basename "$ROOT")
fi
[ -n "$REPO" ] || exit 0

DECISION_DIR="$HOME/claude-library/decisions/$REPO"
[ -d "$DECISION_DIR" ] || exit 0

# OKF §5.4 status 가 stable/draft 인 것만 (deprecated 제외), category별로 묶어서
BODY=$(
  for CAT in architecture stack convention process scope; do
    [ -d "$DECISION_DIR/$CAT" ] || continue
    FIRST=1
    for F in "$DECISION_DIR/$CAT"/*.md; do
      [ -f "$F" ] || continue
      grep -qE '^status: *(stable|draft)' "$F" || continue
      if [ $FIRST -eq 1 ]; then
        printf '\n## %s\n' "$CAT"
        FIRST=0
      fi
      TITLE=$(grep -m1 '^# ' "$F" | sed 's/^# //')
      # "## 결정" 다음 첫 비어있지 않은 줄
      DECISION=$(awk '/^## Decision Outcome/{f=1;next} f&&NF{print;exit}' "$F")
      printf -- '- **%s**\n' "$TITLE"
      [ -n "$DECISION" ] && printf -- '  %s\n' "$DECISION"
    done
  done
)

[ -n "$BODY" ] || exit 0

COUNT=$(printf '%s' "$BODY" | grep -c '^- \*\*')

CONTEXT="# 이 레포($REPO)의 확정된 결정사항 ${COUNT}건

아래는 이 프로젝트에서 **이미 결정된 사항**이다. 지식이 아니라 결정이다.
새 제안을 하기 전에 여기서 이미 정해졌는지 확인하고, 뒤집으려면 이유를 먼저 밝혀라.
$BODY

전문은 decision_read(\"decisions/$REPO/<category>/<name>.md\") 로 읽는다."

jq -n --arg c "$CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'

exit 0
