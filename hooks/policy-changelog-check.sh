#!/bin/bash
# stdin은 Python 코드와 분리해 hook JSON 그대로 전달한다.
exec python3 "$(dirname "$0")/policy-changelog.py" "$@"
