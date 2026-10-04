#!/usr/bin/env bash
# 프롬프트를 막지 않는 선택적 검색 주입. macOS에서도 subprocess timeout을 사용한다.
[ "${LIBRARY_AUTOINJECT:-1}" = "0" ] && exit 0
python3 -c '
import json, os, shlex, shutil, signal, subprocess, sys
from pathlib import Path
try:
    payload = json.load(sys.stdin)
    prompt = payload.get("prompt", "")
    if not isinstance(prompt, str) or len(prompt.strip()) < 8 or prompt.lstrip().startswith("/"):
        sys.exit(0)
    override = os.environ.get("LIBRARY_KB_CMD")
    if override:
        command = shlex.split(override)
    elif shutil.which("claude-library-kb"):
        command = ["claude-library-kb"]
    else:
        spec = (Path.home() / ".claude/hooks/.learnings-kb-spec").read_text().strip()
        if not spec:
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
        sys.exit(0)
    context = stdout.strip()
    if process.returncode == 0 and context:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}, ensure_ascii=False))
except Exception:
    pass
' 2>/dev/null
exit 0
