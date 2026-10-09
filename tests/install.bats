#!/usr/bin/env bats
# install.sh / update.sh E2E tests

setup() {
  export TEST_HOME="$(mktemp -d)"
  export ORIG_HOME="$HOME"
  export HOME="$TEST_HOME"
  export CLAUDE_DIR="$TEST_HOME/.claude"
  export LIB_DIR="$TEST_HOME/claude-library"
  export SETTINGS="$CLAUDE_DIR/settings.json"
  export INSTALL_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/install.sh"

  unset LEARNINGS_PROFILE LIBRARY_USAGE_LOG LEARNINGS_BRANCH LEARNINGS_AUTO_UPDATE LIBRARY_KB_CMD LIBRARY_AUTOINJECT KB_SLEEP KB_FAIL
  export ORIG_TEST_PATH="$PATH"
  # 테스트가 실제 uvx 로 PyPI 를 받지 않게 한다. 미리 받기 동작은 전용 테스트에서 stub 으로 검증한다.
  export LEARNINGS_KB_WARM=0
  export REPO_DIR="$(dirname "$INSTALL_SH")"
  # 네트워크와 실제 홈에 의존하지 않는 소스 복제본.
  export SOURCE_DIR="$TEST_HOME/source"
  mkdir -p "$SOURCE_DIR" "$TEST_HOME/bin"
  cp -R "$REPO_DIR/hooks" "$REPO_DIR/scripts" "$REPO_DIR/skills" "$REPO_DIR/templates" "$SOURCE_DIR/"
  cp "$REPO_DIR/install.sh" "$REPO_DIR/update.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/GUIDE.md" "$REPO_DIR/TAXONOMY.md" "$SOURCE_DIR/"
  mkdir -p "$SOURCE_DIR/mcp-server"
  cp "$REPO_DIR/mcp-server/pyproject.toml" "$SOURCE_DIR/mcp-server/"
  [ -f "$SOURCE_DIR/hooks/library-autoinject.sh" ] || printf '#!/bin/bash\nexit 0\n' > "$SOURCE_DIR/hooks/library-autoinject.sh"
  export INSTALL_SH="$SOURCE_DIR/install.sh"
  export CURL_LOG="$TEST_HOME/curl.log"
  cat > "$TEST_HOME/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  */commits/*) printf '{"sha":"abcdef123456789"}\n' ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$TEST_HOME/bin/curl"
  export PATH="$TEST_HOME/bin:$PATH"
  mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills"
  echo '{"hooks":{},"mcpServers":{}}' > "$SETTINGS"
}

teardown() {
  export HOME="$ORIG_HOME"
  export PATH="$ORIG_TEST_PATH"
  rm -rf "$TEST_HOME"
}

# Helper: run install.sh with tty input via stdin redirect
# Patches /dev/tty reads to use stdin, but preserves SCRIPT_DIR pointing to real repo
install_with_input() {
  local input="$1"
  shift
  local patched="$TEST_HOME/install_patched.sh"
  local real_script_dir
  real_script_dir="$(cd "$(dirname "$INSTALL_SH")" && pwd)"
  # Remove </dev/tty and force SCRIPT_DIR to real repo path
  sed 's|</dev/tty||g' "$INSTALL_SH" | \
    sed "s|SCRIPT_DIR=.*|SCRIPT_DIR='$real_script_dir'|" > "$patched"
  chmod +x "$patched"
  # install.sh 는 프롬프트가 여러 개다(언어·git방식·Notion·프로젝트경로).
  # 한 줄만 주면 두 번째 read 에서 EOF → set -e 로 죽는다.
  # 첫 답을 주고 나머지는 기본값(빈 줄)으로 흘려보낸다.
  { echo "$input"; for _ in $(seq 1 20); do echo ""; done; } | bash "$patched" "$@" 2>&1
}

# 여러 프롬프트에 순서대로 답한다. 예: install_with_answers "1" "1"
install_with_answers() {
  local patched="$TEST_HOME/install_patched.sh"
  local real_script_dir
  real_script_dir="$(cd "$(dirname "$INSTALL_SH")" && pwd)"
  sed 's|</dev/tty||g' "$INSTALL_SH" | \
    sed "s|SCRIPT_DIR=.*|SCRIPT_DIR='$real_script_dir'|" > "$patched"
  chmod +x "$patched"
  { for a in "$@"; do echo "$a"; done; for _ in $(seq 1 20); do echo ""; done; } | bash "$patched" 2>&1
}

# ─── 1. Directory structure ───────────────────────────────────────

@test "TC-01: creates .claude-library directory" {
  install_with_input "1"
  [ -d "$LIB_DIR" ]
}

@test "TC-02: creates .claude-library/library subdirectory" {
  install_with_input "1"
  [ -d "$LIB_DIR/library" ]
}

@test "TC-03: creates LIBRARY.md" {
  install_with_input "1"
  [ -f "$LIB_DIR/LIBRARY.md" ]
}

@test "TC-04: LIBRARY.md contains header" {
  install_with_input "1"
  grep -q "# Library" "$LIB_DIR/LIBRARY.md"
}

@test "TC-05: creates GUIDE.md" {
  install_with_input "1"
  [ -f "$LIB_DIR/GUIDE.md" ]
}

@test "TC-06: creates _template.md" {
  install_with_input "1"
  [ -f "$LIB_DIR/library/_template.md" ]
}

@test "TC-07: does not overwrite existing LIBRARY.md" {
  mkdir -p "$LIB_DIR"
  echo "EXISTING_CONTENT" > "$LIB_DIR/LIBRARY.md"
  install_with_input "1"
  grep -q "EXISTING_CONTENT" "$LIB_DIR/LIBRARY.md"
}

@test "TC-08: does not overwrite existing GUIDE.md" {
  mkdir -p "$LIB_DIR"
  echo "MY_GUIDE" > "$LIB_DIR/GUIDE.md"
  install_with_input "1"
  grep -q "MY_GUIDE" "$LIB_DIR/GUIDE.md"
}

@test "TC-09: does not overwrite existing _template.md" {
  mkdir -p "$LIB_DIR/library"
  echo "MY_TEMPLATE" > "$LIB_DIR/library/_template.md"
  install_with_input "1"
  grep -q "MY_TEMPLATE" "$LIB_DIR/library/_template.md"
}

# ─── 2. CLAUDE.md rules injection ────────────────────────────────

@test "TC-10: creates CLAUDE.md with Library section if missing" {
  install_with_input "1"
  [ -f "$CLAUDE_DIR/CLAUDE.md" ]
  grep -q "## Library" "$CLAUDE_DIR/CLAUDE.md"
}

@test "TC-11: appends rules to existing CLAUDE.md without marker" {
  echo "# Existing Rules" > "$CLAUDE_DIR/CLAUDE.md"
  install_with_input "1"
  grep -q "## Library" "$CLAUDE_DIR/CLAUDE.md"
  grep -q "# Existing Rules" "$CLAUDE_DIR/CLAUDE.md"
}

@test "TC-12: preserves legacy Library section on reinstall" {
  printf "# Rules\n\n## Library 시스템\nOLD_CONTENT\n" > "$CLAUDE_DIR/CLAUDE.md"
  install_with_input "1"
  grep -q "OLD_CONTENT" "$CLAUDE_DIR/CLAUDE.md"
  [ -f "$CLAUDE_DIR/CLAUDE.md.library-rules.new" ]
}

@test "TC-13: preserves content before Library section after update" {
  printf "# My Rules\n\n## Library 시스템\nOLD\n" > "$CLAUDE_DIR/CLAUDE.md"
  install_with_input "1"
  grep -q "# My Rules" "$CLAUDE_DIR/CLAUDE.md"
}

@test "TC-14: warns and skips if templates/claude-rules.md missing" {
  local real_script_dir
  real_script_dir="$(cd "$(dirname "$INSTALL_SH")" && pwd)"
  local patched="$TEST_HOME/install_norules.sh"
  sed "s|SCRIPT_DIR=.*|SCRIPT_DIR='$real_script_dir'|" "$INSTALL_SH" | \
    sed 's|</dev/tty||g' | \
    sed 's|RULES_SRC=.*|RULES_SRC=/nonexistent/nowhere.md|' > "$patched"
  chmod +x "$patched"
  local out
  out=$({ echo "1"; for _ in $(seq 1 20); do echo ""; done; } | bash "$patched" 2>&1)
  echo "$out" | grep -q "경고"
}

# ─── 3. library-sync hook ────────────────────────────────────────

@test "TC-15: creates library-sync.sh" {
  install_with_input "1"
  [ -f "$CLAUDE_DIR/hooks/library-sync.sh" ]
}

@test "TC-16: library-sync.sh is executable" {
  install_with_input "1"
  [ -x "$CLAUDE_DIR/hooks/library-sync.sh" ]
}

@test "TC-17: registers SessionEnd hook in settings.json" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('SessionEnd', [])
cmds = [h['command'] for e in hooks for h in e.get('hooks', [])]
assert any('library-sync' in c for c in cmds), cmds
"
}

@test "TC-18: registers PostCompact hook in settings.json" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('PostCompact', [])
cmds = [h['command'] for e in hooks for h in e.get('hooks', [])]
assert any('library-sync' in c for c in cmds), cmds
"
}

@test "TC-19: no duplicate SessionEnd hook on reinstall" {
  install_with_input "1"
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('SessionEnd', [])
cmds = [h['command'] for e in hooks for h in e.get('hooks', [])]
n = sum(1 for c in cmds if 'library-sync' in c)
assert n == 1, f'count={n}'
"
}

@test "TC-20: warns and skips hooks when jq not available" {
  local patched="$TEST_HOME/install_nojq.sh"
  local real_script_dir
  real_script_dir="$(cd "$(dirname "$INSTALL_SH")" && pwd)"
  sed 's|command -v jq|command -v jq_FAKE_NOTEXIST|g' "$INSTALL_SH" | \
    sed 's|</dev/tty||g' | \
    sed "s|SCRIPT_DIR=.*|SCRIPT_DIR='$real_script_dir'|" > "$patched"
  chmod +x "$patched"
  local out
  out=$({ echo "1"; for _ in $(seq 1 20); do echo ""; done; } | bash "$patched" 2>&1)
  echo "$out" | grep -q "jq"
}

# ─── 4. library-save-check (Stop hook) ───────────────────────────

