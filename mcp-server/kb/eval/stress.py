"""비공개 입력을 읽는 장문·실사용·중복 평가. 출력에는 집계만 포함한다."""

import argparse
import json
from pathlib import Path

from kb.relevance import Corpus, duplicate_similarity, citation_signals
from kb.search import format_results


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def selected(rows, threshold, query):
    if len(query.strip()) < 8 or query.lstrip().startswith('/'):
        return []
    kept = []
    for row in rows:
        if row['score'] < threshold:
            continue
        if len(format_results(kept + [row], 1500).splitlines()) != len(kept) + 1:
            break
        kept.append(row)
    return kept


def measure(data, rankings, threshold):
    valid = [q for q in data if q.get('relevant', True) is not None]
    positives = sum(bool(q.get('expected')) for q in valid)
    injected = correct = suppressed = r5 = 0
    for q in valid:
        rows = rankings[q['q']]
        kept = selected(rows, threshold, q['q'])
        injected += bool(kept)
        correct += any(r['path'] in q.get('expected', []) for r in kept)
        suppressed += not kept and not q.get('expected')
        r5 += any(r['path'] in q.get('expected', []) for r in rows[:5])
    negative = len(valid) - positives
    return {'n': len(valid), 'excluded': len(data) - len(valid), 'positive_n': positives,
            'injected': injected, 'correct': correct, 'R@5': r5,
            'precision': correct / injected if injected else None,
            'recall': correct / positives if positives else None,
            'negative_n': negative, 'negative_suppressed': suppressed,
            'suppression': suppressed / negative if negative else None}


def duplicate_metrics(pairs, scores, threshold):
    positive = sum(p['positive'] for p in pairs)
    tp = sum(p['positive'] and s >= threshold for p, s in zip(pairs, scores))
    fp = sum(not p['positive'] and s >= threshold for p, s in zip(pairs, scores))
    return {'positive_n': positive, 'negative_n': len(pairs) - positive, 'tp': tp, 'fp': fp,
            'recall': tp / positive if positive else None}


def main():
    parser = argparse.ArgumentParser()
    for name in ('queries', 'long', 'real', 'pairs', 'thresholds'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--negative', type=Path, default=Path(__file__).with_name('negatives.jsonl'))
    parser.add_argument('--audit', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--split', choices=('dev', 'test'), required=True)
    parser.add_argument('--calibrate', action='store_true')
    args = parser.parse_args()
    if args.calibrate and args.split != 'dev':
        parser.error('임계값 선정은 dev에서만 가능')
    import os
    os.environ['LIBRARY_LOG'] = '0'
    import server
    groups = {name: [q for q in read_rows(getattr(args, name)) if q['split'] == args.split]
              for name in ('queries', 'long', 'real', 'negative')}
    pairs = [p for p in read_rows(args.pairs) if p['split'] == args.split]
    # test 질의는 calibration 중 검색조차 하지 않는다.
    rankings = {q['q']: server._search(q['q']) for data in groups.values() for q in data}
    docs = server._build_index()
    corpus = Corpus(docs)
    by = {d['path']: d for d in docs}
    scores = [duplicate_similarity(by[p['a']], by[p['b']], corpus) for p in pairs]
    if args.calibrate:
        candidates = []
        for t in (i / 1000 for i in range(25, 951, 5)):
            neg = measure(groups['negative'], rankings, t)
            real = measure(groups['real'], rankings, t)
            short = measure(groups['queries'], rankings, t)
            if neg['suppression'] >= .9 and (real['precision'] or 0) >= .6:
                candidates.append((short['correct'], real['correct'], -t))
        if not candidates:
            raise ValueError('dev 제약을 충족하는 주입 임계값 없음')
        threshold = -max(candidates)[2]
        # dev F1 최대화, 동률이면 높은 임계값으로 선택한다.
        dup_candidates = []
        for t in (i / 1000 for i in range(25, 951, 5)):
            m = duplicate_metrics(pairs, scores, t)
            if m['fp'] <= 1:
                dup_candidates.append((2*m['tp'] / (m['positive_n']+m['tp']+m['fp']), t))
        duplicate_threshold = max(dup_candidates)[1]
        config = {'search': threshold, 'duplicate': duplicate_threshold, 'selected_on': 'dev'}
        with args.thresholds.open('x') as stream:
            json.dump(config, stream, indent=2)
    else:
        config = json.loads(args.thresholds.read_text())
        threshold, duplicate_threshold = config['search'], config['duplicate']
        if config['selected_on'] != 'dev':
            raise ValueError('dev에서 고정한 임계값 필요')
    result = {'split': args.split, 'thresholds': config,
              **{name: measure(data, rankings, threshold) for name, data in groups.items()},
              'duplicates': duplicate_metrics(pairs, scores, duplicate_threshold)}
    result['length_recall_drop_pp'] = 100 * (result['queries']['recall'] - result['long']['recall'])
    # 정답 문서 점수 자체도 비교한다. 둘 다 검색되지 않는 경우와 구분한다.
    deltas = []
    for q in groups['long']:
        for p in q['expected']:
            if p in by:
                # 전 코퍼스 IDF를 공유해야 점수를 직접 비교할 수 있다.
                i = docs.index(by[p])
                deltas.append(abs(corpus.scores(q['short'])[i] - corpus.scores(q['q'])[i]))
    result['length_score_delta'] = {'n': len(deltas), 'mean': sum(deltas)/len(deltas) if deltas else None,
                                    'max': max(deltas, default=None)}
    if args.audit:
        audit = json.loads(args.audit.read_text())
        truth, predicted = [], []
        for turn in audit:
            for d in turn['docs']:
                truth.append(d['used'])
                predicted.append(bool(citation_signals(by[d['path']], turn['answer'], corpus)))
        result['citation_audit'] = {'n': len(truth), 'agreement': sum(a == b for a,b in zip(truth,predicted)),
                                  'tp': sum(a and b for a,b in zip(truth,predicted)),
                                  'fp': sum(not a and b for a,b in zip(truth,predicted)),
                                  'fn': sum(a and not b for a,b in zip(truth,predicted))}
    with args.output.open('x') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
