"""코퍼스 IDF 커버리지와 별도의 대칭 문서 유사도. 점수는 확률이 아니다."""

import math
import re
from collections import Counter, defaultdict
from functools import lru_cache


@lru_cache(maxsize=8192)
def _tokens(text):
    from .search import query_terms
    terms = query_terms(text)
    # 경로의 하이픈·점 경계도 검색하되 식별자 원형은 보존한다.
    return frozenset(terms + [part for t in terms for part in re.split(r"[.+-]", t)
                              if len(part) > 1])


def field_terms(entry):
    result = {}
    for key, weight in (("title", 1.0), ("description", .85), ("tags", .65),
                        ("path", .5), ("body", .2)):
        for term in _tokens(str(entry.get(key) or "")):
            result[term] = max(result.get(term, 0), weight)
    return result


def weights(entry, terms):
    evidence = field_terms(entry)
    return [6 * evidence.get(t, 0) for t in terms]


_ANALYZED_KEYS = ("title", "description", "tags", "path", "body")


def _analyze(doc):
    return field_terms(doc), _tokens(" ".join(str(doc.get(k) or "") for k in
                                            ("title", "description", "path")))


def _analyze_cached(docs):
    """문서 토큰화는 검색 시간의 대부분이다. 내용 해시로 디스크에 캐시한다.

    캐시는 토크나이저 소스가 바뀌면 통째로 버린다. 실패하면 캐시 없이 계산한다.
    """
    import hashlib
    import json
    import os
    from pathlib import Path
    folder = Path(os.environ.get("LIBRARY_CACHE_DIR") or
                  Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "claude-library-kb")
    here = Path(__file__).resolve().parent
    try:
        code = hashlib.sha1(b"".join((here / f).read_bytes() for f in ("search.py", "relevance.py"))).hexdigest()[:12]
    except OSError:
        return [_analyze(d) for d in docs]
    file = folder / f"corpus-{code}.json"
    try:
        cache = json.loads(file.read_text())
    except (OSError, ValueError):
        cache = {}
    fresh, result = {}, []
    for doc in docs:
        key = hashlib.sha1(json.dumps([str(doc.get(k) or "") for k in _ANALYZED_KEYS],
                                      ensure_ascii=False).encode()).hexdigest()
        hit = cache.get(key)
        if not (isinstance(hit, list) and len(hit) == 2 and isinstance(hit[0], dict)):
            fields, meta = _analyze(doc)
            hit = [fields, sorted(meta)]
        fresh[key] = hit
        result.append((hit[0], frozenset(hit[1])))
    if fresh.keys() != cache.keys():
        try:
            folder.mkdir(parents=True, exist_ok=True)
            for old in folder.glob("corpus-*.json"):
                if old != file:
                    old.unlink(missing_ok=True)
            tmp = file.with_suffix(f".{os.getpid()}.tmp")
            tmp.write_text(json.dumps(fresh, ensure_ascii=False))
            os.replace(tmp, file)
        except OSError:
            pass
    return result


