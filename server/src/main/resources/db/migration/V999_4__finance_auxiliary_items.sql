-- Financial auxiliary identities retain their source book/code/name separately from ERP party UUIDs.
CREATE TABLE finance_auxiliary_parties (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), source_system text NOT NULL,
    source_code text NOT NULL, source_name text NOT NULL,
    row_version bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL REFERENCES users(id),
    updated_by uuid NOT NULL REFERENCES users(id), UNIQUE(source_system,source_code),
    CHECK(length(btrim(source_system)) BETWEEN 1 AND 80),
    CHECK(length(btrim(source_code)) BETWEEN 1 AND 240),CHECK(length(btrim(source_name)) BETWEEN 1 AND 240)
);
CREATE TABLE finance_auxiliary_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), source_system text NOT NULL,
    source_code text NOT NULL, source_name text NOT NULL,
    role text NOT NULL CHECK(role IN('CUSTOMER','SUPPLIER','EMPLOYEE','OTHER')),
    party_id uuid, client_id uuid REFERENCES clients(id), supplier_id uuid REFERENCES suppliers(id),
    employee_id uuid REFERENCES employees(id), financial_party_id uuid REFERENCES finance_auxiliary_parties(id),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK(status IN('ACTIVE','ARCHIVED')),
    source_reference text, row_version bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid NOT NULL REFERENCES users(id), updated_by uuid NOT NULL REFERENCES users(id),
    UNIQUE(source_system,role,source_code),CHECK(length(btrim(source_system)) BETWEEN 1 AND 80),
    CHECK(length(btrim(source_code)) BETWEEN 1 AND 240),CHECK(length(btrim(source_name)) BETWEEN 1 AND 240),
    CONSTRAINT finance_auxiliary_items_party_shape CHECK (
        (party_id IS NULL AND num_nonnulls(client_id,supplier_id,employee_id,financial_party_id)=0)
        OR (party_id IS NOT NULL AND num_nonnulls(client_id,supplier_id,employee_id,financial_party_id)=1 AND (
            (role='CUSTOMER' AND client_id IS NOT NULL AND client_id=party_id)
            OR (role='SUPPLIER' AND supplier_id IS NOT NULL AND supplier_id=party_id)
            OR (role='EMPLOYEE' AND employee_id IS NOT NULL AND employee_id=party_id)
            OR (role='OTHER' AND financial_party_id IS NOT NULL AND financial_party_id=party_id))))
);
CREATE INDEX idx_finance_auxiliary_items_party ON finance_auxiliary_items(role,party_id) WHERE party_id IS NOT NULL;
CREATE TABLE finance_account_auxiliary_rules (
    account_code text PRIMARY KEY REFERENCES finance_chart_codes(code), required boolean NOT NULL,
    allowed_roles text[] NOT NULL CHECK(allowed_roles <@ ARRAY['CUSTOMER','SUPPLIER','EMPLOYEE','OTHER']::text[]),
    source_reference text NOT NULL, row_version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid NOT NULL REFERENCES users(id)
);
CREATE TABLE finance_account_auxiliary_bindings (
    account_code text NOT NULL REFERENCES finance_chart_codes(code), auxiliary_id uuid NOT NULL REFERENCES finance_auxiliary_items(id),
    created_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL REFERENCES users(id),
    PRIMARY KEY(account_code,auxiliary_id)
);
CREATE TRIGGER trg_audit_finance_auxiliary_parties AFTER INSERT OR UPDATE OR DELETE ON finance_auxiliary_parties
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_auxiliary_items AFTER INSERT OR UPDATE OR DELETE ON finance_auxiliary_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_account_auxiliary_rules AFTER INSERT OR UPDATE OR DELETE ON finance_account_auxiliary_rules
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_account_auxiliary_bindings AFTER INSERT OR UPDATE OR DELETE ON finance_account_auxiliary_bindings
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_auxiliary_parties ENABLE ALWAYS TRIGGER trg_audit_finance_auxiliary_parties;
ALTER TABLE finance_auxiliary_items ENABLE ALWAYS TRIGGER trg_audit_finance_auxiliary_items;
ALTER TABLE finance_account_auxiliary_rules ENABLE ALWAYS TRIGGER trg_audit_finance_account_auxiliary_rules;
ALTER TABLE finance_account_auxiliary_bindings ENABLE ALWAYS TRIGGER trg_audit_finance_account_auxiliary_bindings;

ALTER TABLE finance_gl_entry_allocations ADD CONSTRAINT finance_gl_entry_allocations_auxiliary_fk
    FOREIGN KEY(auxiliary_id) REFERENCES finance_auxiliary_items(id);
