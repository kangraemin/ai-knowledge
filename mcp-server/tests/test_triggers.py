import importlib.util
import json
from pathlib import Path
import pytest

spec = importlib.util.spec_from_file_location('trigger', Path(__file__).resolve().parents[2] / 'hooks/library-trigger.py')
trigger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trigger)


@pytest.mark.parametrize('response,expected', [({'exit_code': 1}, True), ({'exitCode': '2'}, True), ({'returncode': 0}, False), ({'stderr': 'ValueError: broken'}, True), ({'stderr': 'Traceback (most recent call last):'}, True), ({'stderr': 'build failed'}, True), ({'stderr': 'warning only'}, False), ({}, False)])
def test_failed(response, expected):
    assert trigger.failed(response) == expected


def test_core_and_cache():
    assert trigger.core_error('Traceback (most recent call last):\n  foo()\nRuntimeError: broken') == 'RuntimeError: broken'
    assert trigger.claim('s1', 'error', 'broken')
    assert not trigger.claim('s1', 'error', 'broken')
    assert trigger.claim('s2', 'error', 'broken')


@pytest.mark.parametrize('command,expected', [('bouncer start bug "fix parser"', 'bug fix parser'), ('echo bouncer start bug', ''), ('bouncer restart bug', ''), ('bouncer start "', ''), ('bouncer start simple goal-x 2>&1 | tail -30', 'simple goal-x'), ('bouncer start simple "a b" && ls', 'simple a b')])
def test_start(command, expected):
    assert trigger.start_args(command) == expected


def test_paths(tmp_path, monkeypatch):
    monkeypatch.setenv('LIBRARY_ROOT', str(tmp_path))
    assert trigger.library_path(str(tmp_path / 'library/new.md'))
    assert not trigger.library_path(str(tmp_path / 'library/../outside.md'))
    assert not trigger.library_path(str(tmp_path / 'library/index.md'))
    (tmp_path / 'library').mkdir()
    (tmp_path / 'library/link').symlink_to(tmp_path)
    assert not trigger.library_path(str(tmp_path / 'library/link/out.md'))


def test_inject_and_log(tmp_path, monkeypatch, capsys):
    stub = tmp_path / 'stub.py'
    stub.write_text('print("related context")')
    monkeypatch.setenv('LIBRARY_KB_CMD', f'python3 {stub}')
    payload = dict(session_id='s', tool_name='Bash', tool_response={'stderr': 'Error: synthetic'}, tool_input={})
    trigger.run(payload)
    assert json.loads(capsys.readouterr().out)['hookSpecificOutput']['additionalContext'] == 'related context'
    trigger.run(payload)
    assert capsys.readouterr().out == ''
    # 성공한 검색은 CLI 가 기록하므로 hook 은 중복 기록하지 않는다.
    assert not list((Path(__import__('os').environ['LIBRARY_ROOT']) / '.activity').glob('*.jsonl'))


def test_cli_failure_logged_by_hook(tmp_path, monkeypatch):
    monkeypatch.setenv('LIBRARY_KB_CMD', '/nonexistent/synthetic-kb')
    trigger.run(dict(session_id='fail', tool_name='Bash', tool_response={'stderr': 'Error: synthetic'}, tool_input={}))
    logs = list((Path(__import__('os').environ['LIBRARY_ROOT']) / '.activity').glob('*.jsonl'))
    record = json.loads(logs[0].read_text())
    assert record['source'] == 'trigger:error' and record['skipped_reason'] == 'unavailable_or_timeout'
    assert 'query' not in record


def test_search_passes_trigger_source(tmp_path, monkeypatch, capsys):
    stub = tmp_path / 'stub.py'
    stub.write_text('import sys\nprint(" ".join(sys.argv[1:]))')
    monkeypatch.setenv('LIBRARY_KB_CMD', f'python3 {stub}')
    trigger.run(dict(session_id='src', tool_name='Bash', tool_response={'stderr': 'Error: source check'}, tool_input={}))
    assert '--source trigger:error' in capsys.readouterr().out


def test_real_cli_logs_trigger_results_with_scores(tmp_path, monkeypatch, capsys):
    import sys
    monkeypatch.setenv('LIBRARY_ROOT', str(tmp_path))
    monkeypatch.setenv('LIBRARY_USAGE_LOG', 'aggregate')
    monkeypatch.setenv('LIBRARY_KB_CMD', f'{sys.executable} -m kb.cli')
    folder = tmp_path / 'library'
    folder.mkdir()
    (folder / 'zorblat.md').write_text('---\ntype: knowledge\ntitle: zorblat quuxinator crash fix\ndescription: zorblat quuxinator error\n---\nbody\n')
    for i in range(25):
        (folder / f'filler{i}.md').write_text(f'---\ntype: knowledge\ntitle: unrelated note {i}\ndescription: plain text {i}\n---\n')
    trigger.run(dict(session_id='real', tool_name='Bash', tool_response={'stderr': 'ZorblatError: zorblat quuxinator crashed'}, tool_input={}))
    capsys.readouterr()
    rows = [json.loads(x) for f in (tmp_path / '.activity').glob('search-*.jsonl') for x in f.read_text().splitlines()]
    assert len(rows) == 1 and rows[0]['source'] == 'trigger:error' and rows[0]['session_id'] == 'real'
    assert rows[0]['results'] and 'score' in rows[0]['results'][0]


