#!/bin/bash
set -e

REPO="https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main"
HOOK_DEST="$HOME/.claude/hooks/library-sync.sh"

# 로컬 실행이면 소스에서, 아니면 GitHub에서
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -d "$SCRIPT_DIR/hooks" ]; then
  HOOK_SRC="$SCRIPT_DIR/hooks/library-sync.sh"
else
  HOOK_SRC=""
fi

echo "learnings-for-claude 업데이트 중..."

# library-sync.sh 업데이트
if [ ! -f "$HOOK_DEST" ]; then
  echo "  library-sync.sh 없음 — install.sh를 먼저 실행하세요."
  exit 1
fi

TMP="$(mktemp)"
if [ -n "$HOOK_SRC" ]; then
  cp "$HOOK_SRC" "$TMP"
else
  curl -fsSL "$REPO/hooks/library-sync.sh" -o "$TMP"
fi

if cmp -s "$TMP" "$HOOK_DEST"; then
  echo "  library-sync.sh 변경 없음"
else
  cp "$TMP" "$HOOK_DEST"
  chmod +x "$HOOK_DEST"
  echo "  library-sync.sh 업데이트됨"
fi
rm -f "$TMP"

echo ""
echo "완료."
