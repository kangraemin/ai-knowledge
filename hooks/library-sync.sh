#!/bin/bash
# SessionEnd / PostCompact: library 업데이트 체크 + commit/push

LIBRARY="$HOME/.claude/.claude-library/LIBRARY.md"
LIB_DIR="$HOME/.claude/.claude-library"

[ -f "$LIBRARY" ] || exit 0

claude -p "이번 세션에서 ~/.claude/.claude-library/library/ 에 기록할 만한 결론이 있었는지 확인하고, 있다면 ~/.claude/.claude-library/GUIDE.md 형식에 따라 파일을 추가하고 ~/.claude/.claude-library/LIBRARY.md index를 업데이트해라. 없으면 아무것도 하지 마라." 2>/dev/null || true

# 새 파일 있으면 commit + push
if [ -d "$LIB_DIR/.git" ] && [ -n "$(git -C "$LIB_DIR" status --porcelain 2>/dev/null)" ]; then
  git -C "$LIB_DIR" add -A
  git -C "$LIB_DIR" commit -q -m "feat: library 업데이트 $(date +%Y-%m-%d)"
  git -C "$LIB_DIR" push -q 2>/dev/null || true
fi
