#!/bin/bash
set -e

GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC}  $*"; }
skip() { echo -e "${DIM}·  $*${NC}"; }

UPDATED=0
UNCHANGED=0

copy_if_changed() {
  local src="$1" dst="$2" label="$3"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    skip "$label"
    UNCHANGED=$((UNCHANGED + 1))
  else
    cp "$src" "$dst"
    chmod +x "$dst" 2>/dev/null || true
    ok "$label"
    UPDATED=$((UPDATED + 1))
  fi
}

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

# 소스 없으면 clone
if [ ! -f "$PACKAGE_DIR/hooks/library-sync.sh" ]; then
  echo -e "${BOLD}최신 소스 다운로드 중...${NC}"
  TMPDIR_UPDATE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_UPDATE"' EXIT
  git clone --depth 1 https://github.com/kangraemin/learnings-for-claude.git "$TMPDIR_UPDATE/learnings-for-claude" -q
  PACKAGE_DIR="$TMPDIR_UPDATE/learnings-for-claude"
  ok "다운로드 완료"

  if [ "${_UPDATE_BOOTSTRAPPED:-}" != "1" ] && [ -f "$PACKAGE_DIR/update.sh" ]; then
    export _UPDATE_BOOTSTRAPPED=1
    exec bash "$PACKAGE_DIR/update.sh" "$@"
  fi
fi

echo -e "${BOLD}learnings-for-claude 업데이트 중...${NC}"
echo ""

HOOK_DIR="$HOME/.claude/hooks"

[ -f "$HOOK_DIR/library-sync.sh" ] || { echo "  install.sh를 먼저 실행하세요."; exit 1; }

LIB_DIR="$HOME/.claude/.claude-library"

copy_if_changed "$PACKAGE_DIR/hooks/library-sync.sh" "$HOOK_DIR/library-sync.sh" "library-sync.sh (hook)"
copy_if_changed "$PACKAGE_DIR/hooks/library-save-check.sh" "$HOOK_DIR/library-save-check.sh" "library-save-check.sh (stop hook)"
copy_if_changed "$PACKAGE_DIR/scripts/update-check.sh" "$HOOK_DIR/learnings-update-check.sh" "learnings-update-check.sh (script)"
copy_if_changed "$PACKAGE_DIR/hooks/code-lesson-check.sh" "$HOOK_DIR/code-lesson-check.sh" "code-lesson-check.sh (stop hook)"
copy_if_changed "$PACKAGE_DIR/GUIDE.md" "$LIB_DIR/GUIDE.md" "GUIDE.md"
copy_if_changed "$PACKAGE_DIR/TAXONOMY.md" "$HOME/.claude/TAXONOMY.md" "TAXONOMY.md"

# Notion library 스크립트 (있으면 업데이트)
SCRIPTS_DIR="$HOME/.claude/scripts"
if [ -f "$SCRIPTS_DIR/notion-library.sh" ]; then
  copy_if_changed "$PACKAGE_DIR/scripts/notion-library.sh" "$SCRIPTS_DIR/notion-library.sh" "notion-library.sh (script)"
  copy_if_changed "$PACKAGE_DIR/scripts/notion-library-create-db.sh" "$SCRIPTS_DIR/notion-library-create-db.sh" "notion-library-create-db.sh (script)"
  copy_if_changed "$PACKAGE_DIR/scripts/notion-library-migrate.sh" "$SCRIPTS_DIR/notion-library-migrate.sh" "notion-library-migrate.sh (script)"
fi

# 스킬 업데이트
SKILL_DIR="$HOME/.claude/skills"
for skill in session-review update-learnings code-lesson; do
  if [ -f "$PACKAGE_DIR/skills/$skill/SKILL.md" ]; then
    copy_if_changed "$PACKAGE_DIR/skills/$skill/SKILL.md" "$SKILL_DIR/$skill/SKILL.md" "$skill (skill)"
  fi
done

# ~/.claude/CLAUDE.md Library 섹션 업데이트
GLOBAL_CLAUDE="$HOME/.claude/CLAUDE.md"
RULES_SRC="$PACKAGE_DIR/templates/claude-rules.md"
if [ -f "$GLOBAL_CLAUDE" ] && [ -f "$RULES_SRC" ]; then
  python3 - "$GLOBAL_CLAUDE" "$RULES_SRC" << 'PYEOF'
import sys, re
target, src = sys.argv[1], sys.argv[2]
content = open(target).read()
new_rules = "\n" + open(src).read()
updated = re.sub(r'\n## Library 시스템.*', new_rules, content, flags=re.DOTALL)
if updated != content:
    open(target, 'w').write(updated)
    print("  CLAUDE.md Library 섹션 업데이트")
else:
    print("·  CLAUDE.md 변경 없음")
PYEOF
fi

# --- permissions: library 경로 허용 (누락 시 보충) ---
SETTINGS="$HOME/.claude/settings.json"
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  if jq -e '.permissions.allow // [] | map(select(test("claude-library"))) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
    skip "library 경로 권한 이미 존재"
  else
    jq '
      .permissions.allow = ((.permissions.allow // []) + [
        "Write(~/.claude/.claude-library/**)",
        "Edit(~/.claude/.claude-library/**)"
      ] | unique)
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    ok "library 경로 Write/Edit 권한 추가"
    UPDATED=$((UPDATED + 1))
  fi
fi

# 버전 기록
LATEST_SHA=$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "$LATEST_SHA" > "$HOOK_DIR/.learnings-version"

echo ""
echo -e "${GREEN}✓${NC}  ${BOLD}업데이트 완료${NC} — ${GREEN}${UPDATED}개 업데이트${NC}, ${DIM}${UNCHANGED}개 변경 없음${NC}"
