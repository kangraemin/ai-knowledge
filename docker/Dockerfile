FROM pgvector/pgvector:0.8.0-pg17
ARG PG_BIGM_REF=v1.2-20250903
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git postgresql-server-dev-17 ca-certificates \
    && git clone --depth 1 --branch "$PG_BIGM_REF" https://github.com/pgbigm/pg_bigm.git /tmp/pg_bigm \
    && cd /tmp/pg_bigm && make USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config \
    && make USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config install \
    && rm -rf /tmp/pg_bigm /var/lib/apt/lists/*
