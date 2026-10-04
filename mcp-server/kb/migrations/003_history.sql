-- 편집자는 문서를 삭제할 수 없지만 본문 교체 시 파생 청크는 정리해야 한다.
-- 호출자가 임의 ID를 넘기는 함수 대신 해당 행의 트리거에서만 처리한다.
CREATE OR REPLACE FUNCTION kb.archive_document() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,kb AS $$
BEGIN
 INSERT INTO kb.document_versions(doc_id,version,title,body,frontmatter,author_id)
 VALUES(OLD.id,OLD.version,OLD.title,OLD.body,OLD.frontmatter,OLD.author_id);
 NEW.version := OLD.version+1;
 NEW.updated_at := now();
 IF NEW.body IS DISTINCT FROM OLD.body OR NEW.frontmatter IS DISTINCT FROM OLD.frontmatter THEN
   DELETE FROM kb.chunks WHERE doc_id=OLD.id;
   DELETE FROM kb.sources WHERE doc_id=OLD.id;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION kb.archive_document() FROM PUBLIC;
CREATE TRIGGER archive_document BEFORE UPDATE ON kb.documents
 FOR EACH ROW EXECUTE FUNCTION kb.archive_document();
