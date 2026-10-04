import pytest
from kb import db as database, store
from kb.markdown import parse
from kb.search import search
from kb.embed import Provider, embed_pending

RAW = '---\ntype: Gotcha\ntitle: 사과 과수원\ndescription: 달콤한 과일\ntags: [농장, 과일]\nsources:\n  - id: src\n    resource: "https://example.org"\n---\n\n# 사과\n\n## 관찰\n수확한 사과를 저장한다.\n\n'


def setup_scopes(conn):
    wid = store.workspace(conn, "test")
    return store.ensure_scope(conn, wid), store.ensure_scope(conn, wid, "personal", "a")


def test_migration_idempotent(db):
    before = db.execute(
        "SELECT * FROM kb.schema_migrations ORDER BY version"
    ).fetchall()
    database.migrate(db)
    database.migrate(db)
    assert (
        db.execute("SELECT * FROM kb.schema_migrations ORDER BY version").fetchall()
        == before
    )
    assert database.doctor(db)["rls_ok"]
    assert not database.doctor(db)["app_role_safe"]


def test_rls_personal_team_inbox_viewer_and_unmapped(db, as_user):
    import psycopg

    with as_user("a") as a:
        team, personal = setup_scopes(a)
        store.write(a, "library/team.md", RAW, team)
        store.write(a, "library/private.md", RAW, personal)
        store.write(a, "library/inbox.md", RAW, team, kind="inbox")
    with as_user("b") as b:
        assert [
            r["path"] for r in b.execute("SELECT path FROM kb.documents").fetchall()
        ] == ["library/team.md"]
        assert len(b.execute("SELECT * FROM kb.chunks").fetchall()) == 2
        store.write(b, "library/b-inbox.md", RAW, team, kind="inbox")
        assert len(search(b, "사과")) == 2
        # 위조 가능한 사용자 GUC를 믿지 않는다.
        b.execute("SET LOCAL kb.user_id='00000000-0000-0000-0000-000000000000'")
        assert b.execute("SELECT count(*) AS n FROM kb.documents").fetchone()["n"] == 2
    with as_user("a") as a:
        assert a.execute("SELECT count(*) AS n FROM kb.documents").fetchone()["n"] == 4
    with as_user("viewer") as v:
        assert len(search(v, "사과")) == 1
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            with v.transaction():
                store.write(v, "library/no.md", RAW, team)
        assert v.execute("DELETE FROM kb.documents RETURNING id").fetchall() == []
    with as_user("unmapped") as u:
        assert search(u, "사과") == []
        assert u.execute("SELECT * FROM kb.documents").fetchall() == []


def test_editor_update_history_and_owner_delete(db, as_user):
    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(a, "library/team.md", RAW, team)
    with as_user("b") as b:
        result = store.write(
            b, "library/team.md", RAW.replace("사과", "배"), team, expected_version=1
        )
        assert result["version"] == 2
        assert (
            b.execute("SELECT body FROM kb.document_versions").fetchone()["body"]
            == parse(RAW)[1]
        )
        assert b.execute("DELETE FROM kb.documents RETURNING id").fetchall() == []
        assert all(
            "사과" not in r["text"] for r in b.execute("SELECT text FROM kb.chunks")
        )
    with as_user("a") as a:
        assert len(a.execute("DELETE FROM kb.documents RETURNING id").fetchall()) == 1


def test_import_idempotence_roundtrip(db, as_user, tmp_path):
    root = tmp_path / "input"
    for path, raw in [
        ("library/a.md", RAW),
        ("library/b.md", RAW + "관련: [[a]]\n"),
        ("decisions/repo/stack/choice.md", RAW),
    ]:
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw.encode())
    with as_user("a") as a:
        first = store.import_library(a, root, "test")
        assert first["insert"] == 3 and first["failed"] == 0
        second = store.import_library(a, root, "test")
        assert second["skip"] == 3 and second["failed"] == 0
        assert a.execute("SELECT count(*) AS n FROM kb.relations").fetchone()["n"] == 1
        assert store.export_library(a, tmp_path / "out", "test") == 3
        for path in root.rglob("*.md"):
            assert parse(path.read_text()) == parse(
                (tmp_path / "out" / path.relative_to(root)).read_text()
            )
        (root / "library/a.md").write_text(RAW + "추가\n")
        third = store.import_library(a, root, "test")
        assert third["update"] == 1 and third["skip"] == 2
        assert (
            a.execute("SELECT count(*) AS n FROM kb.document_versions").fetchone()["n"]
            == 1
        )


