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
  echo "  3) 별도 private repo로 관리"
  printf "선택 [1/2/3]: "
  read -r git_choice </dev/tty
  IS_GIT=true
else
  echo "~/.claude 가 git repo가 아닙니다."
  echo ".claude-library/ 를 어떻게 관리하시겠습니까?"
  echo "  1) 로컬만 유지 (git 없음)"
  echo "  2) private repo로 관리"
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
> 카테고리 → 주제 → 지식 파일 계층으로 구성.
> 실험/작업 전 관련 카테고리를 찾아보고, 주제 index.md를 읽는다.

EOF
fi

if [ ! -f "$LIB_DIR/GUIDE.md" ]; then
  curl -sf --max-time 10 "https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/GUIDE.md" \
    -o "$LIB_DIR/GUIDE.md" 2>/dev/null || \
  cat > "$LIB_DIR/GUIDE.md" << 'EOF'
# Library 작성 가이드

## 구조

도서관처럼 카테고리 → 주제 → 지식 파일 계층으로 구성한다.

```
library/
  equity/       ← 미국 주식/ETF 전략
  crypto/       ← 코인 전략
  ml/           ← 머신러닝/모델
  macro/        ← 거시경제
  claude/       ← Claude 행동 패턴
```

### 카테고리 예시
- `equity` — 미국 주식/ETF 전략, 레버리지 ETF
- `crypto` — 코인 전략 (BTC/ETH/XRP 등)
- `ml` — 머신러닝/모델
- `macro` — 거시경제
- `claude` — Claude 행동 패턴, 프롬프트
- 필요하면 새 카테고리 추가

## 언제 기록하나

- 실험/백테스트에서 뭔가 배웠을 때
- 아티클/논문에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때
- **개발 중 삽질로 알게 된 API/라이브러리 동작** — 에러로 발견한 것, 문서에 없는 것, 다음에 또 삽질할 것 같은 것. 발견 즉시 기록한다. 사용자가 요청하기 전에.
- 세션 종료/compact 시 — 위 경우를 놓쳤다면 그때 정리

## 지식 파일 형식

```markdown
# [제목]

- 날짜: YYYY-MM-DD
- 출처: [실험명 / 링크 / 경험]

## 내용
핵심 내용. 데이터, 수치, 상황 설명.

## 시사점
이 지식에서 얻은 것.
```

## 하지 말 것

- 미결이라도 기록할 가치가 있으면 기록한다 (억지로 결론 내리지 않는다)
- 파일명에 날짜 붙이지 않는다
- 오타/포맷 수정은 기록하지 않는다
EOF
fi

if [ ! -f "$LIB_DIR/library/_template.md" ]; then
  cat > "$LIB_DIR/library/_template.md" << 'EOF'
# [제목]

- 날짜: YYYY-MM-DD
- 출처: [실험명 / 링크 / 경험]

## 내용
핵심 내용. 데이터, 수치, 상황 설명.

