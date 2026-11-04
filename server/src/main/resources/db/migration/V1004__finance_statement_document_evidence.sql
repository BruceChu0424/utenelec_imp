-- Original statement captions/footer data are reviewed versions, never sample company/bank defaults.
CREATE TABLE finance_statement_profiles (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL,
 kind text NOT NULL CHECK(kind IN('OWN','COUNTERPART','CONTEXT')),template_key text NOT NULL,
 party_role text CHECK(party_role IN('CUSTOMER','SUPPLIER','EMPLOYEE','OTHER')),party_id uuid,
 currency_id uuid NOT NULL REFERENCES currencies(id),revision bigint NOT NULL CHECK(revision>=0),
 body_cipher text NOT NULL,source_reference text NOT NULL,
 status text NOT NULL CHECK(status IN('SUBMITTED','APPROVED','REJECTED')),
 submitted_by uuid NOT NULL REFERENCES users(id),submitted_name text NOT NULL,submitted_at timestamptz NOT NULL DEFAULT now(),
 reviewed_by uuid REFERENCES users(id),reviewed_name text,reviewed_at timestamptz,review_reason text,
 CHECK((kind='OWN' AND party_id IS NULL AND party_role IS NULL) OR(kind<>'OWN' AND party_id IS NOT NULL AND party_role IS NOT NULL)),CHECK(reviewed_by IS NULL OR reviewed_by<>submitted_by),
 CHECK((status='SUBMITTED')=(reviewed_by IS NULL AND reviewed_at IS NULL)),
 CHECK(status='SUBMITTED' OR(reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)),
 UNIQUE NULLS NOT DISTINCT(kind,template_key,party_role,party_id,currency_id,revision)
);
CREATE TABLE finance_statement_document_reviews (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL,template_key text NOT NULL,
 party_role text NOT NULL CHECK(party_role IN('CUSTOMER','SUPPLIER','EMPLOYEE','OTHER')),party_id uuid NOT NULL,
 currency_id uuid NOT NULL REFERENCES currencies(id),date_from date NOT NULL,date_to date NOT NULL CHECK(date_from<=date_to),
 own_profile_id uuid REFERENCES finance_statement_profiles(id),counterpart_profile_id uuid REFERENCES finance_statement_profiles(id),
 context_profile_id uuid NOT NULL REFERENCES finance_statement_profiles(id),
 document_sha256 text NOT NULL CHECK(document_sha256~'^[0-9a-f]{64}$'),source_fingerprint text NOT NULL,
 snapshot_cipher text NOT NULL,status text NOT NULL CHECK(status IN('SUBMITTED','INTERNAL_CONFIRMED','BOTH_CONFIRMED','REJECTED','CANCELLED')),
 submitted_by uuid NOT NULL REFERENCES users(id),submitted_name text NOT NULL,submitted_at timestamptz NOT NULL DEFAULT now(),
 approved_by uuid REFERENCES users(id),approved_name text,approved_at timestamptz,review_reason text,
 counterpart_name text,counterpart_confirmed_date date,counterpart_received_by uuid REFERENCES users(id),counterpart_received_name text,counterpart_received_at timestamptz,
 counterpart_source_reference text,counterpart_file_name text,counterpart_file_content_type text,
 counterpart_file_provider text,counterpart_file_key text,counterpart_file_version text,counterpart_file_size bigint,
 counterpart_file_sha256 text CHECK(counterpart_file_sha256 IS NULL OR counterpart_file_sha256~'^[0-9a-f]{64}$'),
 CHECK(approved_by IS NULL OR approved_by<>submitted_by),
 CHECK(status NOT IN('INTERNAL_CONFIRMED','BOTH_CONFIRMED') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
 CHECK((status='BOTH_CONFIRMED')=(counterpart_received_by IS NOT NULL AND counterpart_name IS NOT NULL AND counterpart_confirmed_date IS NOT NULL
   AND counterpart_file_provider IS NOT NULL AND counterpart_file_key IS NOT NULL AND counterpart_file_size>0 AND counterpart_file_sha256 IS NOT NULL))
);
CREATE INDEX idx_finance_statement_profile_scope ON finance_statement_profiles(kind,template_key,party_id,currency_id,status,revision DESC);
CREATE INDEX idx_finance_statement_review_scope ON finance_statement_document_reviews(template_key,party_id,currency_id,date_to,id);
CREATE FUNCTION fn_guard_finance_statement_profile_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN RETURN NEW;END IF;
 IF TG_OP='UPDATE' AND OLD.status='SUBMITTED' AND NEW.status IN('APPROVED','REJECTED')
   AND (to_jsonb(NEW)-ARRAY['status','reviewed_by','reviewed_name','reviewed_at','review_reason'])=(to_jsonb(OLD)-ARRAY['status','reviewed_by','reviewed_name','reviewed_at','review_reason']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'statement profile source versions cannot be overwritten; submit another reviewed version' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_finance_statement_profile_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_statement_profiles FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_statement_profile_immutable();
CREATE FUNCTION fn_guard_finance_statement_review_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN RETURN NEW;END IF;
 IF TG_OP='UPDATE' AND (to_jsonb(NEW)-ARRAY['status','approved_by','approved_name','approved_at','review_reason','counterpart_name','counterpart_confirmed_date',
   'counterpart_received_by','counterpart_received_name','counterpart_received_at','counterpart_source_reference','counterpart_file_name','counterpart_file_content_type','counterpart_file_provider','counterpart_file_key','counterpart_file_version','counterpart_file_size','counterpart_file_sha256'])
   =(to_jsonb(OLD)-ARRAY['status','approved_by','approved_name','approved_at','review_reason','counterpart_name','counterpart_confirmed_date',
   'counterpart_received_by','counterpart_received_name','counterpart_received_at','counterpart_source_reference','counterpart_file_name','counterpart_file_content_type','counterpart_file_provider','counterpart_file_key','counterpart_file_version','counterpart_file_size','counterpart_file_sha256'])
   AND ((OLD.status='SUBMITTED' AND NEW.status IN('INTERNAL_CONFIRMED','REJECTED','CANCELLED'))
     OR(OLD.status='INTERNAL_CONFIRMED' AND NEW.status IN('BOTH_CONFIRMED','CANCELLED'))) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'statement source snapshot or confirmations cannot be overwritten' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_finance_statement_review_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_statement_document_reviews FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_statement_review_immutable();
CREATE TRIGGER trg_audit_finance_statement_profiles AFTER INSERT OR UPDATE OR DELETE ON finance_statement_profiles FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_statement_reviews AFTER INSERT OR UPDATE OR DELETE ON finance_statement_document_reviews FOR EACH ROW EXECUTE FUNCTION fn_audit();
