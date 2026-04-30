#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
LIB_DIR="$CLAUDE_DIR/.claude-library"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DEST="$CLAUDE_DIR/hooks/library-sync.sh"

# --- 언어 선택 / Language selection ---
echo "Select language / 언어를 선택하세요"
echo "  1) 한국어"
echo "  2) English"
printf ">>> "
read -r _lang_choice </dev/tty
if [ "$_lang_choice" = "2" ]; then
  _LANG=en
else
  _LANG=ko
fi

msg() {
  if [ "$_LANG" = "en" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

echo ""
echo "$(msg 'learnings-for-claude 설치 중...' 'Installing learnings-for-claude...')"
echo ""

# --- git 관리 방식 결정 ---
if git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$(msg '~/.claude 가 git repo로 감지됐습니다.' '~/.claude detected as a git repo.')"
  echo "$(msg '.claude-library/ 를 어떻게 관리하시겠습니까?' 'How would you like to manage .claude-library/?')"
  echo "  1) $(msg 'git 추적 안 함 (.gitignore에 추가)' 'Do not track in git (add to .gitignore)')"
  echo "  2) $(msg '기존 ~/.claude repo에 포함' 'Include in existing ~/.claude repo')"
  echo "  3) $(msg '별도 private repo로 관리' 'Manage as a separate private repo')"
  printf "$(msg '선택' 'Select') [1/2/3]: "
  read -r git_choice </dev/tty
  IS_GIT=true
else
  echo "$(msg '~/.claude 가 git repo가 아닙니다.' '~/.claude is not a git repo.')"
  echo "$(msg '.claude-library/ 를 어떻게 관리하시겠습니까?' 'How would you like to manage .claude-library/?')"
  echo "  1) $(msg '로컬만 유지 (git 없음)' 'Keep local only (no git)')"
  echo "  2) $(msg 'private repo로 관리' 'Manage as a private repo')"
  printf "$(msg '선택' 'Select') [1/2]: "
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

if [ ! -f "$HOME/.claude/TAXONOMY.md" ]; then
  curl -sf --max-time 10 "https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/TAXONOMY.md" \
    -o "$HOME/.claude/TAXONOMY.md" 2>/dev/null || \
  cp "$SCRIPT_DIR/TAXONOMY.md" "$HOME/.claude/TAXONOMY.md" 2>/dev/null || true
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

echo "  $(msg '~/.claude/.claude-library/ 생성' '~/.claude/.claude-library/ created')"

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
    echo "  $(msg '.gitignore에 .claude-library/ 추가' 'Added .claude-library/ to .gitignore')"
  fi
fi

if [ "$NEED_REPO" = true ]; then
  printf "  $(msg '기존 private repo가 있나요?' 'Do you have an existing private repo?') [y/n]: "
  read -r has_existing </dev/tty
  printf "  $(msg 'private repo URL을 입력하세요' 'Enter private repo URL'): "
  read -r repo_url </dev/tty
  if [ -z "$repo_url" ]; then
    echo "  $(msg '오류: repo URL을 입력해야 합니다. 설치를 중단합니다.' 'Error: repo URL is required. Aborting installation.')"
    exit 1
  fi
  if [ "$has_existing" = "y" ] || [ "$has_existing" = "Y" ]; then
    # 기존 repo → clone 후 템플릿 파일만 보완
    TMPDIR_INIT=$(mktemp -d)
    cp -r "$LIB_DIR/." "$TMPDIR_INIT/"
    rm -rf "$LIB_DIR"
    if git clone -q "$repo_url" "$LIB_DIR" 2>/dev/null; then
      [ -f "$LIB_DIR/GUIDE.md" ] || cp "$TMPDIR_INIT/GUIDE.md" "$LIB_DIR/"
      [ -f "$LIB_DIR/LIBRARY.md" ] || cp "$TMPDIR_INIT/LIBRARY.md" "$LIB_DIR/"
      mkdir -p "$LIB_DIR/library"
      [ -f "$LIB_DIR/library/_template.md" ] || cp "$TMPDIR_INIT/library/_template.md" "$LIB_DIR/library/"
      echo "  $(msg '기존 repo clone 완료' 'Cloned existing repo')"
    else
      mv "$TMPDIR_INIT" "$LIB_DIR"
      echo "  $(msg '오류: repo clone 실패. URL을 확인하세요.' 'Error: repo clone failed. Check the URL.')"
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
    git -C "$LIB_DIR" commit -q -m "feat: learnings-for-claude initial setup" 2>/dev/null || true
    git -C "$LIB_DIR" push -u origin HEAD
    echo "  $(msg '새 repo 초기화 및 push 완료' 'Initialized and pushed new repo')"
  fi
fi

# --- ~/.claude/CLAUDE.md에 규칙 추가/업데이트 ---
GLOBAL_CLAUDE="$CLAUDE_DIR/CLAUDE.md"
MARKER="## Library 시스템"
RULES_SRC="$SCRIPT_DIR/templates/claude-rules.md"

_inject_rules() {
  local target="$1"
  if [ ! -f "$RULES_SRC" ]; then
    echo "  $(msg '경고: templates/claude-rules.md 없음 — 스킵' 'Warning: templates/claude-rules.md not found — skipped')"
    return
  fi
  if grep -qF "$MARKER" "$target" 2>/dev/null; then
    python3 - "$target" "$RULES_SRC" << 'PYEOF'
import sys, re
target, src = sys.argv[1], sys.argv[2]
content = open(target).read()
new_block = open(src).read()

START = '## Library 시스템'
start_idx = content.find('\n' + START)
if start_idx != -1:
    rest = content[start_idx + 1:]
    # 다음 섹션(## 또는 # ---) 직전까지만 교체
    end_match = re.search(r'\n(##? |# ---)', rest)
    if end_match:
        end_idx = start_idx + 1 + end_match.start()
        content = content[:start_idx + 1] + new_block + '\n\n' + content[end_idx:]
    else:
        content = content[:start_idx + 1] + new_block + '\n'
open(target, 'w').write(content)
PYEOF
    echo "  $(msg '~/.claude/CLAUDE.md 규칙 업데이트' '~/.claude/CLAUDE.md rules updated')"
  else
    python3 - "$target" "$RULES_SRC" << 'PYEOF'
import sys, re
target, src = sys.argv[1], sys.argv[2]
content = open(target).read()
new_block = open(src).read()

# ai-bouncer 섹션 앞에 삽입, 없으면 파일 끝에 추가
bouncer_idx = content.find('\n# ---')
if bouncer_idx != -1:
    content = content[:bouncer_idx + 1] + new_block + '\n\n' + content[bouncer_idx + 1:]
else:
    content = content.rstrip('\n') + '\n\n' + new_block + '\n'
open(target, 'w').write(content)
PYEOF
    echo "  $(msg '~/.claude/CLAUDE.md 규칙 추가' '~/.claude/CLAUDE.md rules added')"
  fi
}

_inject_rules "$GLOBAL_CLAUDE"

# --- SessionEnd / PostCompact 훅 등록 ---
if ! command -v jq >/dev/null 2>&1; then
  echo "  $(msg '경고: jq 없음 — 훅 스킵 (brew install jq 후 재설치 권장)' 'Warning: jq not found — hooks skipped (install jq and re-run)')"
elif grep -qF "library-sync" "$SETTINGS" 2>/dev/null; then
  echo "  $(msg '훅 이미 존재 — 스킵' 'Hooks already exist — skipped')"
else
  mkdir -p "$(dirname "$HOOK_DEST")"
  cp "$SCRIPT_DIR/hooks/library-sync.sh" "$HOOK_DEST"
  chmod +x "$HOOK_DEST"

  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak" || echo "{\"hooks\":{}}" > "$SETTINGS"

  HOOK_JSON="{\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK_DEST\",\"timeout\":30}]}"
  jq --argjson hook "$HOOK_JSON" '
    .hooks.SessionEnd = (.hooks.SessionEnd // []) + [$hook] |
    .hooks.PostCompact = (.hooks.PostCompact // []) + [$hook]
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

  echo "  $(msg 'SessionEnd / PostCompact 훅 등록' 'SessionEnd / PostCompact hooks registered')"
fi

# --- Stop hook: library 저장 체크 ---
SAVE_CHECK_DEST="$CLAUDE_DIR/hooks/library-save-check.sh"

if grep -qF "library-save-check" "$SETTINGS" 2>/dev/null; then
  echo "  $(msg 'library-save-check 훅 이미 존재 — 스킵' 'library-save-check hook already exists — skipped')"
elif ! command -v jq >/dev/null 2>&1; then
  echo "  $(msg '경고: jq 없음 — Stop 훅 스킵' 'Warning: jq not found — Stop hook skipped')"
else
  cp "$SCRIPT_DIR/hooks/library-save-check.sh" "$SAVE_CHECK_DEST"
  chmod +x "$SAVE_CHECK_DEST"

  SAVE_CHECK_JSON="{\"hooks\":[{\"type\":\"command\",\"command\":\"$SAVE_CHECK_DEST\",\"timeout\":10}]}"
  jq --argjson hook "$SAVE_CHECK_JSON" '
    .hooks.Stop = (.hooks.Stop // []) + [$hook]
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

  echo "  $(msg 'Stop 훅 등록: library-save-check.sh' 'Stop hook registered: library-save-check.sh')"
fi

# --- SessionStart 자동 업데이트 체크 훅 등록 ---
UPDATE_CHECK_DEST="$CLAUDE_DIR/hooks/learnings-update-check.sh"

if grep -qF "learnings-update-check" "$SETTINGS" 2>/dev/null; then
  echo "  $(msg '자동 업데이트 훅 이미 존재 — 스킵' 'Auto-update hook already exists — skipped')"
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
echo "learnings-for-claude $INSTALLED_SHA → $LATEST_SHA updated"
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

  echo "  $(msg 'SessionStart 자동 업데이트 체크 등록' 'SessionStart auto-update check registered')"
fi

# --- session-review 스킬 설치 ---
SKILL_DIR="$CLAUDE_DIR/skills/session-review"
if [ -d "$SKILL_DIR" ]; then
  echo "  $(msg 'session-review 스킬 이미 존재 — 스킵' 'session-review skill already exists — skipped')"
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
**도서관에서 책을 정리하듯, 지식의 주제(도메인) 기준으로 분류한다.**
- "이 지식이 무엇에 관한 것인지"로 판단. CLAUDE.md 목차에서 가장 가까운 카테고리 선택, 없으면 새로 생성
- ❌ `kaggle/`, `spring/`, `claude/` 같은 도구명/플랫폼명 카테고리 금지

### 파일 작성 순서
1. `~/.claude/.claude-library/library/[카테고리]/[주제]/[파일명].md` 생성
2. 주제 `index.md` 생성 또는 업데이트 + `관련:` 태그 추가 (관련 주제가 있으면)
3. `~/.claude/.claude-library/LIBRARY.md` 업데이트
4. `~/.claude/CLAUDE.md` 목차에 새 주제 추가 (없으면)

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
  echo "  $(msg 'session-review 스킬 설치' 'session-review skill installed')"
fi

# --- update-learnings 스킬 설치 ---
SKILL_DIR="$CLAUDE_DIR/skills/update-learnings"
if [ -d "$SKILL_DIR" ]; then
  echo "  $(msg 'update-learnings 스킬 이미 존재 — 스킵' 'update-learnings skill already exists — skipped')"
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
  echo "  $(msg 'update-learnings 스킬 설치' 'update-learnings skill installed')"
fi

# --- code-lesson 스킬 설치 ---
SKILL_DIR="$CLAUDE_DIR/skills/code-lesson"
if [ -d "$SKILL_DIR" ]; then
  echo "  $(msg 'code-lesson 스킬 이미 존재 — 업데이트' 'code-lesson skill already exists — updating')"
fi
mkdir -p "$SKILL_DIR"
cp "$SCRIPT_DIR/skills/code-lesson/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "  $(msg 'code-lesson 스킬 설치' 'code-lesson skill installed')"

# --- code-lesson Stop hook 등록 ---
CODE_LESSON_DEST="$CLAUDE_DIR/hooks/code-lesson-check.sh"

if grep -qF "code-lesson-check" "$SETTINGS" 2>/dev/null; then
  echo "  $(msg 'code-lesson-check 훅 이미 존재 — 스킵' 'code-lesson-check hook already exists — skipped')"
elif ! command -v jq >/dev/null 2>&1; then
  echo "  $(msg '경고: jq 없음 — code-lesson 훅 스킵' 'Warning: jq not found — code-lesson hook skipped')"
else
  cp "$SCRIPT_DIR/hooks/code-lesson-check.sh" "$CODE_LESSON_DEST"
  chmod +x "$CODE_LESSON_DEST"

  CODE_LESSON_JSON="{\"hooks\":[{\"type\":\"command\",\"command\":\"$CODE_LESSON_DEST\",\"timeout\":10}]}"
  jq --argjson hook "$CODE_LESSON_JSON" '
    .hooks.Stop = (.hooks.Stop // []) + [$hook]
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

  echo "  $(msg 'Stop 훅 등록: code-lesson-check.sh' 'Stop hook registered: code-lesson-check.sh')"
fi

# --- MCP 서버 등록 ---
if command -v jq >/dev/null 2>&1; then
  if python3 -m json.tool "$SETTINGS" 2>/dev/null | grep -q "claude-library-mcp\|claude-library"; then
    echo "  $(msg 'MCP claude-library 이미 존재 — uvx로 업데이트' 'MCP claude-library already exists — updating via uvx')"
  fi
  jq '.mcpServers["claude-library"] = {
    "command": "uvx",
    "args": ["claude-library-mcp"],
    "env": {"LIBRARY_ROOT": ($home + "/.claude/.claude-library")}
  }' --arg home "$HOME" "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "  $(msg 'MCP 서버 등록: claude-library-mcp (uvx)' 'MCP server registered: claude-library-mcp (uvx)')"
fi

# --- permissions: library 경로 허용 ---
if command -v jq >/dev/null 2>&1; then
  if jq -e '.permissions.allow // [] | map(select(test("claude-library"))) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
    echo "  $(msg 'library 경로 권한 이미 존재 — 스킵' 'Library path permissions already exist — skipped')"
  else
    jq '
      .permissions.allow = ((.permissions.allow // []) + [
        "Write(~/.claude/.claude-library/**)",
        "Edit(~/.claude/.claude-library/**)"
      ] | unique)
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    echo "  $(msg 'library 경로 Write/Edit 권한 등록' 'Library path Write/Edit permissions registered')"
  fi
fi

# --- Library Notion 연동 (선택) ---
echo ""
printf "$(msg 'Library를 Notion에도 연동할까요?' 'Sync Library to Notion?') [y/N]: "
read -r notion_lib </dev/tty

if [ "$notion_lib" = "y" ] || [ "$notion_lib" = "Y" ]; then
  # notion-library 스크립트 복사
  NOTION_LIB_SCRIPT="$CLAUDE_DIR/scripts/notion-library.sh"
  NOTION_LIB_CREATE="$CLAUDE_DIR/scripts/notion-library-create-db.sh"
  NOTION_LIB_MIGRATE="$CLAUDE_DIR/scripts/notion-library-migrate.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  cp "$SCRIPT_DIR/scripts/notion-library.sh" "$NOTION_LIB_SCRIPT"
  cp "$SCRIPT_DIR/scripts/notion-library-create-db.sh" "$NOTION_LIB_CREATE"
  cp "$SCRIPT_DIR/scripts/notion-library-migrate.sh" "$NOTION_LIB_MIGRATE"
  chmod +x "$NOTION_LIB_SCRIPT" "$NOTION_LIB_CREATE" "$NOTION_LIB_MIGRATE"

  # NOTION_TOKEN 확인
  NOTION_TOKEN=""
  for _envfile in "$HOME/.claude/.env" ${AI_WORKLOG_DIR:+"$AI_WORKLOG_DIR/.env"}; do
    if [ -f "$_envfile" ]; then
      _val=$(grep -E '^NOTION_TOKEN=' "$_envfile" 2>/dev/null | tail -1 | cut -d'=' -f2-)
      [ -n "$_val" ] && NOTION_TOKEN="$_val"
    fi
  done

  if [ -z "$NOTION_TOKEN" ]; then
    echo "  $(msg 'NOTION_TOKEN이 필요합니다.' 'NOTION_TOKEN is required.')"
    echo "  $(msg 'Notion 통합 페이지에서 Internal Integration Token을 발급받으세요.' 'Get an Internal Integration Token from Notion integrations page.')"
    printf "  NOTION_TOKEN: "
    read -r NOTION_TOKEN </dev/tty
    if [ -n "$NOTION_TOKEN" ]; then
      echo "NOTION_TOKEN=$NOTION_TOKEN" >> "$HOME/.claude/.env"
      echo "  $(msg '~/.claude/.env에 NOTION_TOKEN 저장' 'NOTION_TOKEN saved to ~/.claude/.env')"
    fi
  else
    echo "  $(msg 'NOTION_TOKEN 감지됨' 'NOTION_TOKEN detected')"
  fi

  if [ -n "$NOTION_TOKEN" ]; then
    echo ""
    echo "  $(msg 'Library DB를 어떻게 설정할까요?' 'How would you like to set up the Library DB?')"
    echo "    1) $(msg '새 DB 자동 생성 (Notion 페이지 ID 필요)' 'Create new DB automatically (Notion page ID required)')"
    echo "    2) $(msg '기존 DB ID 직접 입력' 'Enter existing DB ID')"
    printf "  $(msg '선택' 'Select') [1/2]: "
    read -r db_choice </dev/tty

    LIBRARY_NOTION_DB_ID=""
    if [ "$db_choice" = "1" ]; then
      echo "  $(msg 'DB를 생성할 Notion 페이지의 ID를 입력하세요.' 'Enter the Notion page ID where the DB will be created.')"
      echo "  $(msg '(페이지 URL의 마지막 32자리 또는 하이픈 포함 ID)' '(Last 32 characters of the page URL, or hyphenated ID)')"
      printf "  $(msg '페이지 ID' 'Page ID'): "
      read -r page_id </dev/tty
      if [ -n "$page_id" ]; then
        LIBRARY_NOTION_DB_ID=$(NOTION_TOKEN="$NOTION_TOKEN" bash "$NOTION_LIB_CREATE" "$page_id" 2>/dev/null) || true
        if [ -n "$LIBRARY_NOTION_DB_ID" ]; then
          echo "  $(msg 'DB 생성 완료' 'DB created'): $LIBRARY_NOTION_DB_ID"
        else
          echo "  $(msg 'DB 생성 실패. 나중에 수동으로 설정할 수 있습니다.' 'DB creation failed. You can configure it manually later.')"
        fi
      fi
    elif [ "$db_choice" = "2" ]; then
      printf "  Library Notion DB ID: "
      read -r LIBRARY_NOTION_DB_ID </dev/tty
    fi

    # settings.json에 LIBRARY_NOTION_DB_ID 추가
    if [ -n "$LIBRARY_NOTION_DB_ID" ] && command -v jq >/dev/null 2>&1; then
      jq --arg dbid "$LIBRARY_NOTION_DB_ID" '.env.LIBRARY_NOTION_DB_ID = $dbid' \
        "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
      echo "  $(msg 'settings.json에 LIBRARY_NOTION_DB_ID 등록' 'LIBRARY_NOTION_DB_ID registered in settings.json')"
      echo ""
      echo "  $(msg 'Notion 연동 완료! Library 저장 시 Notion에도 자동 동기화됩니다.' 'Notion sync enabled! Library entries will auto-sync to Notion.')"

      # 기존 library 파일이 있으면 마이그레이션 제안
      EXISTING_COUNT=$(find "$LIB_DIR/library" -name '*.md' -type f \
        ! -name '_template.md' ! -name 'index.md' 2>/dev/null | wc -l | tr -d ' ')
      if [ "$EXISTING_COUNT" -gt 0 ]; then
        echo ""
        printf "  $(msg "기존 library 파일 ${EXISTING_COUNT}개를 Notion에 마이그레이션할까요?" "Migrate ${EXISTING_COUNT} existing library files to Notion?") [y/N]: "
        read -r migrate_choice </dev/tty
        if [ "$migrate_choice" = "y" ] || [ "$migrate_choice" = "Y" ]; then
          LIBRARY_NOTION_DB_ID="$LIBRARY_NOTION_DB_ID" bash "$NOTION_LIB_MIGRATE" "$LIB_DIR"
        fi
      fi
    fi
  fi
fi

echo ""

# --- 프로젝트 디렉토리 스캔 ---
echo ""
echo "$(msg '로컬 프로젝트를 스캔하여 library에 등록할 수 있습니다.' 'You can scan local projects and register them in the library.')"
echo "$(msg '프로젝트가 있는 디렉토리를 입력하세요 (예: ~/programming).' 'Enter the directory containing your projects (e.g., ~/programming).')"
printf "$(msg '디렉토리 경로 [스킵하려면 Enter]' 'Directory path [Enter to skip]'): "
read -r project_root </dev/tty

if [ -n "$project_root" ]; then
  project_root="${project_root/#\~/$HOME}"
  if [ -d "$project_root" ]; then
    PROJECT_LIB="$LIB_DIR/library/projects/local"
    mkdir -p "$PROJECT_LIB"
    INDEX_FILE="$PROJECT_LIB/index.md"

    echo "# $(msg '로컬 프로젝트 디렉토리' 'Local Project Directory')" > "$INDEX_FILE"
    echo "" >> "$INDEX_FILE"
    echo "## $(msg '요약' 'Summary')" >> "$INDEX_FILE"
    echo "$(msg "$project_root 아래 활성 프로젝트 목록과 경로." "Active projects under $project_root.")" >> "$INDEX_FILE"
    echo "" >> "$INDEX_FILE"

    CUTOFF=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d 2>/dev/null)
    for dir in "$project_root"/*/; do
      [ -d "$dir/.git" ] || continue
      name=$(basename "$dir")
      last=$(git -C "$dir" log -1 --format="%ai" 2>/dev/null | cut -d' ' -f1)
      [ -z "$last" ] && continue
      if [[ "$last" > "$CUTOFF" ]] || [[ "$last" = "$CUTOFF" ]]; then
        desc=$(head -5 "$dir/README.md" 2>/dev/null | grep -v '^#' | grep -v '^$' | grep -v '^<' | head -1)
        [ -z "$desc" ] && desc="$(msg '(설명 없음)' '(no description)')"
        echo "- \`$dir\` — $desc" >> "$INDEX_FILE"
      fi
    done

    # LIBRARY.md에 projects 카테고리 추가
    if ! grep -qF "## projects" "$LIB_DIR/LIBRARY.md" 2>/dev/null; then
      echo "" >> "$LIB_DIR/LIBRARY.md"
      echo "## projects" >> "$LIB_DIR/LIBRARY.md"
      echo "- [local](library/projects/local/index.md) — $(msg '로컬 프로젝트 디렉토리 및 경로' 'Local project directories and paths')" >> "$LIB_DIR/LIBRARY.md"
    fi

    # CLAUDE.md 목차에 projects 추가
    if grep -qF "### 목차" "$GLOBAL_CLAUDE" 2>/dev/null && ! grep -qF "projects:" "$GLOBAL_CLAUDE" 2>/dev/null; then
      sed -i '' '/^- projects:/d' "$GLOBAL_CLAUDE" 2>/dev/null
      python3 - "$GLOBAL_CLAUDE" << 'PYEOF'
import sys
f = sys.argv[1]
lines = open(f).readlines()
inserted = False
for i in range(len(lines)-1, -1, -1):
    if lines[i].startswith("- ") and "### 목차" in ''.join(lines[max(0,i-10):i]):
        lines.insert(i+1, "- projects: local\n")
        inserted = True
        break
if inserted:
    open(f, 'w').writelines(lines)
PYEOF
    fi

    count=$(grep -c '^\- ' "$INDEX_FILE" 2>/dev/null || echo 0)
    echo "  $(msg "프로젝트 ${count}개 스캔 완료" "${count} projects scanned")"

    # git repo면 커밋
    if [ -d "$LIB_DIR/.git" ]; then
      git -C "$LIB_DIR" add -A
      git -C "$LIB_DIR" commit -q -m "feat: local project directory added" 2>/dev/null || true
      git -C "$LIB_DIR" push -q 2>/dev/null || true
    fi
  else
    echo "  $(msg "경고: $project_root 디렉토리 없음 — 스킵" "Warning: $project_root not found — skipped")"
  fi
fi

echo ""
echo "$(msg '완료.' 'Done.')"
echo "  library: ~/.claude/.claude-library/library/"
echo "  index:   ~/.claude/.claude-library/LIBRARY.md"
