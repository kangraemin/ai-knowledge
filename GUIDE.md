# Library 작성 가이드

## 구조

도서관처럼 카테고리 → 주제 → 지식 파일 계층으로 구성한다.

```
library/
  equity/                       ← 카테고리 (미국 주식/ETF 전략)
    fibonacci-retracement/      ← 주제
      index.md                  ← 주제 요약 + 하위 파일 목록
      backtest.md               ← 지식 파일
      article.md
    indicator-timing/
      index.md
  crypto/                       ← 카테고리 (코인 전략)
    bb-rsi-longshort/
      index.md
  ml/                           ← 카테고리 (머신러닝 모델)
    lgbm/
      index.md
  macro/                        ← 카테고리 (거시경제)
  claude/                       ← 카테고리 (Claude 행동 패턴)
    prompt-patterns/
      index.md
```

### 카테고리 예시
- `equity` — 미국 주식/ETF 전략, 레버리지 ETF
- `crypto` — 코인 전략 (BTC/ETH/XRP 등)
- `ml` — 머신러닝/모델
- `macro` — 거시경제
- `claude` — Claude 행동 패턴, 프롬프트
- 필요하면 새 카테고리 추가

### 주제 폴더
- 구체적인 개념 하나 = 폴더 하나
- 영어, 소문자, hyphen 구분 (`fibonacci-retracement`, `gld-defense`)
- 날짜 붙이지 않는다

### 지식 파일
- 내용을 설명하는 이름 (`backtest.md`, `paper.md`, `discovery.md`)
- 날짜 붙이지 않는다
- 같은 주제에 지식이 쌓이면 파일 추가

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

## 요약
현재까지 알고 있는 것. 핵심 내용.

## 지식 목록
- [backtest.md](backtest.md) — 한 줄 설명
- [article.md](article.md) — 한 줄 설명
```

---

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

---

## LIBRARY.md 업데이트

카테고리별로 주제 index.md를 링크한다.

```markdown
## equity
- [fibonacci-retracement](library/equity/fibonacci-retracement/index.md) — 한 줄 요약
- [indicator-timing](library/equity/indicator-timing/index.md) — 한 줄 요약

## crypto
- [bb-rsi-longshort](library/crypto/bb-rsi-longshort/index.md) — 한 줄 요약

## ml
- [lgbm](library/ml/lgbm/index.md) — 한 줄 요약
```

---

## 하지 말 것

- 미결이라도 기록할 가치가 있으면 기록한다 (억지로 결론 내리지 않는다)
- 파일명에 날짜 붙이지 않는다
- 오타/포맷 수정은 기록하지 않는다
