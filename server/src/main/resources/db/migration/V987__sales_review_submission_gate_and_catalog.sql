-- Preserve permission identities/grants while placing each review with its document.
UPDATE permissions SET module='销售管理',category=CASE
 WHEN code LIKE 'sales_quote_manager:%' THEN '销售报价' ELSE '销售订货' END
WHERE code LIKE 'sales_quote_manager:%' OR code LIKE 'sales_order_manager:%';

-- An older running application could still submit NOT_REQUIRED after V978.
-- Completed finance decisions and imported history retain their original provenance.
UPDATE sales_orders SET manager_review_state='PENDING'
WHERE manager_review_state='NOT_REQUIRED' AND status=1 AND NOT finance_confirmed
 AND NOT finance_rejected AND NOT is_deleted AND NOT is_stopped AND NOT is_closed
 AND requoted_to_id IS NULL AND legacy_id IS NULL AND NOT fn_imported_business_document('sales_orders',id);
UPDATE sales_quotes SET manager_review_state='PENDING'
WHERE manager_review_state='NOT_REQUIRED' AND status=2 AND NOT is_deleted AND NOT is_closed
 AND legacy_id IS NULL AND NOT fn_imported_business_document('sales_quotes',id);

-- Prevent stale submitters from skipping management; never manufacture an approval.
CREATE OR REPLACE FUNCTION fn_guard_sales_manager_finance_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND NEW.manager_review_state='NOT_REQUIRED' AND NEW.legacy_id IS NULL THEN
  IF TG_TABLE_NAME='sales_orders' THEN
   IF OLD.status=0 AND NEW.status=1 AND NOT fn_imported_business_document('sales_orders',NEW.id) THEN
    NEW.manager_review_state:='PENDING';
   END IF;
  ELSIF OLD.status=0 AND NEW.status=2 AND NOT fn_imported_business_document('sales_quotes',NEW.id) THEN
   NEW.manager_review_state:='PENDING';
  END IF;
 END IF;
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

UPDATE task_claims SET released_at=now(),release_reason='workflow_changed'
WHERE released_at IS NULL AND (
 (target_type='SALES_ORDER_FINANCE_CONFIRM' AND target_key IN
  (SELECT id::text FROM sales_orders WHERE manager_review_state='PENDING')) OR
 (target_type='SALES_QUOTE_FINANCE_REVIEW' AND target_key IN
  (SELECT id::text FROM sales_quotes WHERE manager_review_state='PENDING')));

UPDATE notices SET resolved_at=now(),resolved_reason='MOVED_TO_SALES_MANAGER_REVIEW'
WHERE resolved_at IS NULL AND (
 (source_event='SALES_ORDER_PENDING_FINANCE_CONFIRM' AND aggregate_id IN
  (SELECT id FROM sales_orders WHERE manager_review_state='PENDING')) OR
 (source_event='SALES_QUOTE_PENDING_FINANCE_REVIEW' AND aggregate_id IN
  (SELECT id FROM sales_quotes WHERE manager_review_state='PENDING')));