@test "TC-21: creates library-save-check.sh" {
  install_with_input "1"
  [ -f "$CLAUDE_DIR/hooks/library-save-check.sh" ]
}

@test "TC-22: library-save-check.sh is executable" {
  install_with_input "1"
  [ -x "$CLAUDE_DIR/hooks/library-save-check.sh" ]
}

@test "TC-23: registers Stop hook in settings.json" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('Stop', [])
cmds = [h['command'] for e in hooks for h in e.get('hooks', [])]
assert any('library-save-check' in c for c in cmds), cmds
"
}

@test "TC-24: no duplicate Stop hook on reinstall" {
  install_with_input "1"
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('Stop', [])
cmds = [h['command'] for e in hooks for h in e.get('hooks', [])]
n = sum(1 for c in cmds if 'library-save-check' in c)
assert n == 1, f'count={n}'
"
}

@test "TC-25: library-save-check.sh has re-entry guard" {
  install_with_input "1"
  grep -q "stop_hook_active" "$CLAUDE_DIR/hooks/library-save-check.sh"
}

@test "TC-26: library-save-check.sh has counter throttle" {
  install_with_input "1"
  grep -q "COUNTER_FILE" "$CLAUDE_DIR/hooks/library-save-check.sh"
}

@test "TC-27: library-save-check.sh counter is session-based" {
  install_with_input "1"
  grep -q "session_id" "$CLAUDE_DIR/hooks/library-save-check.sh"
}

# ─── 5. learnings-update-check (SessionStart hook) ───────────────

@test "TC-28: creates learnings-update-check.sh" {
  install_with_input "1"
  [ -f "$CLAUDE_DIR/hooks/learnings-update-check.sh" ]
}

@test "TC-29: learnings-update-check.sh is executable" {
  install_with_input "1"
  [ -x "$CLAUDE_DIR/hooks/learnings-update-check.sh" ]
}

@test "TC-30: registers SessionStart hook in settings.json" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('SessionStart', [])
cmds = [h['command'] for e in hooks for h in e.get('hooks', [])]
assert any('learnings-update-check' in c for c in cmds), cmds
"
}

@test "TC-31: no duplicate SessionStart hook on reinstall" {
  install_with_input "1"
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('SessionStart', [])
cmds = [h['command'] for e in hooks for h in e.get('hooks', [])]
n = sum(1 for c in cmds if 'learnings-update-check' in c)
assert n == 1, f'count={n}'
"
}

@test "TC-32: SessionStart hook has async:true" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {}).get('SessionStart', [])
for e in hooks:
    for h in e.get('hooks', []):
        if 'learnings-update-check' in h.get('command', ''):
            assert h.get('async') == True, 'async not set'
"
}

@test "TC-33: install exits 0 even if curl fails (version recording)" {
  install_with_input "1"
  [ -d "$CLAUDE_DIR/hooks" ]  # side effect check
}

# ─── 6. Skills ───────────────────────────────────────────────────

@test "TC-34: creates session-review skill directory" {
  install_with_input "1"
  [ -d "$CLAUDE_DIR/skills/session-review" ]
}

@test "TC-35: creates session-review SKILL.md" {
  install_with_input "1"
  [ -f "$CLAUDE_DIR/skills/session-review/SKILL.md" ]
}

@test "TC-36: session-review SKILL.md contains name field" {
  install_with_input "1"
  grep -q "name: session-review" "$CLAUDE_DIR/skills/session-review/SKILL.md"
}

@test "TC-37: session-review SKILL.md contains description" {
  install_with_input "1"
  grep -q "description:" "$CLAUDE_DIR/skills/session-review/SKILL.md"
}

@test "TC-38: does not overwrite existing session-review skill" {
  mkdir -p "$CLAUDE_DIR/skills/session-review"
  echo "CUSTOM_SKILL" > "$CLAUDE_DIR/skills/session-review/SKILL.md"
  install_with_input "1"
  grep -q "CUSTOM_SKILL" "$CLAUDE_DIR/skills/session-review/SKILL.md"
}

@test "TC-39: creates update-learnings skill directory" {
  install_with_input "1"
  [ -d "$CLAUDE_DIR/skills/update-learnings" ]
}

@test "TC-40: creates update-learnings SKILL.md" {
  install_with_input "1"
  [ -f "$CLAUDE_DIR/skills/update-learnings/SKILL.md" ]
}

@test "TC-41: does not overwrite existing update-learnings skill" {
  mkdir -p "$CLAUDE_DIR/skills/update-learnings"
  echo "CUSTOM_UPDATE" > "$CLAUDE_DIR/skills/update-learnings/SKILL.md"
  install_with_input "1"
  grep -q "CUSTOM_UPDATE" "$CLAUDE_DIR/skills/update-learnings/SKILL.md"
}

# ─── 7. MCP server registration ──────────────────────────────────

@test "TC-42: registers claude-library MCP server" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
mcp = d.get('mcpServers', {}).get('claude-library', {})
assert mcp.get('command') == 'uvx', mcp
"
}

@test "TC-43: MCP args contains claude-library-mcp" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
mcp = d.get('mcpServers', {}).get('claude-library', {})
assert any('claude-library-mcp' in a for a in mcp.get('args', [])), mcp
"
}

@test "TC-44: MCP env contains LIBRARY_ROOT pointing to claude-library" {
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
mcp = d.get('mcpServers', {}).get('claude-library', {})
lr = mcp.get('env', {}).get('LIBRARY_ROOT', '')
assert 'claude-library' in lr, lr
"
}

@test "TC-45: overwrites old MCP config with uvx on reinstall" {
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
d.setdefault('mcpServers', {})['claude-library'] = {'command': 'python3', 'args': ['old_server.py']}
json.dump(d, open('$SETTINGS', 'w'))
"
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
mcp = d.get('mcpServers', {}).get('claude-library', {})
assert mcp.get('command') == 'uvx', mcp
"
}

# ─── 8. settings.json integrity ──────────────────────────────────

@test "TC-46: settings.json is valid JSON after install" {
  install_with_input "1"
  python3 -m json.tool "$SETTINGS" > /dev/null
}

@test "TC-47: install succeeds even if settings.json does not exist" {
  rm -f "$SETTINGS"
  install_with_input "1"
  [ -f "$SETTINGS" ]
}

@test "TC-48: settings.json is valid JSON after reinstall" {
  install_with_input "1"
  install_with_input "1"
  python3 -m json.tool "$SETTINGS" > /dev/null
}

# ─── 9. git management options ───────────────────────────────────

@test "TC-49: IS_GIT=false git_choice=1 - no gitignore changes" {
  install_with_input "1"
  [ "$?" -eq 0 ]
  ! grep -qF ".claude-library/" "$CLAUDE_DIR/.gitignore" 2>/dev/null
}

@test "TC-50: stale .claude-library/ entry is removed from .gitignore" {
  git -C "$CLAUDE_DIR" init -q 2>/dev/null
  # 옛 항목만 있는 경우 — grep -v 결과가 0줄이라 예전엔 제거에 실패했다
  echo ".claude-library/" > "$CLAUDE_DIR/.gitignore"
  install_with_answers "1" "1" > /dev/null 2>&1 || true
  # `! grep` 은 set -e 가 무시하므로 명시적으로 실패시킨다
  if grep -qF ".claude-library/" "$CLAUDE_DIR/.gitignore"; then
    echo "stale entry survived: $(cat "$CLAUDE_DIR/.gitignore")" >&2
    return 1
  fi
  # .tmp 고아가 남지 않아야 한다
  if [ -f "$CLAUDE_DIR/.gitignore.tmp" ]; then
    echo ".gitignore.tmp orphan left behind" >&2
    return 1
  fi
}

@test "TC-50b: unrelated .gitignore entries survive cleanup" {
  git -C "$CLAUDE_DIR" init -q 2>/dev/null
  printf 'keepme/\n.claude-library/\nother.log\n' > "$CLAUDE_DIR/.gitignore"
  install_with_answers "1" "1" > /dev/null 2>&1 || true
  grep -qF "keepme/" "$CLAUDE_DIR/.gitignore"
  grep -qF "other.log" "$CLAUDE_DIR/.gitignore"
  if grep -qF ".claude-library/" "$CLAUDE_DIR/.gitignore"; then
    echo "stale entry survived" >&2
    return 1
  fi
}

@test "TC-51: IS_GIT=true git_choice=2 - does not add to .gitignore" {
  git -C "$CLAUDE_DIR" init -q 2>/dev/null
  install_with_input "2"
  ! grep -qF ".claude-library/" "$CLAUDE_DIR/.gitignore" 2>/dev/null
}

@test "TC-52: empty repo_url causes install to abort with error" {
  git -C "$CLAUDE_DIR" init -q 2>/dev/null
  local real_script_dir
  real_script_dir="$(cd "$(dirname "$INSTALL_SH")" && pwd)"
  local patched="$TEST_HOME/install_patched.sh"
  sed "s|SCRIPT_DIR=.*|SCRIPT_DIR='$real_script_dir'|" "$INSTALL_SH" | \
    sed 's|</dev/tty||g' > "$patched"
  chmod +x "$patched"
  local out
  out=$(printf "1\n3\nn\n\n" | bash "$patched" 2>&1) || true
  echo "$out" | grep -q "오류"
}

# ─── 10. Idempotency ─────────────────────────────────────────────

@test "TC-53: no duplicate hooks after reinstall (all events)" {
  install_with_input "1"
  install_with_input "1"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
for event in ['SessionEnd', 'PostCompact', 'Stop', 'SessionStart']:
    hooks = d.get('hooks', {}).get(event, [])
    cmds = [h['command'].split('/')[-1] for e in hooks for h in e.get('hooks', [])]
    assert len(cmds) == len(set(cmds)), f'Dup in {event}: {cmds}'
"
}

@test "TC-54: reinstall preserves custom content in LIBRARY.md" {
  install_with_input "1"
  echo "MY_ENTRY" >> "$LIB_DIR/LIBRARY.md"
  install_with_input "1"
  grep -q "MY_ENTRY" "$LIB_DIR/LIBRARY.md"
}

@test "TC-55: reinstall preserves existing library knowledge files" {
  install_with_input "1"
  mkdir -p "$LIB_DIR/library/test-topic"
  echo "KNOWLEDGE_FILE" > "$LIB_DIR/library/test-topic/discovery.md"
  install_with_input "1"
  grep -q "KNOWLEDGE_FILE" "$LIB_DIR/library/test-topic/discovery.md"
}

