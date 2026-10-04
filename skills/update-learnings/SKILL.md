---
description: learnings-for-claude 최신 버전 확인 및 업데이트
---

# /update-learnings

## 플로우

1. update-check.sh 경로 탐색:
   - `~/.claude/hooks/learnings-update-check.sh`
   - 없으면 "learnings-update-check.sh를 찾을 수 없습니다. install.sh를 먼저 실행하세요." 출력 후 종료
2. `bash "$HOME/.claude/hooks/learnings-update-check.sh" --check-only` 로 현재/최신 버전 확인
3. 결과 출력:
   - `up-to-date` → "최신 버전입니다 (SHA)" 출력 후 종료
   - `update-available` → 현재/최신 SHA 보여주고 업데이트 여부 확인
4. 업데이트 확인 시 `bash "$HOME/.claude/hooks/learnings-update-check.sh" --force` 실행
5. 완료 메시지 출력

## 브랜치 선택

사용자가 브랜치를 지정하면 검사와 적용 명령에 `--branch <name>`을 전달한다.
예: `bash "$HOME/.claude/hooks/learnings-update-check.sh" --branch feat/pg-multiuser-kb --check-only`.
적용: `bash "$HOME/.claude/hooks/learnings-update-check.sh" --branch feat/pg-multiuser-kb --force`.
`--branch main`은 저장된 브랜치를 삭제하고 MCP를 PyPI 배포판으로 복원한다.
`LEARNINGS_BRANCH`는 저장된 값보다 우선하며 파일에는 저장하지 않는다.
버전은 `branch@sha`이며 구형 SHA 단독 표기는 main으로 해석한다.