@pytest.mark.parametrize('text,expected', [
    ('(eval):1: == not found', ''),
    ('✓ screen 일치율 97.6%\n(eval):1: == not found', ''),
    ('deploy.sh\napp/x.ait', ''),
    ("TypeError: 'bool' object is not iterable", ''),
    ("raise JSONDecodeError(\"Expecting value\", s, err.value) from None\njson.decoder.JSONDecodeError: Expecting value", ''),
    ("ModuleNotFoundError: No module named 'pkg_resources'", "ModuleNotFoundError: No module named 'pkg_resources'"),
    ('✗ unlock.png: 불투명', '✗ unlock.png: 불투명'),
    ('zsh: command not found: foo\nError: real failure', 'Error: real failure'),
    ('SyntaxError: unterminated string literal (detected at line 1)', ''),
    ('The above exception was the direct cause of the following exception:\nRuntimeError: boom', 'RuntimeError: boom'),
])
def test_core_error_skips_noise(text, expected):
    assert trigger.core_error(text) == expected


def test_duplicates(tmp_path, monkeypatch):
    from kb.duplicates import related
    monkeypatch.setenv('LIBRARY_ROOT', str(tmp_path))
    folder = tmp_path / 'library'
    folder.mkdir()
    for name in ('old', 'new'):
        (folder / f'{name}.md').write_text('---\ntype: knowledge\ntitle: Synthetic parser boundary regression\ndescription: structured input validation\n---\n')
    assert related(folder / 'new.md') == '중복/관련 가능: library/old.md (1.00)'


def test_new_document_edit_scope(tmp_path, monkeypatch):
    monkeypatch.setenv('LIBRARY_ROOT', str(tmp_path))
    payload = dict(session_id='s', tool_input={'file_path': str(tmp_path / 'library/new.md')}, tool_response={'type': 'update'})
    assert trigger.new_document(payload) is None
    payload['tool_response']['type'] = 'create'
    assert trigger.new_document(payload)
    payload['tool_response']['type'] = 'update'
    assert trigger.new_document(payload)
    payload['session_id'] = 'other'
    assert trigger.new_document(payload) is None


def test_failure_event_and_start(tmp_path, monkeypatch, capsys):
    stub = tmp_path / 'stub.py'
    stub.write_text('import sys\nprint(sys.argv[-1])')
    monkeypatch.setenv('LIBRARY_KB_CMD', f'python3 {stub}')
    trigger.run(dict(session_id='f', hook_event_name='PostToolUseFailure', tool_name='Bash', error='Exit code 1\nError: synthetic failure'))
    output = json.loads(capsys.readouterr().out)['hookSpecificOutput']
    assert output['hookEventName'] == 'PostToolUseFailure'
    assert output['additionalContext'] == 'Error: synthetic failure'
    trigger.run(dict(tool_name='Skill', tool_input={'skill': 'dev-bounce', 'args': 'synthetic task'}))
    assert 'synthetic task' in capsys.readouterr().out


