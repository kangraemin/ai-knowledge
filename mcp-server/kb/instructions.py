"""사용자가 세션에서 직접 한 말을 빠짐없이 모아 찾는다.

훅·LLM 없이 Claude Code 세션 기록(jsonl)에서 사람이 입력한 줄만 읽는다. 무엇을 남길지
판단하지 않으므로 기록이 빠지지 않는다. 내용이 개인적이라 라이브러리(git) 밖에 둔다.
LIBRARY_INSTRUCTIONS=off 로 끈다.
"""

import fcntl
import hashlib
import json
import math
import os
import re
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

_SKIP_PREFIX = ("<", "[Request interrupted", "This session", "Base directory", "Stop hook", "Caveat:")
_HUMAN_SKIP_PREFIX = ("<command-", "<local-command", "<bash-", "[Request interrupted", "[계정 전환 재시작]")
_CHANNEL = re.compile(r"\s*<channel[^>]*>(.*)</channel>\s*$", re.S)
_COMMAND = re.compile(r"<command-name>\s*(/[^<\s]+)\s*</command-name>.*?<command-args>(.*?)</command-args>", re.S)
_PASTED = re.compile(r"</?pasted_content[^>]*>")
_IMAGE = re.compile(r"^(?:\[Image #\d+\]\s*)+")
_MARKS = (b'"type":"user"', b'"type": "user"', b"queued_command", b"<command-args>")
_MIN_LEN, _MAX_LEN = 2, 2000
SHOW_CHARS = 220


def enabled():
    return os.environ.get("LIBRARY_INSTRUCTIONS", "on") != "off"


def store_dir():
    base = os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share"
    return Path(base) / "claude-library"


