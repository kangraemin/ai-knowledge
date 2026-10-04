"""키워드·벡터 후보를 문서 단위 RRF로 융합한다."""

from .embed import provider, vector_literal


def format_results(rows, token_budget=1500):
    # UTF-8 바이트 수는 한/영 모두에서 보수적인 토큰 상한으로 사용한다.
    out, used = [], 0
    for row in rows:
        line = " · ".join(
            str(row.get(key) or "").replace("\n", " ")[:160]
            if key == "description"
            else str(row.get(key) or "").replace("\n", " ")
            for key in ("path", "title", "description")
        )
        if row.get("supersedes"):
            line += " [대체: " + ", ".join(row["supersedes"]) + "]"
        cost = len((line + "\n").encode())
        if used + cost > token_budget:
            break
        out.append(line)
        used += cost
    return "\n".join(out)


def search(
    conn,
    query,
    scope=None,
    include_deprecated=False,
    k=7,
    token_budget=None,
    embedder=None,
    kind=None,
    repo=None,
):
    terms = query.strip().split()
    if not terms or k <= 0:
        return []
    where, params = ["true"], []
    if not include_deprecated:
        where.append(
            "d.status<>'deprecated' AND d.invalid_at IS NULL AND NOT EXISTS(SELECT 1 FROM kb.relations r WHERE r.dst_id=d.id AND r.type='supersedes' AND r.invalid_at IS NULL)"
        )
    if scope:
        where.append("d.scope_id=%s")
        params.append(scope)
    if kind:
        where.append("d.kind=%s")
        params.append(kind)
    if repo:
        where.append(
            "EXISTS(SELECT 1 FROM kb.scopes s WHERE s.id=d.scope_id AND s.kind='repo' AND s.key=%s)"
        )
        params.append(repo)
    predicate = " AND ".join(where)
    # LIKE 후보는 토큰별로 합집합을 만들고 bigm_similarity로 정렬한다.
    keyword = conn.execute(
        f"""SELECT id,max(score) AS score FROM (SELECT d.id,c.id AS chunk_id,t.score FROM kb.documents d
        JOIN kb.chunks c ON c.doc_id=d.id
        CROSS JOIN LATERAL (
          SELECT sum(bigm_similarity(c.text,q) + 2*bigm_similarity(d.title||' '||coalesce(d.description,''),q)) AS score
          FROM unnest(%s::text[]) q WHERE c.text LIKE likequery(q)
          OR d.title||' '||coalesce(d.description,'') LIKE likequery(q)
          OR c.text =%% q OR (d.title||' '||coalesce(d.description,'')) =%% q
        ) t WHERE {predicate} AND t.score IS NOT NULL
        ORDER BY t.score DESC,c.id LIMIT 50) candidates
        GROUP BY id ORDER BY score DESC,id""",
        (terms, *params),
    ).fetchall()
    lists = [keyword]
    embedder = embedder or provider()
    if embedder.name != "none":
        vector = embedder.encode([query], query=True)[0]
        semantic = conn.execute(
            f"""SELECT id,min(distance) AS distance FROM (SELECT d.id,c.id AS chunk_id,e.vec <=> %s::vector AS distance
            FROM kb.embeddings e JOIN kb.chunks c ON c.id=e.chunk_id JOIN kb.documents d ON d.id=c.doc_id
            WHERE e.model=%s AND e.dim=%s AND {predicate}
            ORDER BY distance,c.id LIMIT 50) candidates GROUP BY id ORDER BY distance,id""",
            (vector_literal(vector), embedder.model, len(vector), *params),
        ).fetchall()
        lists.append(semantic)
    scores = {}
    for ranking in lists:
        for rank, row in enumerate(ranking, 1):
            scores[row["id"]] = scores.get(row["id"], 0) + 1 / (60 + rank)
    ids = sorted(scores, key=lambda id: (-scores[id], str(id)))[:k]
    rows = []
    if ids:
        fetched = conn.execute(
            """SELECT d.id,d.path,d.title,d.description,d.version,d.scope_id,
            ARRAY(SELECT target.path FROM kb.relations r JOIN kb.documents target ON target.id=r.dst_id
                  WHERE r.src_id=d.id AND r.type='supersedes' AND r.invalid_at IS NULL) AS supersedes
            FROM kb.documents d WHERE d.id=ANY(%s)""",
            (ids,),
        ).fetchall()
        by_id = {r["id"]: r for r in fetched}
        rows = [by_id[id] for id in ids if id in by_id]
    conn.execute(
        "INSERT INTO kb.events(user_id,action,query) VALUES(kb.current_user_id(),'search',%s)",
        (query,),
    )
    if token_budget is not None:
        kept = []
        for row in rows:
            if (
                len(format_results(kept + [row], token_budget).splitlines())
                != len(kept) + 1
            ):
                break
            kept.append(row)
        rows = kept
    return rows
