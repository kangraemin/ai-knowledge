#!/bin/bash
set -e

CLAUDE_DIR="$HOME/.claude"
LIB_DIR="$CLAUDE_DIR/.claude-library"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DEST="$CLAUDE_DIR/hooks/library-sync.sh"

echo "learnings-for-claude 설치 중..."
echo ""

# --- git 관리 방식 결정 ---
if git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "~/.claude 가 git repo로 감지됐습니다."
  echo ".claude-library/ 를 어떻게 관리하시겠습니까?"
  echo "  1) git 추적 안 함 (.gitignore에 추가)"
  echo "  2) 기존 ~/.claude repo에 포함"
  echo "  3) 별도 private repo로 관리 (.gitignore에 추가 + 새 repo 설정)"
  printf "선택 [1/2/3]: "
  read -r git_choice </dev/tty
  IS_GIT=true
else
  echo "~/.claude 가 git repo가 아닙니다."
  echo ".claude-library/ 를 어떻게 관리하시겠습니까?"
  echo "  1) 로컬만 유지 (git 없음)"
  echo "  2) 새 private repo 생성"
  printf "선택 [1/2]: "
  read -r git_choice </dev/tty
  IS_GIT=false
fi

echo ""

# --- .claude-library/ 구조 생성 ---
mkdir -p "$LIB_DIR/library"

if [ ! -f "$LIB_DIR/LIBRARY.md" ]; then
  cat > "$LIB_DIR/LIBRARY.md" << 'EOF'
# Library

> 작업에서 도출된 지식 저장소.
> 실험/작업 전 관련 항목이 있는지 확인하고, 필요한 파일만 읽는다.

| 날짜 | 제목 | 결론 | 파일 |
|------|------|------|------|
EOF
fi

if [ ! -f "$LIB_DIR/GUIDE.md" ]; then
  cat > "$LIB_DIR/GUIDE.md" << 'EOF'
# Library 작성 가이드

## 언제 기록하나

- 실험/백테스트 결론이 났을 때
- 링크/아티클에서 유효한 인사이트를 얻었을 때
- 사용자가 수정을 요청했을 때 (접근법이 틀렸을 때)
- 더 나은 방법을 발견했을 때
- 세션 종료/compact 시 — 위 경우를 놓쳤다면 그때 정리

## 파일명 규칙

YYYY-MM-DD-[주제]-[결론].md

예)
2026-03-07-피보나치-안됨.md
2026-03-20-gld-방어-유효.md

## 제목 규칙

- 한 줄로, 결론이 바로 보이게
- "~는 안 된다" / "~는 유효하다" 형식 권장

## 결론 판단 기준

- 유효: 데이터/실험/복수 소스로 확인됨
- 안됨: 데이터/실험으로 효과 없음 확인됨
- 미결: 아직 판단 불가 → library에 기록하지 않는다

## 파일 템플릿

_template.md 참고

## LIBRARY.md 업데이트

파일 추가할 때 LIBRARY.md에 한 줄 동시 추가:

| 날짜 | 제목 | 결론 | 파일 |
|------|------|------|------|
| 2026-03-07 | 피보나치 되돌림 | 안됨 | [링크](library/2026-03-07-피보나치-안됨.md) |

## 하지 말 것

- 미결 상태로 기록하지 않는다
- 결론 없이 "흥미롭다"만 기록하지 않는다
- 오타/포맷 수정은 기록하지 않는다
EOF
fi

if [ ! -f "$LIB_DIR/library/_template.md" ]; then
  cat > "$LIB_DIR/library/_template.md" << 'EOF'
# [제목]

- 날짜: YYYY-MM-DD
- 출처: [실험명 / 링크 / 경험]
- 결론: 유효 / 안됨

## 근거
왜 이 결론인지. 데이터나 상황.

## 적용
앞으로 어떻게 행동할지. 예외 조건이 있다면 명시.
EOF
fi

echo "  ~/.claude/.claude-library/ 생성"

# --- git 설정 ---
NEED_GITIGNORE=false
NEED_REPO=false

if [ "$IS_GIT" = true ]; then
  if [ "$git_choice" = "1" ] || [ "$git_choice" = "3" ]; then
    NEED_GITIGNORE=true
  fi
  if [ "$git_choice" = "3" ]; then
    NEED_REPO=true
  fi
else
  if [ "$git_choice" = "2" ]; then
    NEED_REPO=true
  fi
