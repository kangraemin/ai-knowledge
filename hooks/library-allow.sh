#!/bin/bash
# library-allow: PreToolUse hook
# ~/.claude/.claude-library/ 파일 편집 시 "edit own settings" dialog 없이 즉시 허용

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')

case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
LIB_DIR="$HOME/.claude/.claude-library"

if [[ "$FILE_PATH" == "$LIB_DIR/"* ]]; then
  echo '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}'
fi

exit 0