ALTER TABLE finance_gl_auxiliary_opening_evidence ADD CONSTRAINT finance_gl_aux_opening_auxiliary_fk
    FOREIGN KEY(auxiliary_id) REFERENCES finance_auxiliary_items(id);
ALTER TABLE finance_gl_entry_allocations ADD CONSTRAINT finance_gl_alloc_auxiliary_currency
    CHECK(auxiliary_id IS NULL OR currency_id IS NOT NULL);

-- Every new source snapshot must agree with the immutable auxiliary identity, even if a caller bypasses its port.
CREATE OR REPLACE FUNCTION fn_finance_auxiliary_snapshot_reference()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE auxiliary finance_auxiliary_items%ROWTYPE; must_have boolean; roles text[];
BEGIN
    must_have:=left(NEW.account_code,4) IN('1122','2202','1123','2203','1221','2241','2701');
    SELECT required OR must_have,allowed_roles INTO must_have,roles
        FROM finance_account_auxiliary_rules WHERE account_code=NEW.account_code;
    IF NOT FOUND THEN
        must_have:=left(NEW.account_code,4) IN('1122','2202','1123','2203','1221','2241','2701');
        roles:=CASE WHEN left(NEW.account_code,4) IN('1122','2203') THEN ARRAY['CUSTOMER']
                    WHEN left(NEW.account_code,4) IN('2202','1123') THEN ARRAY['SUPPLIER']
                    ELSE ARRAY['CUSTOMER','SUPPLIER','EMPLOYEE','OTHER'] END;
    END IF;
    IF NEW.auxiliary_id IS NULL THEN
        IF must_have THEN RAISE EXCEPTION '应收应付科目必须设置已核验的辅助核算项目' USING ERRCODE='23514'; END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO auxiliary FROM finance_auxiliary_items WHERE id=NEW.auxiliary_id FOR SHARE;
    IF NOT FOUND OR auxiliary.status<>'ACTIVE' OR auxiliary.party_id IS NULL THEN
        RAISE EXCEPTION '辅助项目未对应有效业务对象，只能保存草稿' USING ERRCODE='23514';
    END IF;
    IF NEW.currency_id IS NULL OR NOT(NEW.auxiliary_role=ANY(roles))
        OR (NEW.auxiliary_role,NEW.party_id_snapshot,NEW.source_system,NEW.source_code)
            IS DISTINCT FROM (auxiliary.role,auxiliary.party_id,auxiliary.source_system,auxiliary.source_code) THEN
        RAISE EXCEPTION '辅助项目类别、业务UUID、原账套或原编号与引用快照不一致' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_finance_gl_allocation_auxiliary_reference BEFORE INSERT OR UPDATE ON finance_gl_entry_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_finance_auxiliary_snapshot_reference();
CREATE TRIGGER trg_finance_gl_opening_auxiliary_reference BEFORE INSERT OR UPDATE ON finance_gl_auxiliary_opening_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_finance_auxiliary_snapshot_reference();
ALTER TABLE finance_gl_entry_allocations ENABLE ALWAYS TRIGGER trg_finance_gl_allocation_auxiliary_reference;
ALTER TABLE finance_gl_auxiliary_opening_evidence ENABLE ALWAYS TRIGGER trg_finance_gl_opening_auxiliary_reference;
CREATE OR REPLACE FUNCTION fn_guard_posted_finance_auxiliary_identity()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        IF EXISTS(SELECT 1 FROM finance_gl_entry_allocations WHERE auxiliary_id=OLD.id)
           OR EXISTS(SELECT 1 FROM finance_gl_auxiliary_opening_evidence WHERE auxiliary_id=OLD.id) THEN
            RAISE EXCEPTION '辅助项目已有会计分录引用，不能删除；须走受控更正';
        END IF;
        RETURN OLD;
    END IF;
    IF (NEW.source_system,NEW.source_code,NEW.role,NEW.party_id)
        IS DISTINCT FROM (OLD.source_system,OLD.source_code,OLD.role,OLD.party_id) THEN
        IF EXISTS(SELECT 1 FROM finance_gl_entry_allocations WHERE auxiliary_id=OLD.id)
           OR EXISTS(SELECT 1 FROM finance_gl_auxiliary_opening_evidence WHERE auxiliary_id=OLD.id) THEN
            RAISE EXCEPTION '辅助项目已有会计分录引用，不能更换账套、原编号、类别或业务对象；须走受控更正';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_posted_finance_auxiliary_identity BEFORE UPDATE OR DELETE ON finance_auxiliary_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_posted_finance_auxiliary_identity();
ALTER TABLE finance_auxiliary_items ENABLE ALWAYS TRIGGER trg_guard_posted_finance_auxiliary_identity;
