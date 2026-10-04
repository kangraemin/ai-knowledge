"""키워드·벡터 후보를 문서 단위 RRF로 융합한다."""

import re

from .embed import provider, vector_literal


# Function words are not useful evidence in prose queries. This list is fixed,
# language-level vocabulary, not terms selected from evaluation questions.
_STOPWORDS = frozenset(
    "a an the and or but as at by for from in into of on to with "
    "is are was were be been being do does did have has had "
    "i we you it its this that these those how what which who "
    "where when why can could would should will".split()
)
_PARTICLES = re.compile(
    r"^([가-힣]{2,}?)(?:에서는|으로는|에서|에게|으로|까지|부터|처럼|보다|은|는|이|가|을|를|와|과|의|도|만)$"
)


def query_terms(query):
    """Normalize prose punctuation/case, common particles and repeated words."""
    terms = re.findall(r"[^\W_]+(?:[._+-][^\W_]+)*", query.lower())
    terms = [_PARTICLES.sub(r"\1", t) for t in terms if t not in _STOPWORDS]
    # 영문 기술명 뒤의 조사와 자주 쓰는 서술형 어미를 제거한다.
    terms = [re.sub(r"^([a-z][a-z0-9._+-]*)(?:에서는|에서|으로|은|는|이|가|을|를|의|도)$", r"\1", t) for t in terms]
    terms = [re.sub(r"^([가-힣]{2,}?)(?:했습니다|합니다|하였다|한다|하는|하기|하면|되는|됩니다|된다)$", r"\1", t) for t in terms]
    return list(dict.fromkeys([t for t in terms if len(t) > 1] or terms))


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
        if row.get("superseded_by"):
            line += " (대체됨 → " + str(row["superseded_by"]) + ")"
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
    terms = query_terms(query)
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
    # Score whole documents before limiting: repeated chunks must not consume
    # candidate slots. IDF is computed over accessible, filtered documents only.
    # Literal LIKE matching avoids length-biased whole-chunk bigram similarity.
    # ASCII tokens need boundaries (e.g. "DB" must not match "IMDb").
    patterns = [r"\m" + re.escape(t) + r"\M" if t.isascii() else None for t in terms]
    keyword = conn.execute(
        f"""WITH docs AS MATERIALIZED (
          SELECT d.id,lower(d.title) AS title,lower(coalesce(d.description,'')) AS description,
                 lower(d.path) AS path,lower(array_to_string(d.tags,' ')) AS tags,
                 lower(d.body) AS body
          FROM kb.documents d WHERE {predicate}
        ), matches AS (
          SELECT d.id,q.term,greatest(
            CASE WHEN d.title LIKE likequery(q.term) AND (q.pattern IS NULL OR d.title ~ q.pattern) THEN 6 ELSE 0 END,
            CASE WHEN d.description LIKE likequery(q.term) AND (q.pattern IS NULL OR d.description ~ q.pattern) THEN 4 ELSE 0 END,
            CASE WHEN d.path LIKE likequery(q.term) AND (q.pattern IS NULL OR d.path ~ q.pattern) THEN 5 ELSE 0 END,
            CASE WHEN d.tags LIKE likequery(q.term) AND (q.pattern IS NULL OR d.tags ~ q.pattern) THEN 3 ELSE 0 END,
            CASE WHEN d.body LIKE likequery(q.term) AND (q.pattern IS NULL OR d.body ~ q.pattern) THEN 1 ELSE 0 END
          ) AS weight
          FROM docs d CROSS JOIN unnest(%s::text[],%s::text[]) q(term,pattern)
        ), weighted AS (
          SELECT id,weight,ln(1.0 + (SELECT count(*) FROM docs)::numeric /
                    count(*) OVER (PARTITION BY term)) AS idf
          FROM matches WHERE weight>0
        ) SELECT id,sum(weight*idf)*count(*) AS score FROM weighted
          GROUP BY id ORDER BY score DESC,id LIMIT 50""",
        (*params, terms, patterns),
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
            """SELECT d.id,d.path,d.title,d.description,d.version,d.scope_id,d.body,d.tags,d.frontmatter,
            ARRAY(SELECT target.path FROM kb.relations r JOIN kb.documents target ON target.id=r.dst_id
                  WHERE r.src_id=d.id AND r.type='supersedes' AND r.invalid_at IS NULL) AS supersedes
            FROM kb.documents d WHERE d.id=ANY(%s)""",
            (ids,),
        ).fetchall()
        by_id = {r["id"]: r for r in fetched}
        rows = [by_id[id] for id in ids if id in by_id]
    from .relevance import normalized
    from .activity import pg_event
    for row in rows:
        row["score"] = normalized(row, terms)
        row["superseded_by"] = row.pop("frontmatter").get("superseded_by", "")
        row.pop("body", None)
        row.pop("tags", None)
    pg_event(conn, "search", query=query)
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
