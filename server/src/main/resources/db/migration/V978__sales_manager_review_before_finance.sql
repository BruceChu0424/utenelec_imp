-- Sales management approval precedes finance. Existing completed decisions retain their historical provenance.
-- New capabilities are explicitly granted through the existing audited permission administration flow (V936).
ALTER TABLE sales_quotes
    ADD COLUMN manager_review_state text NOT NULL DEFAULT 'NOT_REQUIRED' CHECK(manager_review_state IN ('NOT_REQUIRED','PENDING','APPROVED','REJECTED')),
    ADD COLUMN manager_approved_at timestamptz,
    ADD COLUMN manager_approved_by uuid REFERENCES employees(id),
    ADD COLUMN manager_rejected_at timestamptz,
    ADD COLUMN manager_rejected_by uuid REFERENCES employees(id),
    ADD COLUMN manager_reject_reason text,
    ADD COLUMN manager_review_remark text,
    ADD COLUMN manager_decision_claim_id uuid;
ALTER TABLE sales_orders
    ADD COLUMN manager_review_state text NOT NULL DEFAULT 'NOT_REQUIRED' CHECK(manager_review_state IN ('NOT_REQUIRED','PENDING','APPROVED','REJECTED')),
    ADD COLUMN manager_approved_at timestamptz,
    ADD COLUMN manager_approved_by uuid REFERENCES employees(id),
    ADD COLUMN manager_rejected_at timestamptz,
    ADD COLUMN manager_rejected_by uuid REFERENCES employees(id),
    ADD COLUMN manager_reject_reason text,
    ADD COLUMN manager_review_remark text,
    ADD COLUMN manager_decision_claim_id uuid;
UPDATE sales_quotes SET manager_review_state='PENDING'
WHERE status=2 AND NOT is_deleted AND NOT is_closed AND legacy_id IS NULL AND NOT fn_imported_business_document('sales_quotes',id);
UPDATE sales_orders SET manager_review_state='PENDING'
WHERE status=1 AND NOT finance_confirmed AND NOT finance_rejected AND NOT is_deleted AND NOT is_stopped
  AND (NOT is_closed OR finance_review_revision>0) AND requoted_to_id IS NULL
  AND legacy_id IS NULL AND NOT fn_imported_business_document('sales_orders',id);
CREATE INDEX idx_sales_quotes_manager_pending ON sales_quotes(manager_review_state, submitted_at, id) WHERE NOT is_deleted;
CREATE INDEX idx_sales_orders_manager_pending ON sales_orders(manager_review_state, deliver_date, id) WHERE NOT is_deleted;

CREATE FUNCTION fn_guard_sales_manager_finance_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.manager_review_state NOT IN ('APPROVED','NOT_REQUIRED') THEN
        IF TG_TABLE_NAME='sales_orders' THEN
            IF NEW.finance_confirmed THEN RAISE EXCEPTION '须先通过销售负责人审核，才能财务确认' USING ERRCODE='23514'; END IF;
        ELSIF NEW.status=1 THEN
            RAISE EXCEPTION '须先通过销售负责人审核，才能确认报价' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sales_order_manager_finance_gate BEFORE INSERT OR UPDATE ON sales_orders
FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_manager_finance_gate();
CREATE TRIGGER trg_sales_quote_manager_finance_gate BEFORE INSERT OR UPDATE ON sales_quotes
FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_manager_finance_gate();

ALTER TABLE sales_quote_revision_logs DROP CONSTRAINT sales_quote_revision_logs_action_check,
ADD CONSTRAINT sales_quote_revision_logs_action_check CHECK(action IN (
'SUBMIT','WITHDRAW','FINANCE_EDIT','RETURN','CONFIRM','REOPEN','FINANCE_REOPEN',
'SALES_EDIT','CUSTOMER_ACCEPT','CANCEL','CONVERT','MANAGER_EDIT','MANAGER_CONFIRM','MANAGER_REJECT','MANAGER_REVERSE'));

