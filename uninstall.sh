#!/bin/bash
set -e

TARGET="${1:-$(pwd)}"

echo "learnings-for-claude: $TARGET 에서 제거 중..."

# LEARNINGS.md 제거
if [ -f "$TARGET/LEARNINGS.md" ]; then
  rm "$TARGET/LEARNINGS.md"
  echo "  LEARNINGS.md 제거"
fi

# CLAUDE.md에서 규칙 제거
CLAUDE_MD="$TARGET/CLAUDE.md"
MARKER="## Learnings 시스템"

if [ -f "$CLAUDE_MD" ] && grep -qF "$MARKER" "$CLAUDE_MD"; then
  # marker부터 다음 ## 섹션 전까지 삭제
  awk "/^$MARKER/{found=1} found && /^## / && !/^$MARKER/{found=0} !found" "$CLAUDE_MD" > "$CLAUDE_MD.tmp"
  # 끝 공백 정리
  sed -i '' -e '${/^[[:space:]]*$/d;}' "$CLAUDE_MD.tmp"
  mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
  echo "  CLAUDE.md 규칙 제거"
fi

echo "완료"
