#!/bin/bash
set -e

TARGET="${1:-$(pwd)}"
SETTINGS="$HOME/.claude/settings.json"
HOOK_DIR="$HOME/.claude/hooks"
HOOK_DEST="$HOOK_DIR/library-sync.sh"

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
    echo "  훅 제거"
  else
    echo "  스킵"
  fi
fi

echo ""
echo "완료. ~/.claude/library/ 와 ~/.claude/LIBRARY.md 는 유지됩니다."

# 3. decision / 활동로그 훅 제거 (library-sync 유무와 무관하게 독립 처리)
if [ -f "$HOOK_DIR/decision-inject.sh" ] || [ -f "$HOOK_DIR/library-activity-log.sh" ] || [ -f "$HOOK_DIR/policy-inject.sh" ]; then
  rm -f "$HOOK_DIR/decision-inject.sh" "$HOOK_DIR/library-activity-log.sh" "$HOOK_DIR/policy-inject.sh"
  if command -v jq &>/dev/null && [ -f "$SETTINGS" ]; then
    if jq '
      .hooks.SessionStart |= ((. // []) | map(.hooks |= map(select((.command // "") | test("decision-inject.sh|policy-inject.sh") | not))) | map(select((.hooks | length) > 0)))
      | .hooks.PostToolUse |= ((. // []) | map(.hooks |= map(select((.command // "") | test("library-activity-log.sh") | not))) | map(select((.hooks | length) > 0)))
    ' "$SETTINGS" > "$SETTINGS.tmp"; then
      mv "$SETTINGS.tmp" "$SETTINGS"
      echo "  decision/활동로그 훅 제거"
    else
      rm -f "$SETTINGS.tmp"
      echo "  ⚠️ settings.json 갱신 실패 — 훅 등록이 남았을 수 있다"
    fi
  fi
fi
