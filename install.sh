#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$(pwd)}"
SETTINGS="$HOME/.claude/settings.json"
HOOK_DEST="$HOME/.claude/hooks/session-start-learnings.sh"

echo "learnings-for-claude: $TARGET 에 설치 중..."

# 1. LEARNINGS.md 생성
if [ -f "$TARGET/LEARNINGS.md" ]; then
  echo "  LEARNINGS.md 이미 존재 — 스킵"
else
  cp "$SCRIPT_DIR/templates/LEARNINGS.md" "$TARGET/LEARNINGS.md"
  echo "  LEARNINGS.md 생성"
fi

# 2. 프로젝트 CLAUDE.md에 규칙 추가
CLAUDE_MD="$TARGET/CLAUDE.md"
MARKER="## Learnings 시스템"

if [ -f "$CLAUDE_MD" ] && grep -qF "$MARKER" "$CLAUDE_MD"; then
  echo "  CLAUDE.md 규칙 이미 존재 — 스킵"
else
  echo "" >> "$CLAUDE_MD"
  cat "$SCRIPT_DIR/templates/claude-rules.md" >> "$CLAUDE_MD"
  echo "  CLAUDE.md 규칙 추가"
fi

# 3. 글로벌 learnings 디렉토리 생성
GLOBAL_DIR="$HOME/.claude/learnings"
if [ ! -d "$GLOBAL_DIR" ]; then
  mkdir -p "$GLOBAL_DIR"
  cp "$SCRIPT_DIR/global/_template.md" "$GLOBAL_DIR/_template.md"
  echo "  ~/.claude/learnings/ 생성"
else
  echo "  ~/.claude/learnings/ 이미 존재 — 스킵"
fi

# 4. SessionStart 훅 설치 (jq 필요)
if ! command -v jq &>/dev/null; then
  echo "  경고: jq 없음 — SessionStart 훅 스킵 (brew install jq 후 재설치 권장)"
elif grep -qF "session-start-learnings" "$SETTINGS" 2>/dev/null; then
  echo "  SessionStart 훅 이미 존재 — 스킵"
else
  cp "$SCRIPT_DIR/hooks/session-start-learnings.sh" "$HOOK_DEST"
  chmod +x "$HOOK_DEST"

  # settings.json 백업
  cp "$SETTINGS" "$SETTINGS.bak"

  # SessionStart 배열에 훅 추가 (없으면 배열 생성)
  HOOK_JSON="{\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK_DEST\",\"timeout\":5}]}"
  jq --argjson hook "$HOOK_JSON" \
    '.hooks.SessionStart = (.hooks.SessionStart // []) + [$hook]' \
    "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

  echo "  SessionStart 훅 등록 (백업: settings.json.bak)"
fi

echo ""
echo "완료. Claude가 자동으로 학습을 기록합니다."
