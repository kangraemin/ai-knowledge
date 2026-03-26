#!/bin/bash
set -e

REPO="https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main"
CLAUDE_DIR="$HOME/.claude"
LIB_DIR="$CLAUDE_DIR/.claude-library"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DEST="$CLAUDE_DIR/hooks/library-sync.sh"

# 로컬 실행인지 curl 실행인지 판단
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
USE_LOCAL=false
[ -f "$SCRIPT_DIR/templates/LIBRARY.md" ] && USE_LOCAL=true

fetch() {
  local path="$1"
  local dest="$2"
  if $USE_LOCAL; then
    cp "$SCRIPT_DIR/$path" "$dest"
  else
    curl -fsSL "$REPO/$path" -o "$dest"
  fi
}

echo "learnings-for-claude 설치 중..."
echo ""

# --- git 관리 방식 결정 ---
if git -C "$CLAUDE_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  echo "~/.claude 가 git repo로 감지됐습니다."
  echo ".claude-library/ 를 어떻게 관리하시겠습니까?"
  echo "  1) git 추적 안 함 (.gitignore에 추가)"
  echo "  2) 기존 ~/.claude repo에 포함"
  echo "  3) 별도 private repo로 관리 (.gitignore에 추가 + 새 repo 설정)"
  printf "선택 [1/2/3]: "
  read -r git_choice </dev/tty
else
  echo "~/.claude 가 git repo가 아닙니다."
  echo ".claude-library/ 를 어떻게 관리하시겠습니까?"
  echo "  1) 로컬만 유지 (git 없음)"
  echo "  2) 새 private repo 생성"
  printf "선택 [1/2]: "
  read -r git_choice </dev/tty
  [ "$git_choice" = "2" ] && git_choice="4"
fi

echo ""

# --- .claude-library/ 구조 생성 ---
mkdir -p "$LIB_DIR/library"

[ -f "$LIB_DIR/LIBRARY.md" ]             || fetch "templates/LIBRARY.md" "$LIB_DIR/LIBRARY.md"
[ -f "$LIB_DIR/GUIDE.md" ]               || fetch "GUIDE.md" "$LIB_DIR/GUIDE.md"
[ -f "$LIB_DIR/library/_template.md" ]   || fetch "templates/library/_template.md" "$LIB_DIR/library/_template.md"
echo "  ~/.claude/.claude-library/ 생성"

# --- git 설정 ---
case "$git_choice" in
  1|3)
    GITIGNORE="$CLAUDE_DIR/.gitignore"
    if ! grep -qF ".claude-library/" "$GITIGNORE" 2>/dev/null; then
      echo ".claude-library/" >> "$GITIGNORE"
      echo "  .gitignore에 .claude-library/ 추가"
    fi
    ;;& # fallthrough for case 3
  3|4)
    printf "  private repo URL을 입력하세요: "
    read -r repo_url </dev/tty
    git -C "$LIB_DIR" init -q
    git -C "$LIB_DIR" remote add origin "$repo_url"
    git -C "$LIB_DIR" add -A
    git -C "$LIB_DIR" commit -q -m "feat: learnings-for-claude 초기 설정"
    git -C "$LIB_DIR" push -u origin HEAD
    echo "  private repo 설정 완료"
    ;;
  2)
    echo "  기존 ~/.claude repo에 포함"
    ;;
  *)
    echo "  로컬만 유지"
    ;;
esac

# --- ~/.claude/CLAUDE.md에 규칙 추가 ---
GLOBAL_CLAUDE="$CLAUDE_DIR/CLAUDE.md"
MARKER="## Library 시스템"
RULES_TMP="$(mktemp)"

fetch "templates/claude-rules.md" "$RULES_TMP"

if [ -f "$GLOBAL_CLAUDE" ] && grep -qF "$MARKER" "$GLOBAL_CLAUDE"; then
  echo "  ~/.claude/CLAUDE.md 규칙 이미 존재 — 스킵"
else
  echo "" >> "$GLOBAL_CLAUDE"
  cat "$RULES_TMP" >> "$GLOBAL_CLAUDE"
  echo "  ~/.claude/CLAUDE.md 규칙 추가"
fi
rm -f "$RULES_TMP"

# --- SessionEnd / PostCompact 훅 등록 ---
if ! command -v jq &>/dev/null; then
  echo "  경고: jq 없음 — 훅 스킵 (brew install jq 후 재설치 권장)"
elif grep -qF "library-sync" "$SETTINGS" 2>/dev/null; then
  echo "  훅 이미 존재 — 스킵"
else
  mkdir -p "$(dirname "$HOOK_DEST")"
  fetch "hooks/library-sync.sh" "$HOOK_DEST"
  chmod +x "$HOOK_DEST"

  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak" || echo "{\"hooks\":{}}" > "$SETTINGS"

  HOOK_JSON="{\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK_DEST\",\"timeout\":30}]}"
  jq --argjson hook "$HOOK_JSON" '
    .hooks.SessionEnd = (.hooks.SessionEnd // []) + [$hook] |
    .hooks.PostCompact = (.hooks.PostCompact // []) + [$hook]
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

  echo "  SessionEnd / PostCompact 훅 등록"
fi

echo ""
echo "완료."
echo "  library: ~/.claude/.claude-library/library/"
echo "  index:   ~/.claude/.claude-library/LIBRARY.md"
