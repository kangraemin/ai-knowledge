#!/bin/bash
# library-allow: PreToolUse hook
# ~/claude-library/ 파일 편집 시 permission dialog 없이 즉시 허용
#
# 주의: 단순 접두사 비교로는 안 된다. `$LIB_DIR/../.claude/settings.json` 같은
# 경로가 접두사를 통과해 라이브러리 밖 쓰기를 무프롬프트로 승인시킨다.
# 반드시 정규화(resolve) 후 실제 포함 여부를 본다.

command -v jq >/dev/null 2>&1 || exit 0

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

# 빠른 선검사: 라이브러리 경로 문자열이 아예 안 들어있으면 python3 를 띄우지 않는다.
# (PreToolUse 는 모든 Write/Edit 마다 돌아서 지연이 그대로 사용자 체감이 된다)
case "$FILE_PATH" in
  *claude-library*) ;;
  *) exit 0 ;;
esac

# 존재하지 않는 파일도 정규화해야 하므로 python 으로 처리한다.
# realpath -m 은 macOS 기본에 없다.
INSIDE=$(FP="$FILE_PATH" LD="$LIB_DIR" python3 - <<'PY' 2>/dev/null
import os, sys
fp = os.path.realpath(os.path.abspath(os.environ["FP"]))
ld = os.path.realpath(os.path.abspath(os.environ["LD"]))
print("yes" if fp == ld or fp.startswith(ld + os.sep) else "no")
PY
)

if [ "$INSIDE" = "yes" ]; then
  echo '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}'
fi

exit 0