## 시사점
이 지식에서 얻은 것.
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
  printf "  기존 private repo가 있나요? [y/n]: "
  read -r has_existing </dev/tty
  printf "  private repo URL을 입력하세요: "
  read -r repo_url </dev/tty
  if [ -z "$repo_url" ]; then
    echo "  오류: repo URL을 입력해야 합니다. 설치를 중단합니다."
    exit 1
  fi
  if [ "$has_existing" = "y" ] || [ "$has_existing" = "Y" ]; then
    # 기존 repo → clone 후 템플릿 파일만 보완
    TMPDIR_INIT=$(mktemp -d)
    cp -r "$LIB_DIR/." "$TMPDIR_INIT/"  # 방금 생성한 템플릿 임시 보관
    rm -rf "$LIB_DIR"
    if git clone -q "$repo_url" "$LIB_DIR" 2>/dev/null; then
      # 기존 repo에 없는 파일만 보완
      [ -f "$LIB_DIR/GUIDE.md" ] || cp "$TMPDIR_INIT/GUIDE.md" "$LIB_DIR/"
      [ -f "$LIB_DIR/LIBRARY.md" ] || cp "$TMPDIR_INIT/LIBRARY.md" "$LIB_DIR/"
      mkdir -p "$LIB_DIR/library"
      [ -f "$LIB_DIR/library/_template.md" ] || cp "$TMPDIR_INIT/library/_template.md" "$LIB_DIR/library/"
      echo "  기존 repo clone 완료"
    else
      # clone 실패 시 복원 후 종료
      mv "$TMPDIR_INIT" "$LIB_DIR"
      echo "  오류: repo clone 실패. URL을 확인하세요."
      exit 1
    fi
    rm -rf "$TMPDIR_INIT"
  else
    # 새 repo → 현재 구조 그대로 push
    if [ ! -d "$LIB_DIR/.git" ]; then
      git -C "$LIB_DIR" init -q
      git -C "$LIB_DIR" remote add origin "$repo_url"
    fi
    git -C "$LIB_DIR" add -A
    git -C "$LIB_DIR" commit -q -m "feat: learnings-for-claude 초기 설정" 2>/dev/null || true
    git -C "$LIB_DIR" push -u origin HEAD
    echo "  새 repo 초기화 및 push 완료"
  fi
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
- 관련 카테고리/주제 폴더의 `index.md`를 찾아 읽는다
- 참조한 항목이 있으면 한 줄로 알린다: `📚 library 참조: [경로]`
- 이미 기록된 방향은 재제안하지 않는다

### 쓰기
아래 경우 library에 기록한다:
- 실험/백테스트 결론이 났을 때
- 아티클에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때
- **개발 중 삽질로 알게 된 API/라이브러리 동작** — 에러로 발견한 것, 문서에 없는 것, 다음에 또 삽질할 것 같은 것. 발견 즉시 기록한다. 사용자가 요청하기 전에.

기록 방법:
1. 카테고리 판단 (equity, crypto, ml, macro, claude 등)
2. 주제 폴더 확인/생성: `~/.claude/.claude-library/library/[카테고리]/[주제]/`
3. 지식 파일 생성 (내용 설명하는 이름, 날짜 없음)
4. 주제 `index.md` 생성/업데이트
5. `~/.claude/.claude-library/LIBRARY.md` 업데이트
6. 한 줄로 알린다: `📚 library에 추가: [경로]`

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
# SessionEnd / PostCompact: library 업데이트 체크 + commit/push

LIBRARY="$HOME/.claude/.claude-library/LIBRARY.md"
LIB_DIR="$HOME/.claude/.claude-library"

[ -f "$LIBRARY" ] || exit 0

claude -p "이번 세션에서 ~/.claude/.claude-library/library/ 에 기록할 만한 내용이 있었는지 확인하고, 있다면 ~/.claude/.claude-library/GUIDE.md 형식에 따라 파일을 추가하고 ~/.claude/.claude-library/LIBRARY.md index를 업데이트해라. 기록 대상: 실험/백테스트 결론, 아티클 인사이트, 개발 중 삽질로 알게 된 API/라이브러리 동작 방식(에러로 발견한 것, 문서에 없는 것). 없으면 아무것도 하지 마라." 2>/dev/null || true

# 새 파일 있으면 commit + push
if [ -d "$LIB_DIR/.git" ] && [ -n "$(git -C "$LIB_DIR" status --porcelain 2>/dev/null)" ]; then
  git -C "$LIB_DIR" add -A
  git -C "$LIB_DIR" commit -q -m "feat: library 업데이트 $(date +%Y-%m-%d)"
  git -C "$LIB_DIR" push -q 2>/dev/null || true
fi
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

# --- SessionStart 자동 업데이트 체크 훅 등록 ---
UPDATE_CHECK_DEST="$CLAUDE_DIR/hooks/learnings-update-check.sh"

if grep -qF "learnings-update-check" "$SETTINGS" 2>/dev/null; then
  echo "  자동 업데이트 훅 이미 존재 — 스킵"
else
  cat > "$UPDATE_CHECK_DEST" << 'EOF'
#!/bin/bash
# learnings-for-claude 자동 업데이트 체커

set -euo pipefail

REPO="kangraemin/learnings-for-claude"
API_URL="https://api.github.com/repos/$REPO/commits/main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/main"

