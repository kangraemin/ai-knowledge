-- 기존 사용자별 SELECT/INSERT RLS 정책과 권한은 그대로 유지한다.
ALTER TABLE kb.events ADD COLUMN IF NOT EXISTS payload jsonb;
