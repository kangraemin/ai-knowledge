"""
Claude Library MCP Server
~/claude-library 에서 지식을 검색하는 MCP 서버
"""

import os
import re
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
            "description": meta.get("description", ""),
            "body": body.lower(),
            "path": str(md_file.relative_to(LIBRARY_ROOT)),
            "index_path": str((md_file.parent / "index.md").relative_to(LIBRARY_ROOT)),
        })

    _index_cache = entries
    return _index_cache


def _score_entry(entry: dict, terms: list[str]) -> float:
    """Score an entry against query terms. Higher = more relevant."""
    if not terms:
        return 0

    total = 0
    matched_terms = 0

    for term in terms:
        term_score = 0

        # Tier 1: topic name (10 pts)
        if _word_match(term, entry["topic"]):
            term_score = max(term_score, 10)

        # Tier 2: filename (8 pts)
        if _word_match(term, entry["filename"]):
            term_score = max(term_score, 8)

        # Tier 3: description (6 pts)
        if entry["description"] and _word_match(term, entry["description"].lower()):
            term_score = max(term_score, 6)

        # Tier 4: category/subcategory (4 pts)
        cat_text = f"{entry['category']} {entry['subcategory']}"
        if _word_match(term, cat_text):
            term_score = max(term_score, 4)

        # Tier 5: body (2 pts)
        if term in entry["body"]:
            term_score = max(term_score, 2)

        if term_score > 0:
            matched_terms += 1
        total += term_score

    # AND bias: penalize if not all terms matched
    if len(terms) > 1:
        total *= (matched_terms / len(terms))

    return total


def _search(query: str) -> list[dict]:
    """Search the index with scoring."""
    index = _build_index()
    terms = [t.lower() for t in re.split(r'\s+', query.strip()) if t]
    if not terms:
        return []

    scored = []
    for entry in index:
        score = _score_entry(entry, terms)
        if score > 0:
            scored.append((score, entry))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [entry for _, entry in scored[:7]]


def _read_topic(rel_path: str) -> str:
    """index.md 내용 읽기"""
    full_path = LIBRARY_ROOT / rel_path
    if full_path.exists():
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
    matches = _search(query)

    if not matches:
        return f"'{query}' 관련 라이브러리 항목 없음."

    parts = []
    for m in matches:
        seg, label_parts = None, []
        for part in (m["category"], m["subcategory"], m["topic"]):
            if part and part != seg:
                label_parts.append(part)
                seg = part
        label = "/".join(label_parts)
        header = f"## {label}/{m['filename']}"
        if m["description"]:
            header += f"\n> {m['description']}"
        parts.append(header)

        # Body preview (first ~200 chars, cut at line boundary)
        if m["body"]:
            preview_lines = []
            char_count = 0
            for line in m["body"].splitlines():
                if char_count + len(line) > 300:
                    break
                preview_lines.append(line)
                char_count += len(line)
            if preview_lines:
                parts.append("\n".join(preview_lines))

        parts.append(f"`library_read('{m['path']}')`로 전문 읽기\n")

    return "\n".join(parts)


@mcp.tool()
def library_read(path: str) -> str:
    """
    라이브러리의 특정 파일을 읽습니다.
    library_search로 찾은 항목의 상세 내용이 필요할 때 사용하세요.

    Args:
        path: library/ 로 시작하는 상대 경로 (예: "library/equity/vix-filter/index.md")
    """
    full_path = LIBRARY_ROOT / path
    if not full_path.exists():
        return f"파일 없음: {path}"
    return _read_file(full_path)


@mcp.tool()
def library_list() -> str:
    """
    라이브러리 전체 인덱스를 반환합니다.
    어떤 카테고리/주제가 있는지 전체 파악이 필요할 때 사용하세요.
    """
    # OKF §8: 번들 루트 index.md 가 정본. LIBRARY.md 는 하위호환 롤업.
    for candidate in ("index.md", "LIBRARY.md"):
        path = LIBRARY_ROOT / candidate
        if path.exists():
            return _read_file(path)
    return "인덱스 없음 (index.md / LIBRARY.md 둘 다 부재)"


