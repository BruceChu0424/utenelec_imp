-- Durable side-path for production / warehouse / purchase / sales notices.
--
-- Business transactions append an event to this table. A background worker
-- delivers the event and marks it delivered in the same transaction as the
-- generated notices. A crash therefore either commits both or neither.
CREATE TABLE business_outbox (
    id              UUID PRIMARY KEY,
    event_type      VARCHAR(80) NOT NULL,
    aggregate_type  VARCHAR(80) NOT NULL,
    aggregate_id    UUID,
    payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
    dedupe_key      VARCHAR(240) NOT NULL,
    status          SMALLINT NOT NULL DEFAULT 0,
    attempts        INTEGER NOT NULL DEFAULT 0,
    available_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at    TIMESTAMPTZ,
    last_error      VARCHAR(1000),
    created_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT business_outbox_status_chk
        CHECK (status IN (0, 1, 2)),
    CONSTRAINT business_outbox_attempts_chk
        CHECK (attempts >= 0)
);

CREATE UNIQUE INDEX uq_business_outbox_dedupe
    ON business_outbox(dedupe_key);

CREATE INDEX idx_business_outbox_pending
    ON business_outbox(available_at, created_at, id)
    WHERE status = 0;

COMMENT ON TABLE business_outbox IS
    '业务链可靠事件旁路：0待处理、1已送达、2人工处理；通知与状态确认同事务，失败指数退避';
COMMENT ON COLUMN business_outbox.dedupe_key IS
    '调用方幂等键；相同业务动作重试只产生一个事件';

-- Keep the event lifecycle visible from the existing system-management audit
-- log. Payloads contain document ids/status only and must never contain direct
-- contact, credential, payment-card, or plaintext PII fields.
DROP TRIGGER IF EXISTS trg_audit_business_outbox ON business_outbox;
CREATE TRIGGER trg_audit_business_outbox
    AFTER INSERT OR UPDATE OR DELETE ON business_outbox
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
