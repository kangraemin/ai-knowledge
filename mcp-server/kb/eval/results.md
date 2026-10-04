# 실제 라이브러리 검색 평가 — 키워드 회귀 수정

측정일: 2026-10-04 (Asia/Seoul). files 검색 로직은 수정하지 않았다.

고정 test 23개에서 **postgres/none R@5 13.04% → 39.13% (3 → 9건)**로 files의 13.04% (3건)를 넘었다. fastembed R@5는 21.74% → 43.48% (5 → 10건). 단 hybrid R@1은 13.04% → 8.70% (3 → 2건)로 하락했다. 이 결과를 확인한 뒤 검색 구현을 다시 조정하지 않았다.

## 고정 분할과 측정 절차

- 원래 45개 질의와 정답은 그대로 두고 `split`만 추가했다. 원래 순서의 인덱스를 `random.Random(20261004).shuffle`로 섞어 앞 22개를 dev, 나머지 23개를 test로 고정했다. 정답 기반 층화나 재분할은 하지 않았다.
- 기존 검색으로 before를 측정하고 test 지표·순위는 파일에만 저장했다. 이후 후보 3개는 dev만 측정했다. 최종 검색 코드를 고정하고 전체 after를 측정한 후 처음으로 test 결과를 열었다.
- 이미 전체 45개에 대한 기존 평가가 있던 자료의 사후 분할이다. 새로운 외부 평가셋이나 완전히 독립적인 blind holdout이라고 주장하지 않는다. 23개 test의 개선을 다른 데이터에 일반화하지 않는다.
- 질의마다 정답 경로 1개. R@1/R@5는 상위 1/5개 포함 비율, MRR@7은 양쪽 기본 상위 7개에서 계산한다. 미검색은 0점.
- 원본 `~/claude-library`는 읽기 전용. DB `127.0.0.1:54329/kb_dev`에 일반 사용자 `kb_eval`로 연결했다. files는 knowledge 725개, PG는 knowledge 725개 + decision 9개. 후보 범위 차이는 before/after 동일하다.
- PostgreSQL 17.11 / pg_bigm 1.2 / vector 0.8.7 / pg_trgm 1.6. fastembed 모델은 기존 `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`(384차원), 저장된 3,715개 임베딩을 재사용했다. fake 모델은 사용하지 않았다. 평가 중 재import나 재임베딩을 하지 않았고 검색 이벤트는 rollback했다.

## Before / after — dev와 test

| 분할 | 백엔드 | 상태 | n | R@1 | R@5 | MRR@7 |
|---|---|---|---:|---:|---:|---:|
| dev | files / none | before | 22 | 0.1364 (3/22) | 0.1818 (4/22) | 0.1591 |
| dev | files / none | after | 22 | 0.1364 (3/22) | 0.1818 (4/22) | 0.1591 |
| dev | postgres / none | before | 22 | 0.0000 (0/22) | 0.0909 (2/22) | 0.0379 |
| dev | postgres / none | after | 22 | 0.0909 (2/22) | 0.2727 (6/22) | 0.1515 |
| dev | postgres / fastembed | before | 22 | 0.1364 (3/22) | 0.3182 (7/22) | 0.1913 |
| dev | postgres / fastembed | after | 22 | 0.2727 (6/22) | 0.4091 (9/22) | 0.3285 |
| test | files / none | before | 23 | 0.0435 (1/23) | 0.1304 (3/23) | 0.0870 |
| test | files / none | after | 23 | 0.0435 (1/23) | 0.1304 (3/23) | 0.0870 |
| test | postgres / none | before | 23 | 0.0000 (0/23) | 0.1304 (3/23) | 0.0543 |
| test | postgres / none | after | 23 | 0.3043 (7/23) | 0.3913 (9/23) | 0.3239 |
| test | postgres / fastembed | before | 23 | 0.1304 (3/23) | 0.2174 (5/23) | 0.1671 |
| test | postgres / fastembed | after | 23 | 0.0870 (2/23) | 0.4348 (10/23) | 0.2297 |

