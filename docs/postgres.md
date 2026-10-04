# PostgreSQL 지식베이스

기본 백엔드는 `files`다. 기존 `claude-library-mcp` 엔트리포인트와 읽기 툴 시그니처는 그대로다. PostgreSQL 사용 시 `claude-library-kb` CLI, 쓰기 툴, 사용자별 RLS, 키워드/의미 검색을 사용할 수 있다.

## 설치와 로컬 실행

```sh
# 레포 루트에서 실행 (미배포 브랜치를 PyPI @latest로 설치하지 않는다)
uv tool install './mcp-server[postgres]'
# 체크아웃에서 개발할 때
cd mcp-server
uv sync --extra postgres
uv run claude-library-kb --help
```

선택적 의존성은 `postgres`(psycopg, YAML), `embed`(fastembed), `openai`다. 파일 백엔드에는 추가 의존성이 필요 없다. 브랜치 설치 시에도 `--from '패키지[postgres] @ git+https://...#subdirectory=mcp-server'`처럼 해당 extra가 필요하다.

Docker:

```sh
export POSTGRES_PASSWORD='로컬에서 정한 비밀번호'
docker compose up -d --build
export LIBRARY_DATABASE_URL='postgresql://postgres:비밀번호@127.0.0.1:54329/kb_dev'
claude-library-kb migrate
```

`docker/Dockerfile`은 PostgreSQL 17 + pgvector 이미지에 pg_bigm을 빌드한다. brew 설치는 PostgreSQL 17의 `pg_config`로 pgvector와 pg_bigm을 빌드·설치한 후 같은 CLI를 사용한다. 포트 54329는 로컬 개발용이다.

## 관리자와 앱 사용자 분리

초기 마이그레이션 계정은 CREATEROLE, 확장 설치, `SET ROLE kb_owner` 권한이 필요하다. 일반 사용자로 migrate를 실행하지 않는다. 이미 역할이 있으면 관리자에게 `kb_owner` 멤버십을 부여한다. `kb_owner`, `kb_app`은 NOLOGIN 그룹이며 실제 접속은 개인 LOGIN 역할로 한다.

```sql
-- DB 관리자 실행. 실제 비밀번호/IAM 인증 설정은 배포 환경에 맞춘다.
CREATE ROLE alice LOGIN;
GRANT kb_app TO alice;
```

```sh
# 관리자 연결로 매핑. DB 역할이 없으면 필요한 SQL만 출력하고 매핑하지 않는다.
claude-library-kb admin add-user alice --db-role alice --workspace my-team --role owner

# 이후 앱은 alice로 연결
export LIBRARY_BACKEND=postgres
export LIBRARY_DATABASE_URL='postgresql://alice@127.0.0.1:54329/kb_dev'
export LIBRARY_WORKSPACE=my-team
claude-library-kb doctor
```

`doctor`는 확장 버전, 각 테이블 ENABLE/FORCE RLS, 현재 역할의 superuser/BYPASSRLS, 사용자 매핑을 출력한다. `app_role_safe=true`, `rls_ok=true`, `user_id` 존재를 확인한다. `kb_owner` 또는 슈퍼유저를 MCP에 넣으면 안 된다.

RLS는 `current_user`와 `kb.users.db_role`을 직접 매핑한다. `SET kb.user_id`는 권한에 영향을 주지 않는다. team/repo 문서는 같은 workspace 멤버가 읽고 owner/editor가 쓴다. personal은 그 소유자만 접근하며, inbox는 작성자와 workspace owner만 읽는다. 삭제는 workspace owner만 가능하다. users/members 관리 DML은 관리자 CLI 전용이며 일반 앱 사용자에게 자체 권한 상승을 허용하지 않는다.

모든 테이블에 FORCE RLS가 있으므로 테이블 소유자가 자동 우회한다는 가정은 사용하지 않았다. 관리 역할 전용 정책을 명시했다. `current_user_id()`는 SECURITY INVOKER다. 이력 트리거 하나만 제한된 SECURITY DEFINER로 실행되어, 편집자의 본문 교체 시 이전 버전과 파생 청크를 원자적으로 정리한다. 직접 호출 권한은 없다.

