-- V398: audited idempotent offboarding and current-responsibility race guards.

-- client:assign is a responsibility-management action, not a synonym for ordinary
-- customer editing. V393 copied it to every legacy client editor for continuity;
-- remove those broad department/role grants before the migration set is released.
-- Super administrators retain the platform bypass and managers can receive an
-- explicit personal grant through permission overrides.
DELETE FROM department_permissions assignment
USING permissions permission
WHERE assignment.permission_id = permission.id
  AND permission.code = 'client:assign';

DELETE FROM role_permissions assignment
USING permissions permission
WHERE assignment.permission_id = permission.id
  AND permission.code = 'client:assign';

-- One unified user_data_scopes trigger validates recipient and visible owner in
-- canonical employee UUID order, then locks/revalidates the recipient account.
-- This prevents A->B / B->A scope writes from taking employee rows in reverse order.
ALTER TABLE user_data_scopes
    ADD COLUMN owner_employment_generation BIGINT;

UPDATE user_data_scopes data_scope
SET owner_employment_generation=(
    SELECT count(*) FROM employment_history history
    WHERE history.employee_id=data_scope.owner_employee_id
      AND history.event_type='rehire'
      AND history.created_at<=data_scope.created_at);

ALTER TABLE user_data_scopes
    ALTER COLUMN owner_employment_generation SET NOT NULL;

ALTER TABLE user_data_scopes
    ADD CONSTRAINT user_data_scopes_owner_generation_chk
        CHECK (owner_employment_generation >= 0);

COMMENT ON COLUMN user_data_scopes.owner_employment_generation IS
    'Owner rehire-count generation; stale prior-employment grants remain audit facts but confer no access';

DROP TRIGGER IF EXISTS trg_user_data_scopes_00_owner_current_employee
    ON user_data_scopes;
DROP TRIGGER IF EXISTS trg_user_data_scopes_current_recipient
    ON user_data_scopes;

CREATE OR REPLACE FUNCTION fn_require_current_data_scope_pair()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_initial_recipient UUID;
    v_locked_ids UUID[];
    v_row RECORD;
    v_seen INTEGER := 0;
    v_user_employee_id UUID;
    v_user_status TEXT;
    v_user_deleted BOOLEAN;
    v_owner_generation BIGINT;
BEGIN
    SELECT account.employee_id
    INTO v_initial_recipient
    FROM users account
    WHERE account.id=NEW.user_id
      AND account.is_deleted=FALSE;

    IF v_initial_recipient IS NULL OR NEW.owner_employee_id IS NULL THEN
        RAISE EXCEPTION 'data scope recipient and owner must exist'
            USING ERRCODE='23514',
                  CONSTRAINT='user_data_scopes_current_pair';
    END IF;

    SELECT array_agg(employee_id ORDER BY employee_id)
    INTO v_locked_ids
    FROM (
        SELECT DISTINCT unnest(
            ARRAY[v_initial_recipient, NEW.owner_employee_id]::UUID[]) AS employee_id
    ) canonical;

    FOR v_row IN
        SELECT employee.id, employee.status
        FROM employees employee
        WHERE employee.id=ANY(v_locked_ids)
          AND employee.is_deleted=FALSE
        ORDER BY employee.id
        FOR SHARE OF employee
    LOOP
        v_seen := v_seen + 1;
        IF v_row.id=v_initial_recipient
           AND v_row.status NOT IN ('active','probation','onLeave') THEN
            RAISE EXCEPTION 'data scope recipient must be a current employee'
                USING ERRCODE='23514',
                      CONSTRAINT='user_data_scopes_current_pair';
        END IF;
    END LOOP;
    IF v_seen <> cardinality(v_locked_ids) THEN
        RAISE EXCEPTION 'data scope recipient/owner employee must exist'
            USING ERRCODE='23514',
                  CONSTRAINT='user_data_scopes_current_pair';
    END IF;

    SELECT count(*)
    INTO v_owner_generation
    FROM employment_history history
    WHERE history.employee_id=NEW.owner_employee_id
      AND history.event_type='rehire';
    NEW.owner_employment_generation:=v_owner_generation;

    SELECT account.employee_id, account.status, account.is_deleted
    INTO v_user_employee_id, v_user_status, v_user_deleted
    FROM users account
    WHERE account.id=NEW.user_id
    FOR SHARE OF account;

    IF v_user_employee_id IS DISTINCT FROM v_initial_recipient
       OR v_user_status IS DISTINCT FROM 'active'
       OR v_user_deleted IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'data-scope recipient must have an active account'
            USING ERRCODE='23514',
                  CONSTRAINT='user_data_scopes_current_pair';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_user_data_scopes_current_pair
