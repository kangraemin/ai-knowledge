import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from kb import activity
from kb.cli import main
from kb.relevance import normalized, select


@pytest.fixture
def files(tmp_path, monkeypatch):
    import server
    root = tmp_path / "library"
    (root / "library").mkdir(parents=True)
    monkeypatch.setenv("LIBRARY_ROOT", str(root))
    monkeypatch.setattr(server, "LIBRARY_ROOT", root)
    monkeypatch.setattr(server, "_index_cache", None)
    (root / "library/new.md").write_text("---\ntype: Concept\ntitle: 데이터베이스 백업 복구\n---\n데이터베이스 백업 복구")
    (root / "library/old.md").write_text("---\ntype: Concept\ntitle: 데이터베이스 백업\nstatus: deprecated\nsuperseded_by: library/new.md\n---\n옛 내용")
    return server, root


def events(root):
    return [json.loads(line) for p in (root / ".activity").glob("search-*.jsonl") for line in p.read_text().splitlines()]


def test_file_search_read_deprecated_and_log(files, monkeypatch):
    server, root = files
    monkeypatch.setenv("LIBRARY_SESSION_ID", "one")
    assert "old.md" not in server.library_search("데이터베이스 백업")
    assert "(대체됨 → library/new.md)" in server.library_read("library/old.md")
    rows = server._search("데이터베이스 백업", include_deprecated=True)
    assert len(rows) == 2 and all(0 <= row["score"] <= 1 for row in rows)
    logged = events(root)
    assert [e["action"] for e in logged] == ["search", "read"]
    assert logged[0]["results"][0]["path"] == "library/new.md"
    assert logged[0]["source"] == "mcp" and logged[0]["backend"] == "files"
    assert logged[1]["session_id"] == "one"


def test_log_disabled_and_broken_destination(files, monkeypatch):
    server, root = files
    monkeypatch.setenv("LIBRARY_LOG", "0")
    assert "new.md" in server.library_search("백업")
    assert events(root) == []
    monkeypatch.delenv("LIBRARY_LOG")
    (root / ".activity").write_text("not a directory")
    assert "new.md" in server.library_search("백업")
    assert "백업" in server.library_read("library/new.md")


def test_cli_threshold_budget_and_stats(files, monkeypatch, capsys):
    _, root = files
    monkeypatch.setenv("LIBRARY_AUTOINJECT_MIN_SCORE", "1")
    assert main(["search", "--format", "inject", "데이터베이스 백업"]) == 0
    assert capsys.readouterr().out == ""
    assert events(root)[-1]["skipped_reason"] == "low_score"
    monkeypatch.setenv("LIBRARY_AUTOINJECT_MIN_SCORE", "0")
    assert main(["search", "--format", "inject", "--budget", "1", "백업"]) == 0
    assert events(root)[-1]["skipped_reason"] == "budget"
    assert main(["search", "--format", "inject", "데이터베이스 백업"]) == 0
    assert "new.md" in capsys.readouterr().out
    assert events(root)[-1]["injected"] is True
    assert main(["search", "--format", "json", "백업"]) == 0
    assert json.loads(capsys.readouterr().out)[0]["score"] > 0
    assert events(root)[-1]["source"] == "cli"
    assert main(["stats", "--days", "1"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["injections"] == 1 and report["skip_reasons"] == {"low_score": 1, "budget": 1}


@pytest.mark.parametrize("value", ["nan", "inf", "-1", "1.1", "bad"])
def test_invalid_threshold(value, monkeypatch):
    monkeypatch.setenv("LIBRARY_AUTOINJECT_MIN_SCORE", value)
    with pytest.raises(ValueError):
        select([], "files", 1500)


def test_stats_only_later_same_session_reads(tmp_path):
    now = datetime.now(timezone.utc)
    def log(seconds, **row):
        activity.append({"ts": (now + timedelta(seconds=seconds)).isoformat(), **row}, tmp_path)
    log(-90, action="read", path="a", session_id="one")
    log(-80, injected=True, results=[{"path":"a", "score":.4}, {"path":"b", "score":.8}], session_id="one", latency_ms=10)
    log(-70, injected=True, results=[{"path":"a", "score":.2}], latency_ms=20)
    log(-60, action="read", path="b", session_id="other")
    log(-50, action="read", path="a", session_id="one")
    log(-40, action="read", path="a", session_id="one")
    log(-30, injected=False, results=[], skipped_reason="low_score", latency_ms=30)
    log(-40 * 86400, injected=True, results=[])
    path = next((tmp_path / ".activity").glob("*.jsonl"))
    with path.open("a") as stream:
        stream.write("broken json\n{}\n")
    report = activity.stats(30, tmp_path)
    assert report["injections"] == 2
    assert report["injected_documents"] == 3
    assert report["session_documents"] == 2
    assert report["read_documents"] == 1
    assert report["inject_to_read_rate"] == .5
    assert report["latency_ms"] == {"count":3,"p50":20,"p95":30}
    assert report["score_distribution"]["p50"] == .4


def test_hook_real_cli_session_and_skip(files, monkeypatch):
    _, root = files
    hook = Path(__file__).resolve().parents[2] / "hooks/library-autoinject.sh"
    monkeypatch.setenv("LIBRARY_KB_CMD", f"{sys.executable} -m kb.cli")
    monkeypatch.setenv("PYTHONPATH", str(Path(__file__).resolve().parents[1]))
    result = subprocess.run(["bash", str(hook)], input=json.dumps({"prompt":"데이터베이스 백업 복구", "session_id":"hook-session"}), text=True, capture_output=True)
    assert result.returncode == 0
    assert "new.md" in json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"]
    assert len(events(root)) == 1
    event = events(root)[0]
    assert event["session_id"] == "hook-session" and event["source"] == "autoinject" and event["injected"]
    result = subprocess.run(["bash", str(hook)], input=json.dumps({"prompt":"안녕", "session_id":"hook-session"}), text=True, capture_output=True)
    assert result.stdout == ""
    assert events(root)[-1]["skipped_reason"] == "short_or_command"


def test_postgres_logging_and_failure_isolation(db, as_user, monkeypatch, tmp_path):
    from kb import store, api
    from kb.search import search
    from psycopg.conninfo import conninfo_to_dict, make_conninfo
    with as_user("a") as conn:
        scope = store.ensure_scope(conn, store.workspace(conn, "test"))
        store.write(conn, "library/a.md", "---\ntype: Concept\ntitle: 백업 복구\n---\n백업", scope)
    options = conninfo_to_dict(db.info.dsn)
    options["user"] = "kb_test_a"
    monkeypatch.setenv("LIBRARY_DATABASE_URL", make_conninfo(**options))
    monkeypatch.setenv("LIBRARY_BACKEND", "postgres")
    assert "a.md" in api.search_text("백업")
    assert "백업" in api.read("library/a.md")
    with as_user("a") as conn:
        actions = [row["action"] for row in conn.execute("SELECT action FROM kb.events").fetchall()]
        assert "search" in actions and "read" in actions
        # 제약 위반을 savepoint로 격리해 다음 SELECT가 계속 실행되어야 한다.
        activity.pg_event(conn, "read", doc_id="not-a-uuid")
        assert search(conn, "백업")[0]["score"] > 0
    assert [e["action"] for e in events(Path(os.environ["LIBRARY_ROOT"]))] == ["search", "read"]
    assert main(["search", "--format", "inject", "백업 복구"]) == 0
    with as_user("a") as conn:
        assert conn.execute("SELECT count(*) AS n FROM kb.events WHERE action='inject'").fetchone()["n"] == 1
    monkeypatch.setenv("LIBRARY_LOG", "0")
    count = len(events(Path(os.environ["LIBRARY_ROOT"])))
    api.search_text("백업")
    api.read("library/a.md")
    assert len(events(Path(os.environ["LIBRARY_ROOT"]))) == count


def test_concurrent_append_is_complete(tmp_path):
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda i: activity.append({"source":"cli", "query":str(i)}, tmp_path), range(80)))
    assert len(events(tmp_path)) == 80
    assert len({e["query_sha256"] for e in events(tmp_path)}) == 80