# ─── 11. Output messages ─────────────────────────────────────────

@test "TC-56: prints completion message" {
  local out
  out=$(install_with_input "1")
  echo "$out" | grep -q "완료"
}

@test "TC-57: prints library path in output" {
  local out
  out=$(install_with_input "1")
  echo "$out" | grep -q ".claude-library"
}

@test "TC-58: exits with 0 on success" {
  install_with_input "1"
  [ "$?" -eq 0 ]
}

# ─── 12. library-save-check.sh behavior ─────────────────────────

@test "TC-59: save-check honors stop_hook_active re-entry guard" {
  install_with_input "1" > /dev/null 2>&1 || true
  local hook="$CLAUDE_DIR/hooks/library-save-check.sh"
  # `|| skip` 은 훅이 아예 설치 안 되는 회귀를 초록불로 만든다. 실패시킨다.
  if [ ! -f "$hook" ]; then
    echo "hook not installed: $hook" >&2
    return 1
  fi
  local cdir="$CLAUDE_DIR/hooks/.counters"
  mkdir -p "$cdir"
  # 스로틀이 삼키지 않도록 카운터를 임계 직전으로 맞춘다.
  # 그래야 이 테스트가 "가드"만을 검증한다 (가드를 지우면 빨간불이 된다).
  echo 19 > "$cdir/.library-check-counter-guard_sess"
  local out
  out=$(echo '{"stop_hook_active": true, "session_id": "guard_sess"}' | bash "$hook")
  [ -z "$out" ]
  # 가드가 작동했으면 카운터는 증가하지 않는다 (조기 exit)
  [ "$(cat "$cdir/.library-check-counter-guard_sess")" = "19" ]
}

@test "TC-60: save-check throttles per session via counter file" {
  install_with_input "1" > /dev/null 2>&1 || true
  local hook="$CLAUDE_DIR/hooks/library-save-check.sh"
  # `|| skip` 은 훅이 아예 설치 안 되는 회귀를 초록불로 만든다. 실패시킨다.
  if [ ! -f "$hook" ]; then
    echo "hook not installed: $hook" >&2
    return 1
  fi
  local input='{"stop_hook_active": false, "session_id": "throttle_xyz"}'
  # transcript_path 가 없으면 조용히 통과하는 게 정상 (백그라운드 리뷰 위임 방식)
  local out
  out=$(echo "$input" | bash "$hook")
  [ -z "$out" ]
  # 카운터가 세션별로 증가한다
  local cf="$CLAUDE_DIR/hooks/.counters/.library-check-counter-throttle_xyz"
  [ -f "$cf" ]
  [ "$(cat "$cf")" = "1" ]
  echo "$input" | bash "$hook" >/dev/null
  [ "$(cat "$cf")" = "2" ]
}

@test "TC-61: save-check counter lives under .counters/ and increments" {
  install_with_input "1" > /dev/null 2>&1 || true
  local hook="$CLAUDE_DIR/hooks/library-save-check.sh"
  # `|| skip` 은 훅이 아예 설치 안 되는 회귀를 초록불로 만든다. 실패시킨다.
  if [ ! -f "$hook" ]; then
    echo "hook not installed: $hook" >&2
    return 1
  fi
  local cdir="$CLAUDE_DIR/hooks/.counters"
  local cf="$cdir/.library-check-counter-sess_mid"
  rm -rf "$cdir"
  echo '{"stop_hook_active": false, "session_id": "sess_mid"}' | bash "$hook" >/dev/null
  # 훅 디렉터리가 없어도 mkdir -p 로 만들어야 한다
  [ -f "$cf" ]
  [ "$(cat "$cf")" = "1" ]
  # 옛 위치에는 만들지 않는다
  [ ! -f "$CLAUDE_DIR/hooks/.library-check-counter-sess_mid" ]
}

# ─── 13. library-sync.sh behavior ────────────────────────────────

@test "TC-62: library-sync.sh exits 0 when LIBRARY.md missing" {
  install_with_input "1"
  rm -f "$LIB_DIR/LIBRARY.md"
  bash "$CLAUDE_DIR/hooks/library-sync.sh" 2>&1
  [ "$?" -eq 0 ]
}

@test "TC-63: library-sync.sh cleans up counter files on run" {
  install_with_input "1"
  touch "$CLAUDE_DIR/hooks/.library-check-counter-sess1"
  touch "$CLAUDE_DIR/hooks/.library-check-counter-sess2"
  bash "$CLAUDE_DIR/hooks/library-sync.sh" 2>&1
  ! ls "$CLAUDE_DIR/hooks/.library-check-counter-"* 2>/dev/null
}

# ─── library-allow 권한 판정 (6회차 보안 수정 — 지금까지 커버리지 0) ───

@test "TC-64: library-allow allows paths inside the library" {
  install_with_input "1" > /dev/null 2>&1 || true
  local hook="$CLAUDE_DIR/hooks/library-allow.sh"
  # `|| skip` 은 훅이 아예 설치 안 되는 회귀를 초록불로 만든다. 실패시킨다.
  if [ ! -f "$hook" ]; then
    echo "hook not installed: $hook" >&2
    return 1
  fi
  local out
  out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/claude-library/library/a.md"}}' "$TEST_HOME" \
        | HOME="$TEST_HOME" bash "$hook")
  echo "$out" | grep -q '"permissionDecision": *"allow"'
}

@test "TC-65: library-allow refuses traversal out of the library" {
  install_with_input "1" > /dev/null 2>&1 || true
  local hook="$CLAUDE_DIR/hooks/library-allow.sh"
  # `|| skip` 은 훅이 아예 설치 안 되는 회귀를 초록불로 만든다. 실패시킨다.
  if [ ! -f "$hook" ]; then
    echo "hook not installed: $hook" >&2
    return 1
  fi
  local p out
  for p in "$TEST_HOME/claude-library/../.claude/settings.json" \
           "$TEST_HOME/claude-library/../../../../etc/passwd" \
           "$TEST_HOME/claude-library-evil/x.md" \
           "/etc/passwd"; do
    out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$p" | HOME="$TEST_HOME" bash "$hook")
    if [ -n "$out" ]; then
      echo "permission bypass for: $p -> $out" >&2
      return 1
    fi
  done
}

@test "TC-66: library-allow ignores non-edit tools" {
  install_with_input "1" > /dev/null 2>&1 || true
  local hook="$CLAUDE_DIR/hooks/library-allow.sh"
  # `|| skip` 은 훅이 아예 설치 안 되는 회귀를 초록불로 만든다. 실패시킨다.
  if [ ! -f "$hook" ]; then
    echo "hook not installed: $hook" >&2
    return 1
  fi
  local out
  out=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s/claude-library/library/a.md"}}' "$TEST_HOME" \
        | HOME="$TEST_HOME" bash "$hook")
  [ -z "$out" ]
}

# ─── 깨진 settings.json 방어 (5회차 수정 — 커버리지 0) ───

@test "TC-67: install aborts when settings.json is not valid JSON" {
  echo '{ this is not valid json' > "$SETTINGS"
  local out status
  out=$(install_with_input "1") || status=$?
  [ "${status:-0}" -ne 0 ]
  echo "$out" | grep -q "유효한 JSON"
  # 아무것도 설치하지 않아야 한다
  [ ! -f "$CLAUDE_DIR/hooks/library-sync.sh" ]
  grep -q "this is not valid json" "$SETTINGS"
}

# ─── permissions 등록 (커버리지 0) ───

@test "TC-68: install registers claude-library write permissions" {
  install_with_input "1" > /dev/null 2>&1 || true
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
allow = d.get('permissions', {}).get('allow', [])
assert any('claude-library' in a for a in allow), allow
"
}

# ─── PreToolUse / PostToolUse 등록 (지금까지 어느 케이스도 검증 안 함) ───

@test "TC-69: registers library-allow.sh as a PreToolUse hook" {
  install_with_input "1" > /dev/null 2>&1 || true
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
cmds = [h['command'] for m in d.get('hooks', {}).get('PreToolUse', []) for h in m.get('hooks', [])]
assert any('library-allow.sh' in c for c in cmds), cmds
"
}

@test "TC-70: registers library-activity-log.sh as a PostToolUse hook with edit matcher" {
  install_with_input "1" > /dev/null 2>&1 || true
  python3 -c "
import json
d = json.load(open('$SETTINGS'))
found = False
for m in d.get('hooks', {}).get('PostToolUse', []):
    for h in m.get('hooks', []):
        if 'library-activity-log.sh' in h['command']:
            found = True
            assert 'Write' in m.get('matcher', ''), m
assert found, d.get('hooks', {}).get('PostToolUse')
"
}

@test "TC-71: no duplicate PreToolUse/PostToolUse registration on reinstall" {
  install_with_input "1" > /dev/null 2>&1 || true
  install_with_input "1" > /dev/null 2>&1 || true
  python3 -c "
import json, collections
d = json.load(open('$SETTINGS'))
for ev in ('PreToolUse', 'PostToolUse'):
    c = collections.Counter(h['command'] for m in d.get('hooks', {}).get(ev, []) for h in m.get('hooks', []))
    dupes = [k for k, n in c.items() if n > 1]
    assert not dupes, (ev, dupes)
"
}

# ─── 브랜치 추적과 자동 주입 설치 ───

@test "TC-73: install persists branch and main removes it" {
  install_with_input 1 --branch feat/test
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-branch")" = feat/test ]
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = "git+https://github.com/kangraemin/learnings-for-claude@feat/test#subdirectory=mcp-server" ]
  install_with_input 1 --branch main
  grep -qx 'claude-library-mcp==[0-9][0-9A-Za-z.+-]*' "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-branch" ]
}

@test "TC-74: all entrypoints reject invalid and missing branches" {
  local script branch
  for script in install.sh update.sh scripts/update-check.sh; do
    for branch in 'a..b' 'a b' 'a;b' ''; do
      run bash "$SOURCE_DIR/$script" --branch "$branch"
      [ "$status" -eq 1 ]
      [ ! -e "$CLAUDE_DIR/hooks/.learnings-branch" ]
    done
    run bash "$SOURCE_DIR/$script" --branch
    [ "$status" -eq 1 ]
  done
}

