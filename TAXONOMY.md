# Library Taxonomy

> 지식 분류 체계. 새 항목 저장 시 이 파일을 먼저 참조한다.
> 카테고리/서브카테고리에 매칭되는 곳이 없으면 여기에 먼저 추가 후 저장.
> **대회명, 프로젝트명, 도구명은 카테고리/서브카테고리가 될 수 없다.**

## testing — 테스트 격리, mock, 픽스처, 테스트 설계

| Subcategory | 설명 | 예시 |
|-------------|------|------|
| spring-isolation | Spring 테스트 격리, JPA mock | mockito-kotlin NPE, JPA entity id |

## tooling — 개발 도구 사용법, 설정, 패턴

| Subcategory | 설명 | 예시 |
|-------------|------|------|
| claude-code | Claude Code hooks, 동작 패턴 | stop hook, bash 감지, stdin JSON |
| mcp-patterns | MCP 서버 설계, FastMCP | instructions 파라미터 |
| itch-deployment | 웹게임 배포 | HTML export gotchas |
| ralph-loop | AI 에이전트 반복 루프 | PRD 기반 체크리스트 |
| ai-agent | AI 에이전트 일반 패턴 | autoplan rewrite trap |

## infra — CI/CD, 배포, 런타임 환경, 플랫폼 제약

| Subcategory | 설명 | 예시 |
|-------------|------|------|
| cicd | CI/CD 파이프라인 | Google Play 인증 |
| kaggle-env | Kaggle notebook 환경 제약 | 모델 마운트, 데드라인 체크 |
| apple-mps | Apple Silicon MPS 학습 | M1 Max 벤치마크 |
| long-running-scripts | 장시간 스크립트 패턴 | 체크포인트, 의존성 |

## api — API 통합, 인증, 에러 처리, CLI 도구

| Subcategory | 설명 | 예시 |
|-------------|------|------|
| (주제 단위) | 개별 API/CLI 삽질 | Kaggle 페이지네이션, Supabase --linked |

## game — 게임 개발 특화 지식

| Subcategory | 설명 | 예시 |
|-------------|------|------|
| (주제 단위) | 에셋, 빌드, 배포 | Kenney 에셋 다운로드 |

## ml — 머신러닝 기법과 패턴

| Subcategory | 설명 | 예시 |
|-------------|------|------|
| classification | 분류 모델, 이진/다중 분류 | churn 예측, 파라미터 튜닝 vs 피처 |
| time-series | 시계열 예측, lag feature, validation 설계 | cold-start, data leakage |
| feature-engineering | 피처 설계, 선택, overfit 방지 | distribution feature overfit |
| gradient-boosting | LightGBM, XGBoost, CatBoost | 피처 중요도, WF 검증 |
| audio | 오디오/음성 모델 | BirdCLEF, spectrogram |

### ml 분류 원칙
- ❌ `ml/kaggle-ts-forecasting/` — 대회명
- ❌ `ml/churn-prediction/` — 프로젝트명
- ❌ `ml/lgbm/` — 모델명을 카테고리로
- ✅ `ml/time-series/lag-features.md` — 기법 기준
- ✅ `ml/classification/churn-tuning-vs-feature.md` — 기법 기준

## finance — 투자 전략과 백테스트 결과

| Subcategory | 설명 | 예시 |
|-------------|------|------|
| crypto | 코인 전략 (BTC, ETH 등) | BB+RSI, Donchian, 팩터 모델 |
| equity | 주식/ETF 전략 | 모멘텀, 자산배분, 레버리지 타이밍 |

### finance 분류 원칙
- Topic = 전략명 (bb-rsi-longshort, cross-momentum 등) ✅
- 현재 구조 유지. 잘 되어 있음.
