-- V327: retain neutral central-override tombstones so row-level CAS versions
-- never reset after the global permission page removes and later re-adds a code.

ALTER TABLE user_permission_overrides
    ADD COLUMN active BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN user_permission_overrides.active IS
    'FALSE is a neutral inherited-state tombstone; ignored by permission resolution but retained for monotonic row_version CAS';

CREATE INDEX idx_user_permission_overrides_active_user
    ON user_permission_overrides(user_id, permission_id)
    WHERE active = TRUE;
