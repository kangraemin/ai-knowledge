#!/usr/bin/env bash
# 설치·업데이트에서 동일한 등록/제거 정책을 적용한다.
configure_library_hooks() {
  local package="$1" settings="$HOME/.claude/settings.json" dest="$HOME/.claude/hooks" tmp
  command -v jq >/dev/null 2>&1 || return 1
  mkdir -p "$dest"
  tmp=$(mktemp "$settings.tmp.XXXXXX") || return 1
  jq --arg dir "$dest" --arg opt "${LIBRARY_AUTOINJECT:-0}" '
    def strip(re): map(.hooks |= map(select((.command // "") | test(re) | not))) | map(select(.hooks | length > 0));
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [] | strip("library-autoinject\\.sh")) +
      (if $opt == "1" then [{hooks:[{type:"command",command:($dir+"/library-autoinject.sh"),timeout:5}]}] else [] end)) |
    .hooks.PostToolUse = ((.hooks.PostToolUse // [] | strip("library-trigger\\.sh")) +
      [{matcher:"Bash|Skill|Write|Edit",hooks:[{type:"command",command:($dir+"/library-trigger.sh"),timeout:5}]}]) |
    .hooks.PostToolUseFailure = ((.hooks.PostToolUseFailure // [] | strip("library-trigger\\.sh")) +
      [{matcher:"Bash",hooks:[{type:"command",command:($dir+"/library-trigger.sh"),timeout:5}]}])
  ' "$settings" > "$tmp" || { rm -f "$tmp"; return 1; }
  cp -p "$settings" "$settings.bak" && mv "$tmp" "$settings" || return 1
  cp "$package/hooks/library-trigger.sh" "$package/hooks/library-trigger.py" "$dest/"
  chmod +x "$dest/library-trigger.sh"
  if [ "${LIBRARY_AUTOINJECT:-0}" = 1 ]; then
    cp "$package/hooks/library-autoinject.sh" "$dest/"
    chmod +x "$dest/library-autoinject.sh"
  else
    rm -f "$dest/library-autoinject.sh"
  fi
}
