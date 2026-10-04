#!/usr/bin/env bash
# 프롬프트를 막지 않는 선택적 검색 주입. macOS에서도 subprocess timeout을 사용한다.
python3 -c '
import json, os, shlex, shutil, signal, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
started = time.monotonic()
payload = {}
prompt = ""
def skip(reason):
    if os.environ.get("LIBRARY_LOG") == "0":
        return
    try:
        import fcntl
        now = datetime.now(timezone.utc)
        root = Path(os.environ.get("LIBRARY_ROOT", Path.home() / "claude-library")) / ".activity"
        root.mkdir(parents=True, exist_ok=True)
        event = {"ts": now.isoformat(), "action": "inject", "source": "autoinject",
                 "backend": os.environ.get("LIBRARY_BACKEND", "files"), "query": prompt,
                 "results": [], "injected": False, "skipped_reason": reason,
                 "latency_ms": (time.monotonic() - started) * 1000}
        if payload.get("session_id"):
            event["session_id"] = payload["session_id"]
        with (root / ("search-" + now.strftime("%Y-%m") + ".jsonl")).open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(json.dumps(event, ensure_ascii=False) + "\n")
    except Exception:
        pass
try:
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        payload = {}
        skip("invalid_payload")
        sys.exit(0)
    prompt = payload.get("prompt", "")
    if os.environ.get("LIBRARY_AUTOINJECT") == "0":
        skip("disabled")
        sys.exit(0)
    if not isinstance(prompt, str) or len(prompt.strip()) < 8 or prompt.lstrip().startswith("/"):
        skip("short_or_command")
        sys.exit(0)
    if payload.get("session_id"):
        os.environ["LIBRARY_SESSION_ID"] = str(payload["session_id"])
    override = os.environ.get("LIBRARY_KB_CMD")
    if override:
        command = shlex.split(override)
    elif shutil.which("claude-library-kb"):
        command = ["claude-library-kb"]
    else:
        spec = (Path.home() / ".claude/hooks/.learnings-kb-spec").read_text().strip()
        if not spec:
            skip("unavailable")
            sys.exit(0)
        command = ["uvx", "--with", "mcp<2", "--from", spec, "claude-library-kb"]
    # Kill the whole process group: uvx or a wrapper can spawn child processes.
    process = subprocess.Popen(
        command + ["search", "--format", "inject", "--budget", "1500", "--", prompt],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
    )
    try:
        stdout, _ = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        skip("timeout")
        sys.exit(0)
    if process.returncode != 0:
        skip("search_error")
    context = stdout.strip()
    if process.returncode == 0 and context:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}, ensure_ascii=False))
except Exception:
    skip("unavailable_or_invalid_payload")
' 2>/dev/null
exit 0
