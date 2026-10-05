"""필요한 순간에만 검색하며 외부 CLI 실행 시간을 제한한다."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

ERROR = re.compile(r'\b(?:\w*Error|Traceback|failed|failure|fatal|exception)\b', re.I)


def failed(response):
    if not isinstance(response, dict):
        return False
    for key in ('exit_code', 'exitCode', 'returncode'):
        if key in response and response[key] is not None:
            try:
                if int(response[key]) != 0:
                    return True
            except (ValueError, TypeError):
                pass
    return bool(ERROR.search(str(response.get('stderr', ''))))


def core_error(text):
    lines = [re.sub(r'\x1b\[[0-9;]*m', '', x).strip() for x in str(text).splitlines() if x.strip()]
    matches = [x for x in lines if ERROR.search(x) and not x.startswith('Traceback (')]
    return '\n'.join((matches or lines)[-2:])[:2000]


def start_args(command):
    try:
        parts = shlex.split(command, comments=True)
        if parts[:2] == ['bouncer', 'start']:
            return ' '.join(parts[2:])
    except (ValueError, TypeError):
        pass
    return ''


def library_path(value):
    root = Path(os.environ.get('LIBRARY_ROOT', Path.home() / 'claude-library')).resolve()
    path = Path(value).expanduser().resolve()
    if path.suffix == '.md' and path.is_relative_to(root / 'library') and path.name != 'index.md':
        return path
    return None


def cache_path(session, kind, value):
    folder = Path.home() / '.claude' / 'cache' / 'library-triggers'
    folder.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(json.dumps([session, kind, value]).encode()).hexdigest()
    return folder / key


def claim(session, kind, value):
    # 세션·문구 해시만 저장하며 원문과 경로는 캐시에 남기지 않는다.
    if not session:
        return True
    try:
        fd = os.open(cache_path(session, kind, value), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        return True
    except FileExistsError:
        return False


def new_document(payload):
    path = library_path((payload.get('tool_input') or {}).get('file_path', ''))
    response = payload.get('tool_response') or {}
    session = str(payload.get('session_id', ''))
    if path is None or not isinstance(response, dict):
        return None
    created = response.get('type') == 'create'
    if created and session:
        claim(session, 'created', str(path))
    if created or (session and cache_path(session, 'created', str(path)).exists()):
        return path
    return None


def command():
    override = os.environ.get('LIBRARY_KB_CMD')
    if override:
        return shlex.split(override)
    if shutil.which('claude-library-kb'):
        return ['claude-library-kb']
    spec = (Path.home() / '.claude/hooks/.learnings-kb-spec').read_text().strip()
    if not spec:
        raise ValueError('빈 CLI 설정')
    return ['uvx', '--with', 'mcp<2', '--from', spec, 'claude-library-kb']


def run(payload):
    started = time.monotonic()
    tool = payload.get('tool_name')
    data = payload.get('tool_input') or {}
    response = payload.get('tool_response') or {}
    event = payload.get('hook_event_name', 'PostToolUse')
    kind, query = '', ''
    if tool == 'Bash':
        if event == 'PostToolUseFailure' and not payload.get('is_interrupt'):
            kind, query = 'error', core_error(payload.get('error', ''))
        elif failed(response):
            kind, query = 'error', core_error(response.get('stderr') or response.get('stdout', ''))
        elif event == 'PostToolUse':
            kind, query = 'start', start_args(data.get('command', ''))
    elif tool == 'Skill' and data.get('skill') == 'dev-bounce':
        kind, query = 'start', data.get('args', '')
    elif tool in ('Write', 'Edit'):
        # 생성 응답을 확인한 문서는 같은 세션의 후속 편집에서도 재검사한다.
        path = new_document(payload)
        if path:
            kind, query = 'write', str(path)
    cache_value = query
    if kind == 'write':
        cache_value += hashlib.sha256(Path(query).read_bytes()).hexdigest()
    if not query or not claim(str(payload.get('session_id', '')), kind, cache_value):
        return
    context, reason = '', None
    try:
        args = ['duplicates', query] if kind == 'write' else ['search', '--format', 'trigger', '--', query]
        env = dict(os.environ, LIBRARY_LOG='0', LIBRARY_SESSION_ID=str(payload.get('session_id', '')))
        proc = subprocess.Popen(command() + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True, env=env)
        try:
            stdout, _ = proc.communicate(timeout=max(.1, 4.5 - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise TimeoutError()
        if proc.returncode == 0:
            context = stdout.strip()
        else:
            reason = 'search_error'
    except Exception:
        reason = 'unavailable_or_timeout'
    # CLI 실패도 같은 활동 로그에 남기되 기본 모드에서는 질의를 해시 처리한다.
    if os.environ.get('LIBRARY_LOG') != '0' and os.environ.get('LIBRARY_USAGE_LOG') != 'off':
        try:
            import fcntl
            now = datetime.now(timezone.utc)
            root = Path(os.environ.get('LIBRARY_ROOT', Path.home() / 'claude-library')) / '.activity'
            root.mkdir(parents=True, exist_ok=True)
            record = dict(ts=now.isoformat(), action='inject', source='trigger:' + kind,
                          session_id=payload.get('session_id', ''), injected=bool(context), results=[],
                          skipped_reason=reason, latency_ms=(time.monotonic()-started)*1000)
            if os.environ.get('LIBRARY_USAGE_LOG') == 'full':
                record['query'] = query
            else:
                record.update(query_sha256=hashlib.sha256(query.encode()).hexdigest()[:16], query_len=len(query))
            # 같은 검색의 판정 기준값(gate 해시)은 CLI 가 남기는 source=trigger 기록에 있다.
            version_file = Path.home() / '.claude/hooks/.learnings-version'
            record['version'] = {'install': version_file.read_text().strip() if version_file.exists() else 'unknown',
                                 'autoinject': os.environ.get('LIBRARY_AUTOINJECT', '0')}
            with (root / ('search-' + now.strftime('%Y-%m') + '.jsonl')).open('a') as stream:
                fcntl.flock(stream, fcntl.LOCK_EX)
                stream.write(json.dumps(record, ensure_ascii=False) + '\n')
        except Exception:
            pass
    if context:
        print(json.dumps({'hookSpecificOutput': {'hookEventName': event, 'additionalContext': context}}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        run(json.load(sys.stdin))
    except Exception:
        pass
