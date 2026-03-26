#!/bin/bash
set -e

TARGET="${1:-$(pwd)}"

echo "learnings-for-claude: $TARGET 에서 제거 중..."

# 1. LIBRARY.md 제거
if [ -f "$TARGET/LIBRARY.md" ]; then
  rm "$TARGET/LIBRARY.md"
  echo "  LIBRARY.md 제거"
fi

# 2. library/ 제거
if [ -d "$TARGET/library" ]; then
  echo ""
  echo "  library/ 디렉토리를 제거하면 모든 학습 기록이 삭제됩니다."
  printf "  계속하시겠습니까? [y/N] "
  read -r answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$TARGET/library"
    echo "  library/ 제거"
  else
    echo "  library/ 유지"
  fi
fi

# 3. 프로젝트 CLAUDE.md에서 규칙 제거
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
  echo "  CLAUDE.md 규칙 제거"
fi

echo "완료"
