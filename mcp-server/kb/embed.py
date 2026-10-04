"""선택적 임베딩. 모델 실행과 다운로드는 명시적으로 선택했을 때만 한다."""

import hashlib
import os
from functools import lru_cache


class Provider:
    def __init__(self, name=None):
        self.name = name or os.environ.get("LIBRARY_EMBED_PROVIDER", "none")
        defaults = {
            "none": "",
            "fake": "fake-sha256-v1",
            "fastembed": "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
            "openai": "text-embedding-3-small",
        }
        if self.name not in defaults:
            raise ValueError("지원하지 않는 LIBRARY_EMBED_PROVIDER")
        self.model = os.environ.get("LIBRARY_EMBED_MODEL") or defaults[self.name]
        self.client = None

    def encode(self, texts, query=False):
        if self.name == "none":
            return []
        if self.name == "fake":
            return [
                [(v - 127.5) / 127.5 for v in hashlib.sha256(t.encode()).digest()]
                for t in texts
            ]
        if self.name == "fastembed":
            if self.client is None:
                from fastembed import TextEmbedding

                self.client = TextEmbedding(model_name=self.model)
            method = self.client.query_embed if query else self.client.embed
            return [v.tolist() for v in method(texts)]
        if self.client is None:
            from openai import OpenAI

            self.client = OpenAI()
        response = self.client.embeddings.create(model=self.model, input=texts)
        return [item.embedding for item in sorted(response.data, key=lambda x: x.index)]


@lru_cache(maxsize=4)
def _provider(name, model):
    return Provider(name)


def provider():
    return _provider(
        os.environ.get("LIBRARY_EMBED_PROVIDER", "none"),
        os.environ.get("LIBRARY_EMBED_MODEL", ""),
    )


def vector_literal(vec):
    import math

    if not vec or any(not math.isfinite(float(v)) for v in vec):
        raise ValueError("임베딩은 유한한 숫자 벡터여야 합니다")
    return "[" + ",".join(str(float(v)) for v in vec) + "]"


def embed_pending(conn, embedder=None):
    embedder = embedder or provider()
    if embedder.name == "none":
        return 0
    count = 0
    # 계산 중 본문이 바뀌면 ID가 삭제된다. 쓰기 직전 잠금으로 재확인한다.
    rows = conn.execute(
        """SELECT c.id,c.text FROM kb.chunks c
        WHERE NOT EXISTS(SELECT 1 FROM kb.embeddings e WHERE e.chunk_id=c.id AND e.model=%s)
        ORDER BY c.id""",
        (embedder.model,),
    ).fetchall()
    for start in range(0, len(rows), 32):
        batch = rows[start : start + 32]
        vectors = embedder.encode([r["text"] for r in batch])
        if len(vectors) != len(batch):
            raise ValueError("임베딩 응답 개수 불일치")
        with conn.transaction():
            for row, vec in zip(batch, vectors):
                if not conn.execute(
                    "SELECT id FROM kb.chunks WHERE id=%s FOR KEY SHARE", (row["id"],)
                ).fetchone():
                    continue
                conn.execute(
                    """INSERT INTO kb.embeddings(chunk_id,model,dim,vec) VALUES(%s,%s,%s,%s::vector)
                    ON CONFLICT(chunk_id,model) DO NOTHING""",
                    (row["id"], embedder.model, len(vec), vector_literal(vec)),
                )
                count += 1
    return count
