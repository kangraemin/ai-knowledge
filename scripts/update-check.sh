#!/bin/bash
# learnings-for-claude 자동 업데이트 체커
# Usage: update-check.sh [--branch <name>] [--force] [--check-only]

# 설치/수동 업데이트에서도 같은 MCP 전환 함수를 사용한다.
update_library_mcp() {
  local branch="$1" spec="$2" mode="${3:-update}"
  local sf tmp snapshot found=false
  command -v jq >/dev/null 2>&1 || { echo "브랜치 설정에는 jq가 필요합니다." >&2; return 1; }
  # 어느 한쪽에만 등록되어 있으면 다른 파일에 중복 등록하지 않는다.
  for sf in "$HOME/.claude/settings.json" "$HOME/.claude.json"; do
    [ -f "$sf" ] || continue
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$sf" >/dev/null 2>&1; then
      echo "경고: $sf JSON 오류 — MCP 변경 중단" >&2
      return 1
    fi
    if jq -e '.mcpServers["claude-library"] | type == "object"' "$sf" >/dev/null; then
      found=true
    fi
  done
  for sf in "$HOME/.claude/settings.json" "$HOME/.claude.json"; do
    [ -f "$sf" ] || continue
    if ! jq -e '.mcpServers["claude-library"] | type == "object"' "$sf" >/dev/null; then
      # 등록이 전혀 없을 때만 기존 settings.json 등록 동작을 유지한다.
      [ "$found" = false ] && [ "$sf" = "$HOME/.claude/settings.json" ] || continue
    fi
    snapshot=$(mktemp "$sf.snapshot.XXXXXX") || return 1
    tmp=$(mktemp "$sf.tmp.XXXXXX") || { rm -f "$snapshot"; return 1; }
    # 변경 직전 스냅샷을 사용하고 동시 쓰기가 감지되면 덮어쓰지 않는다.
    if ! cp -p "$sf" "$snapshot" || ! jq --arg branch "$branch" --arg spec "$spec" \
      --arg home "$HOME" --arg mode "$mode" '
      .mcpServers["claude-library"].alwaysLoad = true |
      .mcpServers["claude-library"].command = "uvx" |
      .mcpServers["claude-library"].args = (if $branch == "main" then
        ["--with", "mcp<2", "claude-library-mcp@latest"] else
        ["--with", "mcp<2", "--from", $spec, "claude-library-mcp"] end) |
      if $mode == "install" then
        .mcpServers["claude-library"].env.LIBRARY_ROOT //= ($home + "/claude-library")
      else . end
    ' "$snapshot" > "$tmp" || ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$tmp" >/dev/null; then
      rm -f "$snapshot" "$tmp"
      echo "경고: $sf MCP 변경 실패 — 원본 유지" >&2
      return 1
    fi
    if ! cmp -s "$sf" "$snapshot"; then
      rm -f "$snapshot" "$tmp"
      echo "경고: $sf 동시 변경 감지 — 다시 실행하세요" >&2
      return 1
    fi
    if ! cmp -s "$sf" "$tmp"; then
      cp -p "$snapshot" "$sf.bak" && mv "$tmp" "$sf" || { rm -f "$snapshot" "$tmp"; return 1; }
    fi
    rm -f "$snapshot" "$tmp"
  done
  # hook 은 uvx 캐시를 쓰므로 이름만 주면 예전에 받은 버전이 계속 돈다.
  # main 은 받은 소스의 패키지 버전으로 고정해 hook 과 CLI 옵션이 항상 맞게 한다.
  local pyproject version
  pyproject="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/mcp-server/pyproject.toml"
  if [ "$spec" = claude-library-mcp ] && [ -f "$pyproject" ]; then
    version=$(sed -n 's/^version = "\([0-9][0-9A-Za-z.+-]*\)"$/\1/p' "$pyproject" | head -1)
    [ -n "$version" ] && spec="claude-library-mcp==$version"
  fi
  mkdir -p "$HOME/.claude/hooks"
  local spec_file="$HOME/.claude/hooks/.learnings-kb-spec"
  # uv 는 PyPI 목록을 캐시해서 방금 올린 버전을 못 찾는다. 그대로 두면 hook 이 매번 즉시 실패한다.
  # 목록을 새로 받아 미리 설치해 두고, 실패하면(아직 미배포·오프라인) 이전 spec 을 유지한다.
  if [ "${spec#claude-library-mcp==}" != "$spec" ] && [ "${LEARNINGS_KB_WARM:-1}" != 0 ] && command -v uvx >/dev/null 2>&1; then
    if ! uvx --refresh-package claude-library-mcp --with 'mcp<2' --from "$spec" claude-library-kb --help >/dev/null 2>&1; then
      if [ -s "$spec_file" ]; then
        echo "경고: $spec 설치 실패 — hook 은 이전 버전($(cat "$spec_file"))을 계속 쓴다" >&2
        return 0
      fi
      spec=claude-library-mcp
    fi
  fi
  printf '%s\n' "$spec" > "$spec_file"
}

