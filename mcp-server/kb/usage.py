"""턴 단위 사용 흔적과 오프라인 관련도에 기반한 휴리스틱 관측."""

import json
import os
import re
import signal
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import activity
from .relevance import (minimum, normalized, Corpus, duplicate_similarity,
                        DEFAULT_DUPLICATE_SCORE, citation_signals)
from .search import query_terms


def stamp(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return result.replace(tzinfo=timezone.utc) if result.tzinfo is None else result


def records(pattern, root):
    for path in sorted((root / '.activity').glob(pattern)):
        try:
            with path.open() as stream:
                for line in stream:
                    try:
                        row = json.loads(line)
                        if isinstance(row, dict):
                            yield row
                    except (ValueError, TypeError):
                        continue
        except OSError:
            continue


def append_turn(row, root=None):
    if os.environ.get('LIBRARY_LOG') == '0' or activity.mode() == 'off':
        return
    try:
        import fcntl
        folder = (root or activity.root()) / '.activity'
        folder.mkdir(parents=True, exist_ok=True)
        # 월 경계를 포함해 같은 사람 프롬프트는 한 번만 기록한다.
        with (folder / '.usage.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if row.get('turn_id') and any(
                old.get('session_id') == row.get('session_id') and old.get('turn_id') == row['turn_id']
                for old in records('usage-*.jsonl', root or activity.root())
            ):
                return False
            row.setdefault('version', activity.runtime_version())
            with (folder / f'usage-{datetime.now(timezone.utc):%Y-%m}.jsonl').open('a') as stream:
                stream.write(json.dumps(row, ensure_ascii=False, default=str) + '\n')
            return True
    except OSError:
        pass


def inventory(root):
    # 전역 서버 캐시를 건드리지 않고 현재 파일 스냅샷으로 평가한다.
    from server import _parse_frontmatter, _strip_frontmatter
    docs = []
    for path in sorted((root / 'library').rglob('*.md')):
        if path.name in ('index.md', 'log.md', '_template.md') or not path.resolve().is_relative_to(root.resolve()):
            continue
        text = path.read_text()
        meta = _parse_frontmatter(text)
        if meta.get('status') == 'deprecated':
            continue
        docs.append({**meta, 'path': path.relative_to(root).as_posix(), 'body': _strip_frontmatter(text)})
    return docs


def offline(query, docs):
    corpus = Corpus(docs)
    rows = [{**doc, 'score': score, 'injection_evidence': evidence}
            for doc, score, evidence in zip(docs, corpus.scores(query), corpus.injection_evidence(query))]
    return sorted((r for r in rows if r['score'] > 0), key=lambda r: (-r['score'], r['path']))


def blocks(row):
    message = row.get('message', row)
    if not isinstance(message, dict):
        return []
    content = message.get('content', [])
    if isinstance(content, str):
        return [{'type': 'text', 'text': content}]
    return [x for x in content if isinstance(x, dict)] if isinstance(content, list) else []


def text_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(str(b.get('text', '')) for b in content if isinstance(b, dict) and b.get('type') == 'text')
    return ''


def human_prompt(row):
    role = row.get('type') or row.get('role') or row.get('message', {}).get('role')
    if role != 'user':
        return False
    # 명시된 출처가 구형 휴리스틱보다 우선한다.
    if 'origin' in row:
        origin = row['origin']
        return isinstance(origin, dict) and origin.get('kind') == 'human'
    content = blocks(row)
    text = text_content(content).lstrip()
    return (not row.get('isMeta') and 'toolUseResult' not in row
            and row.get('turnOrigin', 'human') == 'human'
            and row.get('promptSource') != 'system'
            and any(b.get('type') in ('text', 'image') for b in content)
            and not any(b.get('type') == 'tool_result' for b in content)
            and '<task-notification>' not in text
            and not text.startswith(('<system-reminder>', 'Stop hook feedback:', '[Request interrupted by user')))


def relative(value, root, cwd=''):
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path(cwd or root) / path
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return None


def analyze(transcript, session, cwd, root):
    rows = []
    with Path(transcript).expanduser().open() as stream:
        for line in stream:
            if line.strip():
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError('invalid transcript row')
                rows.append(row)
    starts = [i for i, row in enumerate(rows) if human_prompt(row)]
    if not starts:
        raise ValueError('no user prompt')
    turn = rows[starts[-1]:]
    prompt = '\n'.join(str(b.get('text', '')) for b in blocks(turn[0]) if b.get('type') == 'text')
    start = stamp(turn[0]['timestamp']) if turn[0].get('timestamp') else None
    docs = inventory(root)
    threshold = minimum('files')
    corpus = Corpus(docs)
    calls = {'library_search': [], 'library_read': [], 'decision_*': 0, 'library_write': [], 'library_edit': []}
    tools, results, assistant = {}, {}, []
    for row in turn[1:]:
        role = row.get('type') or row.get('role') or row.get('message', {}).get('role')
        for block in blocks(row):
            if block.get('type') == 'tool_use' and role == 'assistant':
                tools[block.get('id', str(len(tools)))] = block
            elif block.get('type') == 'tool_result':
                results[block.get('tool_use_id')] = block
            elif block.get('type') == 'text' and role == 'assistant':
                assistant.append(str(block.get('text', '')))
    answer = '\n'.join(assistant)
    search_rows, unknown, writes = [], 0, []
    for ident, tool in tools.items():
        name, args = tool.get('name', ''), tool.get('input', {})
        if not isinstance(args, dict):
            continue
        short = name.removeprefix('mcp__claude-library__') if name.startswith('mcp__claude-library__') else ''
        result = results.get(ident)
        if short == 'library_search':
            query = str(args.get('query', ''))
            calls['library_search'].append(query)
            if result is None or result.get('is_error'):
                unknown += 1
                continue
            raw = text_content(result.get('content'))
            # 반환된 경로만 노출로 센다. 재검색 결과를 실제 검색 결과로 둔갑시키지 않는다.
            found = [doc for doc in docs if doc['path'] in raw]
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, list):
                    found = [r for r in parsed if isinstance(r, dict) and isinstance(r.get('path'), str)]
            except ValueError:
                if not found and not re.search(r'항목 없음|결과 없음|no (?:results|matches)|^\s*$', raw, re.I):
                    unknown += 1
            search_rows.extend({**r, 'score': float(r.get('score', normalized(r, query_terms(query), corpus)))} for r in found)
        elif short == 'library_read':
            calls['library_read'].append(str(args.get('path', '')))
        elif short.startswith('decision_'):
            calls['decision_*'] += 1
        elif name in ('Write', 'Edit') and isinstance(args.get('file_path'), str):
            path = relative(args['file_path'], root, cwd)
            if path:
                calls['library_' + name.lower()].append(path)
                if name == 'Write' and result and not result.get('is_error'):
                    writes.append((path, str(args.get('content', '')), text_content(result.get('content'))))
    injections = []
    for event in records('search-*.jsonl', root):
        if not session or event.get('session_id') != session or event.get('action') != 'inject':
            continue
        # 주입은 사용자 메시지 기록 직전에 실행될 수도 있어 질의도 대조한다.
        if event.get('query') != prompt and event.get('query_sha256') != activity.digest(prompt):
            continue
        try:
            if start and stamp(event['ts']) < start - timedelta(seconds=30):
                continue
            injections.append(event)
        except (KeyError, ValueError, TypeError):
            continue
    injection = max(injections, key=lambda e: e['ts']) if injections else {}
    injected = bool(injection.get('injected'))
    injected_paths = [r['path'] for r in injection.get('results', []) if isinstance(r, dict) and r.get('path')] if injected else []
    exposed = sorted(set(injected_paths + [r['path'] for r in search_rows]))
    candidates = set(exposed + calls['library_read'])
    by_path = {d['path']: d for d in docs}
    cited_paths, cited, cited_evidence = [], [], {}
    for path in sorted(candidates):
        signals = citation_signals(by_path.get(path, {'path': path}), answer, corpus)
        if signals:
            cited_paths.append(path)
            cited_evidence[path] = signals
            cited.extend(s['value'] for s in signals if 'value' in s)
    if '📚 library 참조' in answer:
        cited.append('📚 library 참조')
    # 이번 턴에 쓴 문서는 기회·중복의 기존 지식 후보에서 제외한다.
    existing = [d for d in docs if d['path'] not in calls['library_write']]
    opportunity = offline(prompt, existing)
    top_score = max((r['score'] for r in opportunity), default=0)
    from .relevance import select
    eligible = bool(select(opportunity[:7], 'files', 1500)[0]) if len(prompt.strip()) >= 8 and not prompt.lstrip().startswith('/') else False
    duplicates = []
    from server import _parse_frontmatter
    for path, content, result_text in writes:
        # 생성 증거가 없는 Write는 덮어쓰기일 수 있으므로 중복 판정을 보류한다.
        if not re.search(r'created|new file|새 파일|생성', result_text, re.I):
            continue
        meta = _parse_frontmatter(content)
        query = ' '.join(str(meta.get(k, '')) for k in ('title', 'description')).strip()
        if query:
            hits = sorted(({**d, 'score': duplicate_similarity(meta, d, corpus)} for d in existing),
                          key=lambda d: (-d['score'], d['path']))
            hits = [d for d in hits if d['score'] >= DEFAULT_DUPLICATE_SCORE]
            if hits:
                duplicates.append({'path': path, 'matches': [{'path': r['path'], 'score': r['score']} for r in hits[:7]]})
    contact = injected or bool(calls['library_search'] or calls['library_read'])
    labels = []
    if cited_paths:
        labels.append('hit_used')
    if exposed and not calls['library_read'] and not cited_paths:
        labels.append('hit_unused')
    if eligible and not contact:
        labels.append('missed')
    if calls['library_search'] and not unknown and not any(r['score'] >= threshold for r in search_rows):
        labels.append('searched_empty')
    if duplicates:
        labels.append('duplicate_write')
    if not eligible and not contact:
        labels.append('no_need')
    return {'prompt': prompt, 'prompt_len': len(prompt), 'turn_id': turn[0].get('uuid'),
            'autoinject': {'injected': injected, 'paths': injected_paths, 'skipped_reason': injection.get('skipped_reason', None if injection else 'no_event')},
            'calls': calls, 'cited': sorted(set(cited)), 'cited_evidence': cited_evidence, 'cited_paths': cited_paths, 'exposed_paths': exposed,
            'search_paths': sorted({r['path'] for r in search_rows}), 'search_unknown': unknown,
            'opportunity': {'eligible': eligible, 'top_score': top_score, 'top_paths': [r['path'] for r in opportunity[:7]], 'threshold': threshold},
            'duplicates': duplicates, 'labels': labels}