@test "TC-75: update switches MCP source and restores PyPI preserving settings" {
  install_with_input 1
  jq '.custom = {keep: true} | .mcpServers.other = {command:"other"} | .mcpServers["claude-library"].env.EXTRA = "keep"' "$SETTINGS" > "$SETTINGS.new"
  mv "$SETTINGS.new" "$SETTINGS"
  bash "$SOURCE_DIR/update.sh" --branch feat/test
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-branch")" = feat/test ]
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = "git+https://github.com/kangraemin/learnings-for-claude@feat/test#subdirectory=mcp-server" ]
  jq -e '.mcpServers["claude-library"].args == ["--with","mcp<2","--from","git+https://github.com/kangraemin/learnings-for-claude@feat/test#subdirectory=mcp-server","claude-library-mcp"]' "$SETTINGS"
  [ -f "$SETTINGS.bak" ]
  jq -e ' .custom.keep and .mcpServers.other.command == "other"' "$SETTINGS.bak"
  grep -q '^feat/test@' "$CLAUDE_DIR/hooks/.learnings-version"
  bash "$SOURCE_DIR/update.sh" --branch main
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-branch" ]
  grep -qx 'claude-library-mcp==[0-9][0-9A-Za-z.+-]*' "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  jq -e '.custom.keep and .mcpServers.other.command == "other" and .mcpServers["claude-library"].env.EXTRA == "keep" and .mcpServers["claude-library"].args == ["--with","mcp<2","claude-library-mcp@latest"]' "$SETTINGS"
}

@test "TC-76: env branch overrides stored branch in install update and checker" {
  export LEARNINGS_BRANCH=feat/env
  install_with_input 1 --branch feat/file
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-branch")" = feat/file ]
  jq -e '.mcpServers["claude-library"].args[3] | contains("@feat/env#")' "$SETTINGS"
  bash "$SOURCE_DIR/update.sh"
  grep -q '^feat/env@' "$CLAUDE_DIR/hooks/.learnings-version"
  bash "$SOURCE_DIR/scripts/update-check.sh" --check-only
  grep -q '/commits/feat/env' "$CURL_LOG"
}

@test "TC-77: checker persists branch uses branch URL and resets main" {
  touch "$CLAUDE_DIR/hooks/library-sync.sh"
  run bash "$SOURCE_DIR/scripts/update-check.sh" --branch feat/api --check-only
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-branch")" = feat/api ]
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = "git+https://github.com/kangraemin/learnings-for-claude@feat/api#subdirectory=mcp-server" ]
  grep -q '/commits/feat/api' "$CURL_LOG"
  jq -e '.mcpServers["claude-library"].args[3] | contains("@feat/api#")' "$SETTINGS"
  run bash "$SOURCE_DIR/scripts/update-check.sh" --branch main --check-only
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-branch" ]
  grep -qx 'claude-library-mcp==[0-9][0-9A-Za-z.+-]*' "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  grep -q '/commits/main' "$CURL_LOG"
  jq -e '.mcpServers["claude-library"].args == ["--with","mcp<2","claude-library-mcp@latest"]' "$SETTINGS"
}

@test "TC-78: checker reads legacy and branch versions without cross-branch equality" {
  touch "$CLAUDE_DIR/hooks/library-sync.sh"
  local version
  for version in abcdef1 main@abcdef1; do
    echo "$version" > "$CLAUDE_DIR/hooks/.learnings-version"
    run bash "$SOURCE_DIR/scripts/update-check.sh" --check-only
    [ "$status" -eq 0 ]
    [[ "$output" == *'status: up-to-date'* ]]
    run bash "$SOURCE_DIR/scripts/update-check.sh" --branch feat/test --check-only
    [[ "$output" == *'status: update-available'* ]]
    rm "$CLAUDE_DIR/hooks/.learnings-branch"
  done
  echo feat/test@abcdef1 > "$CLAUDE_DIR/hooks/.learnings-version"
  run bash "$SOURCE_DIR/scripts/update-check.sh" --branch feat/test --check-only
  [[ "$output" == *'status: up-to-date'* ]]
}

@test "TC-79: autoinject installs once with timeout 5 and uninstall preserves other hooks" {
  export LIBRARY_AUTOINJECT=1
  install_with_input 1
  install_with_input 1
  bash "$SOURCE_DIR/update.sh"
  bash "$SOURCE_DIR/update.sh"
  [ -x "$CLAUDE_DIR/hooks/library-autoinject.sh" ]
  jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("/library-autoinject.sh"))] | length == 1 and .[0].timeout == 5' "$SETTINGS"
  jq '.hooks.UserPromptSubmit[0].hooks += [{type:"command",command:"keep-me",timeout:2}]' "$SETTINGS" > "$SETTINGS.new"
  mv "$SETTINGS.new" "$SETTINGS"
  sed 's|</dev/tty||g' "$SOURCE_DIR/uninstall.sh" > "$TEST_HOME/uninstall.sh"
  bash "$TEST_HOME/uninstall.sh" "$TEST_HOME" <<< n
  [ ! -e "$CLAUDE_DIR/hooks/library-autoinject.sh" ]
  jq -e '[.hooks.UserPromptSubmit[].hooks[].command] == ["keep-me"]' "$SETTINGS"
}

@test "TC-80: checker clones selected branch only on explicit force or auto update" {
  touch "$CLAUDE_DIR/hooks/library-sync.sh"
  cat > "$TEST_HOME/bin/git" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/git.log"
[ "$1" = clone ] || exit 1
mkdir -p "$7"
printf '#!/bin/bash\nprintf "%%s\n" "$LEARNINGS_BRANCH" > "$HOME/applied"\n' > "$7/update.sh"
STUB
  chmod +x "$TEST_HOME/bin/git"
  run bash "$SOURCE_DIR/scripts/update-check.sh" --branch feat/clone
  [ "$status" -eq 0 ]
  [[ "$output" == *'새 버전 있음'* ]]
  [ ! -e "$HOME/git.log" ]
  run bash "$SOURCE_DIR/scripts/update-check.sh" --branch feat/clone --force
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/applied")" = feat/clone ]
  grep -q 'clone --depth 1 -b feat/clone' "$HOME/git.log"
  rm "$HOME/applied"
  LEARNINGS_AUTO_UPDATE=1 run bash "$SOURCE_DIR/scripts/update-check.sh" --branch feat/clone
  [ "$status" -eq 0 ]
  [ -f "$HOME/applied" ]
}

@test "TC-81: update bootstrap clones selected branch" {
  install_with_input 1
  cp "$SOURCE_DIR/update.sh" "$TEST_HOME/standalone-update.sh"
  cat > "$TEST_HOME/bin/git" <<'STUB'
#!/bin/bash
if [ "$1" = clone ]; then
  printf '%s\n' "$*" > "$HOME/git.log"
  printf '%s\n' "$7" > "$HOME/clone-path"
  cp -R "$SOURCE_DIR" "$7"
else
  echo abcdef1
fi
STUB
  chmod +x "$TEST_HOME/bin/git"
  run bash "$TEST_HOME/standalone-update.sh" --branch feat/bootstrap
  [ "$status" -eq 0 ]
  grep -q 'clone --depth 1 -b feat/bootstrap' "$HOME/git.log"
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-version")" = feat/bootstrap@abcdef1 ]
  [ ! -d "$(cat "$HOME/clone-path")" ]
}

@test "TC-82: checker throttle follows env branch and accepts legacy timestamps" {
  touch "$CLAUDE_DIR/hooks/library-sync.sh"
  date +%s > "$CLAUDE_DIR/hooks/.learnings-version-checked"
  run bash "$SOURCE_DIR/scripts/update-check.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CURL_LOG" ]
  LEARNINGS_BRANCH=feat/env run bash "$SOURCE_DIR/scripts/update-check.sh"
  [ "$status" -eq 0 ]
  grep -q '/commits/feat/env' "$CURL_LOG"
  grep -q '^feat/env@' "$CLAUDE_DIR/hooks/.learnings-version-checked"
  rm "$CURL_LOG"
  LEARNINGS_BRANCH=feat/env run bash "$SOURCE_DIR/scripts/update-check.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CURL_LOG" ]
  run bash "$SOURCE_DIR/scripts/update-check.sh"
  [ "$status" -eq 0 ]
  grep -q '/commits/main' "$CURL_LOG"
}

@test "TC-83: checker compares full and longer abbreviated SHA versions" {
  touch "$CLAUDE_DIR/hooks/library-sync.sh"
  local version
  for version in abcdef123456789 main@abcdef123456789 main@abcdef1234; do
    echo "$version" > "$CLAUDE_DIR/hooks/.learnings-version"
    run bash "$SOURCE_DIR/scripts/update-check.sh" --check-only
    [ "$status" -eq 0 ]
    [[ "$output" == *'status: up-to-date'* ]]
  done
}

@test "TC-84: installed checker is the source script and uninstall removes tracking files" {
  install_with_input 1 --branch feat/test
  cmp "$SOURCE_DIR/scripts/update-check.sh" "$CLAUDE_DIR/hooks/learnings-update-check.sh"
  touch "$CLAUDE_DIR/hooks/.learnings-version-checked"
  sed 's|</dev/tty||g' "$SOURCE_DIR/uninstall.sh" > "$TEST_HOME/uninstall.sh"
  bash "$TEST_HOME/uninstall.sh" "$TEST_HOME" <<< n
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-branch" ]
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-version" ]
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-version-checked" ]
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-kb-spec" ]
}

# Isolated PATH guarantees fallback tests cannot accidentally use a real CLI.
setup_kb_path() {
  export KB_ARGV="$TEST_HOME/argv.json"
  export PATH="$TEST_HOME/kb-bin"
  /bin/mkdir -p "$PATH"
  /bin/ln -s /bin/bash "$PATH/bash"
  /bin/ln -s /bin/sleep "$PATH/sleep"
  /bin/ln -s "$KB_PYTHON" "$PATH/python3"
  /bin/cat > "$PATH/uvx" <<'STUB'
#!/bin/bash
python3 -c 'import json,os,sys; json.dump(sys.argv[1:],open(os.environ["KB_ARGV"],"w"))' "$@"
if [ "${KB_SLEEP:-0}" = 1 ]; then sleep 10; fi
[ "${KB_FAIL:-0}" = 1 ] && exit 1
printf '검색 결과: 룩어헤드 누수\n'
STUB
  /bin/chmod +x "$PATH/uvx"
}