전체 45개 R@5: files 15.56% → 15.56%, PG/none 11.11% → 33.33%, PG/fastembed 26.67% → 42.22%. 전체 수치는 참고용이며 후보 선택에는 dev만 사용했다.

| 전체 45질의 총 시간 | before | after |
|---|---:|---:|
| files / none | 3.160s | 3.227s |
| postgres / none | 86.245s | 2.747s |
| postgres / fastembed | 88.148s | 4.070s |

PG/none 평균은 1.917초 → 0.061초. 단일 실행의 wall time이며 캐시, 로컬 부하, 모델 초기화 영향을 포함한다. 동시 pytest 실행도 있었으므로 엄밀한 성능 벤치마크나 hook 5초 SLA 보장은 아니다.

## 원인과 변경

1. **공백 분리만 하던 질의 처리**: 대소문자와 마지막 `?`·`.`가 매칭을 막고, 영문 기능어·짧은 단어가 후보를 오염시켰다. 소문자·문장부호 정규화, 중복 제거, 고정 영문 기능어 목록, 한글 단어의 일반 조사 제거를 적용했다. 한 글자 토큰은 더 긴 토큰이 있을 때 제외한다. ASCII는 단어 경계를 요구해 `DB`가 `IMDb`에 매칭되지 않게 했다. 혼합 한영 조사와 모든 한국어 활용형을 처리하는 형태소 분석기는 아니다.
2. **bigram 유사도의 길이 편향**: 짧은 검색어를 긴 청크/제목+설명 전체와 비교해 긴 정답이 불리했다. 실측 `bigm_similarity(사과, 사과)=1.0`, 관련 문장을 길게 붙인 본문은 0.15이고 현재 `similarity_limit=0.3`이었다. LIKE 분기가 있으므로 임계값이 정확히 포함된 단어의 후보를 전부 제거하는 것은 아니지만, 점수는 여전히 전체 문자열 유사도에 좌우됐다. 임계값을 dev에 맞춰 낮추는 대신 키워드 단계의 `=%`/유사도 정렬을 제거했다.
3. **필드와 증거 가중치**: 기존 누락된 path/tags를 포함하고 title 6, path 5, description 4, tags 3, body 1의 최대 필드 가중치를 단어마다 사용한다. `ln(1 + 접근 가능한 문서 수 / 해당 단어가 매칭된 문서 수)`를 곱하고 합산한 뒤 매칭한 고유 단어 수를 곱한다. 문서 길이나 단순 반복 횟수를 점수로 삼지 않는다. 가중치 격자 탐색은 하지 않았다.
4. **청크 중복과 잘린 문맥**: 기존 50청크 선별 후 문서 집계는 dev 첫 세 질의에서 실제로 27/23/25개 문서만 남겼다. 이제 키워드는 문서 본문 전체에서 단어를 모아 점수를 내고 상위 50문서를 뽑는다. 섹션이 다른 단어들도 함께 기여하며 동일 문서의 청크 수가 후보 슬롯을 차지하지 않는다.
5. **권한과 하이브리드 유지**: RLS 및 deprecated/supersedes/scope/kind/repo 필터를 먼저 적용한 문서만 점수·IDF 계산에 사용한다. semantic 검색(50청크→문서 집계), 모델, RRF `k=60`은 그대로다.

