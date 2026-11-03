-- A batch and its command receipt commit together. Retry never recreates a subset.
CREATE TABLE finance_batch_entry_commands (
    actor_id uuid NOT NULL REFERENCES users(id),
    idempotency_key varchar(128) NOT NULL,
    document_type varchar(32) NOT NULL,
    request_hash varchar(64) NOT NULL,
    result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (actor_id, idempotency_key)
);
COMMENT ON TABLE finance_batch_entry_commands IS '钱流多行新建的原子提交回执；按账号隔离，保留重试证据';