@test "TC-85: uvx fallback receives exact spec argv and returns hook JSON" {
  export KB_PYTHON="$(command -v python3)"
  setup_kb_path
  local spec='git+https://github.com/kangraemin/learnings-for-claude@feat/test#subdirectory=mcp-server'
  printf '%s\n' "$spec" > "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  run bash "$SOURCE_DIR/hooks/library-autoinject.sh" <<< '{"prompt":"백테스트 룩어헤드 누수 어떻게 잡지"}'
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys; assert json.loads(sys.argv[1]) == {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"검색 결과: 룩어헤드 누수"}}' "$output"
  python3 -c 'import json,os,sys; assert json.load(open(os.environ["KB_ARGV"])) == ["--with","mcp<2","--from",sys.argv[1],"claude-library-kb","search","--format","inject","--budget","1500","--","백테스트 룩어헤드 누수 어떻게 잡지"]' "$spec"
  export PATH="$ORIG_TEST_PATH"
}

@test "TC-86: short slash and disabled prompts never invoke uvx" {
  export KB_PYTHON="$(command -v python3)"
  setup_kb_path
  echo claude-library-mcp > "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  local payload
  for payload in '{"prompt":"짧음"}' '{"prompt":"  /library search something"}'; do
    run bash "$SOURCE_DIR/hooks/library-autoinject.sh" <<< "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$KB_ARGV" ]
  done
  LIBRARY_AUTOINJECT=0 run bash "$SOURCE_DIR/hooks/library-autoinject.sh" <<< '{"prompt":"백테스트 룩어헤드 누수 어떻게 잡지"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$KB_ARGV" ]
  export PATH="$ORIG_TEST_PATH"
}

@test "TC-87: sleeping uvx exits silently in five seconds and failure is silent" {
  export KB_PYTHON="$(command -v python3)"
  setup_kb_path
  echo claude-library-mcp > "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  KB_SLEEP=1 python3 - "$SOURCE_DIR/hooks/library-autoinject.sh" <<'PY'
import subprocess,sys,time
start=time.monotonic()
p=subprocess.run(["bash",sys.argv[1]],input='{"prompt":"백테스트 룩어헤드 누수 어떻게 잡지"}',capture_output=True,text=True,timeout=8)
elapsed=time.monotonic()-start
assert p.returncode == 0 and not p.stdout and not p.stderr, p
assert 5 <= elapsed < 7, elapsed
PY
  KB_FAIL=1 run bash "$SOURCE_DIR/hooks/library-autoinject.sh" <<< '{"prompt":"백테스트 룩어헤드 누수 어떻게 잡지"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  export PATH="$ORIG_TEST_PATH"
}

@test "TC-88: override precedes PATH CLI which precedes uvx" {
  export KB_PYTHON="$(command -v python3)"
  setup_kb_path
  /bin/cp "$PATH/uvx" "$PATH/claude-library-kb"
  # No spec file: PATH CLI must still work.
  run bash "$SOURCE_DIR/hooks/library-autoinject.sh" <<< '{"prompt":"백테스트 룩어헤드 누수 어떻게 잡지"}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  python3 -c 'import json,os; assert json.load(open(os.environ["KB_ARGV"]))[0] == "search"'
  LIBRARY_KB_CMD='uvx --custom "argument with spaces"' run bash "$SOURCE_DIR/hooks/library-autoinject.sh" <<< '{"prompt":"백테스트 룩어헤드 누수 어떻게 잡지"}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  python3 -c 'import json,os; assert json.load(open(os.environ["KB_ARGV"]))[:3] == ["--custom","argument with spaces","search"]'
  export PATH="$ORIG_TEST_PATH"
}

# 사용자 목차와 자체 하위 규칙을 포함한 실제 구조의 축소 픽스처.
legacy_rules_fixture() {
  python3 - "$CLAUDE_DIR/CLAUDE.md" <<'PY'
import sys
from pathlib import Path
s = '# Global Rules\n사용자 규칙\n\n## Library 시스템\n\n참조: GUIDE.md\n\n### 목차\n'
s += ''.join(f'- finance/topic-{i}/ — 사용자 지식 {i}\n' for i in range(20))
s += '\n### 읽기\n사용자 검색 규칙\n### 쓰기\n사용자 저장 규칙\n'
s += '### 지식이냐 결정사항이냐\n사용자 분류\n### 형식 — OKF v0.2\ntype 필수\n'
s += '\n# --- ai-bouncer-rule start ---\n기존 규칙 보존\n# --- ai-bouncer-rule end ---\n'
Path(sys.argv[1]).write_bytes(s.replace('\n', '\r\n').encode())
PY
}

@test "TC-89: update preserves legacy user rules byte for byte and offers new template" {
  install_with_input 1
  legacy_rules_fixture
  cp "$CLAUDE_DIR/CLAUDE.md" "$TEST_HOME/before"
  bash "$SOURCE_DIR/update.sh"
  cmp "$TEST_HOME/before" "$CLAUDE_DIR/CLAUDE.md"
  cmp "$SOURCE_DIR/templates/claude-rules.md" "$CLAUDE_DIR/CLAUDE.md.library-rules.new"
  bash "$SOURCE_DIR/update.sh"
  cmp "$TEST_HOME/before" "$CLAUDE_DIR/CLAUDE.md"
}

@test "TC-90: marked update changes only managed block and backs up original" {
  install_with_input 1
  legacy_rules_fixture
  python3 - "$CLAUDE_DIR/CLAUDE.md" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_bytes()
s = s.replace('참조: GUIDE.md'.encode(), b'<!-- learnings-for-claude:rules start -->\r\nOLD_RULES\r\n<!-- learnings-for-claude:rules end -->')
p.write_bytes(s)
PY
  cp "$CLAUDE_DIR/CLAUDE.md" "$TEST_HOME/before"
  bash "$SOURCE_DIR/update.sh"
  cmp "$TEST_HOME/before" "$CLAUDE_DIR/CLAUDE.md.bak"
  python3 - "$TEST_HOME/before" "$CLAUDE_DIR/CLAUDE.md" "$SOURCE_DIR/templates/claude-rules.md" <<'PY'
import sys
from pathlib import Path
before, after, template = [Path(p).read_bytes() for p in sys.argv[1:]]
a, b = b'<!-- learnings-for-claude:rules start -->', b'<!-- learnings-for-claude:rules end -->'
assert before.split(a)[0] == after.split(a)[0]
assert before.split(b)[1] == after.split(b)[1]
assert after.split(a)[1].split(b)[0] == template.split(a)[1].split(b)[0]
PY
}

@test "TC-91: marked update is byte idempotent including backup" {
  install_with_input 1
  sed 's/### 읽기/### OLD 읽기/' "$CLAUDE_DIR/CLAUDE.md" > "$TEST_HOME/old"
  mv "$TEST_HOME/old" "$CLAUDE_DIR/CLAUDE.md"
  bash "$SOURCE_DIR/update.sh"
  cp "$CLAUDE_DIR/CLAUDE.md" "$TEST_HOME/once"
  cp "$CLAUDE_DIR/CLAUDE.md.bak" "$TEST_HOME/backup"
  bash "$SOURCE_DIR/update.sh"
  cmp "$TEST_HOME/once" "$CLAUDE_DIR/CLAUDE.md"
  cmp "$TEST_HOME/backup" "$CLAUDE_DIR/CLAUDE.md.bak"
}

@test "TC-92: missing reversed and duplicate markers warn without changing rules" {
  install_with_input 1
  local markers
  for markers in start end 'end start' 'start start end' 'start end end'; do
    printf '# User\n' > "$CLAUDE_DIR/CLAUDE.md"
    for marker in $markers; do
      printf '<!-- learnings-for-claude:rules %s -->\n' "$marker" >> "$CLAUDE_DIR/CLAUDE.md"
    done
    cp "$CLAUDE_DIR/CLAUDE.md" "$TEST_HOME/before"
    run bash "$SOURCE_DIR/update.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'경고: CLAUDE.md 관리 마커'* ]]
    cmp "$TEST_HOME/before" "$CLAUDE_DIR/CLAUDE.md"
    install_with_input 1
    cmp "$TEST_HOME/before" "$CLAUDE_DIR/CLAUDE.md"
  done
}

@test "TC-93: fresh install puts table of contents outside exactly one managed block" {
  install_with_input 1
  python3 - "$CLAUDE_DIR/CLAUDE.md" <<'PY'
import sys
from pathlib import Path
s = Path(sys.argv[1]).read_text()
a, b = '<!-- learnings-for-claude:rules start -->', '<!-- learnings-for-claude:rules end -->'
assert s.count(a) == s.count(b) == 1
assert s.index(a) < s.index('### 읽기') < s.index(b)
assert not (s.index(a) < s.index('### 목차') < s.index(b))  # 목차는 사용자 소유 — 관리 블록 밖
PY
}

# 두 등록 위치의 나머지 필드와 큰 projects 객체를 비교한다.
mcp_user_fixture() {
  python3 - "$HOME/.claude.json" <<'PY'
import json, sys
cfg = {'mcpServers': {'claude-library': {'type': 'stdio', 'command': 'uvx', 'args': ['old'], 'env': {'EXTRA': 'keep', 'LIBRARY_ROOT': '/custom'}}, 'other': {'command': 'keep'}}, 'projects': {f'/project/{i}': {'history': ['사용자 데이터'] * 20, 'mcpServers': {'claude-library': {'args': ['local']}}} for i in range(200)}, 'custom': True}
with open(sys.argv[1], 'w') as f:
    json.dump(cfg, f)
PY
  cp "$HOME/.claude.json" "$TEST_HOME/user-before"
}

assert_mcp_preserved() {
  python3 - "$TEST_HOME/user-before" "$HOME/.claude.json" <<'PY'
import json, sys
before, after = [json.load(open(p)) for p in sys.argv[1:]]
assert after['mcpServers']['claude-library']['alwaysLoad'] is True
before['mcpServers']['claude-library']['alwaysLoad'] = True
for cfg in (before, after):
    cfg['mcpServers']['claude-library'].pop('args')
assert before == after
PY
}

