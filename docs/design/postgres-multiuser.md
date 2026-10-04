# Postgres 다중 사용자 지식베이스 + 브랜치 추적 업데이트 — 설계 명세

> 상태: 구현 대상 (브랜치 `feat/pg-multiuser-kb`)
> 근거: 에이전트 메모리 OSS 12종 조사 (`library/tooling/agent-memory/oss-landscape-2026-*`)

## 0. 목표와 비목표

**목표**
1. 업데이트가 `main` 고정이 아니라 사용자가 고른 브랜치를 따라간다 (이 브랜치를 실사용하며 검증하기 위해).
2. 지식베이스 원본을 Postgres로 옮길 수 있게 한다. 로컬(brew/Docker) → Amazon RDS for PostgreSQL 로 `pg_dump` 만으로 이식 가능해야 한다.
3. 여러 명이 같은 DB를 쓸 수 있다 (workspace / scope / 권한).
4. 검색 품질: 키워드(pg_bigm, 한·영) + 의미(pgvector) + RRF 하이브리드. 정정·대체된 문서는 기본 검색에서 제외.
5. 에이전트가 검색을 빼먹어도 되도록 UserPromptSubmit hook 이 검색 결과를 자동 주입한다.
6. 개선 여부를 숫자로 판정할 평가셋(R@5)을 둔다.

**비목표 (이번 범위 밖)**
- 별도 HTTP API 서버. 권한은 DB 롤 + RLS 로 강제한다 (아래 §3). MCP 서버가 사용자 본인 DB 자격으로 직접 접속한다.
- 웹 UI.
- 기존 파일 백엔드 제거. **기본값은 계속 파일 백엔드**이며 `LIBRARY_BACKEND=postgres` 일 때만 새 경로를 탄다. 기존 사용자는 아무 것도 바뀌지 않아야 한다.

## 1. 브랜치 추적 업데이트

| 항목 | 값 |
|---|---|
| 설정 위치 | `~/.claude/hooks/.learnings-branch` (한 줄, 브랜치명). 없으면 `main` |
| env override | `LEARNINGS_BRANCH` 가 파일보다 우선 |
| 설정 방법 | `install.sh --branch <name>` / `update.sh --branch <name>` / `update-check.sh --branch <name>` 이 파일에 기록. `--branch main` 이면 파일 삭제 |
| 검증 | 브랜치명은 `^[A-Za-z0-9._/-]+$` 이고 `..` 미포함일 때만 허용. 아니면 거부(exit 1) |

반영 지점:
- `scripts/update-check.sh`: `API_URL=.../commits/$BRANCH`, clone 은 `git clone --depth 1 -b "$BRANCH"`. 설치 SHA 비교는 브랜치별로 (`.learnings-version` 에 `branch@sha` 를 기록하되 과거 형식 `sha` 만 있는 파일도 읽을 수 있어야 함).
- `update.sh`: 소스가 없어서 clone 할 때 `-b "$BRANCH"`. 끝나면 `.learnings-version` 에 `branch@sha` 기록.
- **MCP 서버도 같은 브랜치를 따라가야 한다.** 지금은 `uvx claude-library-mcp@latest` 라 PyPI 버전만 돈다 (library 기록: "uvx 는 로컬 소스가 아니라 PyPI 를 resolve"). 브랜치가 `main` 이 아니면 settings.json 의 mcpServers.claude-library args 를
  `["--with","mcp<2","--from","git+https://github.com/kangraemin/learnings-for-claude@<BRANCH>#subdirectory=mcp-server","claude-library-mcp"]` 로 바꾸고, `main` 으로 돌아오면 원래 PyPI 형태로 복원한다. 이 변경은 `jq` 로 해당 키만 수정하고 다른 키는 보존한다(백업 `.bak` 남김).
- 자동 적용 정책은 기존 그대로 (기본 알림만, `LEARNINGS_AUTO_UPDATE=1` 이면 적용).

## 2. 스키마 (`mcp-server/kb/migrations/*.sql`, 순번 파일, idempotent)

RDS 호환만 사용: `vector`(pgvector ≥0.5), `pg_bigm`, `pg_trgm`, `pgcrypto`(gen_random_uuid 는 PG13+ 내장이라 불필요). 슈퍼유저 전용 기능 금지.

