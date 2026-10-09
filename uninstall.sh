#!/bin/bash
set -e

TARGET="${1:-$(pwd)}"
SETTINGS="$HOME/.claude/settings.json"
HOOK_DIR="$HOME/.claude/hooks"
HOOK_DEST="$HOOK_DIR/library-sync.sh"

echo "learnings-for-claude 제거 중..."

# 관리 규칙만 제거한다. 구형 무마커 설치는 기존 제거 범위를 유지한다.
remove_library_rules() {
  [ -f "$1" ] || return 0
  python3 - "$1" <<'PYEOF'
import sys, re, shutil
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_bytes()
start = b"<!-- learnings-for-claude:rules start -->"
end = b"<!-- learnings-for-claude:rules end -->"
if start in s or end in s:
    if s.count(start) != 1 or s.count(end) != 1 or s.index(start) >= s.index(end):
        print("경고: CLAUDE.md 관리 마커 오류 — 원본 유지")
        sys.exit(0)
    s2 = s[:s.index(start)] + s[s.index(end) + len(end):]
else:
    s2 = re.sub(r"(?:^|\r?\n)## Library 시스템\r?\n.*?(?=\r?\n#{1,3} (?!Library 시스템)|\r?\n# ---|\Z)".encode(), b"\n", s, flags=re.S)
if s2 != s:
    shutil.copyfile(p, str(p) + ".bak")
    p.write_bytes(s2)
    print("  CLAUDE.md Library 규칙 제거 (백업: CLAUDE.md.bak)")
PYEOF
}

# 1. 프로젝트 CLAUDE.md에서 규칙 제거
CLAUDE_MD="$TARGET/CLAUDE.md"
GLOBAL_CLAUDE_MD="$HOME/.claude/CLAUDE.md"
remove_library_rules "$CLAUDE_MD"

# 2. 훅 제거 여부 확인
if command -v jq &>/dev/null && grep -qF "library-sync" "$SETTINGS" 2>/dev/null; then
  echo ""
  echo "  SessionEnd/PostCompact 훅도 제거하시겠습니까?"
  printf "  [y/N] "
  read -r answer </dev/tty 2>/dev/null || answer="n"
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    jq '
      .hooks.SessionEnd = [(.hooks.SessionEnd // [])[] | select((.hooks[0].command // "") | contains("library-sync") | not)] |
      .hooks.PostCompact = [(.hooks.PostCompact // [])[] | select((.hooks[0].command // "") | contains("library-sync") | not)]
    ' "$SETTINGS" > "$SETTINGS.tmp.$$"
    mv "$SETTINGS.tmp.$$" "$SETTINGS"
    rm -f "$HOOK_DEST"
    echo "  훅 제거"
  else
    echo "  스킵"
  fi
fi

echo ""
echo "완료. ~/claude-library/ (지식·결정사항) 는 유지됩니다."

# 3. decision / 활동로그 훅 제거 (library-sync 유무와 무관하게 독립 처리)
_lfc_installed=0
for _h in decision-inject library-activity-log policy-inject library-save-check \
          code-lesson-check library-allow learnings-update-check library-sync library-trigger library-autoinject policy-changelog-check library-usage-log; do
  [ -f "$HOOK_DIR/$_h.sh" ] && _lfc_installed=1
done
grep -qE "library-trigger|policy-changelog-check|library-usage-log|library-autoinject|decision-inject|library-activity-log|library-save-check|code-lesson-check|library-allow|learnings-update-check" "$SETTINGS" 2>/dev/null && _lfc_installed=1
if [ "$_lfc_installed" = "1" ]; then
  rm -f "$HOOK_DIR/decision-inject.sh" "$HOOK_DIR/library-activity-log.sh" "$HOOK_DIR/policy-inject.sh" \
        "$HOOK_DIR/library-save-check.sh" "$HOOK_DIR/code-lesson-check.sh" \
        "$HOOK_DIR/library-allow.sh" "$HOOK_DIR/learnings-update-check.sh" \
        "$HOOK_DIR/library-trigger.sh" "$HOOK_DIR/library-trigger.py" "$HOOK_DIR/library-sync.sh" "$HOOK_DIR/library-autoinject.sh" \
        "$HOOK_DIR/policy-changelog-check.sh" "$HOOK_DIR/policy-changelog.py" "$HOOK_DIR/library-usage-log.sh"
  if command -v jq &>/dev/null && [ -f "$SETTINGS" ]; then
    if jq '
      def strip(re): map(.hooks |= map(select((.command // "") | test(re) | not))) | map(select((.hooks | length) > 0));
      .hooks.SessionStart |= ((. // []) | strip("policy-changelog-check.sh|decision-inject.sh|policy-inject.sh|learnings-update-check.sh"))
      | .hooks.UserPromptSubmit |= ((. // []) | strip("library-autoinject\\.sh"))
      | .hooks.PostToolUse |= ((. // []) | strip("library-activity-log.sh|library-trigger.sh"))
      | .hooks.PostToolUseFailure |= ((. // []) | strip("library-trigger.sh"))
      | .hooks.PreToolUse  |= ((. // []) | strip("library-allow.sh"))
      | .hooks.PreCompact  |= ((. // []) | strip("library-save-check.sh"))
      | .hooks.Stop        |= ((. // []) | strip("policy-changelog-check.sh|library-usage-log.sh|library-save-check.sh|code-lesson-check.sh"))
      | .hooks.SessionEnd   |= ((. // []) | strip("library-sync.sh"))
      | .hooks.PostCompact  |= ((. // []) | strip("library-sync.sh"))
    ' "$SETTINGS" > "$SETTINGS.tmp.$$"; then
      mv "$SETTINGS.tmp.$$" "$SETTINGS"
      echo "  decision/활동로그 훅 제거"
    fi
    # MCP 서버 등록·권한·추가 디렉터리도 함께 해제
    if jq '
      del(.mcpServers["claude-library"])
      | .permissions.allow |= ((. // []) | map(select(test("claude-library") | not)))
      | .permissions.additionalDirectories |= ((. // []) | map(select(test("claude-library") | not)))
    ' "$SETTINGS" > "$SETTINGS.tmp.$$"; then
      mv "$SETTINGS.tmp.$$" "$SETTINGS"
      echo "  MCP 등록·권한 해제"
    else
      rm -f "$SETTINGS.tmp.$$"
      echo "  ⚠️ settings.json 갱신 실패 — 훅 등록이 남았을 수 있다"
    fi
  fi
fi

# 4. ~/.claude/CLAUDE.md 의 Library 블록 제거 (install 은 여기에 쓴다)
remove_library_rules "$GLOBAL_CLAUDE_MD"
rm -f "$HOME/.claude/hooks/.learnings-version"

rm -f "$HOOK_DIR/.learnings-kb-spec" "$HOOK_DIR/.learnings-kb-pending" "$HOOK_DIR/.learnings-kb-pending.tried" "$HOOK_DIR/.learnings-branch" "$HOOK_DIR/.learnings-version-checked"

rm -f "$HOOK_DIR/.learnings-profile" "$HOOK_DIR/.learnings-usage-log"