## 가져오기와 내보내기

```sh
claude-library-kb import "$HOME/claude-library" --workspace my-team
# 개인 공간
claude-library-kb import /path/to/library --workspace my-team --scope-kind personal --scope-key alice
# 출력은 원본과 다른 디렉터리
claude-library-kb export /tmp/kb-export --workspace my-team
```

`library/**/*.md` 중 index/log/template를 제외하고 가져온다. 결정사항은 `decisions/<repo>/<category>/*.md`만 repo scope로 가져온다. SHA-256이 같으면 skip, 달라지면 이력을 남기고 version을 올린다. YAML의 중첩 값과 본문의 공백·개행을 보존한다. YAML 키 순서와 표기 스타일은 export 시 달라질 수 있다. 표현 불가능한 YAML 값이나 잘못된 상태 값은 파일별 실패로 보고하며 CLI exit 1이다. 기존 자료의 원문 보존을 위해 명시적 import에는 비밀정보 스캔을 적용하지 않는다. MCP 쓰기에는 항상 적용한다.

같은 workspace의 서로 다른 scope에 동일 경로가 있으면 export는 덮어쓰지 않고 거부한다. 기존 읽기 툴에는 scope 인자가 없으므로 중복 경로 역시 명확한 오류를 돌려준다. 원본 밖을 가리키는 symlink 및 export 루트 밖 경로는 거부한다.

`[[name]]`과 `관련:` 줄의 명시적 링크만 related로 가져온다. 정정·철회 문구만으로 상태를 추측하지 않는다.

## 검색과 쓰기

```sh
claude-library-kb search '과거에 해결한 접속 오류' --budget 1500
claude-library-kb search '접속 오류' --scope team:default --include-deprecated
claude-library-kb decisions repository-name
```

pg_bigm의 GIN은 LIKE를 지원하므로 키워드 비교는 LIKE/=%를 사용하며 대소문자를 구분한다. 검색은 pg_bigm 청크 후보 50개, 의미 후보 50개를 각각 문서별 최고 청크로 접은 후 RRF(60)로 합친다. 기본 결과 7개는 `path · title · description`이며 본문은 `library_read`로 읽는다. description은 160자까지다. 출력 예산은 UTF-8 바이트 수를 보수적인 토큰 상한으로 사용한다. 짧은 예산에서는 실제 허용 토큰보다 적게 출력될 수 있다. 파일 백엔드의 점수 계산은 기존 그대로다.

새 MCP 툴:

- `library_write(path, markdown, scope?, expected_version?, kind='knowledge')`: 기존 경로를 수정할 때 현재 version 필수. 최초 생성에는 생략 또는 0. 응답에 유사 문서 top 5를 표시한다.
- `library_relate(src_path, dst_path, type)`: supersedes는 대상 폐기와 관계 생성을 한 트랜잭션으로 실행한다.
- `library_promote(path)`: inbox를 stable knowledge로 승격한다.

파일 백엔드에서 쓰기 툴은 PostgreSQL 설정 안내를 반환한다. 검색과 쓰기는 events에 기록된다. 원본을 갱신하면 이전 임베딩을 무효화한다.

## 임베딩

```sh
# 레포 루트에서 실행
uv tool install './mcp-server[postgres,embed]' --force
export LIBRARY_EMBED_PROVIDER=fastembed
# 기본: sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
claude-library-kb embed --pending

# OpenAI를 선택할 때만 외부 API로 본문을 전송한다.
# LIBRARY_EMBED_PROVIDER=openai, OPENAI_API_KEY, [openai] extra 필요
```

`LIBRARY_EMBED_MODEL`로 모델을 바꿀 수 있다. 모델마다 벡터가 별도로 저장되므로 변경 후 `embed --pending`을 다시 실행한다.

기본 `none`은 모델 다운로드·외부 요청 없이 키워드만 검색한다. 쓰기에서 임베딩을 동기 계산하지 않는다. `embed --pending`이 모델별 누락 청크만 계산한다. 테스트용 `fake`는 SHA-256 결정적 벡터이며 의미 품질 검증용이 아니다.

