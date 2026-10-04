"""dev 임계값 선정과 고정 test 평가. 출력은 집계만, 원본은 읽기 전용."""

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", required=True, choices=["dev", "test"])
    parser.add_argument("--baseline", default=str(Path(__file__).with_name("files_before.py")))
    args = parser.parse_args()
    os.environ["LIBRARY_LOG"] = "0"
    os.environ["LIBRARY_EMBED_PROVIDER"] = "none"
    import server
    from kb.cli import default_queries_path
    from kb.db import connect
    from kb.search import search
    from kb.relevance import DEFAULT_MIN_SCORE, select
    data = [json.loads(line) for line in default_queries_path().read_text().splitlines() if line.strip()]
    negatives = [json.loads(line) for line in Path(__file__).with_name("negatives.jsonl").read_text().splitlines()]
    queries = [q for q in data if q["split"] == args.split]
    negatives = [q for q in negatives if q["split"] == args.split]
    baseline = None
    if args.baseline:
        spec = importlib.util.spec_from_file_location("baseline", args.baseline)
        baseline = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(baseline)
    with connect() as conn:
        for backend in ("files", "postgres"):
            fn = server._search if backend == "files" else lambda q: search(conn, q)
            positive_rows = [fn(q["q"]) for q in queries]
            negative_rows = [fn(q["q"]) for q in negatives]
            hook_negative_rows = [rows if len(q["q"].strip()) >= 8 and not q["q"].lstrip().startswith("/") else []
                                  for q, rows in zip(negatives, negative_rows)]
            threshold = DEFAULT_MIN_SCORE[backend]
            if args.split == "dev":
                # 억제율 조건 아래 가장 낮은 임계값은 정답 질의 주입 유지율을 최대화한다.
                candidates = [0.0] + [math.nextafter(float(rows[0]["score"]), 1.0)
                                      for rows in negative_rows if rows]
                # 주입은 상위 후보 중 하나라도 통과하면 발생한다.
                candidates += [math.nextafter(max(float(r["score"]) for r in rows), 1.0)
                               for rows in negative_rows if rows]
                threshold = min(t for t in candidates if sum(not any(r["score"] >= t for r in rows)
                                                            for rows in negative_rows) / len(negatives) >= .9)
            ranks = [next((i for i,r in enumerate(rows,1) if r["path"] in q["expected"]),0)
                     for q,rows in zip(queries,positive_rows)]
            os.environ["LIBRARY_AUTOINJECT_MIN_SCORE"] = str(threshold)
            selected_rows = [select(rows, backend, 1500)[0] for rows in positive_rows]
            kept = sum(bool(rows) for rows in selected_rows)
            correct_kept = sum(any(r["score"] >= threshold and r["path"] in q["expected"] for r in rows)
                               for q,rows in zip(queries,selected_rows))
            report = {"backend":backend,"split":args.split,"n":len(queries),"threshold":threshold,
                      "R@1":sum(r==1 for r in ranks),"R@5":sum(0<r<=5 for r in ranks),
                      "MRR@7":sum(1/r if r else 0 for r in ranks)/len(ranks),
                      "positive_injected":kept,"correct_injected":correct_kept,
                      "negative_n":len(negatives),"negative_suppressed":sum(not any(r["score"]>=threshold for r in rows) for rows in hook_negative_rows),
                      "search_only_negative_suppressed":sum(not any(r["score"]>=threshold for r in rows) for rows in negative_rows)}
            if baseline and backend == "files":
                ranks = [next((i for i,r in enumerate(baseline._search(q["q"]),1) if r["path"] in q["expected"]),0) for q in queries]
                report["before"] = {"R@1":sum(r==1 for r in ranks),"R@5":sum(0<r<=5 for r in ranks),"MRR@7":sum(1/r if r else 0 for r in ranks)/len(ranks)}
            print(json.dumps(report))
        conn.rollback()


if __name__ == "__main__":
    main()
