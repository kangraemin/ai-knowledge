"""합성 문서만 사용해 장문·중복·인용 회귀를 검증한다."""

import pytest

from kb.relevance import Corpus, citation_signals, duplicate_similarity
from kb.search import query_terms


def documents():
    return [
        {'path': 'library/storage/recovery.md', 'title': 'Postgres WAL archive recovery',
         'description': 'Restore snapshots using WAL archive replay and checksums.'},
        {'path': 'library/ui/colors.md', 'title': 'Canvas palette typography',
         'description': 'Choose accessible contrast for buttons and navigation.'},
    ] + [{'title': f'common pipeline process example {i}', 'body': 'generic operations workflow'}
         for i in range(25)]


def test_chatter_sentences_do_not_change_query_score():
    corpus = Corpus(documents())
    short = 'Postgres WAL archive recovery'
    long = 'Hello. I just came back after a short break. ' + short + '. Please explain this step by step.'
    assert corpus.scores(short)[0] > .8
    assert abs(corpus.scores(short)[0] - corpus.scores(long)[0]) < .05
    assert corpus.scores(long)[1] == 0


def test_long_query_and_repetition_cannot_saturate_unrelated_documents():
    corpus = Corpus(documents())
    query = 'Postgres WAL archive recovery. ' * 30
    assert corpus.scores(query)[0] == pytest.approx(corpus.scores('Postgres WAL archive recovery.')[0])
    assert corpus.scores(query)[1] == 0
    assert max(corpus.scores(query)) < 1


def test_common_terms_are_damped_and_oov_has_no_evidence():
    corpus = Corpus(documents())
    assert corpus.idf('pipeline') < corpus.idf('wal')
    assert corpus.scores('quuxzebra entirelyunknown') == [0] * len(documents())


def test_duplicate_is_symmetric_and_does_not_use_path_or_body():
    a, b = documents()[:2]
    c = {**a, 'path': 'library/elsewhere.md', 'title': 'WAL Postgres recovery archive'}
    corpus = Corpus(documents())
    assert duplicate_similarity(a, c, corpus) == pytest.approx(duplicate_similarity(c, a, corpus))
    assert duplicate_similarity(a, c, corpus) > .8
    assert duplicate_similarity(a, b, corpus) < .05
    assert duplicate_similarity(a, {**b, 'body': a['description'], 'path': a['path']}, corpus) < .05


def test_duplicate_new_unknown_vocabulary_counts_in_denominator():
    a = {'title': 'Postgres WAL'}
    b = {'title': 'Postgres WAL ' + ' '.join('unknown' + str(i) for i in range(30))}
    assert duplicate_similarity(a, b, Corpus([a])) < .15


def test_keyword_citation_records_evidence_without_title_or_filename():
    doc = documents()[0]
    corpus = Corpus(documents())
    answer = 'Replay the archive and verify checksums; restore snapshots with WAL.'
    signals = citation_signals(doc, answer, corpus)
    assert any(s['kind'] == 'keywords' and len(s['matched']) >= 3 for s in signals)
    assert not any(s['kind'] in ('path', 'title', 'filename') for s in signals)
    assert citation_signals(doc, 'archive', corpus) == []
    assert citation_signals(doc, 'The palette needs accessible contrast.', corpus) == []


def test_normalization_particles_and_identifier_boundaries():
    assert query_terms('백업은 복구를 postgres로 WAL과') == ['백업', '복구', 'postgres', 'wal']
    corpus = Corpus([{'title': 'IMDb'}, {'title': 'DB'}, {'path': 'library/HTTP-timeout.md'}])
    assert corpus.scores('DB')[0] == 0
    assert corpus.scores('HTTP timeout')[2] > 0


def test_frontmatter_nested_title_does_not_replace_document_title():
    from server import _parse_frontmatter
    meta = _parse_frontmatter('---\ntitle: Real title\nsources:\n  - id: source\n    title: Nested title\n---\nbody')
    assert meta['title'] == 'Real title'