HOOK_DIR="$HOME/.claude/hooks"
VERSION_FILE="$HOOK_DIR/.learnings-version"
CHECKED_FILE="$HOOK_DIR/.learnings-version-checked"
SELF="$HOOK_DIR/learnings-update-check.sh"

FORCE=false
CHECK_ONLY=false
for arg in "$@"; do
  case $arg in
    --force)      FORCE=true ;;
    --check-only) CHECK_ONLY=true ;;
  esac
done

[ -f "$HOOK_DIR/library-sync.sh" ] || exit 0

if [ "$FORCE" = false ] && [ "$CHECK_ONLY" = false ] && [ -f "$CHECKED_FILE" ]; then
  LAST=$(cat "$CHECKED_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ $(( NOW - LAST )) -lt 86400 ]; then
    exit 0
  fi
fi

LATEST_SHA=$(curl -sf --max-time 5 "$API_URL" 2>/dev/null | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['sha'][:7])" 2>/dev/null) || exit 0

date +%s > "$CHECKED_FILE"

INSTALLED_SHA=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")

if [ "$CHECK_ONLY" = true ]; then
  echo "installed: $INSTALLED_SHA"
  echo "latest:    $LATEST_SHA"
  [ "$LATEST_SHA" = "$INSTALLED_SHA" ] && echo "status: up-to-date" || echo "status: update-available"
  exit 0
fi

[ "$LATEST_SHA" = "$INSTALLED_SHA" ] && exit 0

if [ "${_LEARNINGS_BOOTSTRAPPED:-}" != "1" ]; then
  SELF_TMP=$(mktemp)
  trap 'rm -f "$SELF_TMP"' EXIT
  if curl -sf --max-time 10 "$RAW_BASE/scripts/update-check.sh" -o "$SELF_TMP" 2>/dev/null && \
     [ -s "$SELF_TMP" ] && bash -n "$SELF_TMP" 2>/dev/null; then
    if ! cmp -s "$SELF_TMP" "$SELF" 2>/dev/null; then
      mv "$SELF_TMP" "$SELF"
      chmod +x "$SELF"
      trap - EXIT
      export _LEARNINGS_BOOTSTRAPPED=1
      exec bash "$SELF" --force
    fi
  fi
  rm -f "$SELF_TMP"
  trap - EXIT
fi

CLONE_DIR=$(mktemp -d)
trap 'rm -rf "$CLONE_DIR"' EXIT
git clone --depth 1 "https://github.com/$REPO.git" "$CLONE_DIR/learnings-for-claude" -q 2>/dev/null || exit 0
bash "$CLONE_DIR/learnings-for-claude/update.sh" || exit 0
echo "learnings-for-claude $INSTALLED_SHA → $LATEST_SHA 업데이트 완료"
EOF

  chmod +x "$UPDATE_CHECK_DEST"

  if command -v jq >/dev/null 2>&1; then
    CHECK_HOOK_JSON="{\"hooks\":[{\"type\":\"command\",\"command\":\"$UPDATE_CHECK_DEST\",\"timeout\":15,\"async\":true}]}"
    jq --argjson hook "$CHECK_HOOK_JSON" \
      '.hooks.SessionStart = (.hooks.SessionStart // []) + [$hook]' \
      "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi

  # 초기 버전 기록
  curl -sf --max-time 5 "https://api.github.com/repos/kangraemin/learnings-for-claude/commits/main" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['sha'][:7])" \
    > "$CLAUDE_DIR/hooks/.learnings-version" 2>/dev/null || true

  echo "  SessionStart 자동 업데이트 체크 등록"
fi

# --- session-review 스킬 설치 ---
SKILL_DIR="$CLAUDE_DIR/skills/session-review"
if [ -d "$SKILL_DIR" ]; then
  echo "  session-review 스킬 이미 존재 — 스킵"
else
  mkdir -p "$SKILL_DIR"
  cat > "$SKILL_DIR/SKILL.md" << 'EOF'
---
name: session-review
description: 세션에서 배울게있는지 정리하고 library에 저장. '배운 거 정리해줘', '이번 세션 정리', '세션 리뷰', 'session review', '오늘 배운 거', '이번 대화에서 건진 거' 같은 요청 시 반드시 이 스킬을 사용. 기술적 발견, 삽질 해결, API 동작, 설계 결정 등 다음에 또 쓸 만한 게 있는지 확인할 때도 트리거.
---