def projects_roots():
    """계정을 나눠 쓰면 세션 기록 폴더가 계정마다 따로다. 지금 계정과 기본 폴더를 함께 읽는다."""
    roots = [Path.home() / ".claude/projects"]
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        roots.append(Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects")
    return list({str(r.resolve()): r.resolve() for r in roots}.values())


def _plain(content):
    if isinstance(content, list):
        content = " ".join(x.get("text", "") for x in content
                           if isinstance(x, dict) and x.get("type") == "text")
    return content if isinstance(content, str) else ""


def extract(raw):
    """세션 기록 한 줄에서 사람이 입력한 말을 뽑는다. 도구 결과·자동 알림·서브에이전트·스크립트 실행은 뺀다.

    사람이 친 말은 세 모양으로 남는다. 일반 줄, 작업 중에 쳐서 대기열로 들어간 줄(queued_command),
    명령의 인자(/goal 내용 등). 긴 말은 앞부분만 남기고 버리지 않는다.
    """
    if not any(mark in raw for mark in _MARKS) or b'"tool_use_id"' in raw:
        return None
    try:
        d = json.loads(raw)
    except ValueError:
        return None
    if d.get("isSidechain") or d.get("entrypoint") not in (None, "cli"):
        return None
    kind = d.get("type")
    if kind == "attachment":
        att = d.get("attachment") or {}
        if att.get("type") != "queued_command" or att.get("commandMode") not in (None, "prompt"):
            return None
        origin, content = att.get("origin"), att.get("prompt")
    elif kind in ("user", "system"):
        origin, content = d.get("origin"), d.get("content") if kind == "system" else (d.get("message") or {}).get("content")
    else:
        return None
    origin_kind = origin.get("kind") if isinstance(origin, dict) else None
    if origin_kind not in (None, "human", "channel") or (d.get("isMeta") and origin_kind != "channel"):
        return None
    text = _plain(content).strip()
    command = _COMMAND.search(text)
    if command:
        args = command.group(2).strip()
        # 인자 없는 명령과 숫자 하나짜리 설정값은 지시가 아니다.
        text = f"{command.group(1)} {args}" if len(args) >= 6 else ""
    elif kind == "system":
        return None
    else:
        channel = _CHANNEL.match(text)
        text = (channel.group(1) if channel else text).strip()
        if origin_kind:  # 사람이 친 말임이 확인된 줄은 "[정정] ~" 같은 말머리도 살린다
            if text.startswith(_HUMAN_SKIP_PREFIX):
                return None
            text = _IMAGE.sub("", _PASTED.sub("", text)).strip()
        elif text.startswith(_SKIP_PREFIX):
            return None
    if len(text) < _MIN_LEN:
        return None
    return {"at": d.get("timestamp") or "", "text": text[:_MAX_LEN]}


def sync(budget=1.0):
    """새로 쌓인 줄만 읽어 모은다. 시간을 넘기면 다음 호출이 읽던 자리부터 잇는다.

    최근 세션부터 읽으므로 처음 모을 때도 최근 말은 바로 찾힌다. 다른 서버가 모으는 중이면 건너뛴다.
    끝까지 읽었으면 True.
    """
    folder = store_dir()
    folder.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + budget
    with open(folder / "instructions.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        state_file = folder / "instructions.state.json"
        try:
            state = json.loads(state_file.read_text())
        except (OSError, ValueError):
            state = {}
        files = []
        for path in (p for root in projects_roots() for p in root.glob("*/*.jsonl")):
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_size > state.get(str(path), 0):
                files.append((stat.st_mtime, path))
        if not files:
            return True
        seen = {_key(r["project"], r["text"]) for r in _rows(folder)}
        finished = True
        fd = os.open(folder / "instructions.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as out:
            for _, path in sorted(files, key=lambda f: -f[0]):
                if time.monotonic() > deadline:
                    finished = False
                    break
                finished = _read_new(path, state, seen, out, deadline) and finished
        tmp = state_file.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(state))
        os.replace(tmp, state_file)
        return finished


def _read_new(path, state, seen, out, deadline):
    key = str(path)
    with open(path, "rb") as f:
        f.seek(state.get(key, 0))
        while True:
            pos = f.tell()
            raw = f.readline()
            if not raw.endswith(b"\n"):  # 파일 끝 또는 아직 쓰는 중인 줄
                state[key] = pos
                return True
            row = extract(raw)
            if row:
                row["project"] = path.parent.name
                digest = _key(row["project"], row["text"])
                if digest not in seen:
                    seen.add(digest)
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
            if time.monotonic() > deadline:
                state[key] = f.tell()
                return False


def _key(project, text):
    return hashlib.sha1((project + "\0" + text).encode()).hexdigest()


def _rows(folder=None):
    path = (folder or store_dir()) / "instructions.jsonl"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def current_project():
    """Claude Code 가 세션 기록 폴더 이름을 만드는 규칙(영숫자 외 전부 '-')."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())


def _terms(query, texts):
    """붙여 쓴 구어체는 기록에 나오는 낱말 조각으로 나눈다."""
    from .search import query_terms
    vocabulary = None
    out = []
    for term in query_terms(query):
        if term.isascii() or len(term) < 4 or any(term in t for t in texts):
            out.append(term)
            continue
        if vocabulary is None:
            vocabulary = {w for t in texts for w in re.findall(r"[가-힣]{2,}", t)}
        at = 0
        while at < len(term) - 1:
            for end in range(len(term), at + 1, -1):
                if term[at:end] in vocabulary:
                    out.append(term[at:end])
                    at = end
                    break
            else:
                at += 1
    return list(dict.fromkeys(out))


def search(query, project=None, k=3, all_projects=False, now=None):
    """지금 프로젝트에서 사용자가 전에 한 말 가운데 질의와 겹치는 것. 방금 한 말은 뺀다."""
    project = project or current_project()
    rows = [r for r in _rows() if all_projects or r["project"] == project]
    if not rows:
        return []
    now = now or datetime.now(timezone.utc)
    recent = (now - timedelta(minutes=3)).strftime("%Y-%m-%dT%H:%M:%S")
    query_norm = " ".join(query.split())
    rows = [r for r in rows if r["at"][:19] < recent and " ".join(r["text"].split()) != query_norm]
    texts = [r["text"].lower() for r in rows]
    terms = _terms(query, texts)
    idf = {}
    for term in terms:
        df = sum(term in t for t in texts)
        if df:
            idf[term] = math.log1p(len(rows) / df)
    if len(idf) < 2:
        return []
    total = sum(idf.values())
    scored = []
    for row, text in zip(rows, texts):
        hit = [t for t in idf if t in text]
        # 스크립트가 넣은 긴 작업 지시문은 단어가 많아 아무 질의에나 걸린다. 질의어를 전부 담을 때만 쓴다.
        if len(hit) < 2 or (len(text) > 400 and len(hit) < len(idf)):
            continue
        score = sum(idf[t] for t in hit) / total
        # 흔한 단어 두 개가 겹친 건 근거가 아니다.
        if len(hit) >= 3 or score >= .5:
            scored.append((round(score, 3), row["at"], row))
    scored.sort(key=lambda s: (s[0], s[1]), reverse=True)
    return [{**row, "score": score} for score, _, row in scored[:k]]


def format_rows(rows):
    return "\n".join(f"- {r['at'][:10]} \"{' '.join(r['text'].split())[:SHOW_CHARS]}\"" for r in rows)


def lookup(query, k=3, all_projects=False):
    """검색이 이것 때문에 실패하지 않게 오류는 빈 결과로 돌린다."""
    if not enabled():
        return []
    try:
        sync()
        return search(query, k=k, all_projects=all_projects)
    except (OSError, ValueError, KeyError):
        return []
