#!/bin/bash
# SessionEnd / PostCompact: library 업데이트 체크 + commit/push

LIBRARY="$HOME/.claude/.claude-library/LIBRARY.md"
LIB_DIR="$HOME/.claude/.claude-library"

[ -f "$LIBRARY" ] || exit 0

# 새 파일 있으면 commit + push
if [ -d "$LIB_DIR/.git" ] && [ -n "$(git -C "$LIB_DIR" status --porcelain 2>/dev/null)" ]; then
  git -C "$LIB_DIR" add -A
  git -C "$LIB_DIR" commit -q -m "feat: library 업데이트 $(date +%Y-%m-%d)"
  git -C "$LIB_DIR" push -q 2>/dev/null || true
fi