def test_threshold_boundary_and_budget_rows(monkeypatch):
    score = normalized({"title":"백업 복구"}, ["백업", "복구"])
    monkeypatch.setenv("LIBRARY_AUTOINJECT_MIN_SCORE", str(score))
    row = {"path":"library/a.md", "title":"백업 복구", "score":score}
    assert select([row], "files", 1500) == ([row], None)
    import math
    monkeypatch.setenv("LIBRARY_AUTOINJECT_MIN_SCORE", str(math.nextafter(score, 1)))
    assert select([row], "files", 1500) == ([], "low_score")
    assert select([], "files", 1500) == ([], "no_results")


def test_files_title_particles_and_ascii_boundaries(files):
    server, root = files
    (root / "library/metadata.md").write_text("---\ntype: Concept\ntitle: 유일제목 DB\n---\n")
    (root / "library/noise.md").write_text("---\ntype: Concept\ntitle: IMDb\n---\n")
    assert server._search("유일제목은?")[0]["path"] == "library/metadata.md"
    assert [r["path"] for r in server._search("DB의")] == ["library/metadata.md"]


def test_deprecated_postgres_replacement_read(db, as_user, monkeypatch):
    from kb import store, api
    from psycopg.conninfo import conninfo_to_dict, make_conninfo
    raw = "---\ntype: Concept\ntitle: 교체\n---\n본문"
    with as_user("a") as conn:
        scope = store.ensure_scope(conn, store.workspace(conn, "test"))
        for path in ("library/old.md", "library/new.md"):
            store.write(conn, path, raw, scope)
        store.relate(conn, "library/new.md", "library/old.md", "supersedes")
        meta = store.get_document(conn, "library/old.md")["frontmatter"]
        assert meta["status"] == "deprecated" and meta["superseded_by"] == "library/new.md"
    options = conninfo_to_dict(db.info.dsn)
    options["user"] = "kb_test_a"
    monkeypatch.setenv("LIBRARY_DATABASE_URL", make_conninfo(**options))
    assert "(대체됨 → library/new.md)" in api.read("library/old.md")


def test_negative_fixture_is_public_and_split():
    rows = [json.loads(s) for s in (Path(__file__).resolve().parents[1] / "kb/eval/negatives.jsonl").read_text().splitlines()]
    assert len(rows) == 30 and len({r["q"] for r in rows}) == 30
    assert sum(r["split"] == "dev" for r in rows) == 15
    assert sum(r["split"] == "test" for r in rows) == 15
