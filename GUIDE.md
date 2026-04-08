# Library 작성 가이드

## 구조

카테고리 → 서브카테고리 → 주제 → 지식 파일 계층으로 구성한다.
분류 체계는 `TAXONOMY.md`를 따른다.

```
library/
  dev/                          ← 카테고리
    tooling/                    ← 서브카테고리
      claude-code/              ← 주제
        index.md                ← 주제 요약 + 하위 파일 목록
        hook-input-stdin.md     ← 지식 파일
        stop-hook-timing.md
      mcp-patterns/
        index.md
    testing/
      spring-isolation/
        index.md
  finance/
    crypto/                     ← 서브카테고리 (자산군)
      bb-rsi-longshort/         ← 주제 (전략명)
        index.md
    equity/
      cross-momentum/
        index.md
  ml/
    classification/             ← 서브카테고리 (기법)
      index.md
    time-series/
      index.md
```

### 분류 원칙

**TAXONOMY.md를 먼저 확인한다.** 매칭되는 카테고리/서브카테고리가 없으면 TAXONOMY.md에 먼저 추가 후 저장.

- ❌ 대회명: `kaggle-ts-forecasting/`, `birdclef/`
- ❌ 프로젝트명: `churn-prediction/`, `stock-bot/`
- ❌ 도구명을 카테고리로: `lgbm/`, `claude/`
- ✅ 기법/주제 기준: `time-series/`, `classification/`, `gradient-boosting/`
- ✅ 도메인 기준: `crypto/`, `equity/`, `testing/`

### 파일명 원칙

파일명은 **"뭘 배웠는지"**를 드러내야 한다.

- ❌ `discovery.md`, `backtest.md` (무슨 내용인지 알 수 없음)
- ❌ `churn-lessons.md` (프로젝트명)
- ✅ `ar1-lag-is-dominant-signal.md` (교훈이 드러남)
- ✅ `synthetic-data-distribution-overfit.md` (무슨 일이 있었는지 알 수 있음)

단, finance/ 하위 전략별 `backtest.md`는 폴더가 전략명이므로 OK.

### 주제 폴더
- 영어, 소문자, hyphen 구분
- 날짜 붙이지 않는다

---

## 언제 기록하나

- 실험/백테스트에서 뭔가 배웠을 때
- 아티클/논문에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때
- **개발 중 삽질로 알게 된 API/라이브러리 동작** — 에러로 발견한 것, 문서에 없는 것, 다음에 또 삽질할 것 같은 것. 발견 즉시 기록한다. 사용자가 요청하기 전에.
- 세션 종료/compact 시 — 위 경우를 놓쳤다면 그때 정리

---

## index.md 형식

주제에 대해 현재 알고 있는 것을 요약한다. 지식이 추가될 때마다 업데이트.

```markdown
# [주제명]

관련: category/subcategory/topic-a, category/subcategory/topic-b

## 요약
현재까지 알고 있는 것. 핵심 내용.

## 지식 목록
- [file.md](file.md) — 한 줄 설명
```

### `관련:` 태그
- 이 주제와 관련된 다른 주제를 `카테고리/서브카테고리/주제` 형식으로 나열
- 관련 주제가 없으면 생략
- 양방향으로 추가 (A에 B를 넣으면 B에도 A를 넣는다)
- **자동 탐색**: 새 파일 저장 시 `library_search()`로 핵심 키워드 검색 → 관련 주제 발견 시 양방향 태그 자동 추가

---

## 지식 파일 형식

```markdown
# [제목]

- 날짜: YYYY-MM-DD
- 출처: [실험명 / 링크 / 경험]
- source_session: [워크로그 날짜/시간 or 세션 컨텍스트 — 어느 세션에서 발견했는지]

## 내용
핵심 내용. 데이터, 수치, 상황 설명.

## 시사점
이 지식에서 얻은 것.
```

---

## LIBRARY.md 업데이트

카테고리 → 서브카테고리 → 주제 계층으로 링크한다.

```markdown
## dev
### tooling
- [claude-code](library/dev/tooling/claude-code/index.md) (5)
- [mcp-patterns](library/dev/tooling/mcp-patterns/index.md) (1)

## ml
- [classification](library/ml/classification/index.md) (3)
- [time-series](library/ml/time-series/index.md) (4)
```

---

## Synthesis (종합 문서)

같은 서브카테고리에 파일이 3개 이상 쌓이면:
- "이 주제들을 관통하는 공통 패턴/결론이 있는가?" 자문
- 있으면 `library/synthesis/[결론-요약].md`에 종합 문서 작성
- 아직 패턴이 보이지 않으면 스킵 (강제 아님)

```markdown
# [종합 제목]

- 날짜: YYYY-MM-DD
- 참조: [topic1 경로], [topic2 경로], [topic3 경로]

## 종합
여러 주제에서 도출한 공통 결론.

## 근거
각 주제에서 얻은 증거.

## 열린 질문
아직 확인 안 된 것.
```

---

## 하지 말 것

- 미결이라도 기록할 가치가 있으면 기록한다 (억지로 결론 내리지 않는다)
- 파일명에 날짜 붙이지 않는다
- 오타/포맷 수정은 기록하지 않는다
- TAXONOMY.md에 없는 카테고리를 임의로 만들지 않는다 (먼저 추가 후 저장)
