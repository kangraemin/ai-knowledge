"""문서 쓰기와 import/export. 각 쓰기는 이력·청크·이벤트와 함께 커밋한다."""

import os
import re
from pathlib import Path
from .markdown import parse, render, digest, chunks, scan_secrets, validate_path


class ConflictError(ValueError):
    pass


def workspace(conn, slug=None):
    slug = slug or os.environ.get("LIBRARY_WORKSPACE")
    if not slug:
        raise ValueError("LIBRARY_WORKSPACE 또는 --workspace가 필요합니다")
    row = conn.execute("SELECT id FROM kb.workspaces WHERE slug=%s", (slug,)).fetchone()
    if not row:
        raise ValueError("접근 가능한 workspace가 없습니다")
    return row["id"]


def ensure_scope(conn, workspace_id, kind="team", key="default"):
    found = conn.execute(
        "SELECT id FROM kb.scopes WHERE workspace_id=%s AND kind=%s AND key=%s",
        (workspace_id, kind, key),
    ).fetchone()
    if found:
        return found["id"]
    owner = (
        conn.execute("SELECT kb.current_user_id() AS id").fetchone()["id"]
        if kind == "personal"
        else None
    )
    return conn.execute(
        """INSERT INTO kb.scopes(workspace_id,kind,key,owner_user_id) VALUES(%s,%s,%s,%s)
        ON CONFLICT(workspace_id,kind,key) DO UPDATE SET key=excluded.key RETURNING id""",
        (workspace_id, kind, key, owner),
    ).fetchone()["id"]


def resolve_scope(conn, scope=None):
    wid = workspace(conn)
    if scope:
        row = conn.execute(
            "SELECT id FROM kb.scopes WHERE workspace_id=%s AND (id::text=%s OR kind||':'||key=%s)",
            (wid, str(scope), str(scope)),
        ).fetchone()
        if not row:
            raise ValueError("접근 가능한 scope가 없습니다 (UUID 또는 team:key 형식)")
        return row["id"]
    return ensure_scope(conn, wid)


def get_document(conn, path, scope=None):
    path = validate_path(path)
    sql, args = (
        "SELECT d.* FROM kb.documents d JOIN kb.scopes s ON s.id=d.scope_id WHERE d.path=%s",
        [path],
    )
    if scope:
        sql += " AND d.scope_id=%s"
        args.append(scope)
    elif os.environ.get("LIBRARY_WORKSPACE"):
        sql += " AND s.workspace_id=%s"
        args.append(workspace(conn))
    rows = conn.execute(sql, args).fetchall()
    if len(rows) > 1:
        raise ValueError("동일 경로가 여러 scope에 있습니다. scope를 지정하세요")
    if not rows:
        raise ValueError("문서를 찾을 수 없습니다")
    return rows[0]


def _event(conn, action, doc_id):
    conn.execute(
        "INSERT INTO kb.events(user_id,doc_id,action) VALUES(kb.current_user_id(),%s,%s)",
        (doc_id, action),
    )


def _derived(conn, row):
    for ord, (heading, text) in enumerate(
        list(chunks(row["body"])) or [("", row["title"])]
    ):
        conn.execute(
            "INSERT INTO kb.chunks(doc_id,ord,heading,text) VALUES(%s,%s,%s,%s)",
            (row["id"], ord, heading, text),
        )
    for source in row["frontmatter"].get("sources", []) or []:
        if isinstance(source, dict):
            conn.execute(
                "INSERT INTO kb.sources(doc_id,ref_id,resource,title) VALUES(%s,%s,%s,%s)",
                (
                    row["id"],
                    str(source.get("id", "")),
                    str(source.get("resource", "")),
                    str(source.get("title", "")),
                ),
            )


