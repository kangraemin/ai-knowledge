import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

from kb import activity, usage
from kb.cli import main


@pytest.fixture
def library(tmp_path):
    root = activity.root()
    (root / 'library/testing').mkdir(parents=True)
    (root / 'library/testing/backup.md').write_text('---\ntype: Concept\ntitle: database backup recovery checksum\ndescription: database backup recovery checksum\n---\ndatabase backup recovery checksum')
    for i in range(100):
        (root / f"library/testing/noise-{i}.md").write_text("---\ntitle: unrelated filler\n---\nnoise")
    return root


def transcript(tmp_path, prompt='database backup recovery checksum', tools=(), answer='', previous=False):
    rows = []
    if previous:
        rows.extend([{'type': 'user', 'message': {'content': 'old turn'}}, {'type': 'assistant', 'message': {'content': 'old answer'}}])
    rows.append({'type': 'user', 'uuid': str(uuid.uuid4()), 'timestamp': datetime.now(timezone.utc).isoformat(), 'message': {'content': prompt}})
    for i, (name, args, result) in enumerate(tools):
        rows.append({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': str(i), 'name': name, 'input': args}]}})
        rows.append({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': str(i), 'content': result}]}})
    rows.append({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': answer}]}})
    path = tmp_path / 'transcript.jsonl'
    path.write_text('\n'.join(json.dumps(row) for row in rows))
    return path


SEARCH = 'mcp__claude-library__library_search'
READ = 'mcp__claude-library__library_read'
DOC = 'library/testing/backup.md'


@pytest.mark.parametrize('kind,expected', [('used', 'hit_used'), ('unused', 'hit_unused'), ('missed', 'missed'), ('empty', 'searched_empty'), ('none', 'no_need'), ('duplicate', 'duplicate_write')])
def test_labels(tmp_path, library, kind, expected):
    tools, answer, prompt = [], '', 'database backup recovery checksum'
    if kind in ('used', 'unused'):
        tools.append((SEARCH, {'query': prompt}, f'- database backup recovery checksum `{DOC}`'))
    if kind == 'used':
        tools.append((READ, {'path': DOC}, 'database backup recovery checksum'))
        answer = f'📚 library 참조: {DOC}'
    if kind == 'empty':
        tools.append((SEARCH, {'query': 'unrelated'}, '관련 라이브러리 항목 없음.'))
    if kind == 'none':
        prompt = 'quuxzebra'
    if kind == 'duplicate':
        tools.append(('Write', {'file_path': str(library / 'library/new.md'), 'content': '---\ntitle: database backup recovery checksum\n---\ncontent'}, 'File created successfully'))
    row = usage.log_usage(transcript(tmp_path, prompt, tools, answer, previous=True), 'session', '/tmp/project')
    assert row['labels'] == (['missed', 'duplicate_write'] if kind == 'duplicate' else [expected])
    assert row['prompt_sha256'] == activity.digest(prompt)
    assert 'prompt' not in row
    assert len(list(usage.records('usage-*.jsonl', library))) == 1


def test_join_latest_session_and_stale(tmp_path, library, monkeypatch):
    monkeypatch.setenv('LIBRARY_SESSION_ID', 'session')
    activity.search_event('database backup recovery checksum', [{'path': DOC, 'score': .9}], 'files', 1, injected=True, action='inject')
    activity.append({'session_id': 'other', 'action': 'inject', 'query': 'database backup recovery checksum', 'injected': False})
    path = transcript(tmp_path, answer='backup.md')
    row = usage.log_usage(path, 'session')
    assert row['autoinject']['injected']
    assert row['labels'] == ['hit_used']
    row = usage.log_usage(transcript(tmp_path, prompt='other topic'), 'session')
    assert not row['autoinject']['injected']


def test_low_score_and_unknown_search(tmp_path, library, monkeypatch):
    monkeypatch.setenv('LIBRARY_AUTOINJECT_MIN_SCORE', '1')
    row = usage.log_usage(transcript(tmp_path, tools=[(SEARCH, {'query': 'database'}, DOC)]))
    assert 'searched_empty' in row['labels']
    path = transcript(tmp_path, tools=[(SEARCH, {'query': 'database'}, DOC)])
    rows = [r for r in path.read_text().splitlines() if 'tool_result' not in r]
    path.write_text('\n'.join(rows))
    row = usage.log_usage(path)
    assert 'searched_empty' not in row['labels'] and row['search_unknown'] == 1


def test_parse_error_and_disabled(tmp_path, library, monkeypatch):
    path = tmp_path / 'bad'
    path.write_text('{bad json')
    assert main(['usage-log', '--transcript', str(path)]) == 0
    assert list(usage.records('usage-*.jsonl', library))[0]['labels'] == ['parse_error']
    monkeypatch.setenv('LIBRARY_LOG', '0')
    assert usage.log_usage(path) is None
    assert len(list(usage.records('usage-*.jsonl', library))) == 1


def test_timeout_handler(tmp_path, library, monkeypatch):
    def expired(*args):
        raise TimeoutError()
    monkeypatch.setattr(usage, 'analyze', expired)
    row = usage.log_usage('irrelevant')
    assert row['labels'] == ['parse_error'] and row['error'] == 'TimeoutError'


def test_report_arithmetic_and_save(tmp_path, library, capsys):
    usage.log_usage(transcript(tmp_path), 's')
    usage.log_usage(transcript(tmp_path, tools=[(SEARCH, {'query': 'database backup'}, DOC), (READ, {'path': DOC}, 'contents')], answer=DOC), 's')
    usage.log_usage(transcript(tmp_path, prompt='unrelated'), 's')
    result = usage.report()
    assert result['turns'] == 3
    assert result['contact_rate']['rate'] == pytest.approx(1/3)
    assert result['missed_rate']['rate'] == .5
    assert result['search_success_rate']['rate'] == 1
    assert result['dead_knowledge']['numerator'] == 100
    assert result['documents']['cited'] == [{'path': DOC, 'count': 1}]
    assert len(result['recent_missed']) == 1
    assert main(['report', '--format', 'json']) == 0
    assert json.loads(capsys.readouterr().out)['turns'] == 3
    assert main(['report', '--format', 'md', '--save']) == 0
    assert len(list((library / 'eval').glob('usage-report-*.md'))) == 1


def test_edit_not_duplicate_and_write_outside(tmp_path, library):
    row = usage.log_usage(transcript(tmp_path, tools=[('Edit', {'file_path': str(library / DOC)}, 'ok'), ('Write', {'file_path': str(tmp_path / 'outside.md')}, 'created')]))
    assert row['calls']['library_edit'] == [DOC]
    assert row['calls']['library_write'] == []
    assert 'duplicate_write' not in row['labels']


def test_hook_timeout_and_off(tmp_path, library):
    hook = Path(__file__).resolve().parents[2] / 'hooks/library-usage-log.sh'
    script = tmp_path / 'slow.py'
    script.write_text('import time\ntime.sleep(60)\n')
    env = {**os.environ, 'LIBRARY_KB_CMD': f'{sys.executable} {script}'}
    started = time.monotonic()
    result = subprocess.run(['bash', str(hook)], input=json.dumps({'transcript_path': 'fake', 'session_id': 's'}), text=True, env=env, timeout=21, capture_output=True)
    assert result.returncode == 0 and time.monotonic()-started < 20
    assert list(usage.records('usage-*.jsonl', library))[0]['error'] == 'timeout'
    env['LIBRARY_LOG'] = '0'
    result = subprocess.run(['bash', str(hook)], input='invalid', text=True, env=env, timeout=2)
    assert result.returncode == 0
    assert len(list(usage.records('usage-*.jsonl', library))) == 1


def test_pg_turn_payload_and_rls(db, as_user, tmp_path, library, monkeypatch):
    from psycopg.conninfo import conninfo_to_dict, make_conninfo
    options = conninfo_to_dict(os.environ['KB_TEST_DATABASE_URL'])
    options['user'] = 'kb_test_a'
    monkeypatch.setenv('LIBRARY_DATABASE_URL', make_conninfo(**options))
    monkeypatch.setenv('LIBRARY_BACKEND', 'postgres')
    row = usage.log_usage(transcript(tmp_path), 'session')
    with as_user('a') as conn:
        events = conn.execute("SELECT payload FROM kb.events WHERE action='turn'").fetchall()
        assert events == [{'payload': row}]
    with as_user('b') as conn:
        assert conn.execute("SELECT payload FROM kb.events WHERE action='turn'").fetchall() == []


def test_report_injection_empty_duplicates_and_window(tmp_path, library, monkeypatch):
    from datetime import timedelta
    monkeypatch.setenv('LIBRARY_SESSION_ID', 's')
    activity.search_event('database backup recovery checksum', [{'path': DOC, 'score': .9}], 'files', 42, injected=True, action='inject')
    usage.log_usage(transcript(tmp_path, answer=DOC), 's', '/tmp/repo')
    usage.log_usage(transcript(tmp_path, tools=[(SEARCH, {'query': 'absent'}, '[]')]), 'other', '/tmp/repo')
    usage.log_usage(transcript(tmp_path, tools=[('Write', {'file_path': str(library / 'library/new.md'), 'content': '---\ntitle: database backup recovery checksum\n---'}, 'created')]), 'other', '/tmp/repo')
    usage.append_turn({'ts': (datetime.now(timezone.utc)-timedelta(days=60)).isoformat(), 'labels': ['parse_error']})
    usage.append_turn({'ts': datetime.now(timezone.utc).isoformat(), 'labels': ['parse_error']})
    result = usage.report(7)
    assert result['turns'] == 3 and result['parse_errors'] == 1
    assert result['injection_precision'] == {'numerator': 1, 'denominator': 1, 'rate': 1.0}
    assert result['searched_empty_rate']['rate'] == 1.0
    assert result['duplicate_write_count'] == 1
    assert result['category_hits'] == {'testing': 1}
    assert result['repos'] == {'repo': 3}
    assert result['search_latency_ms']['p50'] == 42
    assert next(iter(result['daily'].values())) == {'turns': 3, 'contacted': 2, 'missed': 1, 'hit_used': 1}


def test_hook_real_cli(tmp_path, library):
    hook = Path(__file__).resolve().parents[2] / 'hooks/library-usage-log.sh'
    path = transcript(tmp_path)
    env = {**os.environ, 'LIBRARY_KB_CMD': f'{sys.executable} -m kb.cli',
           'PYTHONPATH': str(hook.parents[1] / 'mcp-server')}
    result = subprocess.run(['bash', str(hook)], input=json.dumps({'transcript_path': str(path), 'session_id': 's', 'cwd': '/tmp/repo'}), text=True, env=env, capture_output=True, timeout=20)
    assert result.returncode == 0 and result.stdout == ''
    rows = list(usage.records('usage-*.jsonl', library))
    assert len(rows) == 1 and rows[0]['labels'] == ['missed']
    assert rows[0]['session_id'] == 's'


def test_flattened_transcript_decisions_and_title(tmp_path, library):
    path = tmp_path / 'flat.jsonl'
    rows = [
        {'role': 'user', 'content': 'database backup recovery checksum'},
        {'role': 'assistant', 'content': [{'type': 'tool_use', 'name': READ, 'id': 'one', 'input': {'path': DOC}}, {'type': 'tool_use', 'name': 'mcp__claude-library__decision_list', 'id': 'two', 'input': {'repo': 'repo'}}]},
        {'role': 'assistant', 'content': 'database backup recovery checksum'},
    ]
    path.write_text('\n'.join(json.dumps(r) for r in rows))
    row = usage.log_usage(path)
    assert row['labels'] == ['hit_used']
    assert row['calls']['decision_*'] == 1
    assert row['cited_paths'] == [DOC]


@pytest.mark.parametrize('legacy', [False, True])
def test_six_user_kinds_and_duplicate(tmp_path, library, legacy):
    # 실제 메시지 구조를 재현하되 내용은 합성 데이터만 사용한다.
    rows = [
        {'type': 'user', 'uuid': 'human-one', 'origin': {'kind': 'human'}, 'promptSource': 'queued', 'turnOrigin': 'human', 'message': {'content': 'database backup recovery checksum'}},
        {'type': 'user', 'origin': {'kind': 'task-notification', 'producer': 'session-task'}, 'promptSource': 'system', 'turnOrigin': 'task_notification', 'message': {'content': '<task-notification>completed</task-notification>'}},
        {'type': 'user', 'isMeta': True, 'message': {'content': 'Stop hook feedback: retry'}},
        {'type': 'user', 'isMeta': True, 'message': {'content': [{'type': 'text', 'text': 'skill body'}]}},
        {'type': 'user', 'toolUseResult': {}, 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'x', 'content': 'ok'}]}},
        {'type': 'user', 'message': {'content': [{'type': 'text', 'text': '[Request interrupted by user for tool use]'}]}},
        {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 'r', 'name': READ, 'input': {'path': DOC}}]}},
        {'type': 'assistant', 'message': {'content': DOC}},
    ]
    if legacy:
        for row in rows:
            for key in ('origin', 'promptSource', 'turnOrigin'):
                row.pop(key, None)
    path = tmp_path / 'six.jsonl'
    path.write_text('\n'.join(json.dumps(r) for r in rows))
    result = usage.log_usage(path, 's')
    assert result['turn_id'] == 'human-one' and result['labels'] == ['hit_used']
    assert result['prompt_sha256'] == activity.digest('database backup recovery checksum')
    usage.log_usage(path, 's')
    assert len(list(usage.records('usage-*.jsonl', library))) == 1
    usage.log_usage(path, 'another-session')
    assert len(list(usage.records('usage-*.jsonl', library))) == 2