# source 할 때 체크/다운로드 등 실행 부작용 없이 함수만 제공한다.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

set -euo pipefail

# 브랜치 설정: 명시 옵션은 저장하고 환경변수는 실행 시에만 우선한다.
BRANCH_FILE="$HOME/.claude/hooks/.learnings-branch"
BRANCH_OPTION=""
FORCE=false
CHECK_ONLY=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      [ "$#" -ge 2 ] || { echo "--branch 값이 필요합니다." >&2; exit 1; }
      BRANCH_OPTION="$2"
      [[ "$BRANCH_OPTION" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$BRANCH_OPTION" != *..* ]] || { echo "잘못된 브랜치명" >&2; exit 1; }
      shift 2 ;;
    --force) FORCE=true; shift ;;
    --check-only) CHECK_ONLY=true; shift ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done
BRANCH="${LEARNINGS_BRANCH:-${BRANCH_OPTION:-$(cat "$BRANCH_FILE" 2>/dev/null || echo main)}}"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$BRANCH" != *..* ]] || { echo "잘못된 브랜치명" >&2; exit 1; }
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


REPO="kangraemin/learnings-for-claude"
API_URL="https://api.github.com/repos/$REPO/commits/$BRANCH"

HOOK_DIR="$HOME/.claude/hooks"
VERSION_FILE="$HOOK_DIR/.learnings-version"
CHECKED_FILE="$HOOK_DIR/.learnings-version-checked"

# 명시적인 브랜치 선택은 MCP 실행 소스도 함께 갱신한다.
SETTINGS="$HOME/.claude/settings.json"
if [ -n "$BRANCH_OPTION" ]; then
  update_library_mcp "$BRANCH" "$KB_SPEC"
fi

# ── 누락 hook 검증 (매 세션) ──────────────────────────────────────────────────
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python3)

