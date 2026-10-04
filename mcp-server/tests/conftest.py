import os
from pathlib import Path
import sys
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("LIBRARY_EMBED_PROVIDER", "none")
    monkeypatch.delenv("LIBRARY_EMBED_MODEL", raising=False)
    monkeypatch.delenv("LIBRARY_WORKSPACE", raising=False)
    monkeypatch.setenv("LIBRARY_BACKEND", "files")


@pytest.fixture(scope="session")
def database():
    url = os.environ.get("KB_TEST_DATABASE_URL")
    if not url:
        pytest.skip("KB_TEST_DATABASE_URL 미설정")
    from kb.db import connect, migrate
    from psycopg import sql

    with connect(url) as conn:
        # 파괴적 초기화는 사용자가 지정한 테스트 DB에만 허용한다.
        assert conn.info.dbname == "kb_test", "테스트는 kb_test DB에서만 실행합니다"
        conn.execute("DROP SCHEMA IF EXISTS kb CASCADE")
        migrate(conn)
        for name in ("kb_test_a", "kb_test_b", "kb_test_viewer", "kb_test_unmapped"):
            if not conn.execute(
                "SELECT 1 FROM pg_roles WHERE rolname=%s", (name,)
            ).fetchone():
                conn.execute(
                    sql.SQL("CREATE ROLE {} LOGIN").format(sql.Identifier(name))
                )
            conn.execute(sql.SQL("GRANT kb_app TO {}").format(sql.Identifier(name)))
    return url


@pytest.fixture
def db(database):
    from kb.db import connect
    from kb.cli import add_user

    with connect(database) as conn:
        conn.execute(
            "TRUNCATE kb.workspaces,kb.users,kb.members,kb.scopes,kb.documents,kb.document_versions,kb.relations,kb.sources,kb.chunks,kb.embeddings,kb.events CASCADE"
        )
        for name, role in [("a", "owner"), ("b", "editor"), ("viewer", "viewer")]:
            add_user(conn, name, "kb_test_" + name, "test", role)
    with connect(database) as conn:
        yield conn


@pytest.fixture
def as_user(database):
    from contextlib import contextmanager
    from kb.db import connect
    from psycopg.conninfo import conninfo_to_dict, make_conninfo

    @contextmanager
    def login(name):
        options = conninfo_to_dict(database)
        options["user"] = "kb_test_" + name
        with connect(make_conninfo(**options)) as conn:
            yield conn

    return login