def log_usage(transcript, session='', cwd=''):
    if os.environ.get('LIBRARY_LOG') == '0' or activity.mode() == 'off':
        return None
    started = time.monotonic()
    row = {'ts': datetime.now(timezone.utc).isoformat(), 'session_id': session, 'cwd': cwd,
           'repo': Path(cwd).name, 'prompt': '', 'prompt_len': 0}
    def timeout(*_):
        raise TimeoutError('usage_timeout')
    previous = signal.signal(signal.SIGALRM, timeout)
    signal.setitimer(signal.ITIMER_REAL, 18)
    try:
        row.update(analyze(transcript, session, cwd, activity.root()))
    except Exception as exc:
        row.update(labels=['parse_error'], error=type(exc).__name__)
    activity.redact(row, 'prompt')
    if activity.mode() != 'full' and 'calls' in row:
        row['calls']['library_search'] = [activity.digest(q) for q in row['calls']['library_search']]
    row['latency_ms'] = (time.monotonic() - started) * 1000
    try:
        fresh = append_turn(row)
        if fresh and os.environ.get('LIBRARY_BACKEND') == 'postgres' and time.monotonic() - started < 18:
            try:
                from .db import connect
                from psycopg.types.json import Jsonb
                with connect() as conn:
                    conn.execute("SET LOCAL statement_timeout = '1000ms'")
                    conn.execute('INSERT INTO kb.events(user_id,action,payload) VALUES(kb.current_user_id(),%s,%s)', ('turn', Jsonb(row)))
            except Exception:
                pass
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)

    return row