def test_fixed_vector_semantic_only(db, as_user):
    class Fixed:
        name = "fixed"
        model = "test-fixed"

        def encode(self, texts, query=False):
            return [[1, 0] if query or "apple" in t else [0, 1] for t in texts]

    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(
            a,
            "library/apple.md",
            "---\ntype: Concept\ntitle: Orchard\n---\napple orchard",
            team,
        )
        store.write(
            a,
            "library/boat.md",
            "---\ntype: Concept\ntitle: Ocean\n---\nboat harbor",
            team,
        )
        assert search(a, "과수원에서 재배하는 열매") == []
        assert embed_pending(a, Fixed()) == 2
        assert embed_pending(a, Fixed()) == 0
        assert (
            search(a, "과수원에서 재배하는 열매", embedder=Fixed())[0]["path"]
            == "library/apple.md"
        )


def test_supersedes_conflict_and_promote(db, as_user):
    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(a, "library/old.md", RAW, team)
        store.write(a, "library/new.md", RAW, team, kind="inbox")
        with pytest.raises(store.ConflictError):
            store.write(a, "library/old.md", RAW + "edit", team, expected_version=0)
        store.promote(a, "library/new.md")
        assert store.get_document(a, "library/new.md")["kind"] == "knowledge"
        store.relate(a, "library/new.md", "library/old.md", "supersedes")
        assert [r["path"] for r in search(a, "사과")] == ["library/new.md"]
        assert len(search(a, "사과", include_deprecated=True)) == 2
        assert store.get_document(a, "library/old.md")["invalid_at"] is not None
        assert a.execute("SELECT count(*) AS n FROM kb.events").fetchone()["n"] >= 6


def test_relation_failure_rolls_back(db, as_user):
    import psycopg

    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(a, "library/a.md", RAW, team)
        store.write(a, "library/b.md", RAW, team)
    with as_user("viewer") as v:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            store.relate(v, "library/a.md", "library/b.md", "supersedes")
    assert db.execute("SELECT count(*) AS n FROM kb.relations").fetchone()["n"] == 0
    assert (
        db.execute(
            "SELECT count(*) AS n FROM kb.documents WHERE status='deprecated'"
        ).fetchone()["n"]
        == 0
    )


def test_private_children_and_workspace_isolation(db, as_user):
    from kb.cli import add_user

    add_user(db, "b", "kb_test_b", "other", "owner")
    db.commit()
    with as_user("a") as a:
        team, private = setup_scopes(a)
        store.write(a, "library/private.md", RAW, private)
        store.write(a, "library/private.md", RAW + "new", private, expected_version=1)
    with as_user("b") as b:
        for table in [
            "documents",
            "chunks",
            "sources",
            "document_versions",
            "embeddings",
        ]:
            assert b.execute("SELECT * FROM kb." + table).fetchall() == []
        other = store.ensure_scope(b, store.workspace(b, "other"))
        store.write(b, "library/other.md", RAW, other)
    with as_user("a") as a:
        assert "library/other.md" not in [r["path"] for r in search(a, "사과")]


def test_vector_index_and_unprivileged_admin(db, as_user):
    import psycopg

    db.execute("SELECT kb.ensure_vector_index('test-fixed',2)")
    db.execute("SELECT kb.ensure_vector_index('test-fixed',2)")
    assert (
        db.execute(
            "SELECT count(*) AS n FROM pg_indexes WHERE schemaname='kb' AND indexname LIKE 'emb_hnsw_%'"
        ).fetchone()["n"]
        == 1
    )
    with as_user("b") as b:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            b.execute("SELECT kb.ensure_vector_index('hijack',2)")


def test_postgres_mcp_dispatch(db, as_user, monkeypatch):
    import server
    from psycopg.conninfo import conninfo_to_dict, make_conninfo

    options = conninfo_to_dict(db.info.dsn)
    options["user"] = "kb_test_a"
    monkeypatch.setenv("LIBRARY_BACKEND", "postgres")
    monkeypatch.setenv("LIBRARY_DATABASE_URL", make_conninfo(**options))
    monkeypatch.setenv("LIBRARY_WORKSPACE", "test")
    with as_user("a") as a:
        sid = store.ensure_scope(a, store.workspace(a), "repo", "demo")
        store.write(a, "decisions/demo/stack/db.md", RAW, sid, kind="decision")
    result = server.library_write("library/new.md", RAW, kind="inbox")
    assert "version=1" in result
    assert "library/new.md" in server.library_search("사과")
    assert parse(server.library_read("library/new.md"))[1] == parse(RAW)[1]
    assert "library/new.md" in server.library_list()
    assert "decisions/demo/stack/db.md" in server.decision_list("demo")
    assert "decisions/demo/stack/db.md" in server.decision_search("사과", "demo")
    assert parse(server.decision_read("decisions/demo/stack/db.md"))[1] == parse(RAW)[1]
    server.library_promote("library/new.md")
    server.library_write("library/old.md", RAW)
    server.library_relate("library/new.md", "library/old.md", "supersedes")
    assert "library/old.md ·" not in server.library_search("사과")
    with as_user("a") as a:
        old = store.get_document(a, "library/old.md")
        assert old["frontmatter"]["status"] == "deprecated"
        assert database.doctor(a)["app_role_safe"]


