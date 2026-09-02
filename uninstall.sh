#!/bin/bash
set -e

TARGET="${1:-$(pwd)}"
SETTINGS="$HOME/.claude/settings.json"
HOOK_DEST="$HOME/.claude/hooks/library-sync.sh"

echo "learnings-for-claude 제거 중..."

# 1. 프로젝트 CLAUDE.md에서 규칙 제거
CLAUDE_MD="$TARGET/CLAUDE.md"
MARKER="## Library 시스템"

if [ -f "$CLAUDE_MD" ] && grep -qF "$MARKER" "$CLAUDE_MD"; then
  awk -v marker="$MARKER" '
    $0 == marker { found=1; next }
    found && /^## / { found=0 }
    !found
  ' "$CLAUDE_MD" > "$CLAUDE_MD.tmp"
  sed -i '' -e '${/^[[:space:]]*$/d;}' "$CLAUDE_MD.tmp"
  mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
  echo "  $TARGET/CLAUDE.md 규칙 제거"
fi

# 2. 훅 제거 여부 확인
if command -v jq &>/dev/null && grep -qF "library-sync" "$SETTINGS" 2>/dev/null; then
  echo ""
  echo "  SessionEnd/PostCompact 훅도 제거하시겠습니까?"
  printf "  [y/N] "
  read -r answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    jq '
      .hooks.SessionEnd = [(.hooks.SessionEnd // [])[] | select((.hooks[0].command // "") | contains("library-sync") | not)] |
      .hooks.PostCompact = [(.hooks.PostCompact // [])[] | select((.hooks[0].command // "") | contains("library-sync") | not)]
    ' "$SETTINGS" > "$SETTINGS.tmp"
    mv "$SETTINGS.tmp" "$SETTINGS"
    rm -f "$HOOK_DEST"
# 결정사항/활동로그 훅도 함께 제거
rm -f "$CLAUDE_DIR/hooks/decision-inject.sh" "$CLAUDE_DIR/hooks/library-activity-log.sh" "$CLAUDE_DIR/hooks/policy-inject.sh"
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  jq '(.hooks.SessionStart // []) |= map(.hooks |= map(select(.command | test("decision-inject.sh|policy-inject.sh") | not)))
    | (.hooks.PostToolUse // []) |= map(.hooks |= map(select(.command | test("library-activity-log.sh") | not)))
    | (.hooks.SessionStart // []) |= map(select(.hooks | length > 0))
    | (.hooks.PostToolUse // []) |= map(select(.hooks | length > 0))' \
    "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi
    echo "  훅 제거"
  else
    echo "  스킵"
  fi
fi

echo ""
echo "완료. ~/.claude/library/ 와 ~/.claude/LIBRARY.md 는 유지됩니다."