@test "TC-94: all entrypoints switch and restore both MCP files preserving user objects" {
  install_with_input 1
  mcp_user_fixture
  local entry branch
  for entry in install update checker; do
    for branch in feat/dual main; do
      case "$entry" in
        install) install_with_input 1 --branch "$branch" ;;
        update) bash "$SOURCE_DIR/update.sh" --branch "$branch" ;;
        checker) bash "$CLAUDE_DIR/hooks/learnings-update-check.sh" --branch "$branch" --check-only ;;
      esac
      jq -s -e '.[0].mcpServers["claude-library"].args == .[1].mcpServers["claude-library"].args' "$SETTINGS" "$HOME/.claude.json"
      if [ "$branch" = main ]; then
        jq -e '.mcpServers["claude-library"].args == ["--with","mcp<2","claude-library-mcp@latest"]' "$HOME/.claude.json"
      else
        jq -e '.mcpServers["claude-library"].args == ["--with","mcp<2","--from","git+https://github.com/kangraemin/learnings-for-claude@feat/dual#subdirectory=mcp-server","claude-library-mcp"]' "$HOME/.claude.json"
      fi
      assert_mcp_preserved
      [ -f "$HOME/.claude.json.bak" ]
    done
  done
}

@test "TC-95: all entrypoints handle user-only MCP without creating duplicate registration" {
  install_with_input 1
  mcp_user_fixture
  jq 'del(.mcpServers["claude-library"])' "$SETTINGS" > "$SETTINGS.new"
  mv "$SETTINGS.new" "$SETTINGS"
  local entry branch
  for entry in install update checker; do
    for branch in feat/only main; do
      case "$entry" in
        install) install_with_input 1 --branch "$branch" ;;
        update) bash "$SOURCE_DIR/update.sh" --branch "$branch" ;;
        checker) bash "$SOURCE_DIR/scripts/update-check.sh" --branch "$branch" --check-only ;;
      esac
      jq -e '.mcpServers | has("claude-library") | not' "$SETTINGS"
      if [ "$branch" = main ]; then
        jq -e '.mcpServers["claude-library"].args[-1] == "claude-library-mcp@latest"' "$HOME/.claude.json"
      else
        jq -e '.mcpServers["claude-library"].args[3] | contains("@feat/only#")' "$HOME/.claude.json"
      fi
      assert_mcp_preserved
    done
  done
}

@test "TC-96: broken user JSON remains byte identical for every entrypoint" {
  install_with_input 1
  printf '{"projects": broken\n' > "$HOME/.claude.json"
  cp "$HOME/.claude.json" "$TEST_HOME/broken"
  local entry
  for entry in install update checker; do
    case "$entry" in
      install) run install_with_input 1 --branch feat/broken ;;
      update) run bash "$SOURCE_DIR/update.sh" --branch feat/broken ;;
      checker) run bash "$SOURCE_DIR/scripts/update-check.sh" --branch feat/broken --check-only ;;
    esac
    [ "$status" -ne 0 ]
    cmp "$TEST_HOME/broken" "$HOME/.claude.json"
    [ ! -e "$HOME/.claude.json.bak" ]
  done
}

@test "TC-97: uninstall removes managed block but preserves user table and trailing rules" {
  install_with_input 1
  printf '\n- topic: 사용자 지식\n# --- ai-bouncer-rule start ---\n유지\n' >> "$CLAUDE_DIR/CLAUDE.md"
  cp "$CLAUDE_DIR/CLAUDE.md" "$TEST_HOME/before"
  sed 's|</dev/tty||g' "$SOURCE_DIR/uninstall.sh" > "$TEST_HOME/uninstall.sh"
  bash "$TEST_HOME/uninstall.sh" "$TEST_HOME" <<< n
  python3 - "$TEST_HOME/before" "$CLAUDE_DIR/CLAUDE.md" <<'PY'
import sys
from pathlib import Path
before, after = [Path(p).read_bytes() for p in sys.argv[1:]]
a, b = b'<!-- learnings-for-claude:rules start -->', b'<!-- learnings-for-claude:rules end -->'
assert after == before.split(a)[0] + before.split(b)[1]
PY
}

@test "TC-98: shared MCP updater rejects broken settings JSON without modifying either file" {
  mcp_user_fixture
  printf '{broken\n' > "$SETTINGS"
  cp "$SETTINGS" "$TEST_HOME/broken"
  run bash -c 'source "$SOURCE_DIR/scripts/update-check.sh"; update_library_mcp feat/test test-spec'
  [ "$status" -ne 0 ]
  cmp "$TEST_HOME/broken" "$SETTINGS"
  cmp "$TEST_HOME/user-before" "$HOME/.claude.json"
}

@test "TC-99: install excludes raw search logs without duplicate entries" {
  install_with_input 1
  install_with_input 1
  [ "$(grep -xcF '.activity/search-*.jsonl' "$LIB_DIR/.gitignore")" -eq 1 ]
  git -C "$LIB_DIR" init -q
  git -C "$LIB_DIR" check-ignore .activity/search-session.jsonl
}

@test "TC-100: update supplements existing gitignore and preserves tracked log" {
  install_with_input 1
  printf 'custom/' > "$LIB_DIR/.gitignore"
  mkdir -p "$LIB_DIR/.activity"
  echo private > "$LIB_DIR/.activity/search-old.jsonl"
  git -C "$LIB_DIR" init -q
  git -C "$LIB_DIR" add .activity/search-old.jsonl
  bash "$SOURCE_DIR/update.sh"
  bash "$SOURCE_DIR/update.sh"
  [ "$(grep -xcF '.activity/search-*.jsonl' "$LIB_DIR/.gitignore")" -eq 1 ]
  grep -qxF 'custom/' "$LIB_DIR/.gitignore"
  [ "$(git -C "$LIB_DIR" ls-files .activity/search-old.jsonl)" = '.activity/search-old.jsonl' ]
  [ "$(cat "$LIB_DIR/.activity/search-old.jsonl")" = private ]
}

@test "TC-101: install and update register PreCompact once and preserve unrelated hooks" {
  echo '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"custom-hook"}]}]}}' > "$SETTINGS"
  install_with_input 1
  install_with_input 1
  bash "$SOURCE_DIR/update.sh"
  bash "$SOURCE_DIR/update.sh"
  [ "$(jq '[.hooks.PreCompact[].hooks[] | select(.command | endswith("library-save-check.sh"))] | length' "$SETTINGS")" -eq 1 ]
  jq -e '[.hooks.PreCompact[].hooks[].command] | index("custom-hook") != null' "$SETTINGS"
}

@test "TC-102: update adds PreCompact for existing installations" {
  install_with_input 1
  jq 'del(.hooks.PreCompact)' "$SETTINGS" > "$TEST_HOME/settings-new"
  mv "$TEST_HOME/settings-new" "$SETTINGS"
  bash "$SOURCE_DIR/update.sh"
  [ "$(jq '[.hooks.PreCompact[].hooks[]] | length' "$SETTINGS")" -eq 1 ]
}

# 훅 동작은 설치와 독립적으로 임시 HOME에서 실행한다.
compact_input() {
  jq -nc --arg event "$1" --arg path "$TEST_HOME/transcript.jsonl" \
    '{hook_event_name:$event, session_id:"compact-test", transcript_path:$path}'
}
compact_transcript() {
  printf '%s\n' '{"type":"user","message":{"content":"압축 전 교훈"}}' > "$TEST_HOME/transcript.jsonl"
}

@test "TC-103: PreCompact emits nothing and next Stop prioritizes preserved excerpt" {
  compact_transcript
  local out
  out=$(compact_input PreCompact | bash "$SOURCE_DIR/hooks/library-save-check.sh")
  [ -z "$out" ]
  [ ! -f "$CLAUDE_DIR/hooks/.counters/.library-check-counter-compact-test" ]
  rm "$TEST_HOME/transcript.jsonl"
  out=$(compact_input Stop | bash "$SOURCE_DIR/hooks/library-save-check.sh")
  [ "$(echo "$out" | jq -r .decision)" = block ]
  echo "$out" | jq -r .reason | grep -q 'run_in_background=true'
  grep -q '압축 전 교훈' "$CLAUDE_DIR"/hooks/.library-review-excerpt-compact-test-*
  [ ! -f "$CLAUDE_DIR/hooks/.library-review-pending-compact-test.txt" ]
  [ -z "$(compact_input Stop | bash "$SOURCE_DIR/hooks/library-save-check.sh")" ]
}

@test "TC-104: repeated PreCompact accumulates only incremental text" {
  compact_transcript
  compact_input PreCompact | bash "$SOURCE_DIR/hooks/library-save-check.sh"
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"새 교훈"},{"type":"tool_use","name":"secret-tool"}]}}' >> "$TEST_HOME/transcript.jsonl"
  compact_input PreCompact | bash "$SOURCE_DIR/hooks/library-save-check.sh"
  compact_input PreCompact | bash "$SOURCE_DIR/hooks/library-save-check.sh"
  local pending="$CLAUDE_DIR/hooks/.library-review-pending-compact-test.txt"
  [ "$(grep -c '압축 전 교훈' "$pending")" -eq 1 ]
  [ "$(grep -c '새 교훈' "$pending")" -eq 1 ]
  ! grep -q secret-tool "$pending"
}

@test "TC-105: pending excerpt survives Stop reentry guard and session isolation" {
  compact_transcript
  compact_input PreCompact | bash "$SOURCE_DIR/hooks/library-save-check.sh"
  [ -z "$(compact_input Stop | jq '.stop_hook_active=true' | bash "$SOURCE_DIR/hooks/library-save-check.sh")" ]
  [ -z "$(compact_input Stop | jq '.session_id="other-session"' | bash "$SOURCE_DIR/hooks/library-save-check.sh")" ]
  [ -s "$CLAUDE_DIR/hooks/.library-review-pending-compact-test.txt" ]
  compact_input Stop | bash "$SOURCE_DIR/hooks/library-save-check.sh" | jq -e '.decision == "block"'
}

@test "TC-106: empty and missing transcripts produce no pending review" {
  compact_input PreCompact | bash "$SOURCE_DIR/hooks/library-save-check.sh"
  printf '%s\n' '{"type":"system"}' 'invalid-json' > "$TEST_HOME/transcript.jsonl"
  compact_input PreCompact | bash "$SOURCE_DIR/hooks/library-save-check.sh"
  [ ! -e "$CLAUDE_DIR/hooks/.library-review-pending-compact-test.txt" ]
  [ -z "$(compact_input Stop | bash "$SOURCE_DIR/hooks/library-save-check.sh")" ]
}

