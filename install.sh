#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$(pwd)}"

echo "learnings-for-claude: $TARGET 에 설치 중..."

# 1. LIBRARY.md 생성
if [ -f "$TARGET/LIBRARY.md" ]; then
  echo "  LIBRARY.md 이미 존재 — 스킵"
else
  cp "$SCRIPT_DIR/templates/LIBRARY.md" "$TARGET/LIBRARY.md"
  echo "  LIBRARY.md 생성"
fi

# 2. library/ 구조 생성
if [ -d "$TARGET/library" ]; then
  echo "  library/ 이미 존재 — 스킵"
else
  mkdir -p "$TARGET/library/entries"
  cp "$SCRIPT_DIR/templates/library/dead-ends.md" "$TARGET/library/dead-ends.md"
  cp "$SCRIPT_DIR/templates/library/principles.md" "$TARGET/library/principles.md"
  cp "$SCRIPT_DIR/templates/library/entries/_template.md" "$TARGET/library/entries/_template.md"
  echo "  library/ 구조 생성"
fi

# 3. 프로젝트 CLAUDE.md에 규칙 추가
CLAUDE_MD="$TARGET/CLAUDE.md"
MARKER="## Library 시스템"

if [ -f "$CLAUDE_MD" ] && grep -qF "$MARKER" "$CLAUDE_MD"; then
  echo "  CLAUDE.md 규칙 이미 존재 — 스킵"
else
  echo "" >> "$CLAUDE_MD"
  cat "$SCRIPT_DIR/templates/claude-rules.md" >> "$CLAUDE_MD"
  echo "  CLAUDE.md 규칙 추가"
fi

# 4. 글로벌 library 디렉토리 생성
GLOBAL_DIR="$HOME/.claude/library"
if [ ! -d "$GLOBAL_DIR" ]; then
  mkdir -p "$GLOBAL_DIR/entries"
  cp "$SCRIPT_DIR/templates/library/entries/_template.md" "$GLOBAL_DIR/entries/_template.md"
  echo "  ~/.claude/library/ 생성"
else
  echo "  ~/.claude/library/ 이미 존재 — 스킵"
fi

echo ""
echo "완료. Claude가 자동으로 학습을 기록합니다."