BEFORE INSERT OR UPDATE OF user_id, owner_employee_id, owner_employment_generation
ON user_data_scopes
FOR EACH ROW EXECUTE FUNCTION fn_require_current_data_scope_pair();

-- Reactivating a previously revoked per-client viewer row updates active rather
-- than grantee_employee_id, so the V393 generic UPDATE OF grantee trigger cannot
-- protect that path. This dedicated guard checks every real activation, locks
-- employee before user, and requires an active login account.
CREATE OR REPLACE FUNCTION fn_require_current_client_visibility_grantee()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_status TEXT;
    v_account_id UUID;
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.grantee_employee_id IS NOT DISTINCT FROM OLD.grantee_employee_id
       AND NEW.active IS NOT DISTINCT FROM OLD.active THEN
        RETURN NEW;
    END IF;
    IF NEW.active IS NOT TRUE THEN
        RETURN NEW;
    END IF;

    SELECT employee.status
    INTO v_status
    FROM employees employee
    WHERE employee.id = NEW.grantee_employee_id
      AND employee.is_deleted = FALSE
    FOR SHARE OF employee;

    IF v_status IS NULL OR v_status NOT IN ('active', 'probation', 'onLeave') THEN
        RAISE EXCEPTION 'client viewer must be a current employee'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'client_visibility_grants_current_grantee';
    END IF;

    SELECT account.id
    INTO v_account_id
    FROM users account
    WHERE account.employee_id = NEW.grantee_employee_id
      AND account.is_deleted = FALSE
      AND account.status = 'active'
    ORDER BY account.id
    LIMIT 1
    FOR SHARE OF account;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'client viewer must have an active account'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'client_visibility_grants_current_grantee';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER trg_client_visibility_grantee_current_employee
    ON client_visibility_grants;

CREATE TRIGGER trg_client_visibility_grantee_current_employee
BEFORE INSERT OR UPDATE OF grantee_employee_id, active ON client_visibility_grants
FOR EACH ROW EXECUTE FUNCTION fn_require_current_client_visibility_grantee();

-- Pending attachment upload sessions are user capabilities. Lock the bound
-- employee before the account, and refuse creation/reactivation after offboard.
CREATE OR REPLACE FUNCTION fn_require_current_attachment_upload_user()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_initial_employee UUID;
    v_employee_status TEXT;
    v_locked_employee UUID;
    v_account_status TEXT;
    v_account_deleted BOOLEAN;
BEGIN
    IF NEW.status NOT IN ('PENDING','SCANNING') THEN
        RETURN NEW;
    END IF;
    SELECT account.employee_id
    INTO v_initial_employee
    FROM users account
    WHERE account.id=NEW.user_id AND account.is_deleted=FALSE;
    IF v_initial_employee IS NULL THEN
        RAISE EXCEPTION 'attachment upload user must exist'
            USING ERRCODE='23514',
                  CONSTRAINT='attachment_upload_sessions_current_user';
    END IF;

    SELECT employee.status
    INTO v_employee_status
    FROM employees employee
    WHERE employee.id=v_initial_employee AND employee.is_deleted=FALSE
    FOR SHARE OF employee;
    IF v_employee_status IS NULL
       OR v_employee_status NOT IN ('active','probation','onLeave') THEN
        RAISE EXCEPTION 'attachment upload user must be a current employee'
            USING ERRCODE='23514',
                  CONSTRAINT='attachment_upload_sessions_current_user';
    END IF;

    SELECT account.employee_id, account.status, account.is_deleted
    INTO v_locked_employee, v_account_status, v_account_deleted
    FROM users account
    WHERE account.id=NEW.user_id
    FOR SHARE OF account;
    IF v_locked_employee IS DISTINCT FROM v_initial_employee
       OR v_account_status IS DISTINCT FROM 'active'
       OR v_account_deleted IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'attachment upload user must have an active account'
            USING ERRCODE='23514',
                  CONSTRAINT='attachment_upload_sessions_current_user';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_attachment_upload_sessions_current_user
