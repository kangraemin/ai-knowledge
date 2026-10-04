# 라이브러리 사용 관측

`library-usage-log.sh`는 Stop의 비동기 훅용이다. 등록은 설치 스크립트에서 담당하며 훅은 stdout을 출력하지 않고 항상 0으로 종료한다. `LIBRARY_USAGE_LOG=off` 또는 `LIBRARY_LOG=0`은 분석과 기록 모두 끈다. 명령 해석 순서는 `LIBRARY_KB_CMD` → PATH의 `claude-library-kb` → `~/.claude/hooks/.learnings-kb-spec`의 `uvx --with 'mcp<2' --from SPEC claude-library-kb`다.

```sh
claude-library-kb usage-log --transcript /tmp/example.jsonl --session example --cwd /tmp/project
claude-library-kb report --days 30 --format json
claude-library-kb report --days 7 --format md --save
```

기록은 `$LIBRARY_ROOT/.activity/usage-YYYY-MM.jsonl`, 저장 보고서는 `$LIBRARY_ROOT/eval/usage-report-YYYY-MM-DD.md`다. 기본 루트는 `~/claude-library`다. 기본 aggregate 모드는 프롬프트와 검색어의 SHA-256 앞 16자·길이만 저장한다. full 모드에서는 원문이 포함되므로 이 디렉터리를 공개 저장소에 추가하지 않는다. postgres 모드는 동일 레코드를 `kb.events(action='turn', payload)`에 저장한다. 006 마이그레이션은 컬럼만 추가하고 기존 RLS를 유지한다. DB 실패가 로컬 기록을 막지 않으며 미등록 DB 사용자는 기존 정책에 따라 기록할 수 없다.

## 턴과 증거

마지막 실제 user 텍스트/이미지 메시지부터 분석한다. `tool_result`와 `isMeta` 메시지는 새 프롬프트가 아니다. `message.content` 및 평탄한 `content`를 지원하고 도구 ID로 호출과 결과를 연결한다. 손상 JSONL·읽기 실패·분석 시간 초과는 `labels=["parse_error"]`로 남긴다. 분석 제한 18초, 훅 자식 프로세스 그룹 제한 19초로 전체 20초 이내 종료를 목표로 한다.

주입은 같은 session_id와 같은 질의(원문 또는 해시)의 최신 inject 이벤트를 결합한다. transcript timestamp가 있으면 턴 시작 30초 이전의 이벤트를 제외한다(주입 훅은 사용자 메시지 기록보다 먼저 실행될 수 있음). timestamp가 없거나 동일 프롬프트를 빠르게 반복하면 오결합 가능성이 있다.

`calls`에는 library_search 질의, library_read 경로, decision_* 횟수, 라이브러리 안의 Write/Edit 경로를 기록한다. 도구 호출은 시도 횟수다. 읽기 실패도 호출률에 포함된다. 검색 노출은 도구 결과에 실제 나타난 문서 경로로만 판정한다. 결과가 없거나 실패하면 `search_unknown`에 남기며 빈 검색으로 단정하지 않는다. 파일 인벤토리에서 제목·본문을 읽고 기존 `relevance.normalized` 점수 및 `LIBRARY_AUTOINJECT_MIN_SCORE`를 적용한다. 이 오프라인 평가는 네트워크 검색이나 검색 활동 로그를 발생시키지 않는다.

`cited`는 후보 문서의 경로·파일명·제목이 assistant 텍스트에 나타난 문자열과 `📚 library 참조` 표기를 보존한다. `cited_paths`는 문서별 집계용이다. 표기만 있고 특정 문서 증거가 없으면 hit_used로 세지 않는다. 이는 유용성의 휴리스틱이며 실제 이해·적용이나 인과적 효과를 증명하지 않는다. 동명 파일·동일 제목은 오탐 가능하다.

## 라벨

라벨은 상호 배타적이지 않다.