CREATE TABLE sales_order_manager_review_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES sales_orders(id),
    revision bigint NOT NULL,
    action text NOT NULL CHECK(action IN ('APPROVED','REJECTED','REVERSED')),
    actor_id uuid NOT NULL REFERENCES employees(id),
    reason text,
    claim_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    snapshot jsonb NOT NULL
);
CREATE INDEX idx_sales_order_manager_review_events_order ON sales_order_manager_review_events(order_id,created_at);
CREATE TRIGGER trg_sales_order_manager_review_events_immutable BEFORE UPDATE OR DELETE ON sales_order_manager_review_events
FOR EACH ROW EXECUTE FUNCTION fn_sales_order_revision_logs_immutable();
-- Immutable actor-bearing decisions are their own evidence (ADR-105 NONE/ledger), not duplicated into generic row audit.

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,high_risk,baseline,sensitivity)
VALUES
('sales_quote_manager:view','查看销售负责人报价单审核','综合营销部','订单审核',0,'VIEW','查看报价单的销售负责人审核；通过后才进入财务，财务权限仍独立授权',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL'),
('sales_quote_manager:confirm','批准销售负责人报价单审核','综合营销部','订单审核',1,'APPROVE','调整本次报价的单价、折扣、有效期、结账方式与审核备注并批准；随后转交财务，不修改货品主档价格或财务结果',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL'),
('sales_quote_manager:reject','驳回销售负责人报价单审核','综合营销部','订单审核',2,'APPROVE','驳回报价单的销售负责人审核；通过后才进入财务，财务权限仍独立授权',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL'),
('sales_quote_manager:reverse','反审核销售负责人报价单审核','综合营销部','订单审核',3,'APPROVE','反审核报价单的销售负责人审核；通过后才进入财务，财务权限仍独立授权',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL'),
('sales_order_manager:view','查看销售负责人订货单审核','综合营销部','订单审核',10,'VIEW','查看订货单的销售负责人审核；通过后才进入财务，财务权限仍独立授权',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL'),
('sales_order_manager:confirm','批准销售负责人订货单审核','综合营销部','订单审核',11,'APPROVE','批准订货单的销售负责人审核；通过后才进入财务，财务权限仍独立授权',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL'),
('sales_order_manager:reject','驳回销售负责人订货单审核','综合营销部','订单审核',12,'APPROVE','驳回订货单的销售负责人审核；通过后才进入财务，财务权限仍独立授权',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL'),
('sales_order_manager:reverse','反审核销售负责人订货单审核','综合营销部','订单审核',13,'APPROVE','反审核订货单的销售负责人审核；通过后才进入财务，财务权限仍独立授权',ARRAY['NORMAL'],false,false,'SENSITIVE_COMMERCIAL');
INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled)
VALUES(gen_random_uuid(),'sales.manager-review','订单审核',299,true);
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key='sales.manager-review' AND p.code LIKE 'sales_%_manager:%';

-- Retire finance work that moved back to the newly introduced management stage.
UPDATE task_claims SET released_at=now(),release_reason='workflow_changed'
WHERE released_at IS NULL AND ((target_type='SALES_QUOTE_FINANCE_REVIEW' AND target_key IN
    (SELECT id::text FROM sales_quotes WHERE manager_review_state='PENDING'))
 OR (target_type='SALES_ORDER_FINANCE_CONFIRM' AND target_key IN
    (SELECT id::text FROM sales_orders WHERE manager_review_state='PENDING')));
UPDATE notices SET resolved_at=now(),resolved_reason='MOVED_TO_SALES_MANAGER_REVIEW'
WHERE resolved_at IS NULL AND ((source_event='SALES_QUOTE_PENDING_FINANCE_REVIEW' AND aggregate_id IN
    (SELECT id FROM sales_quotes WHERE manager_review_state='PENDING'))
 OR (source_event='SALES_ORDER_PENDING_FINANCE_CONFIRM' AND aggregate_id IN
    (SELECT id FROM sales_orders WHERE manager_review_state='PENDING')));

ALTER TABLE sales_quote_items ADD COLUMN manager_price_by uuid REFERENCES employees(id),
ADD COLUMN manager_price_at timestamptz,
DROP CONSTRAINT sales_quote_items_price_source_check,
ADD CONSTRAINT sales_quote_items_price_source_check CHECK(price_source IN ('MASTER','SALES','FINANCE','MANAGER')),
ADD CONSTRAINT ck_sales_quote_items_manager_price CHECK(price_source <> 'MANAGER' OR manager_price_at IS NOT NULL);

-- Extend the current object-level reminder predicate without losing later warehouse/procurement fixes.
DO $migration$
DECLARE definition text; anchor text := E'\n    CASE p_event'; replacement text;
BEGIN
    definition := pg_get_functiondef('fn_notice_business_action_visible(uuid,text,text,uuid,text,text,text,text,text,text)'::regprocedure);
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'Unexpected business notice predicate; inspect before upgrading';
    END IF;
    replacement := E'\n' || $body$    CASE p_event
        WHEN 'SALES_QUOTE_MANAGER_REJECTED' THEN
            expected_kind:='SALES_QUOTE_ACTION';
            pending:=EXISTS(SELECT 1 FROM sales_quotes document WHERE document.id=p_id AND document.status=0
                AND NOT document.is_deleted AND NOT document.is_closed AND document.manager_review_state='REJECTED'
                AND fn_notice_task_owner(scopes,'sales',document.maker_id,TRUE));
        WHEN 'SALES_ORDER_MANAGER_REJECTED' THEN
            expected_kind:='SALES_ORDER';
            pending:=EXISTS(SELECT 1 FROM sales_orders document WHERE document.id=p_id AND document.status IN (0,1)
                AND NOT document.is_deleted AND NOT document.is_stopped AND NOT document.is_closed
                AND document.requoted_to_id IS NULL AND document.manager_review_state='REJECTED'
                AND fn_notice_task_owner(scopes,'sales',document.owner_employee_id,TRUE));
        WHEN 'SALES_QUOTE_PENDING_MANAGER_REVIEW' THEN
            expected_kind:='SALES_QUOTE_MANAGER';
            pending:=EXISTS(SELECT 1 FROM sales_quotes document WHERE document.id=p_id AND document.status=2
                AND NOT document.is_deleted AND NOT document.is_closed AND document.manager_review_state='PENDING');
        WHEN 'SALES_ORDER_PENDING_MANAGER_REVIEW' THEN
            expected_kind:='SALES_ORDER_MANAGER';
            pending:=EXISTS(SELECT 1 FROM sales_orders document WHERE document.id=p_id AND document.status=1
                AND NOT document.is_deleted AND NOT document.is_stopped AND document.requoted_to_id IS NULL
                AND (NOT document.is_closed OR document.finance_review_revision>0) AND NOT document.finance_confirmed AND NOT document.finance_rejected
                AND document.manager_review_state='PENDING');$body$;
    definition := replace(definition,anchor,replacement);
    -- All finance reminders are additionally fenced by management approval; management branches stay independent.
    anchor := '        WHEN ''SALES_ORDER_PENDING_FINANCE_CONFIRM'' THEN';
    replacement := anchor || E'\n            IF NOT EXISTS(SELECT 1 FROM sales_orders WHERE id=p_id AND manager_review_state IN (''NOT_REQUIRED'',''APPROVED'')) THEN RETURN false; END IF;';
    definition := replace(definition,anchor,replacement);
    anchor := '        WHEN ''SALES_QUOTE_PENDING_FINANCE_REVIEW'' THEN';
    replacement := anchor || E'\n            IF NOT EXISTS(SELECT 1 FROM sales_quotes WHERE id=p_id AND manager_review_state IN (''NOT_REQUIRED'',''APPROVED'')) THEN RETURN false; END IF;';
    definition := replace(definition,anchor,replacement);
    EXECUTE definition;
END;
$migration$;
