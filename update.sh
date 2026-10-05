#!/bin/bash
set -e

# 브랜치 설정: 명시 옵션은 저장하고 환경변수는 실행 시에만 우선한다.
BRANCH_FILE="$HOME/.claude/hooks/.learnings-branch"
BRANCH_OPTION=""
PROFILE_FILE="$HOME/.claude/hooks/.learnings-profile"
PROFILE_OPTION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { echo "--profile 값이 필요합니다." >&2; exit 1; }
      PROFILE_OPTION="$2"
      case "$PROFILE_OPTION" in user|maintainer) ;; *) echo "잘못된 프로필" >&2; exit 1 ;; esac
      shift 2 ;;
    --branch)
      [ "$#" -ge 2 ] || { echo "--branch 값이 필요합니다." >&2; exit 1; }
      BRANCH_OPTION="$2"
      [[ "$BRANCH_OPTION" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$BRANCH_OPTION" != *..* ]] || { echo "잘못된 브랜치명" >&2; exit 1; }
      shift 2 ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done
BRANCH="${LEARNINGS_BRANCH:-${BRANCH_OPTION:-$(cat "$BRANCH_FILE" 2>/dev/null || echo main)}}"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$BRANCH" != *..* ]] || { echo "잘못된 브랜치명" >&2; exit 1; }
PROFILE="${LEARNINGS_PROFILE:-${PROFILE_OPTION:-$(cat "$PROFILE_FILE" 2>/dev/null || echo user)}}"
case "$PROFILE" in user|maintainer) ;; *) echo "잘못된 프로필" >&2; exit 1 ;; esac
export LEARNINGS_PROFILE="$PROFILE"  # policy-changelog.py 가 이력 기록 여부를 프로필로 판단
if [ -n "$PROFILE_OPTION" ]; then
  mkdir -p "$(dirname "$PROFILE_FILE")"
  if [ "$PROFILE_OPTION" = user ]; then
    rm -f "$PROFILE_FILE"
  else
    printf '%s\n' "$PROFILE_OPTION" > "$PROFILE_FILE"
  fi
fi
KB_SPEC="claude-library-mcp"
if [ "$BRANCH" != main ]; then
  KB_SPEC="git+https://github.com/kangraemin/learnings-for-claude@$BRANCH#subdirectory=mcp-server"
fi
if [ -n "$BRANCH_OPTION" ]; then
  mkdir -p "$(dirname "$BRANCH_FILE")"
  if [ "$BRANCH_OPTION" = main ]; then
    rm -f "$BRANCH_FILE"
  else
    printf '%s\n' "$BRANCH_OPTION" > "$BRANCH_FILE"
  fi
  rm -f "$HOME/.claude/hooks/.learnings-version-checked"
fi

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
  git clone --depth 1 -b "$BRANCH" https://github.com/kangraemin/learnings-for-claude.git "$TMPDIR_UPDATE/learnings-for-claude" -q
  PACKAGE_DIR="$TMPDIR_UPDATE/learnings-for-claude"
  ok "다운로드 완료"

  if [ "${_UPDATE_BOOTSTRAPPED:-}" != "1" ] && [ -f "$PACKAGE_DIR/update.sh" ]; then
    export _UPDATE_BOOTSTRAPPED=1
    export LEARNINGS_BRANCH="$BRANCH"
    export LEARNINGS_PROFILE="$PROFILE"
    # exec하면 부모 EXIT trap이 사라져 다운로드 디렉터리가 남는다.
    bash "$PACKAGE_DIR/update.sh"
    exit $?
  fi
fi

echo -e "${BOLD}learnings-for-claude 업데이트 중...${NC}"
echo ""

HOOK_DIR="$HOME/.claude/hooks"

[ -f "$HOOK_DIR/library-sync.sh" ] || { echo "  install.sh를 먼저 실행하세요."; exit 1; }

LIB_DIR="$HOME/claude-library"

