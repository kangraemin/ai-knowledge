"""새 파일과 기존 문서의 대칭 유사도를 비교한다."""
from pathlib import Path
from .activity import root
from .markdown import parse
from .relevance import (Corpus, WRITE_DUPLICATE_MAX, WRITE_DUPLICATE_SCORE, _tokens,
                        duplicate_similarity)


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
        except Exception:
            # 다른 문서 하나의 깨진 프론트매터 때문에 중복 검사 전체가 실패하지 않게 한다.
            continue
    current = next((d for d in documents if d['path'] == str(target.relative_to(base))), None)
    if current is None:
        return ''
    corpus = Corpus(documents)
    # 제목·설명 단어를 하나도 공유하지 않는 문서는 유사도가 0이다. 전체 IDF 계산을 피해 hook 시간 안에 끝낸다.
    words = lambda doc: _tokens(' '.join(str(doc.get(k) or '') for k in ('title', 'description')))
    mine = words(current)
    matches = [(duplicate_similarity(current, doc, corpus), doc['path']) for doc in documents
               if doc is not current and mine & words(doc)]
    return '\n'.join(f'중복/관련 가능: {path} ({score:.2f})'
                     for score, path in sorted(matches, reverse=True)[:WRITE_DUPLICATE_MAX]
                     if score >= WRITE_DUPLICATE_SCORE)
