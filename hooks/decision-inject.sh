#!/bin/bash
# decision-inject: SessionStart hook
# 현재 레포의 active 결정사항(Decision History)을 세션 컨텍스트에 주입한다.
# 정책은 pull(검색)이 아니라 push(자동 주입)여야 지켜진다.

command -v jq &>/dev/null || exit 0

INPUT=$(cat 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"

# 레포명 = git remote basename (없으면 디렉토리명). git 밖이면 _global 만 주입한다.
REPO=$(git -C "$CWD" remote get-url origin 2>/dev/null | sed 's#.*/##; s#\.git$##')
if [ -z "$REPO" ]; then
  ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$ROOT" ] && REPO=$(basename "$ROOT")
fi

LIB="${LIBRARY_ROOT:-$HOME/claude-library}"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
MAX_DECISIONS="${DECISION_INJECT_MAX:-200}"

# OKF §5.4 status 가 stable/draft 인 것만 (deprecated 제외), category별로 묶어서
render() {
  local dir="$1" skip_loaded="$2" cat f first title decision rel
  for cat in architecture stack convention process scope; do
    [ -d "$dir/$cat" ] || continue
    first=1
    for f in "$dir/$cat"/*.md; do
      [ -f "$f" ] || continue
      grep -qE '^status: *(stable|draft)' "$f" || continue
      rel="decisions/${f#"$LIB/decisions/"}"
      # CLAUDE.md 에 why 마커로 이미 실린 규칙은 다시 넣지 않는다.
      [ "$skip_loaded" = 1 ] && [ -f "$CLAUDE_MD" ] && grep -qF "$rel" "$CLAUDE_MD" && continue
      # 상한 없이 늘면 SessionStart timeout(10s)에 걸려 주입이 통째로 사라진다
      _shown=$((_shown + 1))
      [ "$_shown" -gt "$MAX_DECISIONS" ] && continue
      if [ $first -eq 1 ]; then
        printf '\n## %s\n' "$cat"
        first=0
      fi
      title=$(grep -m1 '^# ' "$f" | sed 's/^# //')
      # "## Decision Outcome" 다음 첫 줄, 없으면 제목 다음 첫 문단 줄
      decision=$(awk '/^## Decision Outcome/{f=1;next} f&&NF{print;exit}' "$f")
      [ -n "$decision" ] || decision=$(awk '/^# /{f=1;next} f&&NF&&!/^#/{print;exit}' "$f" | cut -c1-400)
      printf -- '- **%s** (%s)\n' "$title" "$rel"
      [ -n "$decision" ] && printf -- '  %s\n' "$decision"
    done
  done
}

_shown=0
BODY=""
[ -n "$REPO" ] && [ "$REPO" != _global ] && [ -d "$LIB/decisions/$REPO" ] && BODY=$(render "$LIB/decisions/$REPO" 0)
GLOBAL=""
[ -d "$LIB/decisions/_global" ] && GLOBAL=$(render "$LIB/decisions/_global" 1)

[ -n "$BODY$GLOBAL" ] || exit 0

CONTEXT="아래는 **이미 결정된 사항**이다. 지식이 아니라 결정이다.
새 제안을 하기 전에 여기서 이미 정해졌는지 확인하고, 뒤집으려면 이유를 먼저 밝혀라.
전문은 decision_read(\"<경로>\") 로 읽는다. 세션 중 추가된 결정은 decision_search 로 찾는다."
if [ -n "$BODY" ]; then
  COUNT=$(printf '%s' "$BODY" | grep -c '^- \*\*')
  TOTAL=$(find "$LIB/decisions/$REPO" -name '*.md' ! -name index.md -exec grep -lE '^status: *(stable|draft)' {} + 2>/dev/null | wc -l | tr -d ' ')
  TRUNC_NOTE=""
  if [ "${TOTAL:-0}" -gt "$COUNT" ]; then
    TRUNC_NOTE=" (전체 ${TOTAL}건 중 ${COUNT}건만 주입 — 나머지는 decision_list(\"$REPO\") 로 확인하라)"
  fi
  CONTEXT="$CONTEXT

# 이 레포($REPO)의 확정된 결정사항 ${COUNT}건${TRUNC_NOTE}
$BODY"
fi
if [ -n "$GLOBAL" ]; then
  CONTEXT="$CONTEXT

# 모든 프로젝트 공통 결정사항 (CLAUDE.md 에 없는 것)
$GLOBAL"
fi

jq -n --arg c "$CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'

exit 0
