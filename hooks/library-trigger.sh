#!/usr/bin/env bash
# 검색 실패가 도구 실행 결과를 바꾸지 않도록 항상 성공으로 종료한다.
python3 "$(dirname "$0")/library-trigger.py" 2>/dev/null
exit 0