@test "TC-107: ordinary twentieth Stop still extracts incremental text" {
  compact_transcript
  mkdir -p "$CLAUDE_DIR/hooks/.counters"
  echo 19 > "$CLAUDE_DIR/hooks/.counters/.library-check-counter-compact-test"
  compact_input Stop | bash "$SOURCE_DIR/hooks/library-save-check.sh" | jq -e '.decision == "block"'
  grep -q '압축 전 교훈' "$CLAUDE_DIR"/hooks/.library-review-excerpt-compact-test-*
  echo 39 > "$CLAUDE_DIR/hooks/.counters/.library-check-counter-compact-test"
  [ -z "$(compact_input Stop | bash "$SOURCE_DIR/hooks/library-save-check.sh")" ]
}

@test "TC-108: uninstall removes PreCompact registration and preserves custom hook" {
  install_with_input 1
  jq '.hooks.PreCompact += [{hooks:[{type:"command",command:"custom-hook"}]}]' "$SETTINGS" > "$TEST_HOME/settings-new"
  mv "$TEST_HOME/settings-new" "$SETTINGS"
  sed 's|</dev/tty||g' "$SOURCE_DIR/uninstall.sh" > "$TEST_HOME/uninstall.sh"
  bash "$TEST_HOME/uninstall.sh" "$TEST_HOME" <<< n
  [ "$(jq -r '.hooks.PreCompact[].hooks[].command' "$SETTINGS")" = custom-hook ]
  [ ! -f "$CLAUDE_DIR/hooks/library-save-check.sh" ]
}

# ─── 정책 변경 이력 ─────────────────────────────────────────────
policy_event() {
  printf '{"session_id":"policy-test","hook_event_name":"%s","stop_hook_active":true}\n' "$1" |
    bash "$SOURCE_DIR/hooks/policy-changelog-check.sh"
}
policy_fixture() {
  mkdir -p "$LIB_DIR" "$CLAUDE_DIR/rules"
  printf '# 규칙\n### 목차\n- old\n## 실제 정책\n기존 정책\n' > "$CLAUDE_DIR/CLAUDE.md"
  printf '# 가이드\n기존 정책\n' > "$LIB_DIR/GUIDE.md"
  policy_event SessionStart
}
policy_entry() {
  printf '\n## 변경 이력\n- 2026-10-05 · codex · 규칙 수정 · 이유: 테스트 · 근거: session:policy-test\n' >> "$1"
}

@test "TC-109: policy snapshot contains hashes original text and history counts" {
  policy_fixture
  jq -e --arg p "$CLAUDE_DIR/CLAUDE.md" '.files[$p] | (.sha256 | length == 64) and (.content | contains("### 목차")) and .count == 0' "$CLAUDE_DIR/hooks/.policy-snapshots/policy-test.json"
}

@test "TC-110: policy change without history blocks with actionable paths" {
  policy_fixture
  echo changed >> "$LIB_DIR/GUIDE.md"
  run policy_event Stop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg p "$LIB_DIR/GUIDE.md" '.decision == "block" and (.reason | contains($p)) and (.reason | contains("근거: session:"))'
}

@test "TC-111: appended history passes then a subsequent unlogged change blocks" {
  policy_fixture
  echo changed >> "$LIB_DIR/GUIDE.md"
  policy_entry "$LIB_DIR/GUIDE.md"
  [ -z "$(policy_event Stop)" ]
  echo another >> "$LIB_DIR/GUIDE.md"
  policy_event Stop | jq -e '.decision == "block"'
}

@test "TC-112: only CLAUDE table of contents changes are exempt" {
  policy_fixture
  sed 's/- old/- new/' "$CLAUDE_DIR/CLAUDE.md" > "$TEST_HOME/new"
  mv "$TEST_HOME/new" "$CLAUDE_DIR/CLAUDE.md"
  [ -z "$(policy_event Stop)" ]
  echo '실제 규칙 변경' >> "$CLAUDE_DIR/CLAUDE.md"
  policy_event Stop | jq -e '.decision == "block" and (.reason | contains("claude-md.md"))'
}

@test "TC-113: third Stop warns even with stop_hook_active true and history resets counter" {
  policy_fixture
  echo changed >> "$LIB_DIR/GUIDE.md"
  policy_event Stop | jq -e '.decision == "block"'
  policy_event Stop | jq -e '.decision == "block"'
  policy_event Stop | jq -e 'has("decision") | not'
  policy_entry "$LIB_DIR/GUIDE.md"
  [ -z "$(policy_event Stop)" ]
  echo new >> "$LIB_DIR/GUIDE.md"
  policy_event Stop | jq -e '.decision == "block"'
}

@test "TC-114: env off disables snapshot and Stop enforcement" {
  export POLICY_CHANGELOG_ENFORCE=0
  policy_fixture
  [ ! -f "$CLAUDE_DIR/hooks/.policy-snapshots/policy-test.json" ]
  [ -z "$(policy_event Stop)" ]
}

@test "TC-115: Stop without snapshot does nothing" {
  echo changed > "$CLAUDE_DIR/CLAUDE.md"
  [ -z "$(policy_event Stop)" ]
}

@test "TC-116: rules use sidecars and new decisions require inline history" {
  policy_fixture
  echo rule > "$CLAUDE_DIR/rules/custom.md"
  policy_event Stop | jq -e '.decision == "block" and (.reason | contains("rules-custom.md"))'
  mkdir -p "$LIB_DIR/decisions/_global/changelog"
  policy_entry "$LIB_DIR/decisions/_global/changelog/rules-custom.md"
  [ -z "$(policy_event Stop)" ]
  mkdir -p "$LIB_DIR/decisions/demo/process"
  echo decision > "$LIB_DIR/decisions/demo/process/test.md"
  policy_event Stop | jq -e '.decision == "block"'
  policy_entry "$LIB_DIR/decisions/demo/process/test.md"
  [ -z "$(policy_event Stop)" ]
}

@test "TC-117: repeated SessionStart preserves baseline and removes stale snapshots" {
  policy_fixture
  cp "$CLAUDE_DIR/hooks/.policy-snapshots/policy-test.json" "$CLAUDE_DIR/hooks/.policy-snapshots/stale.json"
  touch -t 200001010000 "$CLAUDE_DIR/hooks/.policy-snapshots/stale.json"
  echo changed >> "$LIB_DIR/GUIDE.md"
  policy_event SessionStart
  [ ! -f "$CLAUDE_DIR/hooks/.policy-snapshots/stale.json" ]
  policy_event Stop | jq -e '.decision == "block"'
}

@test "TC-118: install update register policy and async usage exactly once and uninstall removes them" {
  [ -f "$SOURCE_DIR/hooks/library-usage-log.sh" ] || printf '#!/bin/bash\nexit 0\n' > "$SOURCE_DIR/hooks/library-usage-log.sh"
  install_with_input 1 --profile maintainer
  install_with_input 1 --profile maintainer
  bash "$SOURCE_DIR/update.sh"
  bash "$SOURCE_DIR/update.sh"
  [ -x "$CLAUDE_DIR/hooks/policy-changelog-check.sh" ]
  [ -f "$CLAUDE_DIR/hooks/policy-changelog.py" ]
  [ -x "$CLAUDE_DIR/hooks/library-usage-log.sh" ]
  jq -e '
    ([.hooks.SessionStart[].hooks[] | select(.command | endswith("policy-changelog-check.sh"))] | length == 1) and
    ([.hooks.Stop[].hooks[] | select(.command | endswith("policy-changelog-check.sh"))] | length == 1) and
    ([.hooks.Stop[].hooks[] | select(.command | endswith("library-usage-log.sh"))] | length == 1 and .[0].async == true and .[0].timeout == 30)
  ' "$SETTINGS"
  sed 's|</dev/tty||g' "$SOURCE_DIR/uninstall.sh" > "$TEST_HOME/uninstall.sh"
  bash "$TEST_HOME/uninstall.sh" "$TEST_HOME" <<< n
  [ ! -e "$CLAUDE_DIR/hooks/policy-changelog-check.sh" ]
  [ ! -e "$CLAUDE_DIR/hooks/policy-changelog.py" ]
  [ ! -e "$CLAUDE_DIR/hooks/library-usage-log.sh" ]
  ! grep -qE 'policy-changelog|library-usage-log' "$SETTINGS"
}

@test "TC-119: update appends history only on actual managed policy changes and preserves old entries" {
  install_with_input 1
  cp "$LIB_DIR/GUIDE.md" "$LIB_DIR/GUIDE.md.orig"
  cp "$LIB_DIR/TAXONOMY.md" "$LIB_DIR/TAXONOMY.md.orig"
  echo '새 가이드 규칙' >> "$SOURCE_DIR/GUIDE.md"
  echo '새 분류 규칙' >> "$SOURCE_DIR/TAXONOMY.md"
  sed 's/<!-- learnings-for-claude:rules end -->/새 관리 규칙\n<!-- learnings-for-claude:rules end -->/' "$SOURCE_DIR/templates/claude-rules.md" > "$TEST_HOME/rules"
  mv "$TEST_HOME/rules" "$SOURCE_DIR/templates/claude-rules.md"
  LEARNINGS_PROFILE=maintainer bash "$SOURCE_DIR/update.sh"
  for doc in "$LIB_DIR/GUIDE.md" "$LIB_DIR/TAXONOMY.md" "$LIB_DIR/decisions/_global/changelog/claude-md.md"; do
    [ "$(grep -c '· process:update.sh ·' "$doc")" -eq 1 ]
    grep -q '이유: learnings-for-claude main@.* 템플릿 갱신' "$doc"
    cp "$doc" "$doc.test-copy"
  done
  LEARNINGS_PROFILE=maintainer bash "$SOURCE_DIR/update.sh"
  for doc in "$LIB_DIR/GUIDE.md" "$LIB_DIR/TAXONOMY.md" "$LIB_DIR/decisions/_global/changelog/claude-md.md"; do
    cmp "$doc" "$doc.test-copy"
  done
  echo '다음 가이드 규칙' >> "$SOURCE_DIR/GUIDE.md"
  LEARNINGS_PROFILE=maintainer bash "$SOURCE_DIR/update.sh"
  [ "$(grep -c '· process:update.sh ·' "$LIB_DIR/GUIDE.md")" -eq 2 ]
  grep -qF -- "$(grep '· process:update.sh ·' "$LIB_DIR/GUIDE.md.test-copy")" "$LIB_DIR/GUIDE.md"
}