def test_silent_failure(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv('LIBRARY_KB_CMD', '/nonexistent/synthetic-kb')
    trigger.run(dict(tool_name='Bash', tool_response={'exit_code': 1, 'stderr': 'Error: synthetic'}))
    assert capsys.readouterr().out == ''


def test_hook_timeout_is_silent(tmp_path, monkeypatch):
    import subprocess
    import time
    stub = tmp_path / 'sleep.py'
    stub.write_text('import time\ntime.sleep(30)')
    monkeypatch.setenv('LIBRARY_KB_CMD', f'python3 {stub}')
    started = time.monotonic()
    result = subprocess.run(['bash', str(Path(trigger.__file__).with_suffix('.sh'))],
                            input=json.dumps(dict(tool_name='Bash', tool_response={'stderr': 'Error: timeout fixture'})),
                            text=True, capture_output=True, timeout=7)
    assert result.returncode == 0 and result.stdout == '' and result.stderr == ''
    assert time.monotonic() - started < 6


def test_write_real_cli(tmp_path, monkeypatch, capsys):
    import sys
    monkeypatch.setenv('LIBRARY_ROOT', str(tmp_path))
    monkeypatch.setenv('LIBRARY_KB_CMD', f'{sys.executable} -m kb.cli')
    folder = tmp_path / 'library'
    folder.mkdir()
    for name in ('old', 'new'):
        (folder / f'{name}.md').write_text('---\ntype: knowledge\ntitle: Synthetic symmetric duplicate detection\ndescription: metadata similarity\n---\n')
    trigger.run(dict(session_id='write', tool_name='Write', tool_input={'file_path': str(folder / 'new.md')}, tool_response={'type': 'create'}))
    output = json.loads(capsys.readouterr().out)
    assert output['hookSpecificOutput']['additionalContext'] == '중복/관련 가능: library/old.md (1.00)'


def test_dotted_module_path_also_yields_last_segment():
    from kb.search import query_terms
    terms = query_terms("ModuleNotFoundError: No module named pkg.server.widgetlib")
    assert "pkg.server.widgetlib" in terms and "widgetlib" in terms


def test_trigger_gate_accepts_strong_or_rare_backed_and_rejects_common_overlap():
    from kb.relevance import select_trigger
    strong = {"path": "library/a.md", "title": "a", "score": .63, "injection_evidence": {"core_matches": 1}}
    backed = {"path": "library/b.md", "title": "b", "score": .35, "injection_evidence": {"core_matches": 2}}
    common = {"path": "library/c.md", "title": "c", "score": .42, "injection_evidence": {"core_matches": 1}}
    weak = {"path": "library/d.md", "title": "d", "score": .2, "injection_evidence": {"core_matches": 3}}
    kept, reason = select_trigger([strong, backed, common, weak], 1500)
    assert [r["path"] for r in kept] == ["library/a.md", "library/b.md"] and reason is None
    assert select_trigger([common, weak], 1500) == ([], "weak_evidence")
    assert select_trigger([], 1500) == ([], "no_results")


def test_trigger_gate_rejects_strong_score_without_rare_term():
    from kb.relevance import select_trigger
    row = {"path": "library/a.md", "title": "a", "score": .9, "injection_evidence": {"core_matches": 0}}
    assert select_trigger([row], 1500) == ([], "weak_evidence")


def test_core_dependencies_cover_files_backend_imports():
    # 파일 백엔드(중복 검사 포함)는 postgres extra 없이 동작해야 한다.
    import tomllib
    meta = tomllib.loads((Path(__file__).resolve().parents[1] / 'pyproject.toml').read_text())
    core = ' '.join(meta['project']['dependencies']).lower()
    assert 'pyyaml' in core


def test_server_import_does_not_load_mcp():
    import subprocess
    import sys
    code = 'import sys, server; assert "mcp" not in sys.modules, "mcp loaded"; print(len(server.mcp.tools))'
    out = subprocess.run([sys.executable, '-c', code], cwd=Path(__file__).resolve().parents[1],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    assert int(out.stdout) >= 9


def test_corpus_cache_matches_uncached_scores(tmp_path, monkeypatch):
    from kb import relevance
    monkeypatch.setenv('LIBRARY_CACHE_DIR', str(tmp_path / 'cache'))
    docs = [{'path': f'library/d{i}.md', 'title': f'alpha beta {i}', 'description': 'gamma delta',
             'tags': ['x'], 'body': f'body text {i} epsilon'} for i in range(30)]
    first = relevance.Corpus(docs).scores('alpha gamma epsilon')
    assert list((tmp_path / 'cache').glob('corpus-*.json'))
    second = relevance.Corpus(docs).scores('alpha gamma epsilon')
    monkeypatch.setattr(relevance, '_analyze_cached', lambda d: [relevance._analyze(x) for x in d])
    third = relevance.Corpus(docs).scores('alpha gamma epsilon')
    assert first == second == third
    docs[0]['title'] = 'changed zeta'
    monkeypatch.undo()
    monkeypatch.setenv('LIBRARY_CACHE_DIR', str(tmp_path / 'cache'))
    assert relevance.Corpus(docs).scores('zeta')[0] > 0


def test_duplicates_skip_broken_frontmatter(tmp_path, monkeypatch):
    from kb.duplicates import related
    monkeypatch.setenv('LIBRARY_ROOT', str(tmp_path))
    folder = tmp_path / 'library'
    folder.mkdir()
    (folder / 'broken.md').write_text('---\ntype: x\ndescription: "quoted" then more\n---\n')
    for name in ('old', 'new'):
        (folder / f'{name}.md').write_text('---\ntype: knowledge\ntitle: Synthetic parser boundary regression\ndescription: structured input validation\n---\n')
    assert related(folder / 'new.md') == '중복/관련 가능: library/old.md (1.00)'


def test_duplicates_skip_unrelated_and_cap_results(tmp_path, monkeypatch):
    from kb.duplicates import related
    monkeypatch.setenv('LIBRARY_ROOT', str(tmp_path))
    folder = tmp_path / 'library'
    folder.mkdir()
    for i in range(5):
        (folder / f'same{i}.md').write_text('---\ntype: k\ntitle: Synthetic parser boundary regression\n---\n')
    for i in range(30):
        (folder / f'other{i}.md').write_text(f'---\ntype: k\ntitle: unrelated topic{i} cache warmup\n---\n')
    (folder / 'new.md').write_text('---\ntype: k\ntitle: Synthetic parser boundary regression\n---\n')
    lines = related(folder / 'new.md').splitlines()
    assert len(lines) == 3 and all('library/same' in x for x in lines)


def test_korean_substring_matches_equal_naive_scan():
    from kb import relevance
    docs = [{'title': t, 'path': f'library/{i}.md'} for i, t in
            enumerate(['개인정보 로컬 파일', '정보보호 규칙', '공모전 개인정보는 비공개', 'ascii only', '보호막'])]
    corpus = relevance.Corpus(docs)
    for term in ['정보', '개인정보', '보호', '공모', '없는말']:
        naive = {}
        for token, postings in corpus.postings.items():
            if term in token:
                for i, w in postings.items():
                    naive[i] = max(naive.get(i, 0), w)
        assert corpus.matches(term) == naive


def test_result_rows_parses_search_and_duplicate_output():
    context = ('library/a/x.md · 제목 · 설명\n'
               '중복/관련 가능: library/b/y.md (0.42)\n중복/관련 가능: library/b/y.md (0.42)')
    assert trigger.result_rows(context) == [{'path': 'library/a/x.md'}, {'path': 'library/b/y.md', 'score': 0.42}]


def test_library_search_includes_global_and_current_repo_decisions(tmp_path, monkeypatch):
    import server
    root = tmp_path / 'root'
    (root / 'library').mkdir(parents=True)
    for repo, title in [('_global', '개인정보는 로컬 파일에서만 읽는다'), ('mine', '배포는 태그로만 한다'),
                        ('other', '개인정보 연락처 다른 레포 규칙')]:
        folder = root / 'decisions' / repo / 'process'
        folder.mkdir(parents=True)
        (folder / 'd.md').write_text(f'---\ntype: Decision\nstatus: stable\n---\n\n# {title}\n\n{title} 본문 요약\n')
    monkeypatch.setattr(server, 'LIBRARY_ROOT', root)
    monkeypatch.setattr(server, '_index_cache', None)
    monkeypatch.setattr(server, '_current_repo', lambda: 'mine')
    result = server.library_search('개인정보 로컬 파일 위치')
    assert 'decisions/_global/process/d.md' in result and '개인정보는 로컬 파일에서만 읽는다 본문 요약' in result
    assert 'decisions/other/' not in result
    assert 'decisions/mine/process/d.md' in server.library_search('배포 태그')
    assert '결정사항 없음' in server.library_search('zzzz')


def test_promote_pending_installs_in_background_and_swaps_spec(tmp_path, monkeypatch):
    import time as _time
    hooks = tmp_path / 'hooks'
    hooks.mkdir()
    (hooks / '.learnings-kb-spec').write_text('claude-library-mcp==0.0.1\n')
    (hooks / '.learnings-kb-pending').write_text('claude-library-mcp==0.0.2\n')
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    uvx = bin_dir / 'uvx'
    uvx.write_text('#!/bin/sh\necho "$@" >> "%s"\n[ -e "%s" ] && exit 1\nexit 0\n' % (tmp_path / 'uvx.log', tmp_path / 'fail'))
    uvx.chmod(0o755)
    monkeypatch.setenv('PATH', f'{bin_dir}:/usr/bin:/bin')
    (tmp_path / 'fail').touch()
    trigger.promote_pending(hooks)
    _time.sleep(.5)
    assert (hooks / '.learnings-kb-spec').read_text().strip() == 'claude-library-mcp==0.0.1'
    assert (hooks / '.learnings-kb-pending').exists()
    (tmp_path / 'fail').unlink()
    trigger.promote_pending(hooks)  # 10분 안에는 다시 시도하지 않는다
    _time.sleep(.5)
    assert (tmp_path / 'uvx.log').read_text().count('--from') == 1
    (hooks / '.learnings-kb-pending.tried').unlink()
    trigger.promote_pending(hooks)
    for _ in range(50):
        if not (hooks / '.learnings-kb-pending').exists():
            break
        _time.sleep(.1)
    assert (hooks / '.learnings-kb-spec').read_text().strip() == 'claude-library-mcp==0.0.2'
    assert '--refresh-package claude-library-mcp' in (tmp_path / 'uvx.log').read_text()
