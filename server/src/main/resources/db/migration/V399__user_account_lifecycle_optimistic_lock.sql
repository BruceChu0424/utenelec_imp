-- V399: prevent a stale UserAccount entity save from overwriting offboarding
-- account disablement, remote-access revocation, or credential hardening.
-- auth_version remains the token/permission snapshot version maintained by
-- database triggers; this independent version is JPA's write CAS only.

ALTER TABLE users
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0;

ALTER TABLE users
    ADD CONSTRAINT users_version_chk CHECK (version >= 0) NOT VALID;

ALTER TABLE users
    VALIDATE CONSTRAINT users_version_chk;

COMMENT ON COLUMN users.version IS 'JPA optimistic-lock CAS for all whole-account writes; independent from auth_version';