# 검색 로그에는 프롬프트 원문이 포함되므로 추적 대상에서 제외한다.
# 기존 추적 파일의 인덱스나 이력은 변경하지 않는다.
mkdir -p "$LIB_DIR"
if ! grep -qxF '.activity/search-*.jsonl' "$LIB_DIR/.gitignore" 2>/dev/null; then
  printf '\n.activity/search-*.jsonl\n' >> "$LIB_DIR/.gitignore"
fi


copy_if_changed "$PACKAGE_DIR/hooks/library-sync.sh" "$HOOK_DIR/library-sync.sh" "library-sync.sh (hook)"
copy_if_changed "$PACKAGE_DIR/hooks/library-save-check.sh" "$HOOK_DIR/library-save-check.sh" "library-save-check.sh (stop hook)"
copy_if_changed "$PACKAGE_DIR/scripts/update-check.sh" "$HOOK_DIR/learnings-update-check.sh" "learnings-update-check.sh (script)"
copy_if_changed "$PACKAGE_DIR/hooks/code-lesson-check.sh" "$HOOK_DIR/code-lesson-check.sh" "code-lesson-check.sh (stop hook)"
copy_if_changed "$PACKAGE_DIR/hooks/library-allow.sh" "$HOOK_DIR/library-allow.sh" "library-allow.sh (pretooluse hook)"
copy_if_changed "$PACKAGE_DIR/hooks/decision-inject.sh" "$HOOK_DIR/decision-inject.sh" "decision-inject.sh (sessionstart hook)"
copy_if_changed "$PACKAGE_DIR/hooks/library-activity-log.sh" "$HOOK_DIR/library-activity-log.sh" "library-activity-log.sh (posttooluse hook)"
# GUIDE.md / TAXONOMY.md 는 사용자가 계속 편집하는 파일이다
# (CLAUDE.md 가 "TAXONOMY.md 에 먼저 추가 후 저장"을 지시한다).
# 무조건 덮어쓰면 분류체계가 통째로 사라진다 — 실제로 발생했다.
# 사용자가 손댄 흔적이 있으면 건드리지 않고 새 버전을 옆에 둔다.
POLICY_VERSION="$BRANCH@$(git -C "$PACKAGE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
for doc in GUIDE.md TAXONOMY.md; do
  python3 "$PACKAGE_DIR/hooks/policy-changelog.py" update-doc "$PACKAGE_DIR/$doc" "$LIB_DIR/$doc" "$POLICY_VERSION"
done

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
if [ -f "$GLOBAL_CLAUDE" ] && [ ! -f "$RULES_SRC" ]; then
  echo "  경고: $RULES_SRC 없음 — CLAUDE.md 규칙 갱신 스킵 (다운로드 실패 가능)"
fi
if [ -f "$GLOBAL_CLAUDE" ] && [ -f "$RULES_SRC" ]; then
  python3 - "$GLOBAL_CLAUDE" "$RULES_SRC" "$PACKAGE_DIR/hooks/policy-changelog.py" "$POLICY_VERSION" << 'PYEOF'
import sys, shutil
from pathlib import Path
target, src = map(Path, sys.argv[1:3])
content = target.read_bytes() if target.exists() else b""
template = src.read_bytes()
start = b"<!-- learnings-for-claude:rules start -->"
end = b"<!-- learnings-for-claude:rules end -->"
valid = (content.count(start) == content.count(end) == 1
         and content.index(start) < content.index(end))
if start in content or end in content:
    if not valid:
        print("경고: CLAUDE.md 관리 마커가 올바른 한 쌍이 아님 — 원본 유지")
        sys.exit(0)
    block = template[template.index(start):template.index(end) + len(end)]
    updated = content[:content.index(start)] + block + content[content.index(end) + len(end):]
else:
    updated = None
    Path(str(target) + ".library-rules.new").write_bytes(template)
    print("  CLAUDE.md 원본 유지 — 새 규칙: CLAUDE.md.library-rules.new")