```sql
create schema if not exists kb;

kb.schema_migrations(version text primary key, applied_at timestamptz default now())

kb.workspaces(id uuid pk default gen_random_uuid(), slug text unique not null, name text not null, created_at)
kb.users(id uuid pk, handle text unique not null, db_role text unique not null, created_at)
    -- db_role = 이 사용자가 접속하는 Postgres 롤 이름. RLS 가 current_user 로 사용자를 식별한다
kb.members(workspace_id fk, user_id fk, role text check (role in ('owner','editor','viewer')), pk(workspace_id,user_id))
kb.scopes(id uuid pk, workspace_id fk, kind text check (kind in ('personal','team','repo')), key text not null,
          owner_user_id uuid null,   -- personal 일 때만
          unique(workspace_id, kind, key))

kb.documents(
  id uuid pk, scope_id fk not null,
  kind text check (kind in ('knowledge','decision','inbox')),
  path text not null,              -- 기존 파일 경로 호환키 'library/finance/x/y.md' 또는 'decisions/repo/cat/x.md'
  type text not null,              -- OKF type (Gotcha, Strategy, Decision ...)
  title text not null, description text, body text not null,
  category text, subcategory text, tags text[] default '{}',
  status text check (status in ('draft','stable','deprecated')) default 'stable',
  confidence real null, evidence_count int null,
  frontmatter jsonb default '{}',  -- 원본 프론트매터 전체 (무손실 왕복용)
  content_hash text not null,      -- sha256(raw markdown) — importer 멱등성
  author_id uuid null, version int not null default 1,
  valid_from timestamptz default now(), invalid_at timestamptz null,
  created_at, updated_at,
  unique(scope_id, path)
)
kb.document_versions(doc_id fk, version int, title, body, frontmatter jsonb, author_id, created_at, pk(doc_id,version))
kb.relations(id uuid pk, src_id fk, dst_id fk,
  type text check (type in ('supersedes','contradicts','refines','derived_from','example_of','related')),
  created_by uuid, valid_from timestamptz default now(), invalid_at timestamptz null, unique(src_id,dst_id,type))
kb.sources(id uuid pk, doc_id fk, ref_id text, resource text, title text)
kb.chunks(id uuid pk, doc_id fk on delete cascade, ord int, heading text, text text not null, unique(doc_id, ord))
kb.embeddings(chunk_id fk on delete cascade, model text, dim int, vec vector, pk(chunk_id, model))
kb.events(id bigserial pk, user_id uuid, doc_id uuid null, action text, query text null, at timestamptz default now())
```

인덱스: `chunks.text` 와 `documents.title||' '||coalesce(description,'')` 에 `gin (... gin_bigm_ops)`. 임베딩은 모델별 차원이 달라 컬럼을 `vector` (차원 미지정)로 두고, 검색은 `where model = $1` 로 거른 뒤 `vec <=> $2` 정렬. 규모가 커지면 모델별 부분 HNSW 인덱스를 `kb.ensure_vector_index(model, dim)` 함수로 만든다 (`create index ... using hnsw ((vec::vector(N)) vector_cosine_ops) where model = '...'`).

## 3. 다중 사용자와 권한

- 사용자마다 **자기 DB 롤**로 접속한다 (RDS 에서는 IAM DB 인증 또는 비밀번호 롤 — 둘 다 결국 Postgres 롤). 앱 레벨에서 `set kb.user_id` 같은 걸 믿지 않는다 — 클라이언트가 위조할 수 있다.
- `kb.current_user_id()` = `select id from kb.users where db_role = current_user` (SECURITY DEFINER 아님, 단순 sql stable 함수).
- 모든 kb 테이블에 RLS enable + force. 정책:
  - 읽기: 문서의 scope 가 속한 workspace 의 member 이고, scope.kind='personal' 이면 owner 본인만.
  - 쓰기(insert/update): role in (owner, editor). personal scope 는 owner 본인만. viewer 는 읽기만.
  - `kind='inbox'` 는 작성자 본인 + workspace owner 만 읽는다.
  - delete 는 owner 만. (일반 경로는 delete 대신 `status='deprecated'` + `invalid_at`.)
