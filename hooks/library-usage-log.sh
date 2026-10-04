#!/usr/bin/env bash
# Stop 훅은 실패하거나 시간이 초과되어도 대화를 막지 않는다.
python3 -c '
import hashlib, json, os, shlex, shutil, signal, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
started = time.monotonic()
payload = {}
def failure(reason):
    try:
        import fcntl
        now = datetime.now(timezone.utc)
        folder = Path(os.environ.get("LIBRARY_ROOT", Path.home() / "claude-library")) / ".activity"
        folder.mkdir(parents=True, exist_ok=True)
        row = {"ts": now.isoformat(), "session_id": payload.get("session_id", ""), "cwd": payload.get("cwd", ""),
               "repo": Path(payload.get("cwd", "")).name, "prompt": "", "prompt_len": 0,
               "labels": ["parse_error"], "error": reason, "latency_ms": (time.monotonic()-started)*1000}
        if os.environ.get("LIBRARY_USAGE_LOG", "aggregate") != "full":
            row.pop("prompt", None)
            row["prompt_sha256"] = hashlib.sha256(b"").hexdigest()[:16]
        with (folder / ("usage-" + now.strftime("%Y-%m") + ".jsonl")).open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    except Exception:
        pass
if os.environ.get("LIBRARY_LOG") == "0" or os.environ.get("LIBRARY_USAGE_LOG") == "off":
    sys.exit(0)
try:
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        payload = {}
        raise ValueError("invalid_payload")
    override = os.environ.get("LIBRARY_KB_CMD")
    if override:
        command = shlex.split(override)
    elif shutil.which("claude-library-kb"):
        command = ["claude-library-kb"]
    else:
        spec = (Path.home() / ".claude/hooks/.learnings-kb-spec").read_text().strip()
        if not spec:
            raise ValueError("empty_spec")
        command = ["uvx", "--with", "mcp<2", "--from", spec, "claude-library-kb"]
    process = subprocess.Popen(command + ["usage-log", "--transcript", payload["transcript_path"],
        "--session", payload.get("session_id", ""), "--cwd", payload.get("cwd", "")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        process.wait(timeout=max(.01, 19 - (time.monotonic()-started)))
        if process.returncode:
            failure("command_failed")
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        failure("timeout")
except Exception as exc:
    failure(type(exc).__name__)
' 2>/dev/null
exit 0