BEFORE INSERT OR UPDATE OF user_id, status ON attachment_upload_sessions
FOR EACH ROW EXECUTE FUNCTION fn_require_current_attachment_upload_user();

-- Handover reasons are one 1-2000 character contract. V394's original 1000
-- limit is widened forward; V394 bytes remain immutable.
ALTER TABLE client_access_change_events
    DROP CONSTRAINT client_access_change_events_reason_chk;
ALTER TABLE client_access_change_events
    ADD CONSTRAINT client_access_change_events_reason_chk
        CHECK (btrim(reason) <> '' AND char_length(reason) <= 2000) NOT VALID;
ALTER TABLE client_access_change_events
    VALIDATE CONSTRAINT client_access_change_events_reason_chk;

-- One durable idempotency/audit row covers the entire offboarding transaction,
-- including zero-business-data departures and response-loss retries.
CREATE TABLE employee_offboarding_events (
    id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id                    UUID NOT NULL UNIQUE,
    employee_id                   UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    employment_generation        BIGINT NOT NULL,
    default_successor_employee_id UUID REFERENCES employees(id) ON DELETE RESTRICT,
    default_successor_employment_generation BIGINT,
    effective_date                DATE NOT NULL,
    resign_type                   TEXT NOT NULL,
    reason                        TEXT NOT NULL,
    handover_reason               TEXT NOT NULL,
    checklist_codes               TEXT[] NOT NULL,
    status                        TEXT NOT NULL,
    result_summary                JSONB NOT NULL DEFAULT '{}'::JSONB,
    actor_user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at                  TIMESTAMPTZ,
    CONSTRAINT employee_offboarding_events_generation_chk
        CHECK (employment_generation >= 0
           AND ((default_successor_employee_id IS NULL
                 AND default_successor_employment_generation IS NULL)
             OR (default_successor_employee_id IS NOT NULL
                 AND default_successor_employment_generation IS NOT NULL
                 AND default_successor_employment_generation >= 0))),
    CONSTRAINT employee_offboarding_events_type_chk
        CHECK (resign_type IN ('VOLUNTARY','DISMISSED','CONTRACT_END','RETIRE')),
    CONSTRAINT employee_offboarding_events_reason_chk
        CHECK (btrim(reason) <> '' AND char_length(reason) <= 2000
           AND btrim(handover_reason) <> '' AND char_length(handover_reason) <= 2000),
    CONSTRAINT employee_offboarding_events_status_chk
        CHECK (status IN ('EXECUTING','COMPLETED')),
    CONSTRAINT employee_offboarding_events_completion_chk
        CHECK ((status='COMPLETED') = (completed_at IS NOT NULL)),
    CONSTRAINT employee_offboarding_events_checklist_chk CHECK (
        cardinality(checklist_codes)=4
        AND checklist_codes <@ ARRAY[
            'ACCESS_CARD_RETURNED',
            'COMPANY_ASSETS_ACCOUNTED',
            'ACCOUNT_DISABLE_ACKNOWLEDGED',
            'SOCIAL_BENEFITS_ARRANGED']::TEXT[]
        AND ARRAY[
            'ACCESS_CARD_RETURNED',
            'COMPANY_ASSETS_ACCOUNTED',
            'ACCOUNT_DISABLE_ACKNOWLEDGED',
            'SOCIAL_BENEFITS_ARRANGED']::TEXT[] <@ checklist_codes)
);

CREATE INDEX idx_employee_offboarding_events_employee
    ON employee_offboarding_events(employee_id, created_at DESC);

CREATE OR REPLACE FUNCTION fn_guard_employee_offboarding_event_state()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'employee offboarding events are append-only'
            USING ERRCODE='55000';
    END IF;
    IF OLD.status='EXECUTING'
       AND NEW.status='COMPLETED'
       AND (to_jsonb(NEW) - ARRAY['status','result_summary','completed_at']::TEXT[])
           = (to_jsonb(OLD) - ARRAY['status','result_summary','completed_at']::TEXT[]) THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'employee offboarding event is immutable after creation'
        USING ERRCODE='55000';
END;
$$;

CREATE TRIGGER trg_employee_offboarding_events_state
BEFORE UPDATE OR DELETE ON employee_offboarding_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_offboarding_event_state();

