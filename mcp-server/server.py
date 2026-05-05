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
    """Walk library/ and build per-file index from index.md + file bodies."""
    global _index_cache
    if _index_cache is not None:
        return _index_cache

    entries = []
    library_dir = LIBRARY_ROOT / "library"
    if not library_dir.exists():
        _index_cache = []
        return _index_cache

    for index_path in library_dir.rglob("index.md"):
        topic_dir = index_path.parent
        # Derive category/subcategory/topic from path
        rel = topic_dir.relative_to(library_dir)
        parts = list(rel.parts)
        topic_name = parts[-1] if parts else ""
        category = parts[0] if len(parts) >= 1 else ""
        subcategory = parts[1] if len(parts) >= 3 else ""

        index_content = _read_file(index_path)

        # Parse index.md for knowledge file entries
        # Format: - [filename.md](path) — description
        file_entries = re.findall(
            r'-\s+\[([^\]]+\.md)\]\(([^)]+)\)\s+—\s+(.*)',
            index_content
        )

        if file_entries:
            for fname, fpath, description in file_entries:
                full_file = topic_dir / fpath
                body = ""
                if full_file.exists():
                    body = _strip_frontmatter(_read_file(full_file))

                entries.append({
                    "topic": topic_name,
                    "category": category,
                    "subcategory": subcategory,
                    "filename": fname.replace(".md", ""),
                    "description": description.strip(),
                    "body": body.lower(),
                    "path": str(full_file.relative_to(LIBRARY_ROOT)),
                    "index_path": str(index_path.relative_to(LIBRARY_ROOT)),
                })
        else:
            # index.md exists but no file entries — index itself as a topic
            entries.append({
                "topic": topic_name,
                "category": category,
                "subcategory": subcategory,
                "filename": topic_name,
                "description": "",
                "body": _strip_frontmatter(index_content).lower(),
                "path": str(index_path.relative_to(LIBRARY_ROOT)),
                "index_path": str(index_path.relative_to(LIBRARY_ROOT)),
            })

        # Also pick up knowledge files NOT listed in index.md
        listed_files = {fname for fname, _, _ in file_entries}
        for md_file in topic_dir.glob("*.md"):
            if md_file.name == "index.md" or md_file.name == "_template.md":
                continue
            if md_file.name in listed_files:
                continue
            body = _strip_frontmatter(_read_file(md_file))
            entries.append({
                "topic": topic_name,
                "category": category,
                "subcategory": subcategory,
                "filename": md_file.stem,
                "description": "",
                "body": body.lower(),
                "path": str(md_file.relative_to(LIBRARY_ROOT)),
                "index_path": str(index_path.relative_to(LIBRARY_ROOT)),
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
        label = "/".join(filter(None, [m["category"], m["subcategory"], m["topic"]]))
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
    library_md = LIBRARY_ROOT / "LIBRARY.md"
    if not library_md.exists():
        return "LIBRARY.md 없음"
    return _read_file(library_md)


def main():
    mcp.run()


if __name__ == "__main__":
    main()
