"""연결과 원자적·멱등 마이그레이션. 일반 연결은 SET ROLE을 사용하지 않는다."""

import os
from pathlib import Path


def connect(url=None):
    try:
        import psycopg
        from psycopg.rows import dict_row
    except ImportError as exc:
        raise RuntimeError(
            "Postgres 사용: claude-library-mcp[postgres]를 설치하세요"
        ) from exc
    url = url or os.environ.get("LIBRARY_DATABASE_URL")
    if not url:
        raise ValueError("LIBRARY_DATABASE_URL이 필요합니다")
    return psycopg.connect(url, row_factory=dict_row, connect_timeout=5)


def migrate(conn):
    from psycopg import sql

    with conn.transaction():
        conn.execute("SELECT pg_advisory_xact_lock(734851903)")
        for role in ("kb_owner", "kb_app"):
            if not conn.execute(
                "SELECT 1 FROM pg_roles WHERE rolname=%s", (role,)
            ).fetchone():
                conn.execute(
                    sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(role))
                )
                if role == "kb_owner":
                    login = conn.execute("SELECT current_user AS name").fetchone()[
                        "name"
                    ]
                    conn.execute(
                        sql.SQL("GRANT kb_owner TO {}").format(sql.Identifier(login))
                    )
        # RDS에서는 확장 설치 권한이 있는 관리 계정으로 먼저 실행한다.
        for extension in ("vector", "pg_bigm", "pg_trgm"):
            conn.execute(
                sql.SQL("CREATE EXTENSION IF NOT EXISTS {}").format(
                    sql.Identifier(extension)
                )
            )
        conn.execute("CREATE SCHEMA IF NOT EXISTS kb AUTHORIZATION kb_owner")
        conn.execute("SET LOCAL ROLE kb_owner")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS kb.schema_migrations(version text PRIMARY KEY, applied_at timestamptz DEFAULT now())"
        )
        for path in sorted((Path(__file__).parent / "migrations").glob("*.sql")):
            if conn.execute(
                "SELECT 1 FROM kb.schema_migrations WHERE version=%s", (path.name,)
            ).fetchone():
                continue
            conn.execute(path.read_text())
            conn.execute(
                "INSERT INTO kb.schema_migrations(version) VALUES (%s)", (path.name,)
            )
        conn.execute("RESET ROLE")


def doctor(conn):
    extensions = conn.execute("SELECT extname,extversion FROM pg_extension").fetchall()
    tables = conn.execute(
        "SELECT relname,relrowsecurity,relforcerowsecurity FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace WHERE n.nspname='kb' AND relkind='r'"
    ).fetchall()
    role = conn.execute(
        "SELECT current_user AS name,rolsuper,rolbypassrls, pg_has_role(current_user,'kb_owner','MEMBER') AS owner_member FROM pg_roles WHERE rolname=current_user"
    ).fetchone()
    return {
        "extensions": extensions,
        "tables": tables,
        "role": role,
        "extensions_ok": {"vector", "pg_bigm", "pg_trgm"}
        <= {e["extname"] for e in extensions},
        "dml_grants": conn.execute(
            "SELECT has_table_privilege(current_user,'kb.documents','SELECT,INSERT,UPDATE,DELETE') AS ok"
        ).fetchone()["ok"],
        "rls_ok": bool(tables)
        and all(t["relrowsecurity"] and t["relforcerowsecurity"] for t in tables),
        "app_role_safe": not (
            role["rolsuper"] or role["rolbypassrls"] or role["owner_member"]
        ),
        "user_id": conn.execute("SELECT kb.current_user_id() AS id").fetchone()["id"],
    }
