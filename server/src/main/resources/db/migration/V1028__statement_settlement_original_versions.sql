-- A paper settlement version references original evidence and approved per-document
-- decisions. It creates no GL, debt, payment or inventory fact.
CREATE TABLE finance_statement_settlement_versions (
 review_id uuid PRIMARY KEY REFERENCES finance_statement_document_reviews(id),
 root_review_id uuid NOT NULL REFERENCES finance_statement_document_reviews(id),
 based_review_id uuid NOT NULL REFERENCES finance_statement_document_reviews(id),
 based_source_fingerprint text NOT NULL CHECK(based_source_fingerprint~'^[0-9a-f]{64}$'),
 effect_fingerprint text NOT NULL CHECK(effect_fingerprint~'^[0-9a-f]{64}$'),
 explicitly_no_deductions boolean NOT NULL,
 source_reference text NOT NULL CHECK(length(trim(source_reference)) BETWEEN 1 AND 2000),
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 created_tx bigint NOT NULL DEFAULT txid_current(),
 CHECK(review_id<>root_review_id AND review_id<>based_review_id)
);
CREATE INDEX idx_statement_settlement_root ON finance_statement_settlement_versions(root_review_id,created_at);
CREATE FUNCTION fn_guard_statement_settlement_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original finance_statement_document_reviews;based finance_statement_document_reviews;derived finance_statement_document_reviews;
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Settlement paper versions cannot be rewritten or deleted' USING ERRCODE='55000';END IF;
 SELECT * INTO original FROM finance_statement_document_reviews WHERE id=NEW.root_review_id;
 SELECT * INTO based FROM finance_statement_document_reviews WHERE id=NEW.based_review_id;
 SELECT * INTO derived FROM finance_statement_document_reviews WHERE id=NEW.review_id;
 IF original.template_key NOT IN('supplierStatement','subcontractStatement') OR original.party_role<>'SUPPLIER'
   OR original.status NOT IN('INTERNAL_CONFIRMED','BOTH_CONFIRMED') OR based.status NOT IN('INTERNAL_CONFIRMED','BOTH_CONFIRMED')
   OR based.source_fingerprint<>NEW.based_source_fingerprint OR derived.status<>'SUBMITTED'
   OR derived.submitted_by<>NEW.created_by OR NEW.created_tx<>txid_current()
   OR EXISTS(SELECT 1 FROM finance_statement_settlement_versions WHERE review_id=NEW.root_review_id)
   OR (NEW.based_review_id<>NEW.root_review_id AND NOT EXISTS(SELECT 1 FROM finance_statement_settlement_versions prior WHERE prior.review_id=NEW.based_review_id AND prior.root_review_id=NEW.root_review_id))
   OR (original.template_key,original.party_role,original.party_id,original.currency_id,original.date_from,original.date_to,original.material_context_id,original.material_all_contexts)
        IS DISTINCT FROM (derived.template_key,derived.party_role,derived.party_id,derived.currency_id,derived.date_from,derived.date_to,derived.material_context_id,derived.material_all_contexts)
   OR (original.template_key,original.party_role,original.party_id,original.currency_id,original.date_from,original.date_to,original.material_context_id,original.material_all_contexts)
        IS DISTINCT FROM (based.template_key,based.party_role,based.party_id,based.currency_id,based.date_from,based.date_to,based.material_context_id,based.material_all_contexts)
 THEN RAISE EXCEPTION 'Settlement version must retain this exact confirmed original and its actual context' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_statement_settlement_version_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_statement_settlement_versions FOR EACH ROW EXECUTE FUNCTION fn_guard_statement_settlement_version();
SELECT fn_audit_track_table('finance_statement_settlement_versions','COLUMN_SCOPED','data_change',false,
 ARRAY['review_id','root_review_id','based_review_id','based_source_fingerprint','effect_fingerprint','explicitly_no_deductions','created_by'],true,NULL);