def by_version(rows):
    """설치 버전·판정 기준값별로 턴 라벨을 나눈다. 버전 표식이 없는 옛 기록은 'unversioned'."""
    groups = {}
    for r in rows:
        v = r.get('version') or {}
        key = f"{v.get('install', 'unversioned')} gate={v.get('gate', '?')}" if v else 'unversioned'
        g = groups.setdefault(key, {'turns': 0, 'labels': Counter()})
        g['turns'] += 1
        g['labels'].update(r.get('labels', []))
    return {k: {'turns': g['turns'], 'labels': dict(g['labels'])} for k, g in groups.items()}

def report(days=30, root=None):
    if days <= 0:
        raise ValueError('days는 양수여야 합니다')
    root = root or activity.root()
    now = datetime.now(timezone.utc)
    rows = []
    for row in records('usage-*.jsonl', root):
        try:
            if now - timedelta(days=days) <= stamp(row['ts']) <= now:
                rows.append(row)
        except (KeyError, TypeError, ValueError):
            continue
    valid = [r for r in rows if 'parse_error' not in r.get('labels', [])]
    counts = Counter(label for r in valid for label in r.get('labels', []))
    docs = {d['path'] for d in inventory(root)}
    exposed, read, cited, categories, repos = Counter(), Counter(), Counter(), Counter(), Counter()
    daily = defaultdict(Counter)
    contact = injected = inject_used = searched = search_success = opportunities = 0
    duplicates, missed, latencies = [], [], []
    for r in valid:
        calls, auto = r.get('calls', {}), r.get('autoinject', {})
        searching = bool(calls.get('library_search'))
        touching = bool(auto.get('injected') or searching or calls.get('library_read'))
        contact += touching
        injected += bool(auto.get('injected'))
        inject_used += bool(auto.get('injected') and
                            set(auto.get('paths', [])) & set(r.get('cited_paths', [])))
        searched += searching
        search_success += bool(searching and (set(r.get('search_paths', [])) & set(calls.get('library_read', []) + r.get('cited_paths', []))))
        opp = r.get('opportunity', {})
        opportunities += opp.get('eligible', opp.get('top_score', 0) >= opp.get('threshold', minimum('files')))
        exposed.update(set(r.get('exposed_paths', [])))
        read.update(set(calls.get('library_read', [])))
        cited.update(set(r.get('cited_paths', [])))
        categories.update(set('/'.join(Path(p).parts[1:-1][:2]) for p in r.get('cited_paths', [])))
        repos[r.get('repo', '')] += 1
        day = r['ts'][:10]
        daily[day].update(turns=1, contacted=int(touching), missed=int('missed' in r.get('labels', [])), hit_used=int('hit_used' in r.get('labels', [])))
        duplicates.extend({'ts': r['ts'], 'repo': r.get('repo'), **d} for d in r.get('duplicates', []))
        if 'missed' in r.get('labels', []):
            missed.append({'ts': r['ts'], 'repo': r.get('repo'), **({'prompt': r['prompt'][:80]} if 'prompt' in r and activity.mode() == 'full' else {'prompt_sha256': r.get('prompt_sha256', activity.digest(r.get('prompt', ''))), 'prompt_len': r.get('prompt_len', 0)}), 'opportunity': opp})
        if isinstance(r.get('latency_ms'), (float, int)):
            latencies.append(r['latency_ms'])
    def ratio(n, d):
        return {'numerator': n, 'denominator': d, 'rate': n / d if d else None}
    dead = docs - set(exposed) - set(read) - set(cited)
    return {'days': days, 'turns': len(valid), 'parse_errors': len(rows) - len(valid),
            'contact_rate': ratio(contact, len(valid)), 'injection_citation_rate': ratio(inject_used, injected),
            'injection_precision': ratio(inject_used, injected),
            'injection_precision_deprecated': '인용률 별칭. 관련성 정밀도는 수작업 라벨로 별도 평가한다.',
            'search_success_rate': ratio(search_success, searched), 'missed_rate': ratio(counts['missed'], opportunities),
            'searched_empty_rate': ratio(counts['searched_empty'], searched), 'labels': dict(counts),
            'duplicate_write_count': len(duplicates), 'duplicate_writes': duplicates,
            'documents': {k: [{'path': p, 'count': n} for p, n in c.most_common(10)] for k, c in [('exposed', exposed), ('read', read), ('cited', cited)]},
            'dead_knowledge': {**ratio(len(dead), len(docs)), 'paths': sorted(dead)},
            'category_hits': dict(categories), 'repos': dict(repos), 'by_version': by_version(valid), 'daily': {k: dict(v) for k, v in sorted(daily.items())},
            'search_latency_ms': activity.stats(days, root)['latency_ms'],
            'latency_ms': {'count': len(latencies), 'p50': activity.percentile(latencies, .5), 'p95': activity.percentile(latencies, .95)},
            'recent_missed': sorted(missed, key=lambda r: r['ts'], reverse=True)[:10]}


def render_report(result, fmt):
    if fmt == 'json':
        return json.dumps(result, ensure_ascii=False, indent=2)
    # 모든 지표를 텍스트/마크다운에서도 누락 없이 보존한다.
    lines = ['# Library usage report' if fmt == 'md' else 'Library usage report']
    for key, value in result.items():
        lines.append(f'\n{key}:\n' + json.dumps(value, ensure_ascii=False, indent=2))
    return '\n'.join(lines)
