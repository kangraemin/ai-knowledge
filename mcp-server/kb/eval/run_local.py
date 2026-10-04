"""실제 라이브러리는 읽기만 한다. 평가 DB 준비 후 이 스크립트로 재현한다."""

import json
import os
import time
from pathlib import Path
from kb.db import connect
from kb.store import import_library, export_library
from kb.cli import default_queries_path, evaluate
from kb.embed import embed_pending


def main():
    folder = default_queries_path().parent  # 비공개 평가 데이터는 라이브러리 쪽
    root = Path(os.environ["LIBRARY_ROOT"])
    with connect() as conn:
        start = time.monotonic()
        report = import_library(conn, root, os.environ["LIBRARY_WORKSPACE"])
        conn.commit()
        print("IMPORT", json.dumps(report, ensure_ascii=False), flush=True)
        (folder / "import-report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        )
        print("IMPORT_SECONDS", time.monotonic() - start, flush=True)
        repeated = import_library(conn, root, os.environ["LIBRARY_WORKSPACE"])
        conn.commit()
        print("REIMPORT", json.dumps(repeated, ensure_ascii=False), flush=True)
        # export는 반드시 임시 HOME 아래로만 쓴다.
        exported = export_library(
            conn, Path.home() / "roundtrip", os.environ["LIBRARY_WORKSPACE"]
        )
        from kb.markdown import parse

        checked = 0
        for p in (Path.home() / "roundtrip").rglob("*.md"):
            original = root / p.relative_to(Path.home() / "roundtrip")
            assert (
                parse(p.read_bytes().decode())[1]
                == parse(original.read_bytes().decode())[1]
            ), str(original)
            assert (
                parse(p.read_bytes().decode())[0]
                == parse(original.read_bytes().decode())[0]
            ), str(original)
            checked += 1
        print("ROUNDTRIP", exported, checked, flush=True)
        measurements = []
        for backend in ("files", "postgres"):
            start = time.monotonic()
            metrics = evaluate(backend, folder / "queries.jsonl", conn)
            conn.commit()
            measurements.append(
                {
                    "backend": backend,
                    "provider": "none",
                    "metrics": metrics,
                    "seconds": time.monotonic() - start,
                }
            )
            print("EVAL", json.dumps(measurements[-1]), flush=True)
        (folder / "measurements.json").write_text(
            json.dumps(measurements, indent=2) + "\n"
        )
        os.environ["LIBRARY_EMBED_PROVIDER"] = "fastembed"
        try:
            start = time.monotonic()
            print("EMBED_BEGIN", flush=True)
            count = embed_pending(conn)
            conn.commit()
            print("EMBEDDED", count, "SECONDS", time.monotonic() - start, flush=True)
            start = time.monotonic()
            metrics = evaluate("postgres", folder / "queries.jsonl", conn)
            conn.commit()
            measurements.append(
                {
                    "backend": "postgres",
                    "provider": "fastembed",
                    "metrics": metrics,
                    "seconds": time.monotonic() - start,
                }
            )
        except Exception as exc:
            conn.rollback()
            measurements.append(
                {"backend": "postgres", "provider": "fastembed", "error": str(exc)}
            )
            print("EMBED_ERROR", type(exc).__name__, str(exc), flush=True)
        (folder / "measurements.json").write_text(
            json.dumps(measurements, ensure_ascii=False, indent=2) + "\n"
        )
        print("DONE", json.dumps(measurements, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
