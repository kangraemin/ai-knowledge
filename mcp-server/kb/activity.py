"""검색 관측은 본 동작에 영향을 주지 않는 선택적 부가기능이다."""

import json
import math
import os
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path


def root():
    return Path(os.environ.get("LIBRARY_ROOT", Path.home() / "claude-library"))


def append(event, library_root=None):
    if os.environ.get("LIBRARY_LOG") == "0":
        return
    try:
        now = datetime.now(timezone.utc)
        record = {"ts": now.isoformat(), **event}
        session = os.environ.get("LIBRARY_SESSION_ID")
        if session:
            record.setdefault("session_id", session)
        folder = Path(library_root or root()) / ".activity"
        folder.mkdir(parents=True, exist_ok=True)
        data = (json.dumps(record, ensure_ascii=False, default=str) + "\n").encode()
        # 프로세스 간 append 위치 충돌과 한 줄의 분할 쓰기를 방지한다.
        import fcntl
        with (folder / f"search-{now:%Y-%m}.jsonl").open("ab") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(data)
    except Exception:
        pass


def pg_event(conn, action, query=None, doc_id=None):
    if os.environ.get("LIBRARY_LOG") == "0":
        return
    try:
        # 실패한 INSERT가 검색 트랜잭션까지 오염시키지 않게 savepoint로 격리한다.
        with conn.transaction():
            conn.execute(
                "INSERT INTO kb.events(user_id,action,query,doc_id) VALUES(kb.current_user_id(),%s,%s,%s)",
                (action, query, doc_id),
            )
    except Exception:
        pass


def search_event(query, rows, backend, latency_ms, source="mcp", injected=False,
                 skipped_reason=None, library_root=None, action="search"):
    append({"action": action, "source": source, "backend": backend, "query": query,
            "results": [{"path": r["path"], "score": float(r.get("score", 0))} for r in rows],
            "injected": injected, "skipped_reason": skipped_reason,
            "latency_ms": latency_ms}, library_root)


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def stats(days=30, library_root=None):
    if days <= 0:
        raise ValueError("days는 양수여야 합니다")
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    events = []
    for path in sorted((Path(library_root or root()) / ".activity").glob("search-*.jsonl")):
        try:
            lines = path.read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                row = json.loads(line)
                stamp = datetime.fromisoformat(row["ts"])
                if stamp.tzinfo is None:
                    stamp = stamp.replace(tzinfo=timezone.utc)
                if stamp >= cutoff:
                    events.append((stamp, row))
            except (ValueError, KeyError, TypeError):
                continue
    events.sort(key=lambda item: item[0])
    injections, followed, reasons, scores, latencies = [], set(), Counter(), [], []
    pending = {}
    for _, row in events:
        session = row.get("session_id")
        if row.get("action") == "read" or ("path" in row and "results" not in row):
            if session:
                followed.update(pending.get((session, row["path"]), []))
            continue
        if row.get("skipped_reason"):
            reasons[row["skipped_reason"]] += 1
        latency = row.get("latency_ms")
        if isinstance(latency, (float, int)) and math.isfinite(latency):
            latencies.append(latency)
        for result in row.get("results", []):
            score = result.get("score")
            if isinstance(score, (float, int)) and math.isfinite(score):
                scores.append(score)
            if row.get("injected"):
                i = len(injections)
                injections.append(bool(session))
                if session:
                    pending.setdefault((session, result["path"]), []).append(i)
    eligible = sum(injections)
    return {"days": days, "injections": sum(bool(e.get("injected")) for _, e in events),
            "skip_reasons": dict(reasons), "injected_documents": len(injections),
            "session_documents": eligible, "read_documents": len(followed),
            "inject_to_read_rate": len(followed) / eligible if eligible else None,
            "score_distribution": {"count": len(scores), "min": min(scores) if scores else None,
                                   "p50": percentile(scores, .5), "p95": percentile(scores, .95),
                                   "max": max(scores) if scores else None},
            "latency_ms": {"count": len(latencies), "p50": percentile(latencies, .5),
                           "p95": percentile(latencies, .95)}}
