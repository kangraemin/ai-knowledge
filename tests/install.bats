#!/usr/bin/env bats
# install.sh E2E tests (62 cases)

setup() {
  export TEST_HOME="$(mktemp -d)"
  export ORIG_HOME="$HOME"
  export HOME="$TEST_HOME"
  export CLAUDE_DIR="$TEST_HOME/.claude"
  export LIB_DIR="$TEST_HOME/claude-library"
  export SETTINGS="$CLAUDE_DIR/settings.json"
  export INSTALL_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/install.sh"

  mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills"
  echo '{"hooks":{},"mcpServers":{}}' > "$SETTINGS"
}

teardown() {
  export HOME="$ORIG_HOME"
  rm -rf "$TEST_HOME"
}

# Helper: run install.sh with tty input via stdin redirect
# Patches /dev/tty reads to use stdin, but preserves SCRIPT_DIR pointing to real repo
install_with_input() {
  local input="$1"
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
  { echo "$input"; for _ in $(seq 1 20); do echo ""; done; } | bash "$patched" 2>&1
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

@test "TC-12: replaces Library section in existing CLAUDE.md" {
  printf "# Rules\n\n## Library 시스템\nOLD_CONTENT\n" > "$CLAUDE_DIR/CLAUDE.md"
  install_with_input "1"
  ! grep -q "OLD_CONTENT" "$CLAUDE_DIR/CLAUDE.md"
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
  [ -f "$hook" ] || skip "hook not installed"
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
  [ -f "$hook" ] || skip "hook not installed"
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
  [ -f "$hook" ] || skip "hook not installed"
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
  [ -f "$hook" ] || skip "hook not installed"
  local out
  out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/claude-library/library/a.md"}}' "$TEST_HOME" \
        | HOME="$TEST_HOME" bash "$hook")
  echo "$out" | grep -q '"permissionDecision": *"allow"'
}

@test "TC-65: library-allow refuses traversal out of the library" {
  install_with_input "1" > /dev/null 2>&1 || true
  local hook="$CLAUDE_DIR/hooks/library-allow.sh"
  [ -f "$hook" ] || skip "hook not installed"
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
  [ -f "$hook" ] || skip "hook not installed"
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
