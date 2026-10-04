"""claude-library-kb 관리·검색 CLI."""

import argparse
import json
import sys
from pathlib import Path
from . import db, store
from .search import search, format_results


def default_queries_path():
    """평가셋은 라이브러리 내용에서 만든다 — 공개 레포가 아니라 라이브러리 쪽에 둔다."""
    import os

    env = os.environ.get("LIBRARY_EVAL_QUERIES")
    if env:
        return Path(env)
    root = Path(os.environ.get("LIBRARY_ROOT", Path.home() / "claude-library"))
    return root / "eval/search/queries.jsonl"


def evaluate(backend, queries, conn=None, split=None):
    import server

    ranks = []
    for line in Path(queries).read_text().splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        if split is not None and item.get("split") != split:
            continue
        rows = (
            server._search(item["q"]) if backend == "files" else search(conn, item["q"])
        )
        ranks.append(
            next((i for i, r in enumerate(rows, 1) if r["path"] in item["expected"]), 0)
        )
    n = len(ranks)
    if not n:
        raise ValueError("빈 평가셋")
    return {
        "n": n,
        "R@1": sum(r == 1 for r in ranks) / n,
        "R@5": sum(0 < r <= 5 for r in ranks) / n,
        "MRR": sum(1 / r if r else 0 for r in ranks) / n,
    }


def add_user(conn, handle, db_role, slug, role):
    from psycopg import sql

    exists = conn.execute(
        "SELECT 1 FROM pg_roles WHERE rolname=%s", (db_role,)
    ).fetchone()
    commands = [
        sql.SQL("CREATE ROLE {} LOGIN;")
        .format(sql.Identifier(db_role))
        .as_string(conn),
        sql.SQL("GRANT kb_app TO {};").format(sql.Identifier(db_role)).as_string(conn),
    ]
    if not exists:
        return {
            "mapped": False,
            "sql": commands,
            "message": "관리 계정으로 SQL 실행 후 다시 add-user를 실행하세요",
        }
    with conn.transaction():
        # 사용자 롤 생성/권한 부여는 관리자가 출력 SQL을 검토해서 실행한다.
        wid = conn.execute(
            "INSERT INTO kb.workspaces(slug,name) VALUES(%s,%s) ON CONFLICT(slug) DO UPDATE SET name=excluded.name RETURNING id",
            (slug, slug),
        ).fetchone()["id"]
        uid = conn.execute(
            "INSERT INTO kb.users(handle,db_role) VALUES(%s,%s) ON CONFLICT(handle) DO UPDATE SET db_role=excluded.db_role RETURNING id",
            (handle, db_role),
        ).fetchone()["id"]
        conn.execute(
            "INSERT INTO kb.members(workspace_id,user_id,role) VALUES(%s,%s,%s) ON CONFLICT(workspace_id,user_id) DO UPDATE SET role=excluded.role",
            (wid, uid, role),
        )
    return {"mapped": True, "sql": commands[1:]}


def parser():
    p = argparse.ArgumentParser(prog="claude-library-kb")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("migrate")
    sub.add_parser("doctor")
    s = sub.add_parser("search")
    s.add_argument("query")
    s.add_argument("--format", choices=["text", "inject", "json"], default="text")
    s.add_argument("--budget", type=int, default=1500)
    s.add_argument("--scope")
    s.add_argument("--include-deprecated", action="store_true")
    s.add_argument("-k", type=int, default=7)
    s = sub.add_parser("decisions")
    s.add_argument("repo")
    s = sub.add_parser("import")
    s.add_argument("library_root")
    s.add_argument("--workspace", required=True)
    s.add_argument("--scope-kind", choices=["team", "personal"], default="team")
    s.add_argument("--scope-key", default="default")
    s = sub.add_parser("export")
    s.add_argument("out_dir")
    s.add_argument("--workspace", required=True)
    s = sub.add_parser("embed")
    s.add_argument("--pending", action="store_true", required=True)
    s = sub.add_parser("eval")
    s.add_argument("--backend", choices=["files", "postgres"], required=True)
    s.add_argument("--split", choices=["dev", "test"])
    s.add_argument(
        "--queries", default=str(default_queries_path())
    )
    s = (
        sub.add_parser("admin")
        .add_subparsers(dest="admin_command", required=True)
        .add_parser("add-user")
    )
    s.add_argument("handle")
    s.add_argument("--db-role", required=True)
    s.add_argument("--workspace", required=True)
    s.add_argument("--role", choices=["owner", "editor", "viewer"], default="editor")
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        from .api import postgres

        if args.command == "search" and not postgres():
            import server

            rows = server._search(args.query)[: args.k]
            result = (
                json.dumps(rows, ensure_ascii=False)
                if args.format == "json"
                else format_results(rows, args.budget)
            )
        elif args.command == "decisions":
            import server

            result = server.decision_list(args.repo)
        elif args.command == "eval" and args.backend == "files":
            result = evaluate("files", args.queries, split=args.split)
        else:
            with db.connect() as conn:
                if args.command == "migrate":
                    db.migrate(conn)
                    result = "마이그레이션 완료"
                elif args.command == "doctor":
                    result = db.doctor(conn)
                elif args.command == "admin":
                    result = add_user(
                        conn, args.handle, args.db_role, args.workspace, args.role
                    )
                elif args.command == "import":
                    result = store.import_library(
                        conn,
                        args.library_root,
                        args.workspace,
                        args.scope_kind,
                        args.scope_key,
                    )
                elif args.command == "export":
                    result = {
                        "exported": store.export_library(
                            conn, args.out_dir, args.workspace
                        )
                    }
                elif args.command == "embed":
                    from .embed import embed_pending

                    result = {"embedded": embed_pending(conn)}
                elif args.command == "eval":
                    result = evaluate("postgres", args.queries, conn, split=args.split)
                elif args.command == "search":
                    sid = store.resolve_scope(conn, args.scope) if args.scope else None
                    rows = search(
                        conn,
                        args.query,
                        scope=sid,
                        include_deprecated=args.include_deprecated,
                        k=args.k,
                    )
                    result = (
                        json.dumps(rows, default=str, ensure_ascii=False)
                        if args.format == "json"
                        else format_results(rows, args.budget)
                    )
        if result:
            print(
                result
                if isinstance(result, str)
                else json.dumps(result, default=str, ensure_ascii=False)
            )
        if isinstance(result, dict) and result.get("failed", 0):
            return 1
        return 0
    except Exception as exc:
        print(f"오류: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