def test_concurrent_optimistic_write(db, as_user):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier

    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(a, "library/shared.md", RAW, team)
    barrier = Barrier(2)

    def edit(suffix):
        with as_user("b") as b:
            barrier.wait(timeout=5)
            try:
                return store.write(
                    b, "library/shared.md", RAW + suffix, team, expected_version=1
                )["version"]
            except store.ConflictError:
                return "conflict"

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(edit, ["one", "two"]))
    assert sorted(map(str, results)) == ["2", "conflict"]
    assert (
        db.execute("SELECT count(*) AS n FROM kb.document_versions").fetchone()["n"]
        == 1
    )


def test_import_excludes_guide_and_export_rejects_symlink(db, as_user, tmp_path):
    root = tmp_path / "root"
    (root / "library").mkdir(parents=True)
    (root / "decisions").mkdir()
    (root / "library/a.md").write_text(RAW)
    (root / "decisions/DECISIONS-GUIDE.md").write_text("guide")
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "library/leak.md").symlink_to(outside / "leak.md")
    (outside / "leak.md").write_text("private")
    with as_user("a") as a:
        report = store.import_library(a, root, "test")
        assert (report["files"], report["insert"], report["failed"]) == (2, 1, 1)
        out = tmp_path / "export"
        out.mkdir()
        (out / "library").symlink_to(outside, target_is_directory=True)
        with pytest.raises(ValueError, match="루트 밖"):
            store.export_library(a, out, "test")
        assert not (outside / "a.md").exists()


def test_search_scope_budget_and_fake_pending(db, as_user):
    with as_user("a") as a:
        team, private = setup_scopes(a)
        store.write(a, "library/public.md", RAW, team)
        store.write(a, "library/private.md", RAW, private)
        assert [r["path"] for r in search(a, "사과", scope=team)] == [
            "library/public.md"
        ]
        assert search(a, "사과", token_budget=2) == []
        assert embed_pending(a, Provider("fake")) == 4
        assert embed_pending(a, Provider("fake")) == 0
        store.write(a, "library/public.md", RAW + "changed", team, expected_version=1)
        assert embed_pending(a, Provider("fake")) == 2


def test_mcp_secret_refused_without_database(monkeypatch):
    import server

    monkeypatch.setenv("LIBRARY_BACKEND", "postgres")
    monkeypatch.setenv("LIBRARY_DATABASE_URL", "postgresql://invalid")
    with pytest.raises(ValueError, match="비밀정보"):
        server.library_write("library/no.md", "sk-" + "a" * 30)


def test_title_only_document_is_searchable(db, as_user):
    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(
            a, "library/empty.md", "---\ntype: Concept\ntitle: 유일제목\n---\n", team
        )
        assert search(a, "유일제목")[0]["path"] == "library/empty.md"


def test_keyword_case_path_and_short_token_boundaries(db, as_user):
    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(
            a,
            "library/ops/HTTP-timeout.md",
            "---\ntype: Gotcha\ntitle: 연결\n---\n",
            team,
        )
        store.write(
            a, "library/movie.md", "---\ntype: Gotcha\ntitle: IMDb\n---\n", team
        )
        store.write(
            a, "library/storage.md", "---\ntype: Gotcha\ntitle: DB\n---\n", team
        )
        assert search(a, "http timeout?")[0]["path"] == "library/ops/HTTP-timeout.md"
        assert [r["path"] for r in search(a, "db")] == ["library/storage.md"]
        assert [r["path"] for r in search(a, "DB DB!")] == ["library/storage.md"]
        assert search(a, "% _") == []


def test_document_candidates_are_not_crowded_out_by_chunks(db, as_user):
    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(
            a,
            "library/many.md",
            "---\ntype: Gotcha\ntitle: needle\n---\n"
            + "".join(f"## Section {i}\nneedle\n" for i in range(60)),
            team,
        )
        store.write(
            a,
            "library/other.md",
            "---\ntype: Gotcha\ntitle: Another\n---\nneedle\n",
            team,
        )
        assert {r["path"] for r in search(a, "needle")} == {
            "library/many.md",
            "library/other.md",
        }


def test_document_terms_across_sections_and_metadata_weight(db, as_user):
    with as_user("a") as a:
        team, _ = setup_scopes(a)
        store.write(
            a,
            "library/relevant.md",
            "---\ntype: Gotcha\ntitle: 저장소\ndescription: 복구\n---\n"
            + "## 첫째\n데이터\n"
            + "설명 " * 2000
            + "\n## 둘째\n백업\n",
            team,
        )
        store.write(
            a,
            "library/noisy.md",
            "---\ntype: Gotcha\ntitle: 다른 문서\n---\n데이터 백업\n",
            team,
        )
        assert (
            search(a, "저장소의 데이터 백업 복구는?")[0]["path"]
            == "library/relevant.md"
        )
