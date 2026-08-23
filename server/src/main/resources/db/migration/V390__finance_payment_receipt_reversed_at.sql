-- V390: 付款/收款红冲事件日不可变。
-- 供应商月结快照（SupplierSettlementService.snapshotLines）与财务报表此前用可变的
-- finance_payments.updated_at / finance_receipts.updated_at 作为红冲负事件的事件日：
-- 任何无关 UPDATE（乐观锁版本推进、备注修改）都会移动红冲事件的月份归属，
-- 破坏跨期连续性。本迁移为两张表引入一次写入即锁定的 reversed_at：
-- 红冲时由服务写入；历史已红冲行以 updated_at 近似回填（更早事实无法复原，
-- 仅保证前向不再漂移）；触发器禁止非空后的任何变更。

ALTER TABLE finance_payments  ADD COLUMN reversed_at timestamptz;
ALTER TABLE finance_receipts ADD COLUMN reversed_at timestamptz;

UPDATE finance_payments
SET reversed_at = updated_at
WHERE status = -1 AND COALESCE(is_deleted, FALSE) = FALSE;

UPDATE finance_receipts
SET reversed_at = updated_at
WHERE status = -1 AND COALESCE(is_deleted, FALSE) = FALSE;

CREATE OR REPLACE FUNCTION fn_guard_finance_document_reversed_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.reversed_at IS NOT NULL
       AND NEW.reversed_at IS DISTINCT FROM OLD.reversed_at THEN
        RAISE EXCEPTION
            'finance document reversed_at is immutable once set'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'finance_document_reversed_at_immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_finance_payments_reversed_at_immutable
    BEFORE UPDATE ON finance_payments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_document_reversed_at();

CREATE TRIGGER trg_finance_receipts_reversed_at_immutable
    BEFORE UPDATE ON finance_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_document_reversed_at();