- 롤: `kb_owner`(마이그레이션 실행, 테이블 소유자 — RLS 우회되므로 앱 접속에 쓰지 않음), `kb_app`(NOLOGIN 그룹 롤, 테이블 DML 권한). 사용자 롤은 `kb_app` 멤버.
- 관리 CLI: `kb admin add-user <handle> --db-role <role> --workspace <slug> --role editor` (롤 생성은 하지 않고, 존재하는 롤을 매핑만. 롤 생성 SQL 은 출력해서 보여준다 — RDS 마스터 계정이 실행).
- 결정사항 push: SessionStart 에서 `scope.kind='repo' and key=<repo>` 인 `kind='decision', status<>'deprecated'` 문서를 주입.

## 4. 쓰기 경로

- `library_write(path, markdown, scope?)` MCP 툴(postgres 백엔드 전용):
  1. 비밀정보 스캔 (AWS 키, `sk-`/`ghp_`/`xox[bp]-`, PEM, `password=` 등). 걸리면 거부.
  2. 유사 문서 top-5 (하이브리드 검색) 를 응답에 포함 — 중복·모순이면 relate/deprecate 하라고 안내.
  3. 같은 path 가 있으면 `version` 낙관적 락으로 update(`expected_version` 인자), 이전 본문은 `document_versions` 로.
  4. 기본 kind 는 `knowledge`. `kind='inbox'` 로 넣으면 후보 상태.
- `library_relate(src_path, dst_path, type)`: `supersedes` 를 걸면 dst 를 `status='deprecated', invalid_at=now()` 로 같은 트랜잭션에서 바꾼다.
- `library_promote(path)`: inbox → knowledge, status stable.
- 모든 쓰기는 `events` 에 기록.

## 5. 검색 (`kb/search.py`)

입력: query, scope 필터(기본: 접근 가능 전체), include_deprecated=False, k=7, token_budget.
1. 키워드: `chunks.text` 와 문서 title/description 에 대해 `bigm_similarity` / `=%` 로 상위 50 청크. 쿼리 토큰화는 공백 분리 후 각 토큰 `likequery()`.
2. 의미: 설정된 임베딩 모델이 있으면 쿼리 임베딩 후 `vec <=> q` 상위 50 청크.
3. 문서 단위로 접고(최고 청크), RRF (k=60) 융합. 관계 보정: `supersedes` 로 대체된 문서는 제외(옵션 시 포함), 결과 문서가 대체한 문서는 표시만.
4. 출력은 **2단계**: `path · title · description(≤160자)` 목록. 본문 미리보기 없음. 본문은 `library_read`.
5. 검색은 `events` 에 action='search' 로 기록.

