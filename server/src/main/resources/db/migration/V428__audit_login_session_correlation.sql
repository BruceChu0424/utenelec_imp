-- Stable authentication-session correlation for audit evidence.
--
-- One successful login creates one session_id. Refresh-token rotation keeps
-- that value while access JWTs carry it to request audit rows. Historical
-- audit rows stay NULL because request/device/time proximity cannot prove a
-- login session. Existing staff refresh-token chains can be grouped by their
-- replaced_by root; visitor history did not retain replacement links, so each
-- historical visitor token is conservatively treated as its own session.

ALTER TABLE refresh_tokens
    ADD COLUMN IF NOT EXISTS session_id UUID;

WITH RECURSIVE token_families AS (
    SELECT
        root.id AS token_id,
        root.id AS session_id,
        ARRAY[root.id]::UUID[] AS visited
    FROM refresh_tokens root
    WHERE NOT EXISTS (
        SELECT 1
        FROM refresh_tokens predecessor
        WHERE predecessor.replaced_by = root.id
    )

    UNION ALL

    SELECT
        successor.id AS token_id,
        family.session_id,
        family.visited || successor.id
    FROM token_families family
    JOIN refresh_tokens current_token
      ON current_token.id = family.token_id
    JOIN refresh_tokens successor
      ON successor.id = current_token.replaced_by
    WHERE NOT successor.id = ANY(family.visited)
)
UPDATE refresh_tokens token
SET session_id = family.session_id
FROM token_families family
WHERE token.id = family.token_id
  AND token.session_id IS NULL;

-- Fail closed for malformed historical cycles/orphans: never merge tokens by
-- actor or timestamps. A distinct session is safer than a false correlation.
UPDATE refresh_tokens
SET session_id = id
WHERE session_id IS NULL;

ALTER TABLE refresh_tokens
    ALTER COLUMN session_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_session_id
    ON refresh_tokens (session_id);

ALTER TABLE visitor_refresh_tokens
    ADD COLUMN IF NOT EXISTS session_id UUID;

UPDATE visitor_refresh_tokens
SET session_id = id
WHERE session_id IS NULL;

ALTER TABLE visitor_refresh_tokens
    ALTER COLUMN session_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_visitor_refresh_tokens_session_id
    ON visitor_refresh_tokens (session_id);

ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS session_id UUID;

ALTER TABLE audit_log_archive
    ADD COLUMN IF NOT EXISTS session_id UUID;

CREATE INDEX IF NOT EXISTS idx_audit_session_created_id
    ON audit_log (session_id, created_at DESC, id DESC)
    WHERE session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_archive_session_created_id
    ON audit_log_archive (session_id, created_at DESC, id DESC)
    WHERE session_id IS NOT NULL;

COMMENT ON COLUMN refresh_tokens.session_id IS
    '服务端生成的员工登录会话 UUID；刷新轮换期间保持不变';
COMMENT ON COLUMN visitor_refresh_tokens.session_id IS
    '服务端生成的访客登录会话 UUID；刷新轮换期间保持不变';
COMMENT ON COLUMN audit_log.session_id IS
    '经登录或已验证访问令牌绑定的会话 UUID；匿名、系统及历史事件可为空';
COMMENT ON COLUMN audit_log_archive.session_id IS
    '审计冷归档中的稳定登录会话 UUID；与 audit_log.session_id 语义一致';