def write(
    conn,
    path,
    markdown,
    scope_id,
    expected_version=None,
    kind="knowledge",
    importing=False,
):
    from psycopg.types.json import Jsonb

    path = validate_path(path)
    # 명시적 로컬 import는 기존 문서를 보존한다. MCP 쓰기는 항상 스캔한다.
    if not importing:
        scan_secrets(markdown)
    meta, body = parse(markdown)
    title = str(
        meta.get("title")
        or next(
            (line[2:] for line in body.splitlines() if line.startswith("# ")),
            Path(path).stem,
        )
    )
    status = meta.get("status", "draft" if kind == "inbox" else "stable")
    if status not in ("draft", "stable", "deprecated"):
        raise ValueError(f"지원하지 않는 status: {status}")
    parts = Path(path).parts
    tags = meta.get("tags", []) or []
    if isinstance(tags, str):
        tags = [tags]
    values = dict(
        kind=kind,
        type=str(meta.get("type", "Knowledge")),
        title=title,
        description=str(meta.get("description", "")),
        body=body,
        category=str(meta.get("category", parts[1] if len(parts) > 2 else "")),
        subcategory=str(meta.get("subcategory", parts[2] if len(parts) > 3 else "")),
        tags=[str(t) for t in tags],
        status=status,
        confidence=meta.get("confidence"),
        evidence_count=meta.get("evidence_count"),
        frontmatter=Jsonb(meta),
        content_hash=digest(markdown),
    )
    with conn.transaction():
        # 동일 경로의 동시 생성도 직렬화한다. 접근 권한은 아래 DML의 RLS가 판정한다.
        conn.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s,0))",
            (str(scope_id) + ":" + path,),
        )
        old = conn.execute(
            "SELECT * FROM kb.documents WHERE scope_id=%s AND path=%s FOR UPDATE",
            (scope_id, path),
        ).fetchone()
        if old and importing and old["content_hash"] == values["content_hash"]:
            return {"action": "skip", "id": old["id"], "version": old["version"]}
        if old and not importing and expected_version != old["version"]:
            raise ConflictError(
                f"version 충돌: 현재 {old['version']}, expected_version 필요"
            )
        if not old and expected_version not in (None, 0):
            raise ConflictError(
                "문서가 없으므로 expected_version은 0 또는 생략이어야 합니다"
            )
        keys = list(values)
        if old:
            row = conn.execute(
                "UPDATE kb.documents SET "
                + ",".join(k + "=%s" for k in keys)
                + ", author_id=kb.current_user_id(), invalid_at=CASE WHEN %s='deprecated' THEN now() ELSE NULL END WHERE id=%s AND version=%s RETURNING *",
                (*values.values(), status, old["id"], old["version"]),
            ).fetchone()
            if row is None:
                raise ConflictError("version 충돌 또는 쓰기 권한 없음")
            action = "update"
        else:
            row = conn.execute(
                "INSERT INTO kb.documents(scope_id,path,"
                + ",".join(keys)
                + ",author_id) VALUES(%s,%s,"
                + ",".join(["%s"] * len(keys))
                + ",kb.current_user_id()) RETURNING *",
                (scope_id, path, *values.values()),
            ).fetchone()
            action = "insert"
        if not old or old["body"] != body or old["frontmatter"] != meta:
            _derived(conn, row)
        _event(conn, action, row["id"])
        return {"action": action, "id": row["id"], "version": row["version"]}


def relate(conn, src_path, dst_path, relation_type, scope=None):
    with conn.transaction():
        src, dst = (
            get_document(conn, src_path, scope),
            get_document(conn, dst_path, scope),
        )
        conn.execute(
            """INSERT INTO kb.relations(src_id,dst_id,type,created_by) VALUES(%s,%s,%s,kb.current_user_id())
            ON CONFLICT(src_id,dst_id,type) DO UPDATE SET invalid_at=NULL""",
            (src["id"], dst["id"], relation_type),
        )
        if relation_type == "supersedes":
            _change_status(conn, dst, "deprecated", superseded_by=src_path)
        _event(conn, "relate:" + relation_type, src["id"])


def _change_status(conn, doc, status, kind=None, superseded_by=None):
    from psycopg.types.json import Jsonb

    meta = dict(doc["frontmatter"], status=status)
    if superseded_by is not None:
        meta["superseded_by"] = superseded_by
    raw = render(meta, doc["body"])
    row = conn.execute(
        """UPDATE kb.documents SET kind=%s,status=%s,frontmatter=%s,content_hash=%s,
        invalid_at=CASE WHEN %s='deprecated' THEN now() ELSE NULL END
        WHERE id=%s AND version=%s RETURNING *""",
        (
            kind or doc["kind"],
            status,
            Jsonb(meta),
            digest(raw),
            status,
            doc["id"],
            doc["version"],
        ),
    ).fetchone()
    if not row:
        raise ConflictError("version 충돌 또는 쓰기 권한 없음")
    if meta != doc["frontmatter"]:
        _derived(conn, row)


