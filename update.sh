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

copy_if_changed "$PACKAGE_DIR/hooks/library-sync.sh" "$HOOK_DIR/library-sync.sh" "library-sync.sh (hook)"
copy_if_changed "$PACKAGE_DIR/scripts/update-check.sh" "$HOOK_DIR/learnings-update-check.sh" "learnings-update-check.sh (script)"

# 버전 기록
LATEST_SHA=$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "$LATEST_SHA" > "$HOOK_DIR/.learnings-version"

echo ""
echo -e "${GREEN}✓${NC}  ${BOLD}업데이트 완료${NC} — ${GREEN}${UPDATED}개 업데이트${NC}, ${DIM}${UNCHANGED}개 변경 없음${NC}"