# Session Review

이번 세션 대화를 돌아보고 library에 저장할 가치가 있는 지식을 추출한다.

## 판단 기준

저장할 가치가 있는 것:
- 삽질로 알게 된 API/라이브러리 동작 (에러로 발견한 것, 문서에 없는 것)
- 설계 결정과 그 이유 (왜 A 대신 B를 선택했는지)
- 시도했다가 실패한 접근법과 이유
- 앞으로 같은 상황에서 다시 쓸 수 있는 패턴/인사이트

저장하지 않는 것:
- 이번 작업에만 해당하는 일회성 정보
- 코드 파일에 이미 반영된 내용
- git history에서 확인 가능한 것
- 오타/포맷 수정

**아무것도 없으면 "이번 세션에서 저장할 내용 없음"으로 끝낸다. 억지로 만들지 않는다.**

## 플로우

1. **스캔**: 이번 세션 대화 전체를 돌아보며 위 기준에 맞는 것 목록화
2. **저장**: 바로 library에 파일로 작성 (확인 없이)
3. **커밋**: git commit & push
4. **보고**: 저장한 내용 한 줄 요약으로 알림

확인 단계 없이 바로 저장한다. 사용자가 "정리해줘"라고 했으면 저장까지가 요청의 범위다.

## 저장 방법

Library 경로: `~/.claude/.claude-library/library/`

### 카테고리 판단
- `claude` — Claude/AI 도구 동작, 프롬프트 패턴, MCP, 스킬
- `equity` — 주식/ETF 전략
- `crypto` — 코인 전략
- `ml` — 머신러닝
- `macro` — 거시경제
- 없으면 새 카테고리 추가

### 파일 작성 순서
1. `~/.claude/.claude-library/library/[카테고리]/[주제]/[파일명].md` 생성
2. 주제 `index.md` 생성 또는 업데이트
3. `~/.claude/.claude-library/LIBRARY.md` 업데이트

### 지식 파일 형식
```markdown
# [제목]

- 날짜: YYYY-MM-DD
- 출처: [세션 설명 / 경험]

## 내용
핵심 내용. 구체적으로.

## 시사점
다음에 이 지식을 어떻게 쓸 수 있는지.
```

## 커밋
```bash
git -C ~/.claude/.claude-library add -A
git -C ~/.claude/.claude-library commit -m "feat: [주제] 추가"
git -C ~/.claude/.claude-library push
```

저장 후: `📚 library에 추가: [경로]` 한 줄로 알린다.
EOF
  echo "  session-review 스킬 설치"
fi

# --- update-learnings 스킬 설치 ---
SKILL_DIR="$CLAUDE_DIR/skills/update-learnings"
if [ -d "$SKILL_DIR" ]; then
  echo "  update-learnings 스킬 이미 존재 — 스킵"
else
  mkdir -p "$SKILL_DIR"
  cat > "$SKILL_DIR/SKILL.md" << 'EOF'
---
description: learnings-for-claude 최신 버전 확인 및 업데이트
---

# /update-learnings

## 플로우

1. update-check.sh 경로 탐색:
   - `~/.claude/hooks/learnings-update-check.sh`
   - 없으면 "learnings-update-check.sh를 찾을 수 없습니다. install.sh를 먼저 실행하세요." 출력 후 종료
2. `bash "~/.claude/hooks/learnings-update-check.sh" --check-only` 로 현재/최신 버전 확인
3. 결과 출력:
   - `up-to-date` → "최신 버전입니다 (SHA)" 출력 후 종료
   - `update-available` → 현재/최신 SHA 보여주고 업데이트 여부 확인
4. 업데이트 확인 시 `bash "~/.claude/hooks/learnings-update-check.sh" --force` 실행
5. 완료 메시지 출력
EOF
  echo "  update-learnings 스킬 설치"
fi

echo ""
echo "완료."
echo "  library: ~/.claude/.claude-library/library/"
echo "  index:   ~/.claude/.claude-library/LIBRARY.md"