@pytest.mark.parametrize('mode', ['aggregate', 'full', 'off'])
def test_privacy_modes(tmp_path, library, monkeypatch, mode):
    monkeypatch.setenv('LIBRARY_USAGE_LOG', mode)
    prompt = 'database backup recovery checksum'
    activity.search_event(prompt, [], 'files', 1)
    result = usage.log_usage(transcript(tmp_path, tools=[(SEARCH, {'query': prompt}, '[]')]), 's')
    events = list(usage.records('search-*.jsonl', library))
    if mode == 'off':
        assert result is None and events == []
        assert list(usage.records('usage-*.jsonl', library)) == []
    elif mode == 'full':
        assert result['prompt'] == prompt and events[0]['query'] == prompt
    else:
        assert 'prompt' not in result and 'query' not in events[0]
        assert events[0]['query_sha256'] == activity.digest(prompt)
        assert events[0]['query_len'] == len(prompt)
        assert prompt not in json.dumps(result)


@pytest.mark.parametrize('payload', [
    {'prompt': '<task-notification>finished</task-notification>'},
    {'prompt': '<system-reminder>notice'},
    {'prompt': 'background finished', 'origin': {'kind': 'task-notification'}},
    {'prompt': 'background finished', 'turnOrigin': 'task_notification'},
])
def test_system_autoinject(tmp_path, library, payload):
    hook = Path(__file__).resolve().parents[2] / 'hooks/library-autoinject.sh'
    result = subprocess.run(['bash', str(hook)], input=json.dumps(payload), text=True, capture_output=True)
    assert result.returncode == 0 and result.stdout == ''
    event = list(usage.records('search-*.jsonl', library))[0]
    assert event['skipped_reason'] == 'system' and 'query' not in event


def test_aggregate_report(tmp_path, library):
    usage.log_usage(transcript(tmp_path), 's')
    missed = usage.report()['recent_missed'][0]
    assert 'prompt' not in missed and missed['prompt_len'] == len('database backup recovery checksum')
    assert missed['prompt_sha256'] == activity.digest('database backup recovery checksum')