fi

if [ "$NEED_GITIGNORE" = true ]; then
  GITIGNORE="$CLAUDE_DIR/.gitignore"
  if ! grep -qF ".claude-library/" "$GITIGNORE" 2>/dev/null; then
    echo ".claude-library/" >> "$GITIGNORE"
    echo "  .gitignore에 .claude-library/ 추가"
  fi
fi

if [ "$NEED_REPO" = true ]; then
  printf "  private repo URL을 입력하세요: "
  read -r repo_url </dev/tty
  if [ -z "$repo_url" ]; then
    echo "  오류: repo URL을 입력해야 합니다. 설치를 중단합니다."
    exit 1
  fi
  if [ ! -d "$LIB_DIR/.git" ]; then
    git -C "$LIB_DIR" init -q
    git -C "$LIB_DIR" remote add origin "$repo_url"
  fi
  git -C "$LIB_DIR" add -A
  git -C "$LIB_DIR" commit -q -m "feat: learnings-for-claude 초기 설정" 2>/dev/null || true
  git -C "$LIB_DIR" push -u origin HEAD
  echo "  private repo 설정 완료"
fi

# --- ~/.claude/CLAUDE.md에 규칙 추가 ---
GLOBAL_CLAUDE="$CLAUDE_DIR/CLAUDE.md"
MARKER="## Library 시스템"

if [ -f "$GLOBAL_CLAUDE" ] && grep -qF "$MARKER" "$GLOBAL_CLAUDE"; then
  echo "  ~/.claude/CLAUDE.md 규칙 이미 존재 — 스킵"
else
  cat >> "$GLOBAL_CLAUDE" << 'EOF'

## Library 시스템

참조: `~/.claude/.claude-library/GUIDE.md`

### 읽기
- 새 실험/전략 제안 전, 막히는 상황에서 `~/.claude/.claude-library/LIBRARY.md`를 읽는다
- 관련 항목이 있으면 해당 파일만 읽는다
- 이미 기록된 방향은 재제안하지 않는다

### 쓰기
아래 경우 조용히 library에 기록한다 (사용자에게 말하지 않는다):
- 실험/백테스트 결론이 났을 때
- 링크/아티클에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때

기록 방법:
1. `~/.claude/.claude-library/library/YYYY-MM-DD-[주제]-[결론].md` 파일 생성
2. `~/.claude/.claude-library/LIBRARY.md` index에 한 줄 추가

미결 상태는 기록하지 않는다.
EOF
  echo "  ~/.claude/CLAUDE.md 규칙 추가"
fi

# --- SessionEnd / PostCompact 훅 등록 ---
if ! command -v jq >/dev/null 2>&1; then
  echo "  경고: jq 없음 — 훅 스킵 (brew install jq 후 재설치 권장)"
elif grep -qF "library-sync" "$SETTINGS" 2>/dev/null; then
  echo "  훅 이미 존재 — 스킵"
else
  mkdir -p "$(dirname "$HOOK_DEST")"

  cat > "$HOOK_DEST" << 'EOF'
#!/bin/bash
# SessionEnd / PostCompact: library 업데이트 체크

LIBRARY="$HOME/.claude/.claude-library/LIBRARY.md"

[ -f "$LIBRARY" ] || exit 0

claude -p "이번 세션에서 ~/.claude/.claude-library/library/ 에 기록할 만한 결론이 있었는지 확인하고, 있다면 ~/.claude/.claude-library/GUIDE.md 형식에 따라 파일을 추가하고 ~/.claude/.claude-library/LIBRARY.md index를 업데이트해라. 없으면 아무것도 하지 마라." 2>/dev/null || true
EOF

  chmod +x "$HOOK_DEST"

  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak" || echo "{\"hooks\":{}}" > "$SETTINGS"

  HOOK_JSON="{\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK_DEST\",\"timeout\":30}]}"
  jq --argjson hook "$HOOK_JSON" '
    .hooks.SessionEnd = (.hooks.SessionEnd // []) + [$hook] |
    .hooks.PostCompact = (.hooks.PostCompact // []) + [$hook]
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

  echo "  SessionEnd / PostCompact 훅 등록"
fi

echo ""
echo "완료."
echo "  library: ~/.claude/.claude-library/library/"
echo "  index:   ~/.claude/.claude-library/LIBRARY.md"
