-- Reconciliation uploads preserve external evidence; they do not create or replace ledger amounts.
CREATE TABLE finance_statement_source_reviews (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor_id uuid NOT NULL REFERENCES users(id),
    kind text NOT NULL CHECK(kind IN('AUXILIARY_RECEIVABLE','AUXILIARY_PAYABLE')),
    source_system text NOT NULL CHECK(length(btrim(source_system)) BETWEEN 1 AND 80),
    currency_id uuid NOT NULL REFERENCES currencies(id),date_from date NOT NULL,date_to date NOT NULL,
    source_name text NOT NULL,sha256 text NOT NULL CHECK(sha256~'^[0-9a-f]{64}$'),
    storage_provider text NOT NULL,storage_key text NOT NULL,storage_version text,storage_size bigint NOT NULL CHECK(storage_size>0),
    preview jsonb NOT NULL,currency_mapping_fingerprint text NOT NULL DEFAULT 'LEGACY',
    directory_result jsonb,created_at timestamptz NOT NULL DEFAULT now(),directory_applied_at timestamptz,
    UNIQUE(actor_id,kind,source_system,currency_id,date_from,date_to,sha256,currency_mapping_fingerprint),CHECK(date_from<=date_to),
    CHECK((directory_result IS NULL)=(directory_applied_at IS NULL))
);
CREATE TRIGGER trg_audit_finance_statement_source_reviews AFTER INSERT OR UPDATE OR DELETE ON finance_statement_source_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_statement_source_reviews ENABLE ALWAYS TRIGGER trg_audit_finance_statement_source_reviews;
CREATE OR REPLACE FUNCTION fn_finance_statement_review_source_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION '原辅助对账资料须保留审计依据，不能删除' USING ERRCODE='23514';END IF;
    IF (NEW.id,NEW.actor_id,NEW.kind,NEW.source_system,NEW.currency_id,NEW.date_from,NEW.date_to,NEW.source_name,NEW.sha256,NEW.storage_provider,NEW.storage_key,NEW.storage_version,NEW.storage_size,NEW.preview,NEW.created_at,NEW.currency_mapping_fingerprint)
        IS DISTINCT FROM(OLD.id,OLD.actor_id,OLD.kind,OLD.source_system,OLD.currency_id,OLD.date_from,OLD.date_to,OLD.source_name,OLD.sha256,OLD.storage_provider,OLD.storage_key,OLD.storage_version,OLD.storage_size,OLD.preview,OLD.created_at,OLD.currency_mapping_fingerprint)
        OR (OLD.directory_result IS NOT NULL AND (NEW.directory_result,NEW.directory_applied_at) IS DISTINCT FROM(OLD.directory_result,OLD.directory_applied_at)) THEN
        RAISE EXCEPTION '原辅助对账资料及已完成的目录结果不可覆盖，请保留原批次并重新导入' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;$$;
CREATE TRIGGER trg_finance_statement_review_source_immutable BEFORE UPDATE OR DELETE ON finance_statement_source_reviews
    FOR EACH ROW EXECUTE FUNCTION fn_finance_statement_review_source_immutable();
