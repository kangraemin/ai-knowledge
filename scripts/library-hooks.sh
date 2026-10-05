#!/usr/bin/env bash
# 설치·업데이트에서 동일한 등록/제거 정책을 적용한다.
configure_library_hooks() {
  local package="$1" settings="$HOME/.claude/settings.json" dest="$HOME/.claude/hooks" tmp trigger
  # 순간 트리거는 실사용 효과 검증 전이라 maintainer 만 기본으로 켠다. LIBRARY_TRIGGER=0|1 로 덮어쓴다.
  trigger="${LIBRARY_TRIGGER:-}"
  if [ -z "$trigger" ]; then
    [ "${LEARNINGS_PROFILE:-${PROFILE:-user}}" = maintainer ] && trigger=1 || trigger=0
  fi
  command -v jq >/dev/null 2>&1 || return 1
  mkdir -p "$dest"
  tmp=$(mktemp "$settings.tmp.XXXXXX") || return 1
  jq --arg dir "$dest" --arg opt "${LIBRARY_AUTOINJECT:-0}" --arg trig "$trigger" '
    def strip(re): map(.hooks |= map(select((.command // "") | test(re) | not))) | map(select(.hooks | length > 0));
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [] | strip("library-autoinject\\.sh")) +
      (if $opt == "1" then [{hooks:[{type:"command",command:($dir+"/library-autoinject.sh"),timeout:5}]}] else [] end)) |
    .hooks.PostToolUse = ((.hooks.PostToolUse // [] | strip("library-trigger\\.sh")) +
      (if $trig == "1" then [{matcher:"Bash|Skill|Write|Edit",hooks:[{type:"command",command:($dir+"/library-trigger.sh"),timeout:5}]}] else [] end)) |
    .hooks.PostToolUseFailure = ((.hooks.PostToolUseFailure // [] | strip("library-trigger\\.sh")) +
      (if $trig == "1" then [{matcher:"Bash",hooks:[{type:"command",command:($dir+"/library-trigger.sh"),timeout:5}]}] else [] end))
  ' "$settings" > "$tmp" || { rm -f "$tmp"; return 1; }
  cp -p "$settings" "$settings.bak" && mv "$tmp" "$settings" || return 1
  if [ "$trigger" = 1 ]; then
    cp "$package/hooks/library-trigger.sh" "$package/hooks/library-trigger.py" "$dest/"
    chmod +x "$dest/library-trigger.sh"
  else
    rm -f "$dest/library-trigger.sh" "$dest/library-trigger.py"
  fi
  if [ "${LIBRARY_AUTOINJECT:-0}" = 1 ]; then
    cp "$package/hooks/library-autoinject.sh" "$dest/"
    chmod +x "$dest/library-autoinject.sh"
  else
    rm -f "$dest/library-autoinject.sh"
  fi
}
