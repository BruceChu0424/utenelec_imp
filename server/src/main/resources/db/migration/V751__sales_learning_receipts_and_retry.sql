-- Confirmed learning is a durable, retryable side effect of a saved sales document.
ALTER TABLE ai_jobs ADD COLUMN learning_retry_until timestamptz;
COMMENT ON COLUMN ai_jobs.learning_retry_until IS 'Bounded retention for confirmed learning retries; successful consumption clears the result and this lease';
CREATE TABLE sales_document_learning_receipts (
    id uuid PRIMARY KEY,
    saved_sequence bigint GENERATED ALWAYS AS IDENTITY,
    doc_type varchar(16) NOT NULL CHECK(doc_type IN ('quote','order')),
    doc_id uuid NOT NULL,
    client_id uuid,
    actor_user_id uuid NOT NULL REFERENCES users(id),
    request_payload jsonb NOT NULL CHECK(jsonb_typeof(request_payload)='object'),
    evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
    steps jsonb NOT NULL CHECK(jsonb_typeof(steps)='object'),
    state varchar(16) NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','PARTIAL','FAILED')),
    retry_until timestamptz NOT NULL DEFAULT now()+interval '30 days',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_sales_learning_receipt_doc ON sales_document_learning_receipts(doc_type,doc_id,saved_sequence DESC);
CREATE INDEX idx_sales_learning_receipt_actor ON sales_document_learning_receipts(actor_user_id,doc_type,doc_id,client_id);
COMMENT ON TABLE sales_document_learning_receipts IS 'Confirmed minimal learning commands, selected server row evidence and per-step outcomes; payload is internal, never an API response or row-audit record';
CREATE TABLE sales_intake_layout_learning_evidence (
    job_id uuid NOT NULL,
    doc_type varchar(16) NOT NULL CHECK(doc_type IN ('quote','order')),
    doc_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(job_id,doc_type,doc_id)
);
COMMENT ON TABLE sales_intake_layout_learning_evidence IS 'Atomic exactly-once evidence for learned header confidence, including retry after an interrupted receipt update';
SELECT fn_audit_track_table('sales_document_learning_receipts','NONE','data_change',false);
SELECT fn_audit_track_table('sales_intake_layout_learning_evidence','NONE','data_change',false);
DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V751 cannot extend reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor
        || E',\n            (''sales_document_learning_receipts'', ''CLEAR''),'
        || E'\n            (''sales_intake_layout_learning_evidence'', ''CLEAR'')');
END;
$reset_policy$;