class Corpus:
    """권한과 scope 필터를 적용한 전체 문서로만 IDF를 계산한다."""

    def __init__(self, docs):
        analyzed = _analyze_cached(docs)
        self.fields = [fields for fields, _ in analyzed]
        self.metadata = [meta for _, meta in analyzed]
        self.df = Counter(t for fields in self.fields for t in fields)
        self.n = len(docs)
        self.postings = defaultdict(dict)
        self.positions = {id(f): i for i, f in enumerate(self.fields)}
        for i, fields in enumerate(self.fields):
            for term, weight in fields.items():
                self.postings[term][i] = weight
        self._matches = {}

    def matches(self, term):
        if term not in self._matches:
            found = dict(self.postings.get(term, {}))
            if not term.isascii():
                for token, postings in self.postings.items():
                    if term in token:
                        for i, weight in postings.items():
                            found[i] = max(found.get(i, 0), weight)
            self._matches[term] = found
        return self._matches[term]

    def idf(self, term):
        df = len(self.matches(term))
        if not df:
            return 0.0
        # 작은 코퍼스에서도 한 문서의 정확한 검색은 유지한다.
        rarity = math.log1p(self.n / df)
        if self.n >= 20:
            rarity *= (1 - df / self.n) ** 2
        return rarity

    def score(self, fields, terms):
        terms = set(terms)
        weighted = {t: self.idf(t) for t in terms}
        total = sum(weighted.values())
        if not total:
            return 0.0
        position = self.positions.get(id(fields))
        evidence = {t: self.matches(t).get(position, 0) if position is not None else
                    max((w for token, w in fields.items() if token == t or
                         (not t.isascii() and t in token)), default=0) for t in terms}
        support = sum(evidence[t] * v for t, v in weighted.items())
        # 한 단어의 우연한 매칭만으로 완전 일치가 되지 않는다.
        matches = sum(evidence[t] > 0 for t in terms)
        confidence = min(1.0, matches / 2)
        if sum(v > 0 for v in weighted.values()) == 1:
            confidence *= .2
        score = .95 * support / total * confidence
        # 알려진 질의어가 하나뿐인 문장은 정규화 분모도 하나여서 과신하기 쉽다.
        # 검색 결과는 유지하되 자동 주입의 증거로는 충분하지 않다.
        return min(score, .02) if sum(v > 0 for v in weighted.values()) == 1 else score

    def injection_evidence(self, query):
        """본문·태그 매칭과 구분되는 메타데이터의 정확한 희소어 근거."""
        from .search import query_terms
        terms = query_terms(query)
        rare = {t for t in terms if self.n and
                0 < len(self.matches(t)) / self.n <= MAX_CORE_DF_RATIO}
        return [{"core_matches": len(rare & meta), "query_terms": len(terms)}
                for meta in self.metadata]

    def scores(self, query):
        from .search import query_terms
        full = query_terms(query)
        # 여러 과제를 담은 장문은 문장별 커버리지의 최댓값을 쓴다.
        # 문장 개수나 반복 횟수를 더하지 않으므로 증거가 포화하지 않는다.
        groups = [full]
        for sentence in re.split(r"(?<=[?!。])\s*|(?<=\.)\s+|\n+", query):
            terms = query_terms(sentence)
            if len(terms) >= 3 and terms != full:
                groups.append(terms)
        result = []
        for fields in self.fields:
            whole = self.score(fields, full)
            best = max((self.score(fields, terms) for terms in groups), default=0.0)
            # 짧은 문장의 우연한 일치도 전체 질의 문맥으로 제한한다.
            result.append(math.sqrt(whole * best))
        return result


def normalized(entry, terms, corpus=None):
    corpus = corpus if corpus is not None else Corpus([entry])
    return corpus.score(field_terms(entry), terms)


def duplicate_similarity(left, right, corpus=None):
    """제목·설명 토큰의 양방향 IDF 커버리지 조화평균. 본문·경로는 제외."""
    a = _tokens(' '.join(str(left.get(k) or '') for k in ('title', 'description')))
    b = _tokens(' '.join(str(right.get(k) or '') for k in ('title', 'description')))
    if not a or not b:
        return 0.0
    corpus = corpus if corpus is not None else Corpus([left, right])
    # 새 문서의 미등록 단어도 분모에 포함한다. 알려진 한 단어로 중복이 되면 안 된다.
    def mass(ts):
        return sum(corpus.idf(t) or math.log1p(max(1, corpus.n)) for t in ts)
    common = mass(a & b)
    return 2 * common / (mass(a) + mass(b))


