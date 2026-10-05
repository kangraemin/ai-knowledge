"""새 파일과 기존 문서의 대칭 유사도를 비교한다."""
from pathlib import Path
from .activity import root
from .markdown import parse
from .relevance import Corpus, DEFAULT_DUPLICATE_SCORE, duplicate_similarity


def related(value):
    base = root().resolve()
    target = Path(value).expanduser().resolve()
    if not target.is_relative_to(base / 'library') or target.suffix != '.md':
        return ''
    documents = []
    for path in (base / 'library').rglob('*.md'):
        if path.name == 'index.md' or not path.resolve().is_relative_to(base / 'library'):
            continue
        try:
            meta, body = parse(path.read_text())
            title = meta.get('title') or next((line.lstrip('# ').strip() for line in body.splitlines() if line.startswith('# ')), '')
            documents.append(dict(meta, title=title, path=str(path.relative_to(base))))
        except (ValueError, OSError):
            continue
    current = next((d for d in documents if d['path'] == str(target.relative_to(base))), None)
    if current is None:
        return ''
    corpus = Corpus(documents)
    matches = [(duplicate_similarity(current, doc, corpus), doc['path']) for doc in documents if doc is not current]
    return '\n'.join('중복/관련 가능: ' + path for score, path in sorted(matches, reverse=True)[:5] if score >= DEFAULT_DUPLICATE_SCORE)