# --- Policy (Decision History) ---

POLICY_CATEGORIES = ("architecture", "stack", "convention", "process", "scope")


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


def _policy_entries(repo: str = "") -> list[dict]:
    """policy/<repo>/<category>/<slug>.md 를 훑어 항목 리스트를 만든다."""
    policy_dir = LIBRARY_ROOT / "policy"
    if not policy_dir.exists():
        return []

    entries = []
    for md in sorted(policy_dir.rglob("*.md")):
        rel = md.relative_to(LIBRARY_ROOT)
        parts = rel.parts  # ('policy', repo, category, file)
        if len(parts) != 4 or md.name in ("index.md", "log.md"):
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


def _policy_title(entry: dict) -> str:
    """본문 첫 # 헤딩을 제목으로."""
    for line in entry["body"].splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return entry["name"]


def _policy_decision(entry: dict) -> str:
    """## 결정 섹션 본문."""
    lines = entry["body"].splitlines()
    out, capture = [], False
    for line in lines:
        if line.startswith("## "):
            if capture:
                break
            capture = line.strip() == "## 결정"
            continue
        if capture and line.strip():
            out.append(line.strip())
    return " ".join(out)


@mcp.tool()
def policy_list(repo: str) -> str:
    """
    특정 레포의 활성 정책(Decision History)을 모두 반환한다.
    "이 프로젝트에선 이렇게 하기로 했다"는 결정들이다 — 지식(library_search)과 다르다.

    Args:
        repo: git remote basename (예: "ai-bouncer", "coinbot", "stock-bot")
    """
    entries = [e for e in _policy_entries(repo) if e["status"] != "deprecated"]
    if not entries:
        return f"'{repo}' 레포에 등록된 활성 정책 없음."

    by_cat: dict[str, list[dict]] = {}
    for e in entries:
        by_cat.setdefault(e["category"], []).append(e)

    out = [f"# {repo} 정책 ({len(entries)}건)"]
    for cat in POLICY_CATEGORIES:
        if cat not in by_cat:
            continue
        out.append(f"\n## {cat}")
        for e in by_cat[cat]:
            out.append(f"- **{_policy_title(e)}** (`{e['name']}`)")
            d = _policy_decision(e)
            if d:
                out.append(f"  - {d}")
    return "\n".join(out)


@mcp.tool()
def policy_search(query: str, repo: str = "") -> str:
    """
    정책(Decision History)을 검색한다. 결정 내용·이유로 찾는다.
    지식이 아니라 "우리가 이렇게 하기로 정한 것"을 찾을 때 쓴다.

    Args:
        query: 검색 키워드
        repo: 특정 레포로 한정 (생략하면 전체)
    """
    terms = [t for t in re.split(r"[\s,]+", query.lower()) if t]
    if not terms:
        return "검색어 없음."

    scored = []
    for e in _policy_entries(repo):
        hay = (e["name"] + " " + e["body"]).lower()
        score = sum(1 for t in terms if _word_match(t, hay))
        if score:
            if e["status"] == "deprecated":
                score -= 0.5
            scored.append((score, e))

    if not scored:
        return f"'{query}' 관련 정책 없음."

    scored.sort(key=lambda x: -x[0])
    out = []
    for _, e in scored[:8]:
        mark = "" if e["status"] == "stable" else f" [{e['status']}]"
        out.append(f"## {e['repo']}/{e['category']}/{e['name']}{mark}")
        out.append(f"> {_policy_title(e)}")
        d = _policy_decision(e)
        if d:
            out.append(d)
        out.append(f"`{e['path']}`\n")
    return "\n".join(out)


@mcp.tool()
def policy_read(path: str) -> str:
    """
    정책 파일 전문을 읽는다. policy_search/policy_list 결과의 경로를 넘긴다.

    Args:
        path: policy/ 로 시작하는 상대 경로
    """
    full = LIBRARY_ROOT / path
    if not full.exists():
        return f"{path} 없음"
    return _read_file(full)


def main():
    mcp.run()


if __name__ == "__main__":
    main()