def citation_signals(doc, answer, corpus, n=8, ratio=.5):
    """명시 인용과 핵심어 일치를 구분해 근거를 반환한다."""
    from pathlib import Path
    path = doc.get('path', '')
    signals = []
    for kind, alias in [('path', path), ('filename', Path(path).name), ('title', doc.get('title', ''))]:
        if alias and alias not in ('index.md', 'log.md') and alias in answer:
            signals.append({'kind': kind, 'value': alias})
    terms = _tokens(' '.join(str(doc.get(k) or '') for k in ('title', 'description')))
    keys = sorted((t for t in terms if corpus.idf(t) > 0 and
                   (corpus.n < 20 or corpus.df[t] / corpus.n <= .1)),
                  key=lambda t: (-corpus.idf(t), t))[:n]
    found = sorted(set(keys) & _tokens(answer))
    if len(found) >= max(3, math.ceil(len(keys) * ratio)):
        signals.append({'kind': 'keywords', 'matched': found, 'total': len(keys),
                        'coverage': len(found) / len(keys)})
    return signals


DEFAULT_MIN_SCORE = {"files": .18, "postgres": .18}
MAX_CORE_DF_RATIO = .03
MIN_CORE_MATCHES = 4
SHORT_QUERY_TERMS = 16
SHORT_MIN_SCORE = .4
DEFAULT_DUPLICATE_SCORE = .045
# 순간 트리거(명령 실패·작업 시작)는 검색이 필요한 시점이라 기저율이 높다.
# 자동 주입보다 느슨하되, 흔한 단어끼리의 우연한 일치(희소어 1개 이하)는 거른다.
# 2026-10 실사용 판정: 희소어 1개·점수 .35~.42 결과는 전부 무관 문서였다.
TRIGGER_MIN_SCORE = .3
TRIGGER_MIN_CORE_MATCHES = 2
TRIGGER_MAX_RESULTS = 2
# 희소어가 1개뿐이어도 점수가 충분히 높으면(예: 에러의 모듈명이 제목에 그대로) 인정한다.
TRIGGER_STRONG_SCORE = .6


def minimum(backend):
    import os
    score = float(os.environ.get("LIBRARY_AUTOINJECT_MIN_SCORE", DEFAULT_MIN_SCORE[backend]))
    if not math.isfinite(score) or not 0 <= score <= 1:
        raise ValueError("LIBRARY_AUTOINJECT_MIN_SCORE는 0~1이어야 합니다")
    return score


def select(rows, backend, budget):
    from .search import format_results
    threshold = minimum(backend)
    scored = [row for row in rows if row.get("score", 0) >= threshold]
    qualified = []
    for row in scored:
        # 근거 없는 구버전/외부 결과는 자동 주입에 사용하지 않는다.
        evidence = row.get("injection_evidence", {})
        if evidence.get("core_matches", 0) < MIN_CORE_MATCHES:
            continue
        if (evidence.get("query_terms", 0) <= SHORT_QUERY_TERMS and
                row["score"] < max(threshold, SHORT_MIN_SCORE)):
            continue
        qualified.append(row)
    if not qualified:
        return [], ("weak_evidence" if scored else "low_score") if rows else "no_results"
    kept = []
    for row in qualified:
        if len(format_results(kept + [row], budget).splitlines()) != len(kept) + 1:
            break
        kept.append(row)
    return kept, None if kept else "budget"


def select_trigger(rows, budget):
    from .search import format_results
    qualified = [row for row in rows
                 if (row.get("score", 0) >= TRIGGER_STRONG_SCORE
                     and row.get("injection_evidence", {}).get("core_matches", 0) >= 1)
                 or (row.get("score", 0) >= TRIGGER_MIN_SCORE
                     and row.get("injection_evidence", {}).get("core_matches", 0) >= TRIGGER_MIN_CORE_MATCHES)]
    if not qualified:
        return [], "weak_evidence" if rows else "no_results"
    kept = qualified[:TRIGGER_MAX_RESULTS]
    while kept and len(format_results(kept, budget).splitlines()) != len(kept):
        kept = kept[:-1]
    return kept, None if kept else "budget"
