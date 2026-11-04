-- Original finance labels identify the source form. Current employee approval,
-- payment and accounting remain the native workflow, not a second approval.
CREATE TABLE expense_claim_source_links (
 claim_id uuid PRIMARY KEY REFERENCES expense_claims(id),
 application_kind text NOT NULL CHECK(application_kind IN('REIMBURSEMENT','TRAVEL_REIMBURSEMENT')),
 travel_application_source_kind text CHECK(travel_application_source_kind IN('BUSINESS_APPLICATION','FINANCE_APPLICATION')),
 business_travel_application_id uuid REFERENCES business_applications(id),
 finance_travel_application_id uuid REFERENCES finance_applications(id),
 created_by uuid NOT NULL REFERENCES users(id),updated_by uuid NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT expense_claim_source_identity CHECK(
  application_kind='REIMBURSEMENT' AND travel_application_source_kind IS NULL
   AND business_travel_application_id IS NULL AND finance_travel_application_id IS NULL
  OR application_kind='TRAVEL_REIMBURSEMENT' AND (
   travel_application_source_kind='BUSINESS_APPLICATION' AND business_travel_application_id IS NOT NULL AND finance_travel_application_id IS NULL
   OR travel_application_source_kind='FINANCE_APPLICATION' AND finance_travel_application_id IS NOT NULL AND business_travel_application_id IS NULL))
 );

CREATE FUNCTION fn_assert_expense_travel_source(form_kind text,source_type text,business_id uuid,finance_id uuid,applicant uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE source_kind text;source_status text;source_owner uuid;
BEGIN
 IF source_type='BUSINESS_APPLICATION' THEN
  SELECT kind,status,applicant_id INTO source_kind,source_status,source_owner FROM business_applications
   WHERE id=business_id FOR SHARE;
  IF NOT FOUND OR source_kind<>'TRAVEL' OR source_status<>'COMPLETED' THEN
   RAISE EXCEPTION 'business travel source has not completed its actual finance custody' USING ERRCODE='23514';END IF;
 ELSIF source_type='FINANCE_APPLICATION' THEN
  SELECT kind,status,applicant_id INTO source_kind,source_status,source_owner FROM finance_applications
   WHERE id=finance_id FOR SHARE;
  IF NOT FOUND OR source_kind<>'TRAVEL_APPLICATION' OR source_status<>'ARCHIVED' THEN
   RAISE EXCEPTION 'original travel source has not completed its actual finance custody' USING ERRCODE='23514';END IF;
 END IF;
 IF form_kind='TRAVEL_REIMBURSEMENT' AND fn_canonical_employee_identity(source_owner) IS DISTINCT FROM fn_canonical_employee_identity(applicant) THEN
  RAISE EXCEPTION 'travel reimbursement source belongs to a different applicant' USING ERRCODE='23514';END IF;
END $$;
CREATE FUNCTION fn_assert_expense_original_source(p_claim_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE source expense_claim_source_links%ROWTYPE;claim expense_claims%ROWTYPE;
BEGIN
 SELECT * INTO source FROM expense_claim_source_links WHERE claim_id=p_claim_id;
 IF NOT FOUND THEN RETURN;END IF;
 SELECT * INTO claim FROM expense_claims WHERE id=p_claim_id FOR UPDATE;
 IF NOT FOUND OR claim.is_deleted OR claim.status NOT IN('DRAFT','REJECTED') OR
   claim.expense_kind IS DISTINCT FROM (CASE WHEN source.application_kind='TRAVEL_REIMBURSEMENT' THEN 'TRAVEL' ELSE 'GENERAL' END) THEN
  RAISE EXCEPTION 'original expense source does not match its editable native claim' USING ERRCODE='55000';END IF;
 PERFORM fn_assert_expense_travel_source(source.application_kind,source.travel_application_source_kind,
   source.business_travel_application_id,source.finance_travel_application_id,claim.applicant_id);
END $$;

CREATE FUNCTION fn_guard_expense_source_link() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE claim expense_claims%ROWTYPE;
BEGIN
 SELECT * INTO claim FROM expense_claims WHERE id=NEW.claim_id FOR UPDATE;
 IF NOT FOUND OR claim.is_deleted OR claim.status NOT IN('DRAFT','REJECTED') THEN
  RAISE EXCEPTION 'original expense source can only be maintained with its editable native draft' USING ERRCODE='55000';END IF;
 IF claim.expense_kind IS DISTINCT FROM (CASE WHEN NEW.application_kind='TRAVEL_REIMBURSEMENT' THEN 'TRAVEL' ELSE 'GENERAL' END) THEN
  RAISE EXCEPTION 'original expense form does not match the native expense kind' USING ERRCODE='23514';END IF;
 PERFORM fn_assert_expense_travel_source(NEW.application_kind,NEW.travel_application_source_kind,
   NEW.business_travel_application_id,NEW.finance_travel_application_id,claim.applicant_id);
 IF TG_OP='UPDATE' AND (NEW.claim_id IS DISTINCT FROM OLD.claim_id OR NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at IS DISTINCT FROM OLD.created_at) THEN
  RAISE EXCEPTION 'original expense source identity cannot be replaced' USING ERRCODE='55000';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_expense_original_source BEFORE INSERT OR UPDATE ON expense_claim_source_links
 FOR EACH ROW EXECUTE FUNCTION fn_guard_expense_source_link();
ALTER TABLE expense_claim_source_links ENABLE ALWAYS TRIGGER trg_expense_original_source;
SELECT fn_audit_track_table('expense_claim_source_links','COLUMN_SCOPED','data_change',false,
 ARRAY['claim_id','application_kind','travel_application_source_kind','business_travel_application_id','finance_travel_application_id','created_by','updated_by'],true,NULL);
