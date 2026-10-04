CREATE TABLE IF NOT EXISTS kb.workspaces (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text UNIQUE NOT NULL,
 name text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS kb.users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), handle text UNIQUE NOT NULL,
 db_role text UNIQUE NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS kb.members (
 workspace_id uuid REFERENCES kb.workspaces NOT NULL, user_id uuid REFERENCES kb.users NOT NULL,
 role text NOT NULL CHECK (role IN ('owner','editor','viewer')), PRIMARY KEY(workspace_id,user_id)
);
CREATE TABLE IF NOT EXISTS kb.scopes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), workspace_id uuid REFERENCES kb.workspaces NOT NULL,
 kind text NOT NULL CHECK(kind IN ('personal','team','repo')), key text NOT NULL,
 owner_user_id uuid REFERENCES kb.users,
 CHECK ((kind = 'personal') = (owner_user_id IS NOT NULL)), UNIQUE(workspace_id,kind,key)
);
CREATE TABLE IF NOT EXISTS kb.documents (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), scope_id uuid REFERENCES kb.scopes NOT NULL,
 kind text NOT NULL CHECK(kind IN ('knowledge','decision','inbox')),
 path text NOT NULL, type text NOT NULL, title text NOT NULL, description text,
 body text NOT NULL, category text, subcategory text, tags text[] NOT NULL DEFAULT '{}',
 status text NOT NULL DEFAULT 'stable' CHECK(status IN ('draft','stable','deprecated')),
 confidence real, evidence_count int, frontmatter jsonb NOT NULL DEFAULT '{}',
 content_hash text NOT NULL, author_id uuid REFERENCES kb.users, version int NOT NULL DEFAULT 1,
 valid_from timestamptz NOT NULL DEFAULT now(), invalid_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(scope_id,path)
);
CREATE TABLE IF NOT EXISTS kb.document_versions (
 doc_id uuid REFERENCES kb.documents ON DELETE CASCADE, version int,
 title text NOT NULL, body text NOT NULL, frontmatter jsonb NOT NULL,
 author_id uuid REFERENCES kb.users, created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(doc_id,version)
);
CREATE TABLE IF NOT EXISTS kb.relations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), src_id uuid REFERENCES kb.documents ON DELETE CASCADE NOT NULL,
 dst_id uuid REFERENCES kb.documents ON DELETE CASCADE NOT NULL,
 type text NOT NULL CHECK(type IN ('supersedes','contradicts','refines','derived_from','example_of','related')),
 created_by uuid REFERENCES kb.users, valid_from timestamptz NOT NULL DEFAULT now(), invalid_at timestamptz,
 CHECK(src_id <> dst_id), UNIQUE(src_id,dst_id,type)
);
CREATE TABLE IF NOT EXISTS kb.sources (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), doc_id uuid REFERENCES kb.documents ON DELETE CASCADE NOT NULL,
 ref_id text, resource text, title text
);
CREATE TABLE IF NOT EXISTS kb.chunks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), doc_id uuid REFERENCES kb.documents ON DELETE CASCADE NOT NULL,
 ord int NOT NULL, heading text, text text NOT NULL, UNIQUE(doc_id,ord)
);
CREATE TABLE IF NOT EXISTS kb.embeddings (
 chunk_id uuid REFERENCES kb.chunks ON DELETE CASCADE, model text, dim int NOT NULL CHECK(dim>0),
 vec vector NOT NULL, CHECK(vector_dims(vec)=dim), PRIMARY KEY(chunk_id,model)
);
CREATE TABLE IF NOT EXISTS kb.events (
 id bigserial PRIMARY KEY, user_id uuid REFERENCES kb.users, doc_id uuid,
 action text NOT NULL, query text, at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chunks_text_bigm ON kb.chunks USING gin (text gin_bigm_ops);
CREATE INDEX IF NOT EXISTS documents_title_bigm ON kb.documents USING gin ((title || ' ' || coalesce(description,'')) gin_bigm_ops);
CREATE INDEX IF NOT EXISTS members_user ON kb.members(user_id);
CREATE INDEX IF NOT EXISTS relations_dst ON kb.relations(dst_id);
CREATE INDEX IF NOT EXISTS sources_doc ON kb.sources(doc_id);
CREATE INDEX IF NOT EXISTS events_user ON kb.events(user_id);
CREATE INDEX IF NOT EXISTS embeddings_model ON kb.embeddings(model);

CREATE OR REPLACE FUNCTION kb.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT id FROM kb.users WHERE db_role = current_user
$$;
CREATE OR REPLACE FUNCTION kb.workspace_role(w uuid) RETURNS text LANGUAGE sql STABLE AS $$
 SELECT role FROM kb.members WHERE workspace_id=w AND user_id=kb.current_user_id()
$$;
CREATE OR REPLACE FUNCTION kb.scope_access(s uuid, roles text[] DEFAULT ARRAY['owner','editor','viewer'])
 RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM kb.scopes WHERE id=s AND kb.workspace_role(workspace_id)=ANY(roles)
 AND (kind<>'personal' OR owner_user_id=kb.current_user_id()))
$$;
CREATE OR REPLACE FUNCTION kb.doc_access(d uuid, roles text[] DEFAULT ARRAY['owner','editor','viewer'])
 RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM kb.documents WHERE id=d AND kb.scope_access(scope_id,roles))
$$;
-- 식별자와 리터럴을 각각 인용하여 모델명이 SQL이 되지 않도록 한다.
CREATE OR REPLACE FUNCTION kb.ensure_vector_index(model text, dim int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF dim < 1 OR dim > 2000 THEN RAISE EXCEPTION 'HNSW vector dimension must be 1..2000'; END IF;
 EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON kb.embeddings USING hnsw ((vec::vector(%s)) vector_cosine_ops) WHERE model=%L',
 'emb_hnsw_' || md5(model),dim,model);
END $$;
