-- V319: provenance for central personal permission overrides.
--
-- Historical rows may have been written by the retired manager endpoint or by
-- a super administrator, and cannot be distinguished safely. Preserve their
-- current effective grant/revoke behavior, but mark every existing row UNKNOWN
-- so it can never become a manager's re-delegation source without explicit
-- super-admin confirmation through the global permission page.

ALTER TABLE user_permission_overrides
    ADD COLUMN authority_source TEXT NOT NULL DEFAULT 'LEGACY_UNKNOWN',
    ADD COLUMN source_actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD CONSTRAINT user_permission_overrides_authority_source_chk
        CHECK (authority_source IN (
            'LEGACY_UNKNOWN',
            'SUPER_ADMIN_CONFIRMED'
        ));

CREATE INDEX idx_user_permission_overrides_authority_source
    ON user_permission_overrides(authority_source, user_id);

COMMENT ON COLUMN user_permission_overrides.authority_source IS
    'LEGACY_UNKNOWN rows remain effective but are never re-delegable; SUPER_ADMIN_CONFIRMED is written only by the global super-admin service';
COMMENT ON COLUMN user_permission_overrides.source_actor_user_id IS
    'Super-admin user that most recently confirmed this central override; NULL for legacy unknown provenance';