CREATE TRIGGER trg_audit_employee_offboarding_events
AFTER INSERT OR UPDATE OR DELETE ON employee_offboarding_events
FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Employment history is the durable employment-generation authority used by
-- offboarding replay. Application services only append; enforce that invariant
-- in PostgreSQL as well, and prevent the legacy employee CASCADE from erasing it.
CREATE OR REPLACE FUNCTION fn_reject_employment_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'employment history is append-only'
        USING ERRCODE='55000';
END;
$$;

CREATE TRIGGER trg_employment_history_append_only
BEFORE UPDATE OR DELETE ON employment_history
FOR EACH ROW EXECUTE FUNCTION fn_reject_employment_history_mutation();

-- Generic strict guard for a responsibility that is active because of status.
-- Unlike fn_require_current_employee_reference, it deliberately revalidates an
-- unchanged employee id when another column reactivates the responsibility.
CREATE OR REPLACE FUNCTION fn_require_current_employee_reference_strict()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_column TEXT := TG_ARGV[0];
    v_employee_id UUID := NULLIF(to_jsonb(NEW)->>v_column,'')::UUID;
    v_status TEXT;
BEGIN
    IF v_employee_id IS NULL THEN RETURN NEW; END IF;
    SELECT employee.status
    INTO v_status
    FROM employees employee
    WHERE employee.id=v_employee_id
      AND employee.is_deleted=FALSE
    FOR SHARE OF employee;
    IF v_status IS NULL OR v_status NOT IN ('active','probation','onLeave') THEN
        RAISE EXCEPTION 'responsibility target must be a current employee'
            USING ERRCODE='23514',
                  CONSTRAINT=TG_TABLE_NAME || '_' || v_column || '_current_employee';
    END IF;
    RETURN NEW;
END;
$$;

-- V393's changed-column guards preserve historical rows, but a soft-deleted
-- responsibility restored without changing its employee id must be revalidated.
DROP TRIGGER trg_clients_owner_current_employee ON clients;
CREATE TRIGGER trg_clients_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id, is_deleted ON clients
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE AND NEW.owner_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('owner_employee_id');

DROP TRIGGER trg_goods_owner_current_employee ON goods;
CREATE TRIGGER trg_goods_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id, is_deleted ON goods
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE AND NEW.owner_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('owner_employee_id');

DROP TRIGGER trg_suppliers_owner_current_employee ON suppliers;
CREATE TRIGGER trg_suppliers_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id, is_deleted ON suppliers
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE AND NEW.owner_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('owner_employee_id');

DROP TRIGGER trg_moulds_keeper_current_employee ON moulds;
CREATE TRIGGER trg_moulds_keeper_current_employee
BEFORE INSERT OR UPDATE OF keeper_id, is_deleted ON moulds
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE AND NEW.keeper_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('keeper_id');

CREATE TRIGGER trg_departments_manager_current_employee
BEFORE INSERT OR UPDATE OF manager_id, is_deleted ON departments
FOR EACH ROW
WHEN (NEW.manager_id IS NOT NULL AND NEW.is_deleted=FALSE)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('manager_id');

CREATE TRIGGER trg_employees_supervisor_current_employee
BEFORE INSERT OR UPDATE OF supervisor_id, is_deleted ON employees
FOR EACH ROW
WHEN (NEW.supervisor_id IS NOT NULL AND NEW.is_deleted=FALSE)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('supervisor_id');

CREATE TRIGGER trg_supplier_return_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id, status ON supplier_return_tasks
FOR EACH ROW
WHEN (NEW.status='PENDING_RETURN')
EXECUTE FUNCTION fn_require_current_employee_reference_strict('owner_employee_id');

