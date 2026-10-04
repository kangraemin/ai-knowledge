"""
Claude Library MCP Server
~/claude-library 에서 지식을 검색하는 MCP 서버
"""

import os
import re
import math
import time
from pathlib import Path
from mcp.server.fastmcp import FastMCP

LIBRARY_ROOT = Path(os.environ.get("LIBRARY_ROOT", Path.home() / "claude-library"))

mcp = FastMCP(
    "claude-library",
    instructions=(
        "ALWAYS call library_search() before answering technical questions, "
        "suggesting approaches, or starting implementation. "
        "Search for relevant keywords from the user's question. "
        "This library contains past experiments, gotchas, and proven solutions — "
        "ignoring it risks repeating known mistakes. "
        "If results found: prefix response with '📚 library 참조: [topic]' and follow stored guidance. "
        "If no results: proceed normally without mentioning the search."
    )
)

# --- In-memory index (lazy built) ---

_index_cache: list[dict] | None = None


def _read_file(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def _strip_frontmatter(text: str) -> str:
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            return text[end + 3:].strip()
    return text


def _word_match(term: str, text: str) -> bool:
    """Word boundary match — 'ml' won't match 'html'."""
    return bool(re.search(r'(?<![a-z가-힣0-9])' + re.escape(term) + r'(?![a-z가-힣0-9])', text))


def _build_index() -> list[dict]:
    """library/ 를 훑어 OKF 프론트매터에서 직접 인덱스를 만든다.

    이전 구현은 index.md 의 마크다운 서식을 정규식으로 파싱했다. 그래서
    index.md 포맷이 바뀌면 검색이 0건이 됐다(=이 라이브러리에 기록된 실제 사고).
    OKF v0.2 는 모든 concept 이 프론트매터를 갖도록 보장하므로, 서식이 아니라
    데이터에서 읽는다. index.md 는 사람/에이전트용 목차로만 남는다.
    """
    global _index_cache
    if _index_cache is not None:
        return _index_cache

    entries = []
    library_dir = LIBRARY_ROOT / "library"
    if not library_dir.exists():
        _index_cache = []
        return _index_cache

    for md_file in sorted(library_dir.rglob("*.md")):
        if md_file.name in ("index.md", "log.md", "_template.md"):
            continue
        # 라이브러리 안의 심볼릭 링크가 밖을 가리킬 수 있다.
        # read 툴만 막고 인덱서를 안 막으면 검색 미리보기로 본문이 샌다.
        if _safe_path(md_file.relative_to(LIBRARY_ROOT)) is None:
            continue

        text = _read_file(md_file)
        meta = _parse_frontmatter(text)
        body = _strip_frontmatter(text)

        rel = md_file.parent.relative_to(library_dir)
        parts = list(rel.parts)
        category = parts[0] if len(parts) >= 1 else ""
        subcategory = parts[1] if len(parts) >= 2 else ""
        topic_name = parts[-1] if parts else ""

        entries.append({
            "topic": topic_name,
            "category": category,
            "subcategory": subcategory,
            "filename": md_file.stem,
            "title": meta.get("title", ""),
            "type": meta.get("type", ""),
            "status": meta.get("status", "stable"),
            "superseded_by": meta.get("superseded_by", ""),
            "tags": meta.get("tags", ""),
            "description": meta.get("description", ""),
            "body": body.lower(),
            "path": str(md_file.relative_to(LIBRARY_ROOT)),
            "index_path": str((md_file.parent / "index.md").relative_to(LIBRARY_ROOT)),
        })

    _index_cache = entries
    return _index_cache


def _search(query: str, include_deprecated=False, k=7) -> list[dict]:
    """문서 단위 IDF·필드 가중치로 정렬하고 독립적인 관련도 점수를 반환한다."""
    from kb.search import query_terms
    from kb.relevance import weights, normalized
    index = [e for e in _build_index() if include_deprecated or e["status"] != "deprecated"]
    terms = query_terms(query)
    if not terms or k <= 0:
        return []
    evidence = [weights(e, terms) for e in index]
    idfs = [math.log1p(len(index) / max(1, sum(w[i] > 0 for w in evidence)))
            for i in range(len(terms))]
    scored = []
    for entry, values in zip(index, evidence):
        rank_score = sum(w * idf for w, idf in zip(values, idfs)) * sum(w > 0 for w in values)
        if rank_score:
            scored.append((rank_score, {**entry, "score": normalized(entry, terms)}))
    scored.sort(key=lambda item: (-item[0], item[1]["path"]))
    return [entry for _, entry in scored[:k]]


def _safe_path(rel_path: str):
    """번들 밖으로 나가는 경로를 거부한다 (../ 탈출 방지)."""
    full = (LIBRARY_ROOT / rel_path).resolve()
    root = LIBRARY_ROOT.resolve()
    if full != root and not str(full).startswith(str(root) + "/"):
        return None
    return full


def _read_topic(rel_path: str) -> str:
    """index.md 내용 읽기"""
    full_path = _safe_path(rel_path)
    if full_path and full_path.exists():
        return _read_file(full_path)
    return ""


@mcp.tool()
def library_search(query: str) -> str:
    """
    Search the knowledge library for past experiments, gotchas, and solutions.
    Contains: backtest results, API/framework gotchas, debugging solutions,
    tool configurations, architecture decisions, proven patterns.

    Args:
        query: search keywords (e.g. "hook timing", "spring test", "bb rsi crypto")
    """
    from kb import api
    if api.postgres():
        return api.search_text(query)
    start = time.monotonic()
    matches = _search(query)
    from kb.activity import search_event
    search_event(query, matches, "files", (time.monotonic() - start) * 1000, library_root=LIBRARY_ROOT)

    if not matches:
        return f"'{query}' 관련 라이브러리 항목 없음."

    from kb.search import format_results
    return format_results(matches, token_budget=10000)


@mcp.tool()
def library_read(path: str) -> str:
    """
    라이브러리의 특정 파일을 읽습니다.
    library_search로 찾은 항목의 상세 내용이 필요할 때 사용하세요.

    Args:
        path: library/ 로 시작하는 상대 경로 (예: "library/equity/vix-filter/index.md")
    """
    from kb import api
    if api.postgres():
        return api.read(path)
    full_path = _safe_path(path)
    if full_path is None:
        return f"{path} 는 라이브러리 밖이다"
    if not full_path.exists():
        return f"파일 없음: {path}"
    text = _read_file(full_path)
    from kb.activity import append
    append({"source": "mcp", "action": "read", "path": path}, LIBRARY_ROOT)
    meta = _parse_frontmatter(text)
    if meta.get("status") == "deprecated":
        text = f"(대체됨 → {meta.get('superseded_by', '')})\n" + text
    return text


@mcp.tool()
def library_list() -> str:
    """
    라이브러리 전체 인덱스를 반환합니다.
    어떤 카테고리/주제가 있는지 전체 파악이 필요할 때 사용하세요.
    """
    from kb import api
    if api.postgres():
        return api.listing()
    # OKF §8: 번들 루트 index.md 가 정본. LIBRARY.md 는 하위호환 롤업.
    for candidate in ("index.md", "LIBRARY.md"):
        path = LIBRARY_ROOT / candidate
        if path.exists():
            return _read_file(path)
    return "인덱스 없음 (index.md / LIBRARY.md 둘 다 부재)"


# --- Decision Records (MADR) ---

DECISION_CATEGORIES = ("architecture", "stack", "convention", "process", "scope")


def _parse_frontmatter(text: str) -> dict:
    """--- 로 감싼 YAML 프론트매터에서 key: value 만 얕게 파싱."""
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    meta = {}
    for line in text[3:end].splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        k, _, v = line.partition(":")
        meta[k.strip()] = v.strip().strip('"').strip("'")
    return meta


def _decision_entries(repo: str = "") -> list[dict]:
    """decisions/<repo>/<category>/<slug>.md 를 훑어 항목 리스트를 만든다."""
    decision_dir = LIBRARY_ROOT / "decisions"
    if not decision_dir.exists():
        return []

    entries = []
    for md in sorted(decision_dir.rglob("*.md")):
        rel = md.relative_to(LIBRARY_ROOT)
        parts = rel.parts  # ('decisions', repo, category, file)
        if len(parts) != 4 or md.name in ("index.md", "log.md"):
            continue
        if _safe_path(rel) is None:
            continue
        if repo and parts[1] != repo:
            continue
        text = _read_file(md)
        meta = _parse_frontmatter(text)
        entries.append({
            "path": str(rel),
            "repo": meta.get("repo", parts[1]),
            "category": meta.get("category", parts[2]),
            "name": meta.get("name", md.stem),
            "status": meta.get("status", "stable"),  # OKF §5.4: draft|stable|deprecated
            "supersedes": meta.get("supersedes", ""),
            "superseded_by": meta.get("superseded_by", ""),
            "date": meta.get("date", ""),
            "body": _strip_frontmatter(text),
        })
    return entries


def _decision_title(entry: dict) -> str:
    """본문 첫 # 헤딩을 제목으로."""
    for line in entry["body"].splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return entry["name"]


def _decision_outcome(entry: dict) -> str:
    """MADR `## Decision Outcome` 섹션 본문."""
    lines = entry["body"].splitlines()
    out, capture = [], False
    for line in lines:
        if line.startswith("## "):
            if capture:
                break
            capture = line.strip() == "## Decision Outcome"  # MADR
            continue
        if capture and line.strip():
            out.append(line.strip())
    return " ".join(out)


@mcp.tool()
def decision_list(repo: str) -> str:
    """
    특정 레포의 활성 결정사항(Decision History)을 모두 반환한다.
    "이 프로젝트에선 이렇게 하기로 했다"는 결정들이다 — 지식(library_search)과 다르다.

    Args:
        repo: git remote basename (예: "ai-bouncer", "coinbot", "stock-bot")
    """
    from kb import api
    if api.postgres():
        return api.listing(repo)
    entries = [e for e in _decision_entries(repo) if e["status"] != "deprecated"]
    if not entries:
        return f"'{repo}' 레포에 등록된 활성 결정사항 없음."

    by_cat: dict[str, list[dict]] = {}
    for e in entries:
        by_cat.setdefault(e["category"], []).append(e)

    out = [f"# {repo} 결정사항 ({len(entries)}건)"]
    for cat in DECISION_CATEGORIES:
        if cat not in by_cat:
            continue
        out.append(f"\n## {cat}")
        for e in by_cat[cat]:
            out.append(f"- **{_decision_title(e)}** (`{e['name']}`)")
            d = _decision_outcome(e)
            if d:
                out.append(f"  - {d}")
    return "\n".join(out)


@mcp.tool()
def decision_search(query: str, repo: str = "") -> str:
    """
    결정사항(Decision History)을 검색한다. 결정 내용·이유로 찾는다.
    지식이 아니라 "우리가 이렇게 하기로 정한 것"을 찾을 때 쓴다.

    Args:
        query: 검색 키워드
        repo: 특정 레포로 한정 (생략하면 전체)
    """
    from kb import api
    if api.postgres():
        return api.search_text(query, kind="decision", repo=repo)
    terms = [t for t in re.split(r"[\s,]+", query.lower()) if t]
    if not terms:
        return "검색어 없음."

    scored = []
    for e in _decision_entries(repo):
        if e["status"] == "deprecated":
            continue
        hay = (e["name"] + " " + e["body"]).lower()
        score = sum(1 for t in terms if _word_match(t, hay))
        if score:
            if e["status"] == "deprecated":
                score -= 0.5
            scored.append((score, e))

    if not scored:
        return f"'{query}' 관련 결정사항 없음."

    scored.sort(key=lambda x: -x[0])
    out = []
    for _, e in scored[:8]:
        mark = "" if e["status"] == "stable" else f" [{e['status']}]"
        out.append(f"## {e['repo']}/{e['category']}/{e['name']}{mark}")
        out.append(f"> {_decision_title(e)}")
        d = _decision_outcome(e)
        if d:
            out.append(d)
        out.append(f"`{e['path']}`\n")
    return "\n".join(out)


@mcp.tool()
def decision_read(path: str) -> str:
    """
    결정사항 파일 전문을 읽는다. decision_search/decision_list 결과의 경로를 넘긴다.

    Args:
        path: decisions/ 로 시작하는 상대 경로
    """
    from kb import api
    if api.postgres():
        return api.read(path)
    full = _safe_path(path)
    if full is None:
        return f"{path} 는 라이브러리 밖이다"
    if not full.exists():
        return f"{path} 없음"
    return _read_file(full)


@mcp.tool()
def library_write(path: str, markdown: str, scope: str | None = None,
                  expected_version: int | None = None, kind: str = "knowledge") -> str:
    """Postgres 문서 저장. 기존 문서는 expected_version을 지정한다."""
    from kb import api
    if not api.postgres():
        return "쓰기 툴은 LIBRARY_BACKEND=postgres에서 사용할 수 있습니다."
    return api.write(path, markdown, scope, expected_version, kind)


@mcp.tool()
def library_relate(src_path: str, dst_path: str, type: str) -> str:
    """관계 연결. supersedes는 대상 문서를 같은 트랜잭션에서 폐기한다."""
    from kb import api, store
    if not api.postgres():
        return "쓰기 툴은 LIBRARY_BACKEND=postgres에서 사용할 수 있습니다."
    with api.connect() as conn:
        store.relate(conn, src_path, dst_path, type)
    return "관계 저장 완료"


@mcp.tool()
def library_promote(path: str) -> str:
    """inbox 후보를 stable knowledge로 승격한다."""
    from kb import api, store
    if not api.postgres():
        return "쓰기 툴은 LIBRARY_BACKEND=postgres에서 사용할 수 있습니다."
    with api.connect() as conn:
        store.promote(conn, path)
    return "승격 완료"


def main():
    mcp.run()


if __name__ == "__main__":
    main()
