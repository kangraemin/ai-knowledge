# Library 작성 가이드

## 구조

도서관처럼 카테고리 → 주제 → 지식 파일 계층으로 구성한다.

```
library/
  quant/                        ← 카테고리
    fibonacci-retracement/      ← 주제
      index.md                  ← 주제 결론 요약 + 하위 파일 목록
      backtest.md               ← 지식 파일
      article.md
    indicator-timing/
      index.md
  ml/
    lgbm/
      index.md
  claude/
    prompt-patterns/
      index.md
```

### 카테고리 예시
- `quant` — 투자/백테스트/전략
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

- 실험/백테스트 결론이 났을 때
- 아티클/논문에서 유효한 인사이트를 얻었을 때
- 사용자가 접근법을 수정했을 때
- 더 나은 방법을 발견했을 때
- 세션 종료/compact 시 — 위 경우를 놓쳤다면 그때 정리

---

## index.md 형식

주제 폴더의 현재 결론을 요약한다. 지식이 추가될 때마다 업데이트.

```markdown
# [주제명]

## 결론
현재까지의 결론 한 줄. (유효 / 안됨 / 조건부)

## 근거
왜 이 결론인지. 핵심 데이터나 상황.

## 적용
앞으로 어떻게 행동할지. 예외 조건이 있다면 명시.

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
이 지식이 주제 결론에 어떻게 기여하는지.
```

---

## LIBRARY.md 업데이트

카테고리별로 주제 index.md를 링크한다.

```markdown
## quant
- [fibonacci-retracement](library/quant/fibonacci-retracement/index.md) — 한 줄 결론
- [indicator-timing](library/quant/indicator-timing/index.md) — 한 줄 결론

## ml
- [lgbm](library/ml/lgbm/index.md) — 한 줄 결론
```

---

## 하지 말 것

- 미결 상태로 기록하지 않는다
- 결론 없이 "흥미롭다"만 기록하지 않는다
- 오타/포맷 수정은 기록하지 않는다
- 파일명에 날짜 붙이지 않는다
