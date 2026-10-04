"""파일·Postgres 공통의 필드 증거 점수(0~1)."""

import math
import re


def weights(entry, terms):
    fields = [(str(entry.get(key) or "").lower(), weight)
              for key, weight in (("title", 6), ("path", 5), ("description", 4),
                                  ("tags", 3), ("body", 1))]
    result = []
    for term in terms:
        pattern = re.compile(r"(?<![a-z0-9_])" + re.escape(term) + r"(?![a-z0-9_])") if term.isascii() else None
        result.append(max((weight for text, weight in fields
                           if (pattern.search(text) if pattern else term in text)), default=0))
    return result


def normalized(entry, terms):
    evidence = weights(entry, terms)
    if not evidence:
        return 0.0
    # 장문의 자연어 질의를 불리하게 만들지 않고 독립적인 단어 증거를 누적한다.
    strength = sum(evidence) * sum(w > 0 for w in evidence)
    return -math.expm1(-strength / 24)


DEFAULT_MIN_SCORE = {"files": 0.22119921692859515, "postgres": 0.22119921692859515}


def minimum(backend):
    import os
    score = float(os.environ.get("LIBRARY_AUTOINJECT_MIN_SCORE", DEFAULT_MIN_SCORE[backend]))
    if not math.isfinite(score) or not 0 <= score <= 1:
        raise ValueError("LIBRARY_AUTOINJECT_MIN_SCORE는 0~1이어야 합니다")
    return score


def select(rows, backend, budget):
    from .search import format_results
    threshold = minimum(backend)
    qualified = [row for row in rows if row.get("score", 0) >= threshold]
    if not qualified:
        return [], "low_score" if rows else "no_results"
    kept = []
    for row in qualified:
        if len(format_results(kept + [row], budget).splitlines()) != len(kept) + 1:
            break
        kept.append(row)
    return kept, None if kept else "budget"
