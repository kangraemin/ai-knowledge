DROP POLICY log_events ON kb.events;
CREATE POLICY log_events ON kb.events FOR INSERT TO kb_app
WITH CHECK ((user_id=kb.current_user_id() AND (doc_id IS NULL OR kb.doc_access(doc_id)))
 OR (user_id IS NULL AND kb.current_user_id() IS NULL AND doc_id IS NULL AND action='search'));