규모가 커지면 관리자 연결로 `SELECT kb.ensure_vector_index('모델명', 384);`를 실행할 수 있다. HNSW는 1..2000차원 vector만 지원하도록 제한했다. 기본 검색은 차원 미지정 vector를 모델별 필터링하는 정확 검색이며, 부분 HNSW를 실제 활용하려면 해당 모델의 차원 캐스트 쿼리로 실행 계획을 확인해야 한다.

## Hook

`hooks/library-autoinject.sh`는 UserPromptSubmit JSON을 읽고 CLI 검색 결과를 additionalContext로 반환한다. 8자 미만, 슬래시 명령, `LIBRARY_AUTOINJECT=0`은 건너뛴다. 실패와 5초 초과는 출력 없이 exit 0이다. `python3`와 PATH의 `claude-library-kb`가 필요하다. 설치 스크립트의 등록은 별도 담당 범위다.

SessionStart 결정사항 주입의 Python 진입점은 `claude-library-kb decisions <repo>`다. 해당 repo scope의 활성 결정사항 본문을 출력한다.

## 평가와 테스트

```sh
LIBRARY_ROOT=/path/to/library claude-library-kb eval --backend files
LIBRARY_EMBED_PROVIDER=none claude-library-kb eval --backend postgres
LIBRARY_EMBED_PROVIDER=fastembed claude-library-kb eval --backend postgres

# 테스트는 오직 kb_test DB만 초기화한다. HOME은 임시 디렉터리로.
run_home=$(mktemp -d)
HOME="$run_home" UV_CACHE_DIR="$run_home/cache" \
KB_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:54329/kb_test \
uv run --extra postgres --with pytest pytest
```

평가셋은 `mcp-server/kb/eval/queries.jsonl`, 측정값은 `results.md`에 있다. 두 백엔드 모두 상위 7개를 사용하므로 MRR은 MRR@7이다. 하나의 관련 문서를 정답으로 지정했다. 실제 라이브러리 원본은 수정하지 않으며 왕복 파일과 모델 캐시는 임시 HOME에 쓴다.

## RDS로 이전

1. 대상 RDS 엔진 버전에서 vector ≥0.5, pg_bigm, pg_trgm 지원 여부를 확인한다. 설치 권한은 RDS 관리자에게 있다.
2. 대상에 kb_owner/kb_app과 개인 로그인 역할을 생성한다. 대상 관리자에 kb_owner 멤버십을 부여하고 확장 설치 및 migrate를 실행한다.
3. 소스 앱 쓰기를 중지하고 `pg_dump --format=custom --schema=kb "$SOURCE_DATABASE_URL" > kb.dump`로 덤프한다. 소스 계정은 모든 행을 읽을 수 있는 관리자여야 한다. FORCE RLS에서 제한된 사용자 덤프를 전체 백업으로 취급하지 않는다.
4. 대상이 새 전용 DB라면 migrate로 생성된 빈 kb 스키마를 제거한 후 `pg_restore --dbname="$TARGET_DATABASE_URL" --no-owner --role=kb_owner kb.dump`로 복원한다. 확장은 public 스키마에 미리 설치되어 있어야 한다. 역할은 pg_dump에 포함되지 않으므로 별도 생성이 필요하다.
5. 개인 사용자 연결로 doctor, 문서 수, 검색, personal/inbox 격리를 확인한 뒤 `LIBRARY_DATABASE_URL`을 교체한다. RDS에는 `sslmode=verify-full`과 AWS CA 인증서를 사용하며 비밀번호 또는 IAM 인증을 적용한다.

공식 근거:

- [PostgreSQL 17 RLS](https://www.postgresql.org/docs/17/ddl-rowsecurity.html)
- [pg_bigm 함수·GIN](https://pgbigm.github.io/pg_bigm/pg_bigm_en.html)
- [pgvector 차원별 부분 인덱스](https://github.com/pgvector/pgvector)
- [RDS 버전별 확장 지원표](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html)
- [FastEmbed](https://github.com/qdrant/fastembed)