_ensure_hook() {
  local sf="$1" event="$2" cmd="$3" timeout="$4" is_async="$5" matcher="${6:-}"
  [ -f "$sf" ] || return 0
  [ -f "$cmd" ] || return 0
  local bn
  bn=$(basename "$cmd")
  grep -q "$bn" "$sf" 2>/dev/null && return 0
  $PYTHON -c "
import json, sys
sf, event, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
timeout, is_async, matcher = int(sys.argv[4]), sys.argv[5] == 'true', sys.argv[6]
cfg = json.load(open(sf))
hooks = cfg.setdefault('hooks', {})
entries = hooks.setdefault(event, [])
hook = {'type': 'command', 'command': cmd, 'timeout': timeout}
if is_async:
    hook['async'] = True
entry = {'hooks': [hook]}
if matcher:
    entry['matcher'] = matcher
entries.append(entry)
with open(sf, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('added')
" "$sf" "$event" "$cmd" "$timeout" "$is_async" "$matcher" >/dev/null 2>&1
  echo "✓  ${event} hook 등록: $bn" >&2
}

SETTINGS="$HOME/.claude/settings.json"
_ensure_hook "$SETTINGS" "SessionStart" "$HOOK_DIR/learnings-update-check.sh" 15 true  "" || true
_ensure_hook "$SETTINGS" "Stop"         "$HOOK_DIR/library-save-check.sh"     10 false "" || true

# 설치 확인
[ -f "$HOOK_DIR/library-sync.sh" ] || exit 0

# 24h throttle
if [ "$FORCE" = false ] && [ "$CHECK_ONLY" = false ] && [ -f "$CHECKED_FILE" ]; then
  CHECKED=$(cat "$CHECKED_FILE" 2>/dev/null || echo 0)
  # 이전 타임스탬프 단독 형식은 main에만 적용한다.
  CHECKED_BRANCH=main
  LAST="$CHECKED"
  if [[ "$CHECKED" = *@* ]]; then
    CHECKED_BRANCH="${CHECKED%@*}"
    LAST="${CHECKED##*@}"
  fi
  NOW=$(date +%s)
  if [ "$CHECKED_BRANCH" = "$BRANCH" ] && [[ "$LAST" =~ ^[0-9]+$ ]] &&
     [ "$LAST" -le "$NOW" ] && [ $(( NOW - LAST )) -lt 86400 ]; then
    exit 0
  fi
fi

# 최신 SHA 조회
LATEST_SHA=$(curl -sfL --max-time 5 "$API_URL" 2>/dev/null | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['sha'][:7])" 2>/dev/null) || exit 0

# 체크 타임스탬프 갱신
printf '%s@%s\n' "$BRANCH" "$(date +%s)" > "$CHECKED_FILE"

INSTALLED_SHA=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")

# 구형 SHA만 있는 버전은 main 설치로 해석한다.
INSTALLED_VERSION="$INSTALLED_SHA"
[[ "$INSTALLED_VERSION" = *@* ]] || INSTALLED_VERSION="main@$INSTALLED_SHA"
# git의 core.abbrev 설정이나 구형 전체 SHA와 무관하게 7자리로 비교한다.
INSTALLED_BRANCH="${INSTALLED_VERSION%@*}"
INSTALLED_COMMIT="${INSTALLED_VERSION##*@}"
INSTALLED_VERSION="$INSTALLED_BRANCH@${INSTALLED_COMMIT:0:7}"
LATEST_VERSION="$BRANCH@$LATEST_SHA"

if [ "$CHECK_ONLY" = true ]; then
  echo "installed: $INSTALLED_SHA"
  echo "latest:    $LATEST_VERSION"
  [ "$LATEST_VERSION" = "$INSTALLED_VERSION" ] && echo "status: up-to-date" || echo "status: update-available"
  exit 0
fi

[ "$LATEST_VERSION" = "$INSTALLED_VERSION" ] && exit 0

# 자기 자신을 원격에서 받아 덮어쓰고 exec 하던 부트스트랩은 제거했다.
# 검증이 `bash -n`(문법)뿐이라 레포가 한 번 털리면 설치된 전 사용자에게
# 매 세션 임의 코드 실행이 된다. 자기갱신은 update.sh 의 copy_if_changed 가 한다.

if [ "${LEARNINGS_AUTO_UPDATE:-0}" = "1" ] || [ "$FORCE" = true ]; then
  # 적용할 때만 선택한 브랜치를 받는다.
  CLONE_DIR=$(mktemp -d)
  trap 'rm -rf "$CLONE_DIR"' EXIT
  git clone --depth 1 -b "$BRANCH" "https://github.com/$REPO.git" "$CLONE_DIR/learnings-for-claude" -q 2>/dev/null || exit 0
  LEARNINGS_BRANCH="$BRANCH" bash "$CLONE_DIR/learnings-for-claude/update.sh" || exit 0
else
  # 동의 없이 사용자 파일을 건드리지 않는다. 알림만 하고 실행은 사용자가 고른다.
  echo "learnings-for-claude 새 버전 있음: $INSTALLED_SHA → $LATEST_SHA"
  echo "  적용: /update-learnings  (또는 LEARNINGS_AUTO_UPDATE=1 로 자동 적용)"
  exit 0
fi

echo "learnings-for-claude $INSTALLED_SHA → $LATEST_SHA 업데이트 완료"
