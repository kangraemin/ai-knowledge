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

`calls`에는 library_search 질의, library_read 경로, decision_* 횟수, 라이브러리 안의 Write/Edit 경로를 기록한다. 도구 호출은 시도 횟수다. 읽기 실패도 호출률에 포함된다. 검색 노출은 도구 결과에 실제 나타난 문서 경로로만 판정한다. 결과가 없거나 실패하면 `search_unknown`에 남기며 빈 검색으로 단정하지 않는다. 파일 인벤토리에서 제목·본문을 읽고 코퍼스 IDF 커버리지 점수 및 `LIBRARY_AUTOINJECT_MIN_SCORE`를 적용한다. 이 오프라인 평가는 네트워크 검색이나 검색 활동 로그를 발생시키지 않는다.

`cited`는 후보 문서의 경로·파일명·제목이 assistant 텍스트에 나타난 문자열과 `📚 library 참조` 표기를 보존한다. `cited_paths`는 문서별 집계용이다. 표기만 있고 특정 문서 증거가 없으면 hit_used로 세지 않는다. 제목·설명에서 문서 빈도 10% 이하인 고IDF 핵심어를 최대 8개 뽑고, 그중 50% 이상이면서 최소 3개가 정규화된 답변에 나타나도 인정한다. `cited_evidence`는 `path`/`filename`/`title`/`keywords` 신호와 일치한 단어·분모·비율을 기록한다. 이는 유용성의 휴리스틱이며 실제 이해·적용이나 인과적 효과를 증명하지 않는다. 동명 파일·동일 제목·어휘만 겹친 답변은 오탐 가능하고 의역은 여전히 놓칠 수 있다.

## 라벨

라벨은 상호 배타적이지 않다.

| 라벨 | 조건 |
| --- | --- |
| hit_used | 주입·검색·읽기 후보 문서가 assistant 텍스트에서 인용됨 |
| hit_unused | 주입·검색 노출이 있지만 library_read도 문서 인용도 없음 |
| missed | 오프라인 최고 점수가 주입 임계값 이상이고 주입·library_search·library_read 모두 없음 |
| searched_empty | 검색했고 결과가 모두 확인됐지만 결과 0개 또는 모든 점수가 임계값 미만 |
| duplicate_write | 성공한 Write 결과에 신규 생성 증거가 있고, 이번 턴 작성 문서를 제외한 기존 문서와 제목/설명 대칭 IDF 유사도가 0.045 이상 |
| no_need | 오프라인 최고 점수가 임계값 미만이고 주입·검색·읽기 없음 |
| parse_error | transcript 분석 불가 또는 훅 실행 실패/시간 초과 |

Write는 덮어쓰기일 수도 있어 생성 증거가 없으면 duplicate_write 판정을 보류한다. Edit는 신규 작성으로 보지 않는다. 이번 턴 작성 문서는 opportunity 후보에서도 제외한다. 이미 삭제된 문서, 로컬에 없는 postgres 문서는 현재 파일 인벤토리 기반 평가에서 누락될 수 있다.

## 보고서 분모

parse_error 턴은 오류 수로 별도 표시하고 비율 분모에서 제외한다. 분모가 0이면 rate는 null이다.

- 호출률: 주입 또는 검색 또는 읽기가 있는 턴 / 유효 턴.
- 주입 인용률(`injection_citation_rate`): 실제 주입된 문서가 인용된 턴 / 주입 턴. 검색으로 따로 읽은 문서의 인용은 분자에 넣지 않는다. `injection_precision`은 기존 클라이언트를 위한 deprecated 별칭이며 관련성 정밀도가 아니다.
- 주입 관련성 정밀도: 수작업 정답 문서가 실제 주입 결과에 포함된 턴 / 주입 턴. 오프라인 라벨로만 평가하며 인용 여부와 분리한다.
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

## 점수와 평가

검색 점수는 접근 가능한 전체 코퍼스의 IDF 가중 커버리지다. 제목 1, 설명 0.85, 태그 0.65, 경로 0.5, 본문 0.2 중 단어별 최댓값을 쓴다. 문서 빈도가 높은 어휘는 감쇠하고, 중복 질의어·불용어·조사·흔한 어미를 정규화한다. 코퍼스에 없는 어휘는 증거에 넣지 않는다. 장문은 전체 질의 커버리지와 문장별 최고 커버리지의 기하평균으로 문맥을 유지한다. 반복 문장은 점수를 누적하지 않는다. 알려진 어휘 하나뿐인 질의의 점수는 0.02 이하로 제한한다. 기본 주입 임계값은 files/postgres 모두 0.085다. 점수는 확률이 아니다.

중복 후보는 경로·본문을 제외하고 제목·설명의 양방향 IDF 커버리지 조화평균으로 계산한다. 미등록 어휘도 분모에 포함한다. 임계값은 검색과 독립적인 0.045이며, 연작의 검토 후보를 찾는 값이다. 자동 삭제나 중복 확정에 사용하지 않는다.

`python -m kb.eval.stress`는 `--queries`, `--long`, `--real`, `--pairs`의 비공개 JSONL 입력을 읽고 집계만 출력한다. `--split dev --calibrate`에서 `--thresholds` 파일을 새로 만들고, `--split test`는 그 값을 읽기만 한다. `--output`도 배타적 생성으로 기존 평가를 덮어쓰지 않는다. 8자 미만/명령 스킵, 1,500바이트 예산까지 포함한다. `--audit`은 수작업 사용 여부와 인용 신호의 일치율을 추가한다. 임계값을 고정했어도 test를 본 뒤 구현을 수정했다면 독립 holdout이라고 주장하지 않는다.

IDF 방식의 근거는 [scikit-learn 공식 문서](https://scikit-learn.org/stable/modules/feature_extraction.html#tfidf-term-weighting)를 참조했다. 위 필드 가중치·문장 결합·게이트는 이 구현의 휴리스틱이며 해당 문서가 보장하는 정확도가 아니다. 파일 백엔드는 최상위 프론트매터 제목만 읽어 중첩 출처 제목의 덮어쓰기를 방지한다. 전체 YAML 구문을 지원하는 파서는 아니다.
