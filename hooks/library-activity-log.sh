#!/bin/bash
# library-activity-log: PostToolUse hook
# ~/claude-library/{library,decision}/ 쓰기를 .activity/YYYY-MM.jsonl 에 append

command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')

case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
FILE_PATH="${FILE_PATH/#\~/$HOME}"
[ -n "$FILE_PATH" ] || exit 0

LIB_DIR="$HOME/claude-library"

# library/ 또는 decision/ 하위 .md 만 기록
case "$FILE_PATH" in
  "$LIB_DIR"/library/*.md) KIND="knowledge" ;;
  "$LIB_DIR"/decision/*.md)  KIND="decisions" ;;
  *) exit 0 ;;
esac

REL="${FILE_PATH#$LIB_DIR/}"

# create vs update: git 추적 여부로 판정 (미추적 = 신규)
if git -C "$LIB_DIR" ls-files --error-unmatch "$REL" >/dev/null 2>&1; then
  ACTION="update"
else
  ACTION="create"
fi

# supersede 표시가 본문에 있으면 우선
if [ "$KIND" = "decisions" ] && grep -q "^superseded_by:" "$FILE_PATH" 2>/dev/null; then
  ACTION="supersede"
fi

# policy는 경로에서 repo/category 추출: decisions/<repo>/<category>/<file>.md
REPO=""
CATEGORY=""
if [ "$KIND" = "decisions" ]; then
  REPO=$(echo "$REL" | cut -d/ -f2)
  CATEGORY=$(echo "$REL" | cut -d/ -f3)
else
  CATEGORY=$(echo "$REL" | cut -d/ -f2)
fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"' | cut -c1-8)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

LOG_DIR="$LIB_DIR/.activity"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m).jsonl"

jq -nc \
  --arg ts "$(date -Iseconds)" \
  --arg kind "$KIND" \
  --arg action "$ACTION" \
  --arg path "$REL" \
  --arg repo "$REPO" \
  --arg category "$CATEGORY" \
  --arg session "$SESSION" \
  --arg cwd "$CWD" \
  '{ts:$ts, kind:$kind, action:$action, path:$path, repo:$repo, category:$category, session:$session, cwd:$cwd}' \
  >> "$LOG_FILE"

exit 0