| 라벨 | 조건 |
| --- | --- |
| hit_used | 주입·검색·읽기 후보 문서가 assistant 텍스트에서 인용됨 |
| hit_unused | 주입·검색 노출이 있지만 library_read도 문서 인용도 없음 |
| missed | 오프라인 최고 점수가 주입 임계값 이상이고 주입·library_search·library_read 모두 없음 |
| searched_empty | 검색했고 결과가 모두 확인됐지만 결과 0개 또는 모든 점수가 임계값 미만 |
| duplicate_write | 성공한 Write 결과에 신규 생성 증거가 있고, 제목/설명 검색에서 이번 턴 작성 문서를 제외한 기존 문서가 임계값 2배 이상 |
| no_need | 오프라인 최고 점수가 임계값 미만이고 주입·검색·읽기 없음 |
| parse_error | transcript 분석 불가 또는 훅 실행 실패/시간 초과 |

Write는 덮어쓰기일 수도 있어 생성 증거가 없으면 duplicate_write 판정을 보류한다. Edit는 신규 작성으로 보지 않는다. 이번 턴 작성 문서는 opportunity 후보에서도 제외한다. 이미 삭제된 문서, 로컬에 없는 postgres 문서는 현재 파일 인벤토리 기반 평가에서 누락될 수 있다.

## 보고서 분모

parse_error 턴은 오류 수로 별도 표시하고 비율 분모에서 제외한다. 분모가 0이면 rate는 null이다.

- 호출률: 주입 또는 검색 또는 읽기가 있는 턴 / 유효 턴.
- 주입 정밀도: hit_used인 주입 턴 / 주입 턴.
- 검색 성공률: 검색 결과 경로를 읽거나 인용한 검색 턴 / 검색 턴.
- 누락률: missed 턴 / opportunity 최고 점수가 임계값 이상인 턴.
- 빈 검색 비율: searched_empty 턴 / 검색 턴.
- duplicate_write: 중복 후보 파일 건수와 일시·레포·매칭 경로 목록.
- 문서 Top 10: 턴별 중복을 제거한 노출·읽기·인용 횟수.
- 죽은 지식: 현재 활성 문서 중 기간 내 노출·읽기·인용이 전혀 없는 문서 / 현재 활성 문서. 기간 중 생성된 문서도 포함하므로 폐기 권고가 아니다.
- 카테고리 hit: 인용 경로의 카테고리/서브카테고리별 턴 수.
- 레포 분포: cwd 마지막 디렉터리명별 유효 턴 수(동명 레포는 합쳐짐).
- 지연: 턴 분석 실행 시간(ms) nearest-rank p50/p95. 모델 응답 시간은 아니다. `search_latency_ms`는 기존 검색/주입 이벤트의 실행 지연을 별도로 집계한다.
- 일별 추이: 턴·호출·missed·hit_used 수. 최근 missed 10건에는 프롬프트 앞 80자를 포함한다.

## 공식 확인 범위

[Claude Code Hooks reference — Stop input](https://code.claude.com/docs/en/hooks#stop-input)에서 Stop 입력의 `session_id`, `transcript_path`, `cwd`, `stop_hook_active`, `last_assistant_message`를 확인했다. 같은 문서의 [비동기 훅](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background)은 command 훅의 async 실행을 설명한다.

이 문서에는 transcript JSONL 내부 `message.content[].tool_use`/`tool_result`의 안정된 저장 스키마가 명시되지 않았다. **transcript 내부 구조는 공식 미확인**이며 합성 fixture로 호환 경로를 검증한다. Claude Code 버전에 따라 새 형식 지원이 필요할 수 있다.

턴 경계는 마지막 사람 프롬프트다. 명시된 `origin.kind=human`을 우선하며 구형 transcript에서는 메타·도구결과·알림·hook 피드백·중단 안내를 제외한다. 알림 뒤의 도구 호출과 응답도 같은 턴에 속한다. 같은 session_id와 프롬프트 UUID는 프로세스 잠금 아래 한 번만 저장하고 후속 Stop은 건너뛴다. 따라서 첫 Stop 이후 추가된 활동은 기존 레코드에 반영되지 않는다.