@test "TC-120: history examples in code fences or later sections do not satisfy the gate" {
  policy_fixture
  cat >> "$LIB_DIR/GUIDE.md" <<'DOC'
```markdown
## 변경 이력
- 2026-10-05 · codex · 예시 · 이유: 예시 · 근거: session:example
```
## 변경 이력
## 다른 섹션
- 2026-10-05 · codex · 예시 · 이유: 예시 · 근거: session:example
DOC
  policy_event Stop | jq -e '.decision == "block"'
}

@test "profile defaults user and switches maintainer back to user" {
  install_with_input 1
  jq -e '.env.LIBRARY_USAGE_LOG == "aggregate"' "$SETTINGS"
  ! grep -q 'policy-changelog-check' "$SETTINGS"
  [ ! -f "$CLAUDE_DIR/hooks/policy-changelog-check.sh" ]
  bash "$SOURCE_DIR/update.sh" --profile maintainer
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-profile")" = maintainer ]
  jq -e '.env.LIBRARY_USAGE_LOG == "full"' "$SETTINGS"
  grep -q 'policy-changelog-check' "$SETTINGS"
  bash "$SOURCE_DIR/update.sh" --profile user
  [ ! -f "$CLAUDE_DIR/hooks/.learnings-profile" ]
  [ ! -f "$CLAUDE_DIR/hooks/policy-changelog-check.sh" ]
  ! grep -q 'policy-changelog-check' "$SETTINGS"
  jq -e '.env.LIBRARY_USAGE_LOG == "aggregate"' "$SETTINGS"
}

@test "profile validates option stored value and environment with env precedence" {
  run bash "$SOURCE_DIR/install.sh" --profile invalid
  [ "$status" -ne 0 ]
  run bash "$SOURCE_DIR/update.sh" --profile
  [ "$status" -ne 0 ]
  echo invalid > "$CLAUDE_DIR/hooks/.learnings-profile"
  run bash "$SOURCE_DIR/update.sh"
  [ "$status" -ne 0 ]
  LEARNINGS_PROFILE=user install_with_input 1 --profile maintainer
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-profile")" = maintainer ]
  jq -e '.env.LIBRARY_USAGE_LOG == "aggregate"' "$SETTINGS"
  LEARNINGS_PROFILE=maintainer bash "$SOURCE_DIR/update.sh" --profile user
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-profile" ]
  jq -e '.env.LIBRARY_USAGE_LOG == "full"' "$SETTINGS"
}

@test "profile preserves custom usage mode and uninstall removes markers" {
  jq '.env.LIBRARY_USAGE_LOG="off"' "$SETTINGS" > "$SETTINGS.new"
  mv "$SETTINGS.new" "$SETTINGS"
  install_with_input 1 --profile maintainer
  jq -e '.env.LIBRARY_USAGE_LOG == "off"' "$SETTINGS"
  bash "$SOURCE_DIR/update.sh" --profile user
  jq -e '.env.LIBRARY_USAGE_LOG == "off"' "$SETTINGS"
  sed 's|</dev/tty||g' "$SOURCE_DIR/uninstall.sh" > "$TEST_HOME/remove.sh"
  bash "$TEST_HOME/remove.sh" "$TEST_HOME" < /dev/null
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-profile" ]
  [ ! -e "$CLAUDE_DIR/hooks/.learnings-usage-log" ]
}

@test "TC-124: user profile update changes policy docs without writing change history" {
  install_with_input 1
  echo '새 가이드 규칙' >> "$SOURCE_DIR/GUIDE.md"
  sed 's/<!-- learnings-for-claude:rules end -->/새 관리 규칙\n<!-- learnings-for-claude:rules end -->/' "$SOURCE_DIR/templates/claude-rules.md" > "$TEST_HOME/rules"
  mv "$TEST_HOME/rules" "$SOURCE_DIR/templates/claude-rules.md"
  LEARNINGS_PROFILE=user bash "$SOURCE_DIR/update.sh"
  grep -q '새 관리 규칙' "$CLAUDE_DIR/CLAUDE.md"
  [ ! -e "$LIB_DIR/decisions/_global/changelog" ]
  ! grep -q '· process:update.sh ·' "$LIB_DIR/GUIDE.md"
}

@test "trigger hooks default off migration and profile parity" {
  for profile in user maintainer; do
    export LEARNINGS_PROFILE="$profile" LIBRARY_AUTOINJECT=1
    install_with_input 1
    unset LIBRARY_AUTOINJECT
    bash "$SOURCE_DIR/update.sh"
    bash "$SOURCE_DIR/update.sh"
    [ ! -e "$CLAUDE_DIR/hooks/library-autoinject.sh" ]
    jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("library-autoinject"))] | length == 0' "$SETTINGS"
    if [ "$profile" = maintainer ]; then n=1; else n=0; fi
    jq -e --argjson n "$n" '[.hooks.PostToolUse[]?.hooks[] | select(.command | endswith("/library-trigger.sh"))] | length == $n and ($n == 0 or .[0].timeout == 5)' "$SETTINGS"
    jq -e --argjson n "$n" '[.hooks.PostToolUseFailure[]?.hooks[] | select(.command | endswith("/library-trigger.sh"))] | length == $n' "$SETTINGS"
    if [ "$n" = 1 ]; then [ -e "$CLAUDE_DIR/hooks/library-trigger.py" ]; else [ ! -e "$CLAUDE_DIR/hooks/library-trigger.py" ]; fi
  done
  LIBRARY_TRIGGER=1 LEARNINGS_PROFILE=user bash "$SOURCE_DIR/update.sh"
  jq -e '[.hooks.PostToolUse[].hooks[] | select(.command | endswith("/library-trigger.sh"))] | length == 1' "$SETTINGS"
  export LEARNINGS_PROFILE=maintainer
  install_with_input 1
  [ ! -e "$CLAUDE_DIR/hooks/library-autoinject.sh" ]
  sed 's|</dev/tty||g' "$SOURCE_DIR/uninstall.sh" > "$TEST_HOME/uninstall.sh"
  bash "$TEST_HOME/uninstall.sh" "$TEST_HOME" <<< n
  [ ! -e "$CLAUDE_DIR/hooks/library-trigger.sh" ]
  [ ! -e "$CLAUDE_DIR/hooks/library-trigger.py" ]
  jq -e '[.hooks.PostToolUse[], .hooks.PostToolUseFailure[] | .hooks[] | select(.command | contains("library-trigger"))] | length == 0' "$SETTINGS"
}

@test "alwaysLoad updates both files preserving custom keys and backups" {
  for file in "$SETTINGS" "$HOME/.claude.json"; do
    printf '%s\n' '{"custom":42,"mcpServers":{"other":{"command":"keep"},"claude-library":{"command":"old","env":{"CUSTOM":"yes"},"custom":true}}}' > "$file"
  done
  source "$SOURCE_DIR/scripts/update-check.sh"
  update_library_mcp main claude-library-mcp install
  update_library_mcp main claude-library-mcp update
  for file in "$SETTINGS" "$HOME/.claude.json"; do
    jq -e '.custom == 42 and .mcpServers.other.command == "keep" and .mcpServers["claude-library"].alwaysLoad == true and .mcpServers["claude-library"].env.CUSTOM == "yes" and .mcpServers["claude-library"].custom == true' "$file"
    jq -e '.mcpServers["claude-library"].command == "old"' "$file.bak"
  done
}

@test "main kb spec pins packaged version and falls back without pyproject" {
  source "$SOURCE_DIR/scripts/update-check.sh"
  update_library_mcp main claude-library-mcp
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = "claude-library-mcp==$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO_DIR/mcp-server/pyproject.toml")" ]
  rm "$SOURCE_DIR/mcp-server/pyproject.toml"
  update_library_mcp main claude-library-mcp
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = claude-library-mcp ]
  update_library_mcp feat/x "git+https://example.invalid/x@feat/x#subdirectory=mcp-server"
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = "git+https://example.invalid/x@feat/x#subdirectory=mcp-server" ]
}

@test "pinned kb spec is refreshed in uv cache and keeps previous spec when install fails" {
  cat > "$TEST_HOME/bin/uvx" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_HOME/uvx.log"
[ "${UVX_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
  chmod +x "$TEST_HOME/bin/uvx"
  export LEARNINGS_KB_WARM=1
  local version
  version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO_DIR/mcp-server/pyproject.toml")
  source "$SOURCE_DIR/scripts/update-check.sh"
  update_library_mcp main claude-library-mcp
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = "claude-library-mcp==$version" ]
  grep -q -- "--refresh-package claude-library-mcp .*--from claude-library-mcp==$version claude-library-kb --help" "$TEST_HOME/uvx.log"
  printf 'claude-library-mcp==0.0.1\n' > "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  UVX_FAIL=1 update_library_mcp main claude-library-mcp
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = "claude-library-mcp==0.0.1" ]
  rm "$CLAUDE_DIR/hooks/.learnings-kb-spec"
  UVX_FAIL=1 update_library_mcp main claude-library-mcp
  [ "$(cat "$CLAUDE_DIR/hooks/.learnings-kb-spec")" = claude-library-mcp ]
}

@test "decision inject adds global decisions outside git and skips ones already in CLAUDE.md" {
  local lib="$TEST_HOME/lib"
  mkdir -p "$lib/decisions/_global/process" "$TEST_HOME/plain"
  printf -- '---\ntype: Decision\nstatus: stable\n---\n\n# 개인정보는 로컬 파일에서 읽는다\n\n개인정보는 ~/x.md 를 읽는다.\n' > "$lib/decisions/_global/process/personal.md"
  printf -- '---\ntype: Decision\nstatus: stable\n---\n\n# 이미 실린 규칙\n\n본문\n' > "$lib/decisions/_global/process/loaded.md"
  printf '규칙 <!-- why: decisions/_global/process/loaded.md -->\n' > "$CLAUDE_DIR/CLAUDE.md"
  run bash -c "printf '{\"cwd\":\"$TEST_HOME/plain\"}' | LIBRARY_ROOT='$lib' bash '$SOURCE_DIR/hooks/decision-inject.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -r .hookSpecificOutput.additionalContext > "$TEST_HOME/ctx"
  grep -q '개인정보는 로컬 파일에서 읽는다' "$TEST_HOME/ctx"
  grep -q '개인정보는 ~/x.md 를 읽는다.' "$TEST_HOME/ctx"
  ! grep -q '이미 실린 규칙' "$TEST_HOME/ctx"
}
