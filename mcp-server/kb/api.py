"""MCP와 CLI가 공유하는 백엔드 어댑터."""

import os
from .db import connect
from .markdown import render
from .search import search, format_results
from . import store


def postgres():
    backend = os.environ.get("LIBRARY_BACKEND", "files")
    if backend not in ("files", "postgres"):
        raise ValueError("LIBRARY_BACKEND는 files 또는 postgres여야 합니다")
    return backend == "postgres"


def search_text(query, **kwargs):
    with connect() as conn:
        return (
            format_results(search(conn, query, **kwargs))
            or f"'{query}' 관련 라이브러리 항목 없음."
        )


def read(path):
    with connect() as conn:
        doc = store.get_document(conn, path)
        return render(doc["frontmatter"], doc["body"])


def listing(repo=None):
    with connect() as conn:
        sql = "SELECT d.* FROM kb.documents d JOIN kb.scopes s ON s.id=d.scope_id WHERE d.status<>'deprecated' AND d.invalid_at IS NULL"
        args = []
        if repo is not None:
            sql += " AND d.kind='decision' AND s.kind='repo' AND s.key=%s"
            args.append(repo)
        rows = conn.execute(sql + " ORDER BY d.path", args).fetchall()
        if repo is not None:
            return "\n\n".join(
                row["path"] + "\n" + render(row["frontmatter"], row["body"])
                for row in rows
            )
        return format_results(rows, token_budget=100000)


def write(path, markdown, scope=None, expected_version=None, kind="knowledge"):
    from .markdown import scan_secrets

    scan_secrets(markdown)
    with connect() as conn:
        sid = store.resolve_scope(conn, scope)
        similar = search(conn, markdown[:1000], scope=sid, k=5)
        result = store.write(conn, path, markdown, sid, expected_version, kind)
        return (
            f"{result['action']}: {path} (version={result['version']})\n유사 문서:\n"
            + format_results(similar, token_budget=10000)
            + "\n중복·모순은 library_relate로 연결하거나 supersedes로 대체하세요."
        )
