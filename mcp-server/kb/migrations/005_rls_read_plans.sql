-- 접근 가능한 ID 집합을 한 번 계산한다. 행마다 부모 정책을 재귀 평가하지 않는다.
-- SECURITY INVOKER와 동일한 RLS 경계를 유지하며 대량 청크 검색 비용을 줄인다.
DROP POLICY workspace_read ON kb.workspaces;
CREATE POLICY workspace_read ON kb.workspaces FOR SELECT TO kb_app
 USING(id IN (SELECT workspace_id FROM kb.members));
DROP POLICY own_membership ON kb.members;
CREATE POLICY own_membership ON kb.members FOR SELECT TO kb_app
 USING(user_id=(SELECT kb.current_user_id()));
DROP POLICY read ON kb.scopes;
CREATE POLICY read ON kb.scopes FOR SELECT TO kb_app
 USING(workspace_id IN (SELECT workspace_id FROM kb.members)
 AND (kind<>'personal' OR owner_user_id=(SELECT kb.current_user_id())));
DROP POLICY read ON kb.documents;
CREATE POLICY read ON kb.documents FOR SELECT TO kb_app
 USING(scope_id IN (SELECT id FROM kb.scopes)
 AND (kind<>'inbox' OR author_id=(SELECT kb.current_user_id())
 OR scope_id IN (SELECT id FROM kb.scopes WHERE workspace_id IN
 (SELECT workspace_id FROM kb.members WHERE role='owner'))));
DROP POLICY read ON kb.chunks;
CREATE POLICY read ON kb.chunks FOR SELECT TO kb_app
 USING(doc_id IN (SELECT id FROM kb.documents));
DROP POLICY read ON kb.sources;
CREATE POLICY read ON kb.sources FOR SELECT TO kb_app
 USING(doc_id IN (SELECT id FROM kb.documents));
DROP POLICY read ON kb.document_versions;
CREATE POLICY read ON kb.document_versions FOR SELECT TO kb_app
 USING(doc_id IN (SELECT id FROM kb.documents));
DROP POLICY read ON kb.embeddings;
CREATE POLICY read ON kb.embeddings FOR SELECT TO kb_app
 USING(chunk_id IN (SELECT id FROM kb.chunks));
DROP POLICY read ON kb.relations;
CREATE POLICY read ON kb.relations FOR SELECT TO kb_app
 USING(src_id IN (SELECT id FROM kb.documents) AND dst_id IN (SELECT id FROM kb.documents));