CREATE TRIGGER trg_inbound_expectation_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id, status ON inbound_expectations
FOR EACH ROW
WHEN (NEW.status='OPEN' AND NEW.owner_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('owner_employee_id');

CREATE TRIGGER trg_arrival_exception_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id, status ON procurement_arrival_exceptions
FOR EACH ROW
WHEN (NEW.status NOT IN ('CLOSED','CANCELED') AND NEW.owner_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('owner_employee_id');

CREATE TRIGGER trg_website_inquiry_assignee_current_employee
BEFORE INSERT OR UPDATE OF assignee_employee_id, status ON website_inquiries
FOR EACH ROW
WHEN (NEW.status IN ('new','following') AND NEW.assignee_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('assignee_employee_id');

CREATE TRIGGER trg_visitor_host_current_employee
BEFORE INSERT OR UPDATE OF host_employee_id, status, planned_visit_at, is_deleted
ON visitor_applications
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE
      AND NEW.status IN ('pending','hostReviewing','approved')
      AND NEW.planned_visit_at>CURRENT_TIMESTAMP
      AND NEW.host_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('host_employee_id');

CREATE TRIGGER trg_rd_task_assignee_current_employee
BEFORE INSERT OR UPDATE OF assignee_employee_id, status, is_deleted ON rd_tasks
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE AND NEW.status IN ('OPEN','IN_PROGRESS')
      AND NEW.assignee_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('assignee_employee_id');

CREATE TRIGGER trg_execution_segment_responsible_current_employee
BEFORE INSERT OR UPDATE OF responsible_employee_id, status, is_deleted
ON production_execution_segments
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE
      AND NEW.status IN ('READY','WAITING','DISPATCHED','IN_PROGRESS')
      AND NEW.responsible_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('responsible_employee_id');

CREATE TRIGGER trg_fixed_asset_custodian_current_employee
BEFORE INSERT OR UPDATE OF custodian_employee_id, lifecycle_status, is_deleted
ON fixed_assets
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE AND NEW.lifecycle_status<>'DISPOSED'
      AND NEW.custodian_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('custodian_employee_id');

CREATE TRIGGER trg_deferred_expense_responsible_current_employee
BEFORE INSERT OR UPDATE OF responsible_employee_id, lifecycle_status, is_deleted
ON deferred_expenses
FOR EACH ROW
WHEN (NEW.is_deleted=FALSE
      AND NEW.lifecycle_status NOT IN ('COMPLETED','TERMINATED')
      AND NEW.responsible_employee_id IS NOT NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('responsible_employee_id');

CREATE TRIGGER trg_task_claim_claimer_current_employee
BEFORE INSERT OR UPDATE OF claimed_by, released_at ON task_claims
FOR EACH ROW
WHEN (NEW.released_at IS NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('claimed_by');

CREATE TRIGGER trg_hr_task_claim_claimer_current_employee
BEFORE INSERT OR UPDATE OF claimed_by, released_at ON hr_task_claims
FOR EACH ROW
WHEN (NEW.released_at IS NULL)
EXECUTE FUNCTION fn_require_current_employee_reference_strict('claimed_by');

-- production_plans carries three employee ids. Lock all applicable new targets
-- once in sorted UUID order so one row update cannot deadlock via per-column triggers.
CREATE OR REPLACE FUNCTION fn_guard_production_plan_employee_refs()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ids UUID[] := ARRAY[]::UUID[];
    v_row RECORD;
    v_seen INTEGER := 0;
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.maker_id IS NOT NULL THEN v_ids:=array_append(v_ids,NEW.maker_id); END IF;
    ELSIF NEW.maker_id IS DISTINCT FROM OLD.maker_id THEN
        IF NEW.maker_id IS NOT NULL THEN v_ids:=array_append(v_ids,NEW.maker_id); END IF;
    END IF;
    IF NEW.status=0 AND NEW.is_deleted=FALSE THEN
        IF NEW.seller_id IS NOT NULL THEN v_ids:=array_append(v_ids,NEW.seller_id); END IF;
        IF NEW.worker_id IS NOT NULL THEN v_ids:=array_append(v_ids,NEW.worker_id); END IF;
    END IF;
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::UUID[])
    INTO v_ids
    FROM (SELECT DISTINCT unnest(v_ids) AS id) canonical;
    IF cardinality(v_ids)=0 THEN RETURN NEW; END IF;

    FOR v_row IN
        SELECT employee.id, employee.status
        FROM employees employee
        WHERE employee.id=ANY(v_ids) AND employee.is_deleted=FALSE
        ORDER BY employee.id
        FOR SHARE OF employee
    LOOP
        v_seen:=v_seen+1;
        IF v_row.status NOT IN ('active','probation','onLeave') THEN
            RAISE EXCEPTION 'production plan responsibility target must be current'
                USING ERRCODE='23514',
                      CONSTRAINT='production_plans_employee_refs_current';
        END IF;
    END LOOP;
    IF v_seen<>cardinality(v_ids) THEN
        RAISE EXCEPTION 'production plan responsibility target must be current'
            USING ERRCODE='23514',
                  CONSTRAINT='production_plans_employee_refs_current';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_production_plan_employee_refs_current
BEFORE INSERT OR UPDATE OF maker_id, seller_id, worker_id, status, is_deleted
ON production_plans
FOR EACH ROW EXECUTE FUNCTION fn_guard_production_plan_employee_refs();

-- Historical actor ids remain immutable in services, but inserts or explicit
-- reassignment must not nominate an already departed employee.
CREATE TRIGGER trg_sales_quotes_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON sales_quotes
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_sales_orders_owner_current
BEFORE INSERT OR UPDATE OF owner_employee_id ON sales_orders
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('owner_employee_id');
CREATE TRIGGER trg_sales_shipments_owner_current
BEFORE INSERT OR UPDATE OF owner_employee_id ON sales_shipments
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('owner_employee_id');
CREATE TRIGGER trg_sales_other_shipments_owner_current
BEFORE INSERT OR UPDATE OF owner_employee_id ON sales_other_shipments
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('owner_employee_id');
CREATE TRIGGER trg_sales_returns_owner_current
BEFORE INSERT OR UPDATE OF owner_employee_id ON sales_returns
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('owner_employee_id');

CREATE TRIGGER trg_finance_payments_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON finance_payments
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_finance_receipts_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON finance_receipts
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_finance_expenses_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON finance_expenses
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_finance_bank_transfers_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON finance_bank_transfers
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_finance_other_incomes_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON finance_other_incomes
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');

CREATE TRIGGER trg_purchase_orders_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON purchase_orders
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_purchase_receipts_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON purchase_receipts
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_purchase_returns_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON purchase_returns
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');

CREATE TRIGGER trg_subcontract_orders_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON subcontract_orders
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_subcontract_inquiries_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON subcontract_inquiries
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_subcontract_material_issues_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON subcontract_material_issues
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_subcontract_material_returns_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON subcontract_material_returns
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_subcontract_receipts_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON subcontract_receipts
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_subcontract_returns_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON subcontract_returns
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_subcontract_wastes_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON subcontract_wastes
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');

CREATE TRIGGER trg_production_daily_reports_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON production_daily_reports
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_production_analyses_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON production_material_analyses
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_stock_documents_maker_current
BEFORE INSERT OR UPDATE OF maker_id ON stock_documents
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');

-- Install HR reason redaction before the metadata backfills below UPDATE
-- employee_data_handovers and therefore fire its existing audit trigger.
CREATE OR REPLACE FUNCTION fn_audit_redact_row(
    p_table_name TEXT,
    p_row JSONB
) RETURNS JSONB AS $$
DECLARE
    v_row JSONB;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    v_row := p_row - ARRAY[
        'password_hash', 'token_hash', 'preview_token_hash', 'code_hash', 'secret',
        'id_card_enc', 'id_card_hash', 'phone_enc', 'phone_hash',
        'phone', 'phone2', 'link_phone', 'office_phone', 'email',
        'address', 'ship_address', 'huji_address', 'residence_address',
        'bank_account_enc', 'bank_branch_enc', 'bank_account', 'bank_account_no',
        'base_salary_enc', 'perf_salary_enc', 'social_insurance_base_enc',
        'housing_fund_base_enc', 'allowance_standard_enc',
        'old_value_enc', 'new_value_enc', 'plate_no_enc', 'qr_token', 'passcode',
        'content', 'body', 'message', 'description', 'remark', 'remarks',
        'note', 'comment', 'reject_reason', 'last_rejection_reason',
        'close_reason', 'reopen_reason', 'reversal_reason', 'location_text',
        'payload', 'exception_snapshot', 'calculation_snapshot',
        'required_document_codes', 'required_document_codes_snapshot',
        'source_ref', 'source_line_ref', 'linkman', 'legal_person',
        'ground_graph', 'product_graph1', 'product_graph2', 'product_graph3',
        'product_graph4', 'product_graph5', 'product_graph6', 'budget_graph'
    ];

    IF p_table_name = 'employees' THEN
        v_row := v_row - ARRAY[
            'full_name', 'gender', 'id_type', 'birth_date', 'ethnicity',
            'political_status', 'marital_status', 'paper_archive_no'
        ];
    ELSIF p_table_name = 'employee_compensation' THEN
        v_row := v_row - 'social_insurance_location';
    ELSIF p_table_name = 'emergency_contacts' THEN
        v_row := v_row - ARRAY['name', 'relationship'];
    ELSIF p_table_name = 'visitor_accounts' THEN
        v_row := v_row - 'name';
    ELSIF p_table_name = 'visitor_applications' THEN
        v_row := v_row - ARRAY['visitor_name', 'company', 'visit_purpose', 'plate_no'];
    ELSIF p_table_name = 'profile_change_requests' THEN
        v_row := v_row - 'review_comment';
    ELSIF p_table_name = 'employee_data_handovers' THEN
        v_row := v_row - 'reason';
    ELSIF p_table_name = 'employee_offboarding_events' THEN
        v_row := v_row - ARRAY['reason', 'handover_reason'];
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Requested scopes are the idempotency/audit command snapshot. The child table
-- contains only scopes with actual business responsibility/history authority;
-- release-only or empty selected scopes never create future-routing graph edges.
CREATE OR REPLACE FUNCTION fn_text_array_has_unique_members(p_values TEXT[])
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT COALESCE(
        cardinality(p_values) = count(DISTINCT member),
        FALSE)
    FROM unnest(p_values) member
$$;

ALTER TABLE employee_data_handovers
    ADD COLUMN requested_scopes TEXT[];

ALTER TABLE employee_data_handovers
    ADD COLUMN source_employment_generation BIGINT;
ALTER TABLE employee_data_handovers ADD COLUMN target_employment_generation BIGINT;

UPDATE employee_data_handovers handover
SET source_employment_generation=(
    SELECT count(*)
    FROM employment_history history
    WHERE history.employee_id=handover.source_employee_id
      AND history.event_type='rehire'
      AND history.created_at<=handover.created_at);
UPDATE employee_data_handovers handover
SET target_employment_generation=(
    SELECT count(*)
    FROM employment_history history
    WHERE history.employee_id=handover.target_employee_id
      AND history.event_type='rehire'
      AND history.created_at<=handover.created_at);

ALTER TABLE employee_data_handovers
    ALTER COLUMN source_employment_generation SET NOT NULL;
ALTER TABLE employee_data_handovers
    ALTER COLUMN target_employment_generation SET NOT NULL;

ALTER TABLE employee_data_handovers
    ADD CONSTRAINT employee_data_handovers_generation_chk
        CHECK (source_employment_generation >= 0
           AND target_employment_generation >= 0);

COMMENT ON COLUMN employee_data_handovers.source_employment_generation IS
    'Source rehire-count generation; only edges matching the current employment generation are authoritative';
COMMENT ON COLUMN employee_data_handovers.target_employment_generation IS
    'Target rehire-count generation; an old edge never grants authority to a target employee new employment';

UPDATE employee_data_handovers handover
SET requested_scopes=COALESCE((
    SELECT array_agg(handover_scope.scope ORDER BY handover_scope.scope)
    FROM employee_data_handover_scopes handover_scope
    WHERE handover_scope.handover_id=handover.id
), ARRAY[]::TEXT[]);

ALTER TABLE employee_data_handovers
    ALTER COLUMN requested_scopes SET NOT NULL;

ALTER TABLE employee_data_handovers
    ADD CONSTRAINT employee_data_handovers_requested_scopes_chk CHECK (
        cardinality(requested_scopes) BETWEEN 1 AND 8
        AND requested_scopes <@ ARRAY[
            'goods','client','sales','finance','purchase','subcontract',
            'production_plan','stock_doc']::TEXT[]
        AND fn_text_array_has_unique_members(requested_scopes)
    );

COMMENT ON COLUMN employee_data_handovers.requested_scopes IS
    'Explicit command scopes; employee_data_handover_scopes stores only effective graph scopes';

-- Handover graph rows are append-only except the service's single
-- EXECUTING->COMPLETED transition. Scope rows never mutate.
CREATE OR REPLACE FUNCTION fn_guard_employee_handover_state()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'employee data handovers are append-only'
            USING ERRCODE='55000';
    END IF;
    IF OLD.status='EXECUTING'
       AND NEW.status='COMPLETED'
       AND (to_jsonb(NEW) - ARRAY['status','result_summary']::TEXT[])
           = (to_jsonb(OLD) - ARRAY['status','result_summary']::TEXT[]) THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'employee data handover is immutable after completion'
        USING ERRCODE='55000';
END;
$$;

CREATE TRIGGER trg_employee_data_handovers_state
BEFORE UPDATE OR DELETE ON employee_data_handovers
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_handover_state();

CREATE OR REPLACE FUNCTION fn_guard_employee_handover_scope_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_status TEXT;
    v_requested_scopes TEXT[];
BEGIN
    IF TG_OP='INSERT' THEN
        SELECT handover.status, handover.requested_scopes
        INTO v_status, v_requested_scopes
        FROM employee_data_handovers handover
        WHERE handover.id=NEW.handover_id
        FOR UPDATE OF handover;
        IF v_status IS NULL THEN
            RAISE EXCEPTION 'employee data handover batch does not exist'
                USING ERRCODE='23503';
        END IF;
        IF v_status<>'EXECUTING' THEN
            RAISE EXCEPTION 'employee data handover scopes can only be added while executing'
                USING ERRCODE='55000';
        END IF;
        IF NOT NEW.scope=ANY(v_requested_scopes) THEN
            RAISE EXCEPTION 'effective handover scope was not requested by the batch'
                USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'employee data handover scopes are append-only'
        USING ERRCODE='55000';
END;
$$;

CREATE TRIGGER trg_employee_data_handover_scopes_append_only
BEFORE INSERT OR UPDATE OR DELETE ON employee_data_handover_scopes
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_handover_scope_mutation();

-- HR reasons stay in their source-of-truth tables but are not duplicated into
-- the broad audit center snapshots.
CREATE OR REPLACE FUNCTION fn_audit_redact_row(
    p_table_name TEXT,
    p_row JSONB
) RETURNS JSONB AS $$
DECLARE
    v_row JSONB;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    v_row := p_row - ARRAY[
        'password_hash', 'token_hash', 'preview_token_hash', 'code_hash', 'secret',
        'id_card_enc', 'id_card_hash', 'phone_enc', 'phone_hash',
        'phone', 'phone2', 'link_phone', 'office_phone', 'email',
        'address', 'ship_address', 'huji_address', 'residence_address',
        'bank_account_enc', 'bank_branch_enc', 'bank_account', 'bank_account_no',
        'base_salary_enc', 'perf_salary_enc', 'social_insurance_base_enc',
        'housing_fund_base_enc', 'allowance_standard_enc',
        'old_value_enc', 'new_value_enc', 'plate_no_enc', 'qr_token', 'passcode',
        'content', 'body', 'message', 'description', 'remark', 'remarks',
        'note', 'comment', 'reject_reason', 'last_rejection_reason',
        'close_reason', 'reopen_reason', 'reversal_reason', 'location_text',
        'payload', 'exception_snapshot', 'calculation_snapshot',
        'required_document_codes', 'required_document_codes_snapshot',
        'source_ref', 'source_line_ref', 'linkman', 'legal_person',
        'ground_graph', 'product_graph1', 'product_graph2', 'product_graph3',
        'product_graph4', 'product_graph5', 'product_graph6', 'budget_graph'
    ];

    IF p_table_name = 'employees' THEN
        v_row := v_row - ARRAY[
            'full_name', 'gender', 'id_type', 'birth_date', 'ethnicity',
            'political_status', 'marital_status', 'paper_archive_no'
        ];
    ELSIF p_table_name = 'employee_compensation' THEN
        v_row := v_row - 'social_insurance_location';
    ELSIF p_table_name = 'emergency_contacts' THEN
        v_row := v_row - ARRAY['name', 'relationship'];
    ELSIF p_table_name = 'visitor_accounts' THEN
        v_row := v_row - 'name';
    ELSIF p_table_name = 'visitor_applications' THEN
        v_row := v_row - ARRAY['visitor_name', 'company', 'visit_purpose', 'plate_no'];
    ELSIF p_table_name = 'profile_change_requests' THEN
        v_row := v_row - 'review_comment';
    ELSIF p_table_name = 'employee_data_handovers' THEN
        v_row := v_row - 'reason';
    ELSIF p_table_name = 'employee_offboarding_events' THEN
        v_row := v_row - ARRAY['reason', 'handover_reason'];
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION fn_audit_redact_row(TEXT, JSONB) IS
    'Redacts secrets/PII, including handover/offboarding reasons, before audit_log persistence';
