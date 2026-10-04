#!/usr/bin/env python3
"""정책 변경 이력 검사와 update.sh의 append-only 이력 기록."""
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

HOME = Path.home()
LIB = HOME / 'claude-library'
CLAUDE = HOME / '.claude'
SIDECARS = LIB / 'decisions/_global/changelog'
ENTRY = re.compile(r'^- \d{4}-\d{2}-\d{2} · (?:human:kangraemin|claude-code/[^ ·]+|codex|process:[^ ·]+) · .+ · 이유: .+ · 근거: .+$')


def read(path):
    return path.read_text() if path.is_file() else ''


def markdown_lines(text):
    # GUIDE의 코드 예시에 들어 있는 제목·항목은 실제 이력이 아니다.
    fence = None
    for i, line in enumerate(text.splitlines(keepends=True)):
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})', line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence is None:
            yield i, line


def history(text):
    lines = text.splitlines(keepends=True)
    for i, line in markdown_lines(text):
        if line.rstrip() == '## 변경 이력':
            return ''.join(lines[:i]), ''.join(lines[i:])
    return text, ''


def count(path):
    total = 0
    for i, line in markdown_lines(history(read(path))[1]):
        if i and re.match(r'^#{1,2}\s', line):
            break
        total += bool(ENTRY.match(line.rstrip('\r\n')))
    return total


def location(path):
    if path == CLAUDE / 'CLAUDE.md':
        return SIDECARS / 'claude-md.md'
    if path.parent == CLAUDE / 'rules':
        return SIDECARS / ('rules-' + path.name)
    return path


def policies():
    paths = [CLAUDE / 'CLAUDE.md', LIB / 'GUIDE.md', LIB / 'TAXONOMY.md']
    paths += list((CLAUDE / 'rules').glob('*.md'))
    paths += [p for p in (LIB / 'decisions').rglob('*.md')
              if p.name != 'index.md' and SIDECARS not in p.parents]
    return {str(p): p for p in paths if p.is_file()}


def record(path):
    raw = path.read_bytes() if path.is_file() else b''
    return {'sha256': hashlib.sha256(raw).hexdigest(),
            'content': raw.decode('utf-8'), 'count': count(location(path))}


def toc_only(before, after):
    old, new = before.splitlines(keepends=True), after.splitlines(keepends=True)

    def allowed(lines):
        result, inside = set(), False
        for i, line in enumerate(lines):
            if line.rstrip() == '### 목차':
                inside = True
                continue
            if re.match(r'^#{1,3}\s|^\s*<!--|^# ---', line):
                inside = False
            if inside:
                result.add(i)
        return result

    a, b = allowed(old), allowed(new)
    for tag, i, j, k, l in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if tag != 'equal' and (any(n not in a for n in range(i, j)) or
                               any(n not in b for n in range(k, l))):
            return False
    return True


def append(path, version, what):
    dest = location(path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    text = read(dest)
    if not text and dest != path:
        text = '---\ntype: Changelog\n---\n\n# 정책 변경 이력\n'
    if not history(text)[1]:
        text = text.rstrip() + '\n\n## 변경 이력\n'
    if not text.endswith('\n'):
        text += '\n'
    day = datetime.date.today().isoformat()
    sha = version.split('@', 1)[-1]
    evidence = f'commit:{sha}' if re.fullmatch(r'[0-9a-f]{7,40}', sha) else f'session:{day}/update.sh'
    text += f'- {day} · process:update.sh · {what} · 이유: learnings-for-claude {version} 템플릿 갱신 · 근거: {evidence}\n'
    dest.write_text(text)


def update_doc(src, dst, version):
    if not src.is_file():
        return
    before, template = read(dst), read(src)
    body, log = history(before)
    incoming, _ = history(template)
    if dst.is_file() and body.rstrip() == incoming.rstrip():
        return
    orig = Path(str(dst) + '.orig')
    if dst.is_file() and (not orig.is_file() or history(read(orig))[0].rstrip() != body.rstrip()):
        Path(str(dst) + '.new').write_text(template)
        print(f'  {dst.name} 수정본 유지 — .new 저장')
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_file():
        Path(str(dst) + '.bak').write_text(before)
    dst.write_text(incoming.rstrip() + '\n\n' + (log or history(template)[1]))
    append(dst, version, f'{dst.name} 템플릿 갱신')
    orig.write_text(read(dst))
    print(f'  {dst.name} 갱신 및 변경 이력 추가')


def save(path, state):
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(state, stream, ensure_ascii=False)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    if len(sys.argv) > 1:
        if sys.argv[1] == 'update-doc':
            update_doc(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
        elif sys.argv[1] == 'append':
            append(Path(sys.argv[2]), sys.argv[3], sys.argv[4])
        return
    if os.environ.get('POLICY_CHANGELOG_ENFORCE') == '0':
        return
    data = json.load(sys.stdin)
    sid = data.get('session_id', '')
    if not isinstance(sid, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', sid):
        return
    event = data.get('hook_event_name')
    if event not in ('SessionStart', 'Stop'):
        return
    folder = CLAUDE / 'hooks/.policy-snapshots'
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    for old in folder.glob('*.json'):
        if old.stat().st_mtime < time.time() - 7 * 86400:
            old.unlink()
    snapshot = folder / (sid + '.json')
    if event == 'SessionStart':
        # resume/compact도 SessionStart를 발생시킨다. 미기록 변경을 덮지 않는다.
        if not snapshot.exists():
            save(snapshot, {'files': {key: record(p) for key, p in policies().items()},
                            'blocks': 0, 'seen_counts': {}})
        return
    if not snapshot.exists():
        return
    state = json.loads(snapshot.read_text())
    current = policies()
    missing, counts = [], {}
    for key in sorted(set(state['files']) | set(current)):
        path = Path(key)
        now = record(path)
        prev = state['files'].get(key, {'sha256': '', 'content': '', 'count': 0})
        counts[key] = now['count']
        if now['sha256'] == prev['sha256']:
            continue
        if path == CLAUDE / 'CLAUDE.md' and toc_only(prev['content'], now['content']):
            continue
        if now['count'] <= prev['count']:
            missing.append(f'{path} → 이력 위치: {location(path)}')
    seen = state.get('seen_counts', {})
    if any(n > seen.get(k, state['files'].get(k, {}).get('count', 0)) for k, n in counts.items()):
        state['blocks'] = 0
    state['seen_counts'] = counts
    if missing:
        state['blocks'] += 1
        reason = '정책 변경 이력이 필요합니다:\n' + '\n'.join(missing)
        reason += '\n## 변경 이력 아래 추가 예시: - ' + datetime.date.today().isoformat() + ' · codex · 규칙 수정 · 이유: 사후 기록 — 이유 미확인 · 근거: session:' + sid
        if state['blocks'] < 3:
            print(json.dumps({'decision': 'block', 'reason': reason}, ensure_ascii=False))
        else:
            print(json.dumps({'systemMessage': '경고 (연속 차단 3회 이상): ' + reason}, ensure_ascii=False))
    else:
        state['blocks'] = 0
        # 이력으로 승인된 변경 이후의 추가 변경도 다시 검사한다.
        state['files'] = {key: record(p) for key, p in current.items()}
    save(snapshot, state)


if __name__ == '__main__':
    main()
