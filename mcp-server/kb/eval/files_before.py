"""0.4.3 파일 검색 평가 전용 기준선. 서비스에서 호출하지 않는다."""

import re
from server import _build_index


def _word_match(term: str, text: str) -> bool:
    """Word boundary match — 'ml' won't match 'html'."""
    return bool(re.search(r'(?<![a-z가-힣0-9])' + re.escape(term) + r'(?![a-z가-힣0-9])', text))


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
