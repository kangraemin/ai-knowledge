"""Evaluate frozen splits without reimporting data or changing embeddings.

Before tuning: --label before. During tuning: --label candidate --split dev.
After freezing code: --label after. Each artifact retains per-query ranks.
"""

import argparse
import hashlib
import json
import os
import time
from pathlib import Path

from kb.db import connect
from kb.search import search
from kb.cli import default_queries_path


def metrics(rows):
    ranks = [r["rank"] for r in rows]
    n = len(ranks)
    return {
        "n": n,
        "R@1": sum(r == 1 for r in ranks) / n,
        "R@5": sum(0 < r <= 5 for r in ranks) / n,
        "MRR@7": sum(1 / r if r else 0 for r in ranks) / n,
    }


def main():
    import server

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    parser.add_argument(
        "--baseline", action="store_true", help="use the archived pre-change search"
    )
    parser.add_argument("--split", choices=["dev", "test"])
    parser.add_argument("--providers", nargs="+", default=["none", "fastembed"])
    args = parser.parse_args()
    folder = default_queries_path().parent  # 비공개 평가 데이터는 라이브러리 쪽
    search_fn = search
    search_source = folder.parent / "search.py"
    if args.baseline:
        import importlib.util

        search_source = folder / "search_before.py"
        spec = importlib.util.spec_from_file_location(
            "kb._evaluation_before", search_source
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        search_fn = module.search
    data = (folder / "queries.jsonl").read_bytes()
    queries = [json.loads(line) for line in data.splitlines() if line.strip()]
    if args.split:
        queries = [q for q in queries if q["split"] == args.split]
    result = {
        "seed": 20261004,
        "queries_sha256": hashlib.sha256(data).hexdigest(),
        "search_sha256": hashlib.sha256(search_source.read_bytes()).hexdigest(),
        "runs": [],
    }
    with connect() as conn:
        for backend, provider in [("files", "none")] + [
            ("postgres", p) for p in args.providers
        ]:
            os.environ["LIBRARY_EMBED_PROVIDER"] = provider
            records = []
            start = time.monotonic()
            for item in queries:
                rows = (
                    server._search(item["q"])
                    if backend == "files"
                    else search_fn(conn, item["q"])
                )
                paths = [r["path"] for r in rows]
                records.append(
                    {
                        "q": item["q"],
                        "split": item["split"],
                        "paths": paths,
                        "rank": next(
                            (
                                i
                                for i, path in enumerate(paths, 1)
                                if path in item["expected"]
                            ),
                            0,
                        ),
                    }
                )
            conn.rollback()  # Evaluation does not persist search events.
            run = {
                "backend": backend,
                "provider": provider,
                "seconds": time.monotonic() - start,
                "metrics": {
                    s: metrics([r for r in records if r["split"] == s])
                    for s in ["dev", "test"]
                    if any(r["split"] == s for r in records)
                },
                "records": records,
            }
            result["runs"].append(run)
            (folder / f"{args.label}.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2) + "\n"
            )
            # Held-out ranks and metrics stay on disk until implementation is frozen.
            print(
                backend,
                provider,
                "dev",
                run["metrics"].get("dev"),
                "seconds",
                run["seconds"],
                flush=True,
            )


if __name__ == "__main__":
    main()