pg_bigm의 LIKE/likequery, 유사도 및 임계값 동작은 [공식 문서](https://pgbigm.github.io/pg_bigm/pg_bigm_en.html)에서 확인했다. 원시 원인 측정은 [diagnostics.json](diagnostics.json). 새 검색은 `lower()`와 문서별 스캔을 사용하며 기존 대소문자 구분 GIN 인덱스를 이용한다고 주장하지 않는다. 더 큰 코퍼스의 인덱싱·응답시간은 별도 검증이 필요하다.

## Dev 후보 선택 기록

| 후보 | dev R@1 | dev R@5 | dev MRR@7 |
|---|---:|---:|---:|
| 문서 단위·필드/IDF·짧은 ASCII 경계 | 0.0455 | 0.2273 | 0.1061 |
| 모든 ASCII 경계·긴 토큰이 있으면 한 글자 제외 | 0.0455 | 0.2273 | 0.1136 |
| 영문 기능어·일반 한글 조사 처리 (최종) | 0.0909 | 0.2727 | 0.1515 |

후보 원시 기록: [candidate.json](candidate.json), [candidate-boundaries.json](candidate-boundaries.json), [candidate-prose.json](candidate-prose.json). dev의 R@1과 MRR은 최종에도 files보다 낮다. test의 hybrid R@1 하락 역시 숨기지 않는다.

## 재현과 검증

레포 루트에서 기존 import/임베딩이 준비된 DB로 실행한다. 원본 files 경로는 같은 라이브러리를 지정한다.

```sh
export LIBRARY_ROOT=~/claude-library
export LIBRARY_DATABASE_URL=postgresql://kb_eval@127.0.0.1:54329/kb_dev
uv run --project mcp-server --extra postgres --extra embed python -m kb.eval.compare --baseline --label rerun-before
uv run --project mcp-server --extra postgres --extra embed python -m kb.eval.compare --label rerun-after
# 개발 중에는 test를 실행하지 않는다:
uv run --project mcp-server --extra postgres --extra embed python -m kb.eval.compare --label dev-only --split dev
# 단일 백엔드도 분할 지정 가능:
LIBRARY_EMBED_PROVIDER=none uv run --project mcp-server --extra postgres claude-library-kb eval --backend postgres --split test
KB_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:54329/kb_test uv run --project mcp-server --extra postgres --extra embed --with pytest python -m pytest mcp-server/tests -q
```

`44 passed in 7.30s`. 추가 검증은 ASCII 경계/경로/대소문자, 중복 청크가 50개 후보를 독점하는 회귀, 섹션 간 문서 점수, 고정 분할 재현 및 반대 분할의 검색 미실행이다. 기존 RLS·필터·제목 전용 문서·하이브리드 테스트도 통과했다.

원시 순위·지표·평가셋(질의 원문과 정답 경로)은 비공개 라이브러리 내용에서 만들어졌으므로 이 공개 레포가 아니라 `$LIBRARY_ROOT/eval/search/` 에 둔다 (before.json, after.json, measurements.json, validation.txt, queries.jsonl). 재측정 가능한 변경 전 검색은 [search_before.py](search_before.py)에 동결했다. 해당 파일은 평가 전용이며 서비스에서 호출하지 않는다.

최종 검색 SHA-256: `ddfb05a9353a747748271c1f389f7b9ed2d23f761d632ecd14af044efd5d74d3`.

## 이전 import / 왕복 검증 기록

최초 734개를 삽입했다. 범위 밖 `decisions/DECISIONS-GUIDE.md`를 잘못 집계한 문제를 수정한 최종 실행 결과:

```text
IMPORT {"files": 734, "insert": 0, "update": 0, "skip": 734, "failed": 0, "errors": []}
REIMPORT {"files": 734, "insert": 0, "update": 0, "skip": 734, "failed": 0, "errors": []}
ROUNDTRIP 734 734
EMBEDDED 0
```

실제 자료 734개 전부의 프론트매터 값 동등성과 본문 문자열(공백·개행 포함) 동등성을 확인했다. export 및 캐시는 임시 HOME으로만 기록했다. 최초 임베딩 3,715개 생성은 88.144초였으며 최종 평가에서는 이를 재사용했다.

위 import/왕복 검증은 이전 작업의 기록이다. 이번 작업은 이미 준비된 DB를 사용한 검색 재측정이며 import/export를 다시 수행하지 않았다. hooks/, install.sh 및 files 백엔드 소스는 변경하지 않았다.
