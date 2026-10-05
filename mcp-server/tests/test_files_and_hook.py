import json
import os
from pathlib import Path
import subprocess
import pytest
from kb.markdown import parse, render, chunks, scan_secrets, validate_path
from kb.search import format_results


@pytest.mark.parametrize(
    "secret",
    [
        "AKIA" + "A" * 16,
        "sk-" + "a" * 30,
        "ghp_" + "a" * 36,
        "xoxb-" + "1" * 20,
        "-----BEGIN RSA PRIVATE KEY-----",
        "password=hunter2",
        "api_key: secretvalue",
    ],
)
def test_secret_scan(secret):
    with pytest.raises(ValueError, match="비밀정보"):
        scan_secrets(secret)


@pytest.mark.parametrize(
    "path",
    [
        "../outside.md",
        "/tmp/a.md",
        "library/../../a.md",
        "decisions/../a.md",
        "other/a.md",
    ],
)
def test_path_traversal(path):
    with pytest.raises(ValueError):
        validate_path(path)


def test_full_yaml_and_body_preservation():
    raw = '---\ntype: Gotcha\ntitle: "한글 \\"인용\\""\ncreated: 2026-10-04\nnested: {list: [a, b], flag: true}\n---\n\n# 본문\n\n끝  \n'
    meta, body = parse(raw)
    assert meta["nested"] == {"list": ["a", "b"], "flag": True}
    assert body == "\n# 본문\n\n끝  \n"
    for _ in range(3):
        assert parse(render(meta, body)) == (meta, body)


def test_chunk_size_and_headings():
    result = list(chunks("## 첫째\n" + "가" * 4000 + "\n\n## 둘째\n본문"))
    assert all(len(t) <= 1500 for h, t in result)
    assert result[-1][0] == "둘째"


def test_file_backend_search_no_body_and_legacy_tools(tmp_path, monkeypatch):
    import server

    root = tmp_path / "root"
    (root / "library/topic").mkdir(parents=True)
    path = root / "library/topic/apple.md"
    path.write_text(
        "---\ntype: Gotcha\ntitle: 제목\ndescription: apples\n---\n본문비공개 apples"
    )
    monkeypatch.setattr(server, "LIBRARY_ROOT", root)
    monkeypatch.setattr(server, "_index_cache", None)
    result = server.library_search("apples")
    assert "library/topic/apple.md · 제목 · apples" == result
    assert "본문비공개" not in result
    assert "본문비공개" in server.library_read("library/topic/apple.md")
    assert "postgres" in server.library_write("library/a.md", "hello")
    assert "밖" in server.library_read("../outside.md")


def test_format_budget_and_description():
    rows = [{"path": "library/a.md", "title": "hi", "description": "가" * 200}]
    line = format_results(rows, 1000)
    assert len(line.split(" · ")[2]) == 160
    assert format_results(rows, 2) == ""


HOOK = Path(__file__).resolve().parents[2] / "hooks/library-autoinject.sh"


@pytest.mark.parametrize(
    "payload",
    [{}, {"prompt": "short"}, {"prompt": "/some-command long"}, {"prompt": None}],
)
def test_hook_skip(payload):
    out = subprocess.run(
        ["bash", str(HOOK)], input=json.dumps(payload), text=True, capture_output=True
    )
    assert out.returncode == 0 and out.stdout == ""


def test_hook_success_and_argument_safety(tmp_path, monkeypatch):
    executable = tmp_path / "claude-library-kb"
    executable.write_text(
        '#!/usr/bin/env python3\nimport sys\nassert sys.argv[-2]=="--"\nprint("library/a.md · hello · description")\n'
    )
    executable.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    out = subprocess.run(
        ["bash", str(HOOK)],
        input=json.dumps({"prompt": "$(touch /tmp/no-execution) hello"}),
        text=True,
        capture_output=True,
    )
    assert out.returncode == 0
    payload = json.loads(out.stdout)["hookSpecificOutput"]
    assert payload["hookEventName"] == "UserPromptSubmit" and payload[
        "additionalContext"
    ].startswith("library/a.md")


def test_hook_failure_disabled_and_malformed(tmp_path, monkeypatch):
    executable = tmp_path / "claude-library-kb"
    executable.write_text("#!/bin/sh\nexit 1\n")
    executable.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    for payload in ["not JSON", json.dumps({"prompt": "a long enough prompt"})]:
        out = subprocess.run(
            ["bash", str(HOOK)], input=payload, text=True, capture_output=True
        )
        assert out.returncode == 0 and out.stdout == ""
    monkeypatch.setenv("LIBRARY_AUTOINJECT", "0")
    out = subprocess.run(
        ["bash", str(HOOK)], input="{}", text=True, capture_output=True
    )
    assert out.returncode == 0 and out.stdout == ""


def test_hook_timeout(tmp_path, monkeypatch):
    executable = tmp_path / "claude-library-kb"
    executable.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(20)\n")
    executable.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    out = subprocess.run(
        ["bash", str(HOOK)],
        input=json.dumps({"prompt": "long enough timeout test"}),
        text=True,
        capture_output=True,
        timeout=8,
    )
    assert out.returncode == 0 and out.stdout == ""


def test_hook_runs_real_cli_evidence_gate(tmp_path, monkeypatch):
    import sys
    root = tmp_path / 'hook-library'
    (root / 'library').mkdir(parents=True)
    (root / 'library/restore.md').write_text('---\ntitle: Postgres WAL archive recovery\n---\n')
    for i in range(100):
        (root / f'library/filler-{i}.md').write_text('---\ntitle: unrelated filler\n---\n')
    monkeypatch.setenv('LIBRARY_ROOT', str(root))
    monkeypatch.setenv('LIBRARY_LOG', '0')
    monkeypatch.setenv('LIBRARY_KB_CMD', f'{sys.executable} -m kb.cli')
    monkeypatch.setenv('PYTHONPATH', str(Path(__file__).resolve().parents[1]))
    for prompt, expected in [('Postgres WAL archive recovery', True),
                             ('continue checking the progress please', False)]:
        out = subprocess.run(['bash', str(HOOK)], input=json.dumps({'prompt': prompt}),
                             text=True, capture_output=True, timeout=8)
        assert out.returncode == 0
        assert bool(out.stdout.strip()) is expected
        if expected:
            assert 'library/restore.md' in json.loads(out.stdout)['hookSpecificOutput']['additionalContext']
