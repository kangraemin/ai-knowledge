"""
Claude Library MCP Server
~/.claude/.claude-library 에서 지식을 검색하는 MCP 서버
"""

import os
import re
from pathlib import Path
from mcp.server.fastmcp import FastMCP

LIBRARY_ROOT = Path(os.environ.get("LIBRARY_ROOT", Path.home() / ".claude" / ".claude-library"))

mcp = FastMCP(
    "claude-library",
    instructions=(
        "도구, 프로젝트, 기술 키워드가 언급되거나 기술적 질문에 답하거나 뭔가 제안하기 전에 library_search()를 무조건 호출해라. "
        "'찾아봐', '검색해봐' 같은 탐색 요청도 파일시스템 뒤지기 전에 library부터 확인해라. "
        "결과가 없어도 호출은 해야 한다. "
        "이미 시도했거나 실패한 접근법, 삽질로 알게 된 사실, 교정받은 내용이 있을 수 있다. "
        "검색 결과가 있으면 '📚 library 참조: [topic]' 한 줄로 알리고 이미 기록된 방향은 재제안하지 마라. "
        "결과가 없으면 그냥 넘어가라."
    )
)


def _read_file(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def _search_index(query: str) -> list[dict]:
    """LIBRARY.md에서 query 관련 항목 찾기"""
    library_md = LIBRARY_ROOT / "LIBRARY.md"
    if not library_md.exists():
        return []

    content = _read_file(library_md)
    query_lower = query.lower()
    results = []

    # 현재 카테고리/서브카테고리 헤더 추적
    current_category = ""
    current_sub = ""

    for line in content.splitlines():
        # 카테고리/서브카테고리 헤더 추적
        if line.startswith("## ") and not line.startswith("### "):
            current_category = line[3:].strip()
            current_sub = ""
            continue
        if line.startswith("### "):
            current_sub = line[4:].strip()
            continue

        # - [topic](path) — description 형식
        match = re.match(r"-\s+\[([^\]]+)\]\(([^)]+)\)\s+—\s+(.*)", line)
        if match:
            topic, rel_path, description = match.groups()
        else:
            # - [topic](path) (N) 형식 (description 없음)
            match = re.match(r"-\s+\[([^\]]+)\]\(([^)]+)\)", line)
            if not match:
                continue
            topic, rel_path = match.groups()
            description = ""

        # 검색 대상: topic, description, category, subcategory, path
        searchable = f"{topic} {description} {current_category} {current_sub} {rel_path}".lower()
        if any(q in searchable for q in query_lower.split()):
            label = "/".join(filter(None, [current_category, current_sub, topic]))
            results.append({
                "topic": label,
                "path": rel_path,
                "description": description or f"{current_category}/{current_sub}",
            })

    return results


def _read_topic(rel_path: str) -> str:
    """index.md 내용 읽기"""
    full_path = LIBRARY_ROOT / rel_path
    if full_path.exists():
        return _read_file(full_path)
    return ""


@mcp.tool()
def library_search(query: str) -> str:
    """
    Claude의 지식 라이브러리에서 관련 지식을 검색합니다.
    투자 전략, 백테스트 결과, 기술 패턴, 삽질 기록 등을 조회할 때 사용하세요.
    새 작업 시작 전, 관련 분야의 과거 결론이 있는지 확인할 때 호출하세요.

    Args:
        query: 검색어 (예: "fibonacci", "VIX filter", "LightGBM", "spring test")
    """
    matches = _search_index(query)

    if not matches:
        return f"'{query}' 관련 라이브러리 항목 없음."

    parts = []
    for m in matches[:5]:  # 최대 5개
        parts.append(f"## {m['topic']}\n> {m['description']}\n")
        content = _read_topic(m["path"])
        if content:
            # index.md 전체 내용 포함 (너무 길면 앞부분만)
            lines = content.splitlines()
            preview = "\n".join(lines[:60])
            if len(lines) > 60:
                preview += f"\n... ({len(lines) - 60}줄 더 있음)"
            parts.append(preview)
        parts.append("")

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