def promote(conn, path, scope=None):
    with conn.transaction():
        doc = get_document(conn, path, scope)
        if doc["kind"] != "inbox":
            raise ValueError("inbox 문서만 promote할 수 있습니다")
        _change_status(conn, doc, "stable", kind="knowledge")
        _event(conn, "promote", doc["id"])


def import_library(conn, root, workspace_slug, scope_kind="team", scope_key="default"):
    root = Path(root).resolve()
    report = dict(files=0, insert=0, update=0, skip=0, failed=0, errors=[])
    wid = workspace(conn, workspace_slug)
    default_scope = ensure_scope(conn, wid, scope_kind, scope_key)
    imported = []
    for folder in ("library", "decisions"):
        for path in sorted((root / folder).rglob("*.md")):
            if path.name in ("index.md", "log.md", "_template.md"):
                continue
            rel = path.relative_to(root).as_posix()
            if folder == "decisions" and len(Path(rel).parts) != 4:
                continue
            report["files"] += 1
            try:
                if not path.resolve().is_relative_to(root):
                    raise ValueError("루트 밖 심볼릭 링크")
                with conn.transaction():
                    sid, kind = default_scope, "knowledge"
                    if folder == "decisions":
                        if len(Path(rel).parts) != 4:
                            raise ValueError(
                                "decisions/<repo>/<category>/<file>.md 형식 필요"
                            )
                        sid, kind = (
                            ensure_scope(conn, wid, "repo", Path(rel).parts[1]),
                            "decision",
                        )
                    raw = path.read_bytes().decode("utf-8")
                    result = write(conn, rel, raw, sid, kind=kind, importing=True)
                    imported.append((result["id"], sid, raw, rel))
                    report[result["action"]] += 1
            except Exception as exc:
                report["failed"] += 1
                report["errors"].append({"path": rel, "error": str(exc)})
    # 명시적 링크만 해석한다. 정정/철회 문구로 상태를 추론하지 않는다.
    stems = {}
    for did, sid, raw, rel in imported:
        stems.setdefault((sid, Path(rel).stem), []).append(did)
    for did, sid, raw, rel in imported:
        links = re.findall(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", raw)
        for line in raw.splitlines():
            if line.startswith("관련:"):
                links.extend(re.findall(r"\[[^\]]+\]\(([^)]+)\)", line))
        for name in links:
            matches = stems.get((sid, Path(name).stem), [])
            if len(matches) == 1 and matches[0] != did:
                with conn.transaction():
                    linked = conn.execute(
                        "INSERT INTO kb.relations(src_id,dst_id,type,created_by) VALUES(%s,%s,'related',kb.current_user_id()) ON CONFLICT DO NOTHING RETURNING id",
                        (did, matches[0]),
                    ).fetchone()
                    if linked:
                        _event(conn, "import:related", did)
    return report


def export_library(conn, out_dir, workspace_slug):
    root = Path(out_dir).resolve()
    rows = conn.execute(
        "SELECT d.* FROM kb.documents d JOIN kb.scopes s ON s.id=d.scope_id WHERE s.workspace_id=%s ORDER BY d.path",
        (workspace(conn, workspace_slug),),
    ).fetchall()
    paths = [row["path"] for row in rows]
    if len(set(paths)) != len(paths):
        raise ValueError("scope 간 경로 중복: 무손실 export 불가")
    targets = []
    for row in rows:
        target = root / validate_path(row["path"])
        if not target.resolve().is_relative_to(root):
            raise ValueError("출력 경로가 루트 밖을 가리킵니다")
        targets.append((target, row))
    for target, row in targets:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(render(row["frontmatter"], row["body"]).encode("utf-8"))
    return len(rows)
