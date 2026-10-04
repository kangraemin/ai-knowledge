import json
import random
from pathlib import Path

import pytest

from kb.cli import default_queries_path, evaluate, parser
from kb.search import query_terms


def test_frozen_split_is_complete_and_reproducible():
    path = default_queries_path()
    if not path.exists():
        pytest.skip(f"평가셋 없음: {path} (라이브러리 쪽 비공개 데이터)")
    rows = [json.loads(s) for s in path.read_text().splitlines()]
    indices = list(range(len(rows)))
    random.Random(20261004).shuffle(indices)
    dev = set(indices[: len(rows) // 2])
    assert len(rows) == 45
    assert len({r["q"] for r in rows}) == 45
    assert all(
        r["split"] == ("dev" if i in dev else "test") for i, r in enumerate(rows)
    )


def test_evaluate_never_searches_other_split(tmp_path, monkeypatch):
    import server

    path = tmp_path / "queries.jsonl"
    path.write_text(
        "\n".join(
            json.dumps({"q": q, "split": split, "expected": ["hit"]})
            for q, split in [("visible", "dev"), ("heldout", "test")]
        )
    )
    seen = []

    def fake_search(q):
        seen.append(q)
        return [{"path": "miss"}, {"path": "hit"}]

    monkeypatch.setattr(server, "_search", fake_search)
    assert evaluate("files", path, split="dev") == {
        "n": 1,
        "R@1": 0,
        "R@5": 1,
        "MRR": 0.5,
    }
    assert seen == ["visible"]
    assert (
        parser().parse_args(["eval", "--backend", "files", "--split", "test"]).split
        == "test"
    )
    with pytest.raises(ValueError, match="빈 평가셋"):
        evaluate("files", path, split="absent")


def test_prose_terms_keep_identifiers_and_remove_duplicate_noise():
    assert query_terms("How can I debug HTTP? http!") == ["debug", "http"]
    assert query_terms("DB의 백업은?") == ["db", "백업"]
    assert query_terms("pg_bigm v1.2 사과는 사과는") == ["pg_bigm", "v1.2", "사과"]
    assert query_terms("") == []
