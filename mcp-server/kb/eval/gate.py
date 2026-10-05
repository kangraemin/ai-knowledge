"""동결한 게이트를 분할별 평가한다. 원문과 경로는 출력하지 않는다."""

import argparse
import json
import os
from pathlib import Path

from kb.relevance import select
from kb.eval.stress import selected as legacy_selected


def measure(data, rankings, legacy=False):
    counts = dict(n=len(data), positive_n=0, negative_n=0, injected=0,
                  correct=0, positive_injected=0, negative_injected=0)
    for item in data:
        query = item.get('prompt', item.get('q', ''))
        expected = item.get('expected_paths', item.get('expected', []))
        relevant = item.get('relevant', bool(expected))
        counts['positive_n' if relevant else 'negative_n'] += 1
        rows = rankings[query]
        if len(query.strip()) < 8 or query.lstrip().startswith('/'):
            kept = []
        elif legacy:
            kept = legacy_selected(rows, .085, query)
        else:
            kept, _ = select(rows, 'files', 1500)
        counts['injected'] += bool(kept)
        counts['positive_injected' if relevant else 'negative_injected'] += bool(kept)
        counts['correct'] += bool(relevant and any(r['path'] in expected for r in kept))
    for name, num, den in (('precision', 'correct', 'injected'),
                           ('recall', 'positive_injected', 'positive_n'),
                           ('correct_recall', 'correct', 'positive_n'),
                           ('negative_rate', 'negative_injected', 'negative_n')):
        counts[name] = counts[num] / counts[den] if counts[den] else None
    return counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--split', choices=('dev', 'test'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    os.environ['LIBRARY_LOG'] = '0'
    # 재평가는 배포 기본값으로 고정한다. 운영 환경의 덮어쓰기를 섞지 않는다.
    os.environ.pop('LIBRARY_AUTOINJECT_MIN_SCORE', None)
    import server
    data = [r for r in map(json.loads, args.input.read_text().splitlines())
            if r['split'] == args.split and r.get('relevant', True) is not None]
    rankings = {r.get('prompt', r.get('q')): server._search(r.get('prompt', r.get('q')))
                for r in data}
    report = {'split': args.split, 'corpus_n': len(server._build_index()),
              'before': measure(data, rankings, legacy=True),
              'after': measure(data, rankings)}
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2)
    print(json.dumps(report))


if __name__ == '__main__':
    main()