if updated is not None and updated != content:
    if target.exists():
        shutil.copyfile(target, str(target) + ".bak")
    target.write_bytes(updated)
    import subprocess
    subprocess.run([sys.executable, sys.argv[3], 'append', str(target), sys.argv[4],
                    'CLAUDE.md 관리 블록 갱신'], check=True)
    print("  CLAUDE.md 관리 규칙 갱신 (기존 파일 백업: CLAUDE.md.bak)")
PYEOF
fi

# --- permissions: library 경로 허용 (누락 시 보충) ---
SETTINGS="$HOME/.claude/settings.json"

# SessionStart 훅이 자동 실행하므로 세션 여러 개를 동시에 열면 그대로 경합한다.
LOCK_DIR="$(dirname "$SETTINGS")/.settings.lock"
_lock_i=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  _lock_i=$((_lock_i + 1))
  [ "$_lock_i" -gt 150 ] && break
  sleep 0.1
done
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  if jq -e '.permissions.allow // [] | map(select(test("claude-library"))) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
    skip "library 경로 권한 이미 존재"
  else
    jq --arg home "$HOME" '
      .permissions.allow = ((.permissions.allow // []) + [
        "Write(~/claude-library/**)",
        "Edit(~/claude-library/**)",
        ("Write(" + $home + "/claude-library/**)"),
        ("Edit(" + $home + "/claude-library/**)")
      ] | unique) |
      .permissions.additionalDirectories = ((.permissions.additionalDirectories // []) + [
        ($home + "/claude-library")
      ] | unique)
    ' "$SETTINGS" > "$SETTINGS.tmp.$$" && mv "$SETTINGS.tmp.$$" "$SETTINGS"
    ok "library 경로 Write/Edit 권한 추가 (절대경로 + additionalDirectories 포함)"
    UPDATED=$((UPDATED + 1))
  fi
fi

# 정책 검사 런타임과 사용량 로거 배치
if [ "$PROFILE" = user ]; then
  rm -f "$HOME/.claude/hooks/policy-changelog-check.sh" "$HOME/.claude/hooks/policy-changelog.py"
fi
for hook in policy-changelog-check.sh policy-changelog.py library-usage-log.sh; do
  if [ "$PROFILE" = user ] && [ "$hook" != library-usage-log.sh ]; then continue; fi
  if [ -f "$PACKAGE_DIR/hooks/$hook" ]; then
    mkdir -p "$HOME/.claude/hooks"
    cp "$PACKAGE_DIR/hooks/$hook" "$HOME/.claude/hooks/$hook"
    chmod +x "$HOME/.claude/hooks/$hook"
  fi
done

