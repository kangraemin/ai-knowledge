#!/bin/bash
# SessionStart hook: PROJECT.md 없으면 생성 안내 (프로젝트별 1회)

# git repo 아니면 스킵
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    exit 0
fi

_PROJ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
_PROMPTED="$_PROJ_ROOT/.claude/.project-md-prompted"

if [ ! -f "$_PROJ_ROOT/PROJECT.md" ] && [ ! -f "$_PROMPTED" ]; then
    mkdir -p "$_PROJ_ROOT/.claude"
    touch "$_PROMPTED"
    printf 'PROJECT.md가 없습니다. /update-project 를 실행하면 프로젝트 문서가 자동 생성됩니다. 사용자에게 실행할지 물어보세요.\n'
fi

exit 0
