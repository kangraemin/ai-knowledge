#!/bin/bash
# Stop hook: 방금 응답에서 library 저장 대상 있는지 체크

command -v jq &>/dev/null || exit 0

INPUT=$(cat)

# 재진입 방지
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

jq -n '{
  "decision": "block",
  "reason": "방금 응답에서 library에 저장할 만한 내용(삽질로 알게 된 API 동작, 교정받은 사실, 설계 결정 이유 등)이 있었나? yes면 /session-review 실행해서 저장해. no면 아무 말도 하지 말고 그냥 넘어가."
}'