def test_calibration_cannot_search_test(tmp_path, monkeypatch):
    from kb.eval import stress
    import sys
    monkeypatch.setattr(sys, 'argv', ['stress', '--split', 'test', '--calibrate'] +
                        [arg for k in ('queries', 'long', 'real', 'pairs', 'thresholds', 'output')
                         for arg in ('--' + k, str(tmp_path / k))])
    with pytest.raises(SystemExit) as error:
        stress.main()
    assert error.value.code == 2


def test_single_known_term_cannot_cross_default_injection_threshold():
    from kb.relevance import minimum
    corpus = Corpus(documents())
    assert 0 < corpus.scores('Postgres')[0] < minimum('files')
    assert corpus.scores('Postgres unknownchatter')[0] < minimum('files')


def test_search_citation_does_not_count_as_injection_citation(tmp_path, monkeypatch):
    from datetime import datetime, timezone
    from kb import usage
    row = {'ts': datetime.now(timezone.utc).isoformat(), 'turn_id': 'one',
           'autoinject': {'injected': True, 'paths': ['library/injected.md']},
           'calls': {'library_search': ['query'], 'library_read': []},
           'cited_paths': ['library/searched.md'], 'labels': ['hit_used'],
           'search_paths': ['library/searched.md']}
    monkeypatch.setattr(usage, 'records', lambda *args: iter([row]))
    monkeypatch.setattr(usage, 'inventory', lambda *args: [])
    monkeypatch.setattr(usage.activity, 'stats', lambda *args: {'latency_ms': {}})
    assert usage.report(root=tmp_path)['injection_citation_rate']['numerator'] == 0


def gate_rows(query, docs):
    corpus = Corpus(docs)
    return [{**d, 'score': score, 'injection_evidence': evidence}
            for d, score, evidence in zip(docs, corpus.scores(query), corpus.injection_evidence(query))]


def test_gate_requires_rare_metadata_evidence_not_body_or_tags():
    from kb.relevance import select
    query = 'Postgres WAL archive recovery'
    filler = [{'title': 'ordinary unrelated document'} for _ in range(100)]
    target = {'path': 'library/restore.md', 'title': query}
    assert select(gate_rows(query, [target] + filler), 'files', 1500)[0] == gate_rows(query, [target] + filler)[:1]
    for field in ('body', 'tags'):
        rows = gate_rows(query, [{'path': 'library/restore.md', field: query}] + filler)
        assert select(rows, 'files', 1500)[0] == []
    # 코퍼스 전체에 반복되는 메타데이터 단어는 핵심어가 아니다.
    assert select(gate_rows(query, [target] * 100), 'files', 1500)[0] == []


def test_gate_exact_terms_short_floor_and_override(monkeypatch):
    from kb.relevance import select
    row = {'path': 'library/example.md', 'title': 'Synthetic example', 'score': .3,
           'injection_evidence': {'core_matches': 4, 'query_terms': 20}}
    assert select([row], 'files', 1500)[0] == [row]
    short = {**row, 'injection_evidence': {'core_matches': 4, 'query_terms': 4}}
    assert select([short], 'files', 1500) == ([], 'weak_evidence')
    assert select([{**short, 'score': .4}], 'files', 1500)[0]
    monkeypatch.setenv('LIBRARY_AUTOINJECT_MIN_SCORE', '.5')
    assert select([row], 'files', 1500) == ([], 'low_score')
    monkeypatch.setenv('LIBRARY_AUTOINJECT_MIN_SCORE', '0')
    assert select([short], 'files', 1500)[0] == []
    assert select([{**row, 'injection_evidence': {}}], 'files', 1500)[0] == []
    assert select([row], 'files', 1) == ([], 'budget')


def test_gate_substring_and_repetition_are_not_extra_core_terms():
    docs = [{'title': '복구절차 백업정책 archive replay'}] + [{'title': 'filler'}] * 100
    evidence = Corpus(docs).injection_evidence('복구 백업 archive archive replay')[0]
    assert evidence['core_matches'] == 2


def test_gate_metrics_zero_injections_is_not_perfect_precision():
    from kb.eval.gate import measure
    data = [{'prompt': 'synthetic query', 'relevant': True, 'expected_paths': ['library/a.md']}]
    result = measure(data, {'synthetic query': []})
    assert result['precision'] is None
    assert result['recall'] == 0