임베딩 제공자 (`kb/embed.py`, env `LIBRARY_EMBED_PROVIDER`):
- `none` (기본) — 의미 검색 단계 생략.
- `fastembed` — 로컬 ONNX, 기본 모델 `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (`LIBRARY_EMBED_MODEL` 로 변경). optional dependency (`claude-library-mcp[embed]`).
- `openai` — `text-embedding-3-small`, `OPENAI_API_KEY`.
- `fake` — 테스트용 결정적 해시 임베딩.
임베딩은 쓰기 시 동기 계산하지 않고 `kb embed --pending` 로 일괄(누락 청크만) 계산한다.

파일 백엔드 검색도 같은 2단계 출력 형식으로 바꾼다 (본문 미리보기 제거 → 토큰 절약). 단 기존 점수 로직은 유지.

## 6. 자동 주입 hook (`hooks/library-autoinject.sh`, UserPromptSubmit)

- stdin JSON 의 `prompt` 를 읽어 `claude-library-kb search --format inject --budget 1500 "<prompt>"` 실행.
- 프롬프트가 너무 짧거나(<8자) `/` 로 시작하는 슬래시 명령이면 건너뜀.
- 출력: `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}`. 결과 0건이면 아무것도 출력하지 않음.
- 백엔드 무관하게 동작 (파일 백엔드면 파일 검색).
- 실패·타임아웃은 조용히 통과 (exit 0) — 프롬프트를 막으면 안 된다. timeout 5s.
- `LIBRARY_AUTOINJECT=0` 이면 끔.

## 7. 가져오기 / 내보내기

- `kb import <library_root> --workspace <slug> [--scope-kind personal|team] [--scope-key ...]`
  - `library/**/*.md` (index.md, log.md 제외) → knowledge, `decisions/<repo>/<cat>/*.md` → kind=decision, scope=repo:<repo>.
  - 프론트매터 전체를 `frontmatter` jsonb 로 보존. content_hash 가 같으면 skip (멱등). 다르면 version+1.
  - 본문 `[[name]]` 링크와 `관련:` 줄을 `relations(type='related')` 로, 본문에 "정정"/"철회"/"⚠️ 보강" 이 있는 경우는 건드리지 않는다(자동 추론 금지 — 오탐).
  - 청크: `## ` 헤딩 단위, 1500자 초과 시 문단 단위로 분할.
  - 끝에 리포트: 파일 수 / 삽입 / 갱신 / skip / 실패.
- `kb export <out_dir> --workspace <slug>`: 같은 경로 구조로 마크다운 재생성 (frontmatter jsonb + body). **왕복 검증**: import → export → 원본과 바이트 비교 시 프론트매터 키 순서 정도만 다르고 본문은 동일해야 한다. 테스트로 강제.

## 8. 평가 (`mcp-server/kb/eval/`)

- `queries.jsonl`: `{"q": "...", "expected": ["library/..."]}`. 쿼리는 **문서 제목·파일명의 단어를 그대로 쓰지 않은 패러프레이즈**, 한국어/영어 섞어서 최소 40개 (한쪽 언어로 쓰인 문서를 다른 언어로 묻는 교차 질의 최소 15개).
- `kb eval --backend files|postgres` → R@1, R@5, MRR 출력. 결과를 `eval/results.md` 에 날짜·백엔드·임베딩 설정과 함께 남긴다.

## 9. CLI / 패키징

- `mcp-server/kb/` 패키지, 엔트리포인트 `claude-library-kb = kb.cli:main` 추가 (기존 `claude-library-mcp` 유지).
- 의존성: 기존 `mcp[cli]>=1.0.0,<2` + `psycopg[binary]>=3.1,<4` 는 **optional** `[postgres]` extra. 파일 백엔드 사용자는 새 의존성 없음.
- 설정 env: `LIBRARY_BACKEND` (files|postgres), `LIBRARY_DATABASE_URL`, `LIBRARY_WORKSPACE`, `LIBRARY_EMBED_PROVIDER`, `LIBRARY_EMBED_MODEL`, `LIBRARY_AUTOINJECT`.
- `kb migrate` (마이그레이션 적용), `kb doctor` (확장·권한·RLS 점검).
- 로컬 개발용 `docker-compose.yml` (pgvector 이미지 + pg_bigm 빌드 Dockerfile) 과 RDS 이전 가이드 `docs/postgres.md`.

## 10. 테스트

- Python: `pytest` (`mcp-server/tests/`). `KB_TEST_DATABASE_URL` 가 없으면 postgres 테스트는 skip.
  - 마이그레이션 2회 적용 멱등
  - RLS: 사용자 A/B/viewer 롤 3개 생성 → A 의 personal 문서는 B 가 못 봄, viewer insert 실패, team 문서는 둘 다 봄, current_user 매핑 안 된 롤은 0건
  - import 멱등 (2회 실행 시 2회차 전부 skip), import→export 왕복 본문 동일
  - 하이브리드 검색: 한국어 쿼리로 영어 제목 문서 찾기 (fake 임베딩 대신 키워드로는 못 찾고 의미로만 찾는 케이스를 고정 벡터로 구성)
  - supersedes → 대체된 문서 기본 검색 제외
  - 낙관적 락 충돌
  - 비밀정보 스캔 거부
  - 파일 백엔드 기존 동작 회귀 (검색 결과가 path 목록으로 나오는지)
- Shell: `tests/install.bats` 기존 전부 통과 + 브랜치 추적 케이스 (파일 기록, 잘못된 브랜치명 거부, MCP args 전환/복원, 다른 settings 키 보존).