# 정책 이력 검사와 턴 사용량 기록: 기존 등록을 정규화해 중복을 없앤다.
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  jq --arg profile "$PROFILE" --arg policy "$HOME/.claude/hooks/policy-changelog-check.sh" \
     --arg usage "$HOME/.claude/hooks/library-usage-log.sh" '
    def strip($cmd): map(.hooks |= map(select(.command != $cmd))) | map(select(.hooks | length > 0));
    .hooks.SessionStart = (((.hooks.SessionStart // []) | strip($policy)) +
      (if $profile == "maintainer" then [{hooks: [{type: "command", command: $policy, timeout: 30}]}] else [] end)) |
    .hooks.Stop = (((.hooks.Stop // []) | strip($policy) | strip($usage)) +
      (if $profile == "maintainer" then [{hooks: [{type: "command", command: $policy, timeout: 30}]}] else [] end) +
      [{hooks: [{type: "command", command: $usage, async: true, timeout: 30}]}])
  ' "$SETTINGS" > "$SETTINGS.tmp.$$" && mv "$SETTINGS.tmp.$$" "$SETTINGS"
fi

# 마지막 관리값과 같을 때만 프로필 기본값을 갱신한다.
python3 - "$SETTINGS" "$PROFILE" <<'PYPROFILE'
import json, os, sys
from pathlib import Path
path = Path(sys.argv[1])
if path.exists():
    settings = json.loads(path.read_text())
    env = settings.setdefault('env', {})
    marker = path.parent / 'hooks/.learnings-usage-log'
    previous = marker.read_text().strip() if marker.exists() else None
    current = env.get('LIBRARY_USAGE_LOG')
    if current is None or (previous is not None and current == previous):
        value = 'full' if sys.argv[2] == 'maintainer' else 'aggregate'
        env['LIBRARY_USAGE_LOG'] = value
        temporary = path.with_name(path.name + '.profile.tmp')
        temporary.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + '\n')
        temporary.replace(path)
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(value + '\n')
    elif marker.exists():
        marker.unlink()
PYPROFILE

# PreCompact는 같은 발췌기를 사용하며 다음 Stop에 리뷰를 맡긴다.
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  jq --arg cmd "$HOME/.claude/hooks/library-save-check.sh" '
    .hooks.PreCompact = (
      [(.hooks.PreCompact // [])[] |
        .hooks |= map(select(.command != $cmd)) | select(.hooks | length > 0)] +
      [{hooks: [{type: "command", command: $cmd, timeout: 10}]}])
  ' "$SETTINGS" > "$SETTINGS.tmp.$$" && mv "$SETTINGS.tmp.$$" "$SETTINGS"
fi

# --- PreToolUse 훅: library-allow 등록 (누락 시 보충) ---
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  if grep -qF "library-allow" "$SETTINGS" 2>/dev/null; then
    skip "library-allow 훅 이미 등록됨"
  else
    LIBRARY_ALLOW_DEST="$HOME/.claude/hooks/library-allow.sh"
    LIBRARY_ALLOW_JSON="{\"matcher\":\"Write|Edit|MultiEdit\",\"hooks\":[{\"type\":\"command\",\"command\":\"$LIBRARY_ALLOW_DEST\",\"timeout\":3}]}"
    jq --argjson hook "$LIBRARY_ALLOW_JSON" '
      .hooks.PreToolUse = (.hooks.PreToolUse // []) + [$hook]
    ' "$SETTINGS" > "$SETTINGS.tmp.$$" && mv "$SETTINGS.tmp.$$" "$SETTINGS"
    ok "library-allow.sh PreToolUse 훅 등록"
    UPDATED=$((UPDATED + 1))
  fi
fi

# --- UserPromptSubmit: 검색 결과 자동 주입 ---
if [ -f "$PACKAGE_DIR/hooks/library-autoinject.sh" ]; then
  copy_if_changed "$PACKAGE_DIR/hooks/library-autoinject.sh" "$HOOK_DIR/library-autoinject.sh" "library-autoinject.sh (prompt hook)"
  if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak"
    jq --arg cmd "$HOME/.claude/hooks/library-autoinject.sh" '
      .hooks.UserPromptSubmit = (
        [(.hooks.UserPromptSubmit // [])[] |
          .hooks |= map(select(.command != $cmd)) | select(.hooks | length > 0)] +
        [{hooks: [{type: "command", command: $cmd, timeout: 5}]}])
    ' "$SETTINGS" > "$SETTINGS.tmp.$$"
    mv "$SETTINGS.tmp.$$" "$SETTINGS"
  fi
fi

# MCP 전환은 설치/자동 체커와 같은 함수를 사용한다.
source "$PACKAGE_DIR/scripts/update-check.sh"
update_library_mcp "$BRANCH" "$KB_SPEC"

# 버전 기록
LATEST_SHA=$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "$BRANCH@$LATEST_SHA" > "$HOOK_DIR/.learnings-version"

echo ""
echo -e "${GREEN}✓${NC}  ${BOLD}업데이트 완료${NC} — ${GREEN}${UPDATED}개 업데이트${NC}, ${DIM}${UNCHANGED}개 변경 없음${NC}"
