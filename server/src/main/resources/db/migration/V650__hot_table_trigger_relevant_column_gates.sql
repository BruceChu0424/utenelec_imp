-- V650 ADR-106 热表约束/守卫触发器只对「相关列真变了」起跳；单号不可变改列级；收付款类别引用改共享锁
--
-- 背景(审计 db-schema-06 / perf-production-exec-02 / perf-warehouse-quality-06 / perf-material-analysis-14 /
-- perf-production-exec-11 / db-schema-08)：预留、单据头/明细、计划明细、执行段、分析三表、估值图等热表上的
-- 约束与守卫触发器几乎都没有列过滤和 WHEN。PostgreSQL 对每一次 INSERT/UPDATE 都给每个延迟约束触发器排一个
-- 事件，提交时逐个执行；只改 updated_at / lock_version / 派生数量、甚至什么都没改的更新，也会把守恒与来源
-- 校验整套重跑一遍。一行车间直送审核(2026-09-23 实测)要调 600 次触发器函数、提交 742ms。
--
-- 本迁移只改触发器的起跳条件，不改任何校验函数的判定：
--   1. 逐个读函数体(连同它调用的函数与视图)，列出它对本表真正读取的列；UPDATE 事件加
--      WHEN (OLD.x IS DISTINCT FROM NEW.x ...)，只有这些列真变了才排队。函数入口本来就按
--      NEW.owner_type / NEW.operation / NEW.value_model 等提前返回的，把同一条件写进 WHEN
--      (用 「条件 IS NOT TRUE」 与函数里的 IF ... RETURN 逐字等价，NULL 语义一致)。
--   2. INSERT 与 UPDATE 共用一个触发器时，WHEN 不能引用 OLD，所以拆成原名(INSERT / DELETE 路径不变)
--      与 _upd(UPDATE 路径带 WHEN)两条；INSERT 与 DELETE 条件不同时 DELETE 另起 _del。
--      新名字都在原名后缀，同表同时机同事件的触发器按名字排序的执行先后保持不变。
--   3. 只用 WHEN、不新加 UPDATE OF：列清单触发器只看 UPDATE 语句的 SET 目标，看不到 BEFORE 触发器
--      改写的列(PostgreSQL 文档明示)；而 WHEN 在最终行上求值。原有的 UPDATE OF 一律原样保留。
--   4. 被完全包含的重复校验合并掉：采购来源溯源触发器在预留/领料单头/领料明细上逐个断言的
--      「生效中的采购收货分配」，正是同表 receipt 覆盖校验(fn_assert_receipt_reservation_coverage)
--      在容量检查之后逐条再断言的同一批分配(production_material_receipt_allocations.reservation_id
--      非空)，三条 trg_purchase_*_provenance 删除，覆盖校验照旧。
--   5. 单号不可变：fn_reserve_business_document_identifier 只管 INSERT 取号；UPDATE 改由
--      BEFORE UPDATE OF <单号列> WHEN (单号/区分列真变了或为空) 触发同文案的不可变守卫。
--   6. 收付款类别引用校验(引用方)改取同一把咨询锁的共享模式，只有类别层级/状态变更一侧保持排他：
--      两笔引用同一类别的财务单据不再互相排队，改层级仍要等引用方提交。
--   7. DROP + CREATE 会把触发器的 ENABLE ALWAYS(复制角色下照样起跳)复位成默认；原来是 ALWAYS 的，
--      重建出的每一条(含 _upd / _del)逐条恢复，绕过普通触发器的维护写入仍被这些守卫拦住。
--
-- 每条 WHEN 的列集与等价性论证见 docs/99-决策记录-ADR/ADR-106-热表触发器按相关列起跳与索引卫生.md，
-- 负向回归(改了相关列仍被拒、无关列更新零调用)见 WorkshopDirectTransferBatchEndToEndTest，
-- 目录规则见 HotTableTriggerHygieneContractTest。

-- ---------------------------------------------------------------------------------------------
-- 一、收付款类别引用：引用方共享锁，层级/状态变更方排他锁(fn_guard_active_account_style_status 不动)
-- ---------------------------------------------------------------------------------------------
DO $patch$
DECLARE
    target TEXT;
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT;
BEGIN
    FOREACH target IN ARRAY ARRAY[
        'fn_guard_payment_style_reference()',
        'fn_enforce_account_style_uuid_authority()',
        'fn_enforce_system_posting_style_role()'] LOOP
        SELECT pg_get_functiondef(target::regprocedure) INTO definition;
        IF definition IS NULL THEN
            RAISE EXCEPTION 'V650 payment style reference function % missing', target USING ERRCODE = '23514';
        END IF;
        normalized := replace(definition, E'\r\n', E'\n');
        anchor := CASE WHEN target = 'fn_guard_payment_style_reference()'
            THEN 'PERFORM pg_advisory_xact_lock(hashtextextended(''PAYMENT_STYLE_HIERARCHY'', 0));'
            ELSE E'PERFORM pg_advisory_xact_lock(\n        hashtextextended(''PAYMENT_STYLE_HIERARCHY'', 0));' END;
        IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
            RAISE EXCEPTION 'V650 payment style reference function % shape changed', target USING ERRCODE = '23514';
        END IF;
        patched := replace(normalized, anchor,
            replace(anchor, 'pg_advisory_xact_lock(', 'pg_advisory_xact_lock_shared('));
        EXECUTE patched;
    END LOOP;
END;
$patch$;

-- ---------------------------------------------------------------------------------------------
-- 二、单号不可变：INSERT 取号不变；UPDATE 只在单号/区分列真变了(或为空)时进入同文案守卫
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_guard_business_document_identifier_immutable()
RETURNS TRIGGER AS $$
DECLARE
    v_identifier_column TEXT := TG_ARGV[0];
    v_discriminator_column TEXT := NULLIF(TG_ARGV[1], '');
    v_row_value JSONB := to_jsonb(NEW);
    v_old_value JSONB := to_jsonb(OLD);
BEGIN
    IF NULLIF(btrim(v_row_value ->> v_identifier_column), '') IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.' || v_identifier_column
                || ' must not be blank';
    END IF;
    IF v_row_value ->> v_identifier_column
            IS DISTINCT FROM v_old_value ->> v_identifier_column THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.' || v_identifier_column
                || ' is immutable after creation';
    END IF;
    IF v_discriminator_column IS NOT NULL
       AND v_row_value ->> v_discriminator_column
            IS DISTINCT FROM v_old_value ->> v_discriminator_column THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.' || v_discriminator_column
                || ' is immutable after identifier creation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 取号函数只剩 INSERT 路径：删掉已走不到的 UPDATE 分支。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    declare_anchor TEXT := E'    v_old_value JSONB;\n';
    update_anchor TEXT := E'    IF TG_OP = ''UPDATE'' THEN\n'
        || E'        v_old_value := to_jsonb(OLD);\n'
        || E'        IF v_row_value ->> v_identifier_column\n'
        || E'                IS DISTINCT FROM v_old_value ->> v_identifier_column THEN\n'
        || E'            RAISE EXCEPTION USING ERRCODE = ''23514'',\n'
        || E'                MESSAGE = TG_TABLE_NAME || ''.'' || v_identifier_column\n'
        || E'                    || '' is immutable after creation'';\n'
        || E'        END IF;\n'
        || E'        IF v_discriminator_column IS NOT NULL\n'
        || E'           AND v_row_value ->> v_discriminator_column\n'
        || E'                IS DISTINCT FROM v_old_value ->> v_discriminator_column THEN\n'
        || E'            RAISE EXCEPTION USING ERRCODE = ''23514'',\n'
        || E'                MESSAGE = TG_TABLE_NAME || ''.'' || v_discriminator_column\n'
        || E'                    || '' is immutable after identifier creation'';\n'
        || E'        END IF;\n'
        || E'        RETURN NEW;\n'
        || E'    END IF;\n\n';
    comment_anchor TEXT := E'    -- The UPDATE branch returns first so unchanged non-canonical history remains\n'
        || E'    -- editable, and controlled legacy imports retain their exact snapshot.\n';
    comment_replacement TEXT := E'    -- UPDATEs never reach this function (V650 immutable guard), so unchanged\n'
        || E'    -- non-canonical history remains editable; controlled legacy imports retain\n'
        || E'    -- their exact snapshot.\n';
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_reserve_business_document_identifier()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V650 business document identifier function missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    FOREACH anchor IN ARRAY ARRAY[declare_anchor, update_anchor, comment_anchor] LOOP
        IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
            RAISE EXCEPTION 'V650 business document identifier function shape changed' USING ERRCODE = '23514';
        END IF;
    END LOOP;
    patched := replace(replace(replace(normalized, declare_anchor, ''), update_anchor, ''),
        comment_anchor, comment_replacement);
    EXECUTE patched;
END;
$patch$;

-- 单号触发器：原名只剩 BEFORE INSERT 取号；_upd 列级守卫只在单号/区分列真变了(或为空)时进入。
DROP TRIGGER trg_business_document_account_balance_adjustment_batches ON account_balance_adjustment_batches;
CREATE TRIGGER trg_business_document_account_balance_adjustment_batches BEFORE INSERT ON account_balance_adjustment_batches FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_ACCOUNT_BALANCE_ADJUSTMENT', 'batch_no', '');
CREATE TRIGGER trg_business_document_account_balance_adjustment_batches_upd BEFORE UPDATE OF batch_no ON account_balance_adjustment_batches FOR EACH ROW WHEN (OLD.batch_no IS DISTINCT FROM NEW.batch_no OR NULLIF(btrim(NEW.batch_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('batch_no', '');
DROP TRIGGER trg_business_document_deferred_expenses ON deferred_expenses;
CREATE TRIGGER trg_business_document_deferred_expenses BEFORE INSERT ON deferred_expenses FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('DEFERRED_EXPENSE', 'code', '');
CREATE TRIGGER trg_business_document_deferred_expenses_upd BEFORE UPDATE OF code ON deferred_expenses FOR EACH ROW WHEN (OLD.code IS DISTINCT FROM NEW.code OR NULLIF(btrim(NEW.code), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('code', '');
DROP TRIGGER trg_business_document_expense_claims ON expense_claims;
CREATE TRIGGER trg_business_document_expense_claims BEFORE INSERT ON expense_claims FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('EXPENSE_CLAIM', 'claim_no', '');
CREATE TRIGGER trg_business_document_expense_claims_upd BEFORE UPDATE OF claim_no ON expense_claims FOR EACH ROW WHEN (OLD.claim_no IS DISTINCT FROM NEW.claim_no OR NULLIF(btrim(NEW.claim_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('claim_no', '');
DROP TRIGGER trg_business_document_finance_bank_transfers ON finance_bank_transfers;
CREATE TRIGGER trg_business_document_finance_bank_transfers BEFORE INSERT ON finance_bank_transfers FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_BANK_TRANSFER', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_bank_transfers_upd BEFORE UPDATE OF bill_no ON finance_bank_transfers FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_finance_expenses ON finance_expenses;
CREATE TRIGGER trg_business_document_finance_expenses BEFORE INSERT ON finance_expenses FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_EXPENSE', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_expenses_upd BEFORE UPDATE OF bill_no ON finance_expenses FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_finance_other_incomes ON finance_other_incomes;
CREATE TRIGGER trg_business_document_finance_other_incomes BEFORE INSERT ON finance_other_incomes FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_OTHER_INCOME', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_other_incomes_upd BEFORE UPDATE OF bill_no ON finance_other_incomes FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_finance_payments ON finance_payments;
CREATE TRIGGER trg_business_document_finance_payments BEFORE INSERT ON finance_payments FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_PAYMENT', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_payments_upd BEFORE UPDATE OF bill_no ON finance_payments FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_finance_receipts ON finance_receipts;
CREATE TRIGGER trg_business_document_finance_receipts BEFORE INSERT ON finance_receipts FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_RECEIPT', 'bill_no', '');
CREATE TRIGGER trg_business_document_finance_receipts_upd BEFORE UPDATE OF bill_no ON finance_receipts FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_fixed_assets ON fixed_assets;
CREATE TRIGGER trg_business_document_fixed_assets BEFORE INSERT ON fixed_assets FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIXED_ASSET', 'code', '');
CREATE TRIGGER trg_business_document_fixed_assets_upd BEFORE UPDATE OF code ON fixed_assets FOR EACH ROW WHEN (OLD.code IS DISTINCT FROM NEW.code OR NULLIF(btrim(NEW.code), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('code', '');
DROP TRIGGER trg_business_document_production_daily_reports ON production_daily_reports;
CREATE TRIGGER trg_business_document_production_daily_reports BEFORE INSERT ON production_daily_reports FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PRODUCTION_DAILY_REPORT', 'bill_no', '');
CREATE TRIGGER trg_business_document_production_daily_reports_upd BEFORE UPDATE OF bill_no ON production_daily_reports FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_production_execution_segments ON production_execution_segments;
CREATE TRIGGER trg_business_document_production_execution_segments BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PRODUCTION_EXECUTION_SEGMENT', 'segment_code', '');
CREATE TRIGGER trg_business_document_production_execution_segments_upd BEFORE UPDATE OF segment_code ON production_execution_segments FOR EACH ROW WHEN (OLD.segment_code IS DISTINCT FROM NEW.segment_code OR NULLIF(btrim(NEW.segment_code), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('segment_code', '');
DROP TRIGGER trg_business_document_production_fqc_inspection_sheets ON production_fqc_inspection_sheets;
CREATE TRIGGER trg_business_document_production_fqc_inspection_sheets BEFORE INSERT ON production_fqc_inspection_sheets FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PRODUCTION_FQC_SHEET', 'sheet_no', '');
CREATE TRIGGER trg_business_document_production_fqc_inspection_sheets_upd BEFORE UPDATE OF sheet_no ON production_fqc_inspection_sheets FOR EACH ROW WHEN (OLD.sheet_no IS DISTINCT FROM NEW.sheet_no OR NULLIF(btrim(NEW.sheet_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('sheet_no', '');
DROP TRIGGER trg_business_document_production_plans ON production_plans;
CREATE TRIGGER trg_business_document_production_plans BEFORE INSERT ON production_plans FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PRODUCTION_PLAN', 'bill_no', '');
CREATE TRIGGER trg_business_document_production_plans_upd BEFORE UPDATE OF bill_no ON production_plans FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_purchase_orders ON purchase_orders;
CREATE TRIGGER trg_business_document_purchase_orders BEFORE INSERT ON purchase_orders FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_ORDER', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_orders_upd BEFORE UPDATE OF bill_no ON purchase_orders FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_purchase_receipts ON purchase_receipts;
CREATE TRIGGER trg_business_document_purchase_receipts BEFORE INSERT ON purchase_receipts FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_RECEIPT', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_receipts_upd BEFORE UPDATE OF bill_no ON purchase_receipts FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_purchase_requests ON purchase_requests;
CREATE TRIGGER trg_business_document_purchase_requests BEFORE INSERT ON purchase_requests FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_REQUEST', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_requests_upd BEFORE UPDATE OF bill_no ON purchase_requests FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_purchase_returns ON purchase_returns;
CREATE TRIGGER trg_business_document_purchase_returns BEFORE INSERT ON purchase_returns FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('PURCHASE_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_purchase_returns_upd BEFORE UPDATE OF bill_no ON purchase_returns FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_rd_tasks ON rd_tasks;
CREATE TRIGGER trg_business_document_rd_tasks BEFORE INSERT ON rd_tasks FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('RD_TASK', 'task_no', '');
CREATE TRIGGER trg_business_document_rd_tasks_upd BEFORE UPDATE OF task_no ON rd_tasks FOR EACH ROW WHEN (OLD.task_no IS DISTINCT FROM NEW.task_no OR NULLIF(btrim(NEW.task_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('task_no', '');
DROP TRIGGER trg_business_document_sales_orders ON sales_orders;
CREATE TRIGGER trg_business_document_sales_orders BEFORE INSERT ON sales_orders FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_ORDER', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_orders_upd BEFORE UPDATE OF bill_no ON sales_orders FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_sales_other_shipments ON sales_other_shipments;
CREATE TRIGGER trg_business_document_sales_other_shipments BEFORE INSERT ON sales_other_shipments FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_OTHER_SHIPMENT', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_other_shipments_upd BEFORE UPDATE OF bill_no ON sales_other_shipments FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_sales_quotes ON sales_quotes;
CREATE TRIGGER trg_business_document_sales_quotes BEFORE INSERT ON sales_quotes FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_QUOTE', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_quotes_upd BEFORE UPDATE OF bill_no ON sales_quotes FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_sales_returns ON sales_returns;
CREATE TRIGGER trg_business_document_sales_returns BEFORE INSERT ON sales_returns FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_returns_upd BEFORE UPDATE OF bill_no ON sales_returns FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_sales_shipments ON sales_shipments;
CREATE TRIGGER trg_business_document_sales_shipments BEFORE INSERT ON sales_shipments FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SALES_SHIPMENT', 'bill_no', '');
CREATE TRIGGER trg_business_document_sales_shipments_upd BEFORE UPDATE OF bill_no ON sales_shipments FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_stock_documents ON stock_documents;
CREATE TRIGGER trg_business_document_stock_documents BEFORE INSERT ON stock_documents FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('', 'bill_no', 'doc_type');
CREATE TRIGGER trg_business_document_stock_documents_upd BEFORE UPDATE OF bill_no, doc_type ON stock_documents FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR OLD.doc_type IS DISTINCT FROM NEW.doc_type OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', 'doc_type');
DROP TRIGGER trg_business_document_subcontract_applications ON subcontract_applications;
CREATE TRIGGER trg_business_document_subcontract_applications BEFORE INSERT ON subcontract_applications FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_APPLICATION', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_applications_upd BEFORE UPDATE OF bill_no ON subcontract_applications FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_subcontract_inquiries ON subcontract_inquiries;
CREATE TRIGGER trg_business_document_subcontract_inquiries BEFORE INSERT ON subcontract_inquiries FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_INQUIRY', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_inquiries_upd BEFORE UPDATE OF bill_no ON subcontract_inquiries FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_subcontract_material_issues ON subcontract_material_issues;
CREATE TRIGGER trg_business_document_subcontract_material_issues BEFORE INSERT ON subcontract_material_issues FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_MATERIAL_ISSUE', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_material_issues_upd BEFORE UPDATE OF bill_no ON subcontract_material_issues FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_subcontract_material_returns ON subcontract_material_returns;
CREATE TRIGGER trg_business_document_subcontract_material_returns BEFORE INSERT ON subcontract_material_returns FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_MATERIAL_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_material_returns_upd BEFORE UPDATE OF bill_no ON subcontract_material_returns FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_subcontract_orders ON subcontract_orders;
CREATE TRIGGER trg_business_document_subcontract_orders BEFORE INSERT ON subcontract_orders FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_ORDER', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_orders_upd BEFORE UPDATE OF bill_no ON subcontract_orders FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_subcontract_receipts ON subcontract_receipts;
CREATE TRIGGER trg_business_document_subcontract_receipts BEFORE INSERT ON subcontract_receipts FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_RECEIPT', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_receipts_upd BEFORE UPDATE OF bill_no ON subcontract_receipts FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_subcontract_returns ON subcontract_returns;
CREATE TRIGGER trg_business_document_subcontract_returns BEFORE INSERT ON subcontract_returns FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_RETURN', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_returns_upd BEFORE UPDATE OF bill_no ON subcontract_returns FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_subcontract_wastes ON subcontract_wastes;
CREATE TRIGGER trg_business_document_subcontract_wastes BEFORE INSERT ON subcontract_wastes FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('SUB_WASTE', 'bill_no', '');
CREATE TRIGGER trg_business_document_subcontract_wastes_upd BEFORE UPDATE OF bill_no ON subcontract_wastes FOR EACH ROW WHEN (OLD.bill_no IS DISTINCT FROM NEW.bill_no OR NULLIF(btrim(NEW.bill_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('bill_no', '');
DROP TRIGGER trg_business_document_visitor_accounts ON visitor_accounts;
CREATE TRIGGER trg_business_document_visitor_accounts BEFORE INSERT ON visitor_accounts FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('VISITOR_ACCOUNT', 'visitor_no', '');
CREATE TRIGGER trg_business_document_visitor_accounts_upd BEFORE UPDATE OF visitor_no ON visitor_accounts FOR EACH ROW WHEN (OLD.visitor_no IS DISTINCT FROM NEW.visitor_no OR NULLIF(btrim(NEW.visitor_no), '') IS NULL) EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('visitor_no', '');

-- ---------------------------------------------------------------------------------------------
-- 三、热表约束/守卫触发器：UPDATE 只在相关列真变了时起跳；入口本就按行类型提前返回的，条件写进 WHEN；
--     被同表覆盖校验完全包含的三条采购来源溯源触发器删除。
-- ---------------------------------------------------------------------------------------------
-- stock_reservations.trg_00_capture_material_reservation_projection
-- 非生产需求预留且两列投影已为空时，函数只是把空值再写成空值；条件与函数入口逐字等价。
DROP TRIGGER trg_00_capture_material_reservation_projection ON stock_reservations;
CREATE TRIGGER trg_00_capture_material_reservation_projection BEFORE INSERT OR UPDATE ON stock_reservations FOR EACH ROW WHEN (NEW.owner_type = 'PRODUCTION_MATERIAL_DEMAND' OR NEW.material_projection_tx_id IS NOT NULL OR NEW.material_projection_initial_consumed_qty IS NOT NULL) EXECUTE FUNCTION fn_capture_material_reservation_projection();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_00_capture_material_reservation_projection;

-- stock_reservations.trg_00_workshop_source_reservation_release
-- 只在释放量/删除标记变化、且预留归属生产需求或车间保管时才记录直送来源释放(函数本身的判定)。
DROP TRIGGER trg_00_workshop_source_reservation_release ON stock_reservations;
CREATE TRIGGER trg_00_workshop_source_reservation_release AFTER UPDATE ON stock_reservations FOR EACH ROW WHEN (NEW.owner_type IN ('PRODUCTION_MATERIAL_DEMAND', 'WORKSHOP_CUSTODY') AND ((OLD.released_qty, OLD.is_deleted) IS DISTINCT FROM (NEW.released_qty, NEW.is_deleted))) EXECUTE FUNCTION fn_capture_workshop_source_reservation_release();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_00_workshop_source_reservation_release;

-- stock_reservations.trg_check_execution_segment_reservation
DROP TRIGGER trg_check_execution_segment_reservation ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_reservation AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.demand_id IS NOT NULL) EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_reservation_del AFTER DELETE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.demand_id IS NOT NULL) EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_reservation_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.demand_id IS NOT NULL OR NEW.demand_id IS NOT NULL) AND ((OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.is_deleted, OLD.owner_type, OLD.demand_id) IS DISTINCT FROM (NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.is_deleted, NEW.owner_type, NEW.demand_id))) EXECUTE FUNCTION fn_check_execution_segment_integrity();

-- stock_reservations.trg_check_material_reservation_consumed_projection
-- 投影列由前置触发器在每个事务首次改动时重写；消耗量没变的事件必然得出差额 0，过账表自身另有同一校验。
DROP TRIGGER trg_check_material_reservation_consumed_projection ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_check_material_reservation_consumed_projection AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type = 'PRODUCTION_MATERIAL_DEMAND') EXECUTE FUNCTION fn_check_material_consumed_projection();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_check_material_reservation_consumed_projection;
CREATE CONSTRAINT TRIGGER trg_check_material_reservation_consumed_projection_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type = 'PRODUCTION_MATERIAL_DEMAND' AND ((OLD.consumed_qty, OLD.owner_type) IS DISTINCT FROM (NEW.consumed_qty, NEW.owner_type))) EXECUTE FUNCTION fn_check_material_consumed_projection();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_check_material_reservation_consumed_projection_upd;

-- stock_reservations.trg_check_root_sales_reservation_release
DROP TRIGGER trg_check_root_sales_reservation_release ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_check_root_sales_reservation_release AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (((OLD.released_qty, OLD.is_deleted) IS DISTINCT FROM (NEW.released_qty, NEW.is_deleted)) AND (NEW.released_qty > 0 OR NEW.is_deleted)) EXECUTE FUNCTION fn_check_root_sales_reservation_release();

-- stock_reservations.trg_check_workshop_custody_reservation_grant
DROP TRIGGER trg_check_workshop_custody_reservation_grant ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_check_workshop_custody_reservation_grant AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_custody_reservation_grant();
CREATE CONSTRAINT TRIGGER trg_check_workshop_custody_reservation_grant_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.source, OLD.source_doc_type, OLD.created_at, OLD.is_deleted, OLD.owner_type) IS DISTINCT FROM (NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.source, NEW.source_doc_type, NEW.created_at, NEW.is_deleted, NEW.owner_type)) EXECUTE FUNCTION fn_check_workshop_custody_reservation_grant();

-- stock_reservations.trg_check_workshop_source_reservation_balance
DROP TRIGGER trg_check_workshop_source_reservation_balance ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_check_workshop_source_reservation_balance AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type IN ('PRODUCTION_MATERIAL_DEMAND', 'WORKSHOP_CUSTODY')) EXECUTE FUNCTION fn_check_workshop_source_event_balance();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_check_workshop_source_reservation_balance;
CREATE CONSTRAINT TRIGGER trg_check_workshop_source_reservation_balance_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type IN ('PRODUCTION_MATERIAL_DEMAND', 'WORKSHOP_CUSTODY') AND ((OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.source, OLD.created_at, OLD.is_deleted, OLD.owner_type) IS DISTINCT FROM (NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.source, NEW.created_at, NEW.is_deleted, NEW.owner_type))) EXECUTE FUNCTION fn_check_workshop_source_event_balance();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_check_workshop_source_reservation_balance_upd;

-- stock_reservations.trg_guard_qualified_origin_reservation_identity
DROP TRIGGER trg_guard_qualified_origin_reservation_identity ON stock_reservations;
CREATE TRIGGER trg_guard_qualified_origin_reservation_identity BEFORE INSERT ON stock_reservations FOR EACH ROW WHEN (NEW.owner_type = 'PRODUCTION_MATERIAL_DEMAND' AND NOT NEW.requires_qualified_origin) EXECUTE FUNCTION fn_guard_qualified_origin_reservation_identity();
CREATE TRIGGER trg_guard_qualified_origin_reservation_identity_upd BEFORE UPDATE ON stock_reservations FOR EACH ROW WHEN (OLD.requires_qualified_origin IS DISTINCT FROM NEW.requires_qualified_origin OR (OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.supply_type, OLD.supply_id, OLD.source_doc_type, OLD.source_doc_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty) IS DISTINCT FROM (NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.supply_type, NEW.supply_id, NEW.source_doc_type, NEW.source_doc_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty) OR (NEW.owner_type = 'PRODUCTION_MATERIAL_DEMAND' AND (NEW.qty - NEW.released_qty > OLD.qty - OLD.released_qty OR NEW.consumed_qty > OLD.consumed_qty))) EXECUTE FUNCTION fn_guard_qualified_origin_reservation_identity();

-- stock_reservations.trg_guard_subcontract_preparation_reservation_identity
DROP TRIGGER trg_guard_subcontract_preparation_reservation_identity ON stock_reservations;
CREATE TRIGGER trg_guard_subcontract_preparation_reservation_identity BEFORE DELETE ON stock_reservations FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_preparation_reservation_identity();
CREATE TRIGGER trg_guard_subcontract_preparation_reservation_identity_upd BEFORE UPDATE ON stock_reservations FOR EACH ROW WHEN (OLD.owner_type IN ('SUBCONTRACT_PREPARE_TASK', 'SUBCONTRACT_OUTBOUND', 'SUBCONTRACT_ORDER_PREPARATION') AND OLD.supply_type = 'PRODUCTION_FINISHED_IN' AND ((OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.supply_type, OLD.supply_id, OLD.source_doc_type, OLD.source_doc_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty) IS DISTINCT FROM (NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.supply_type, NEW.supply_id, NEW.source_doc_type, NEW.source_doc_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty))) EXECUTE FUNCTION fn_guard_subcontract_preparation_reservation_identity();

-- stock_reservations.trg_guard_workshop_custody_reservation
DROP TRIGGER trg_guard_workshop_custody_reservation ON stock_reservations;
CREATE TRIGGER trg_guard_workshop_custody_reservation BEFORE INSERT ON stock_reservations FOR EACH ROW WHEN (NEW.owner_type = 'WORKSHOP_CUSTODY') EXECUTE FUNCTION fn_guard_workshop_custody_reservation();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_guard_workshop_custody_reservation;
CREATE TRIGGER trg_guard_workshop_custody_reservation_upd BEFORE UPDATE ON stock_reservations FOR EACH ROW WHEN ((OLD.owner_type = 'WORKSHOP_CUSTODY' OR NEW.owner_type = 'WORKSHOP_CUSTODY' OR OLD.source_doc_type = 'WORKSHOP_RETURN_CUSTODY') AND ((OLD.owner_type, OLD.owner_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.supply_id, OLD.source_doc_type, OLD.source_doc_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.owner_type, NEW.owner_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.supply_id, NEW.source_doc_type, NEW.source_doc_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.is_deleted))) EXECUTE FUNCTION fn_guard_workshop_custody_reservation();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_guard_workshop_custody_reservation_upd;

-- stock_reservations.trg_main_warehouse_public_stock_budget
-- 函数只在「已占用量(数量-释放)」变大时才检查主仓公共库存预算，条件与函数入口逐字等价。
DROP TRIGGER trg_main_warehouse_public_stock_budget ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_main_warehouse_public_stock_budget AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type = 'PRODUCTION_MATERIAL_DEMAND' AND ((CASE WHEN NEW.is_deleted THEN 0 ELSE NEW.qty - NEW.released_qty END) <= 0) IS NOT TRUE) EXECUTE FUNCTION fn_check_main_warehouse_public_stock_budget();
CREATE CONSTRAINT TRIGGER trg_main_warehouse_public_stock_budget_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type = 'PRODUCTION_MATERIAL_DEMAND' AND ((CASE WHEN NEW.is_deleted THEN 0 ELSE NEW.qty - NEW.released_qty END) <= (CASE WHEN OLD.is_deleted THEN 0 ELSE OLD.qty - OLD.released_qty END)) IS NOT TRUE) EXECUTE FUNCTION fn_check_main_warehouse_public_stock_budget();

-- stock_reservations.trg_make_receipt_reservation_source
DROP TRIGGER trg_make_receipt_reservation_source ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_make_receipt_reservation_source AFTER INSERT OR DELETE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_reservation_source_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.source, OLD.source_doc_type, OLD.is_deleted, OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.demand_id, OLD.supply_type) IS DISTINCT FROM (NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.source, NEW.source_doc_type, NEW.is_deleted, NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.demand_id, NEW.supply_type)) EXECUTE FUNCTION fn_check_make_receipt_source();

-- stock_reservations.trg_purchase_reservation_receipt_provenance
-- 被 trg_receipt_reservation_conservation 完全包含：覆盖校验在容量检查后逐条断言同一批生效分配。
DROP TRIGGER trg_purchase_reservation_receipt_provenance ON stock_reservations;

-- stock_reservations.trg_qualified_origin_target_coverage
DROP TRIGGER trg_qualified_origin_target_coverage ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_qualified_origin_target_coverage AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.requires_qualified_origin) EXECUTE FUNCTION fn_check_qualified_origin_formal_coverage();
CREATE CONSTRAINT TRIGGER trg_qualified_origin_target_coverage_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.requires_qualified_origin AND ((OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.source, OLD.source_doc_type, OLD.source_doc_id, OLD.created_at, OLD.is_deleted, OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.demand_id, OLD.requires_qualified_origin) IS DISTINCT FROM (NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.source, NEW.source_doc_type, NEW.source_doc_id, NEW.created_at, NEW.is_deleted, NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.demand_id, NEW.requires_qualified_origin))) EXECUTE FUNCTION fn_check_qualified_origin_formal_coverage();

-- stock_reservations.trg_receipt_reservation_conservation
DROP TRIGGER trg_receipt_reservation_conservation ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_receipt_reservation_conservation AFTER INSERT OR DELETE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_purchase_receipt_conservation();
CREATE CONSTRAINT TRIGGER trg_receipt_reservation_conservation_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.order_item_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.is_deleted, OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.demand_id, OLD.supply_type) IS DISTINCT FROM (NEW.order_item_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.is_deleted, NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.demand_id, NEW.supply_type)) EXECUTE FUNCTION fn_check_purchase_receipt_conservation();

-- stock_reservations.trg_subcontract_outbound_reservation_guard
DROP TRIGGER trg_subcontract_outbound_reservation_guard ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_subcontract_outbound_reservation_guard AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type = 'SUBCONTRACT_OUTBOUND') EXECUTE FUNCTION fn_check_subcontract_outbound_reservation();
CREATE CONSTRAINT TRIGGER trg_subcontract_outbound_reservation_guard_del AFTER DELETE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.owner_type = 'SUBCONTRACT_OUTBOUND') EXECUTE FUNCTION fn_check_subcontract_outbound_reservation();
CREATE CONSTRAINT TRIGGER trg_subcontract_outbound_reservation_guard_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.owner_type = 'SUBCONTRACT_OUTBOUND' OR NEW.owner_type = 'SUBCONTRACT_OUTBOUND') AND ((OLD.order_item_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.source, OLD.source_doc_type, OLD.source_doc_id, OLD.is_deleted, OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.supply_type, OLD.supply_id) IS DISTINCT FROM (NEW.order_item_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.source, NEW.source_doc_type, NEW.source_doc_id, NEW.is_deleted, NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.supply_type, NEW.supply_id))) EXECUTE FUNCTION fn_check_subcontract_outbound_reservation();

-- stock_reservations.trg_subcontract_prepared_source_capacity
DROP TRIGGER trg_subcontract_prepared_source_capacity ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_subcontract_prepared_source_capacity AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type = 'SUBCONTRACT_PREPARE_TASK') EXECUTE FUNCTION fn_check_subcontract_prepared_source_capacity();
CREATE CONSTRAINT TRIGGER trg_subcontract_prepared_source_capacity_del AFTER DELETE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.owner_type = 'SUBCONTRACT_PREPARE_TASK') EXECUTE FUNCTION fn_check_subcontract_prepared_source_capacity();
CREATE CONSTRAINT TRIGGER trg_subcontract_prepared_source_capacity_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.owner_type = 'SUBCONTRACT_PREPARE_TASK' OR NEW.owner_type = 'SUBCONTRACT_PREPARE_TASK') AND ((OLD.qty, OLD.released_qty, OLD.source, OLD.source_doc_id, OLD.is_deleted, OLD.owner_type, OLD.supply_type, OLD.supply_id) IS DISTINCT FROM (NEW.qty, NEW.released_qty, NEW.source, NEW.source_doc_id, NEW.is_deleted, NEW.owner_type, NEW.supply_type, NEW.supply_id))) EXECUTE FUNCTION fn_check_subcontract_prepared_source_capacity();

-- stock_reservations.trg_subcontract_qualified_preparation_origin
DROP TRIGGER trg_subcontract_qualified_preparation_origin ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_subcontract_qualified_preparation_origin AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.owner_type NOT IN ('SUBCONTRACT_PREPARE_TASK', 'SUBCONTRACT_OUTBOUND', 'SUBCONTRACT_ORDER_PREPARATION') OR NEW.supply_type IS DISTINCT FROM 'PRODUCTION_FINISHED_IN') IS NOT TRUE) EXECUTE FUNCTION fn_check_subcontract_qualified_preparation_reservation();
CREATE CONSTRAINT TRIGGER trg_subcontract_qualified_preparation_origin_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.owner_type NOT IN ('SUBCONTRACT_PREPARE_TASK', 'SUBCONTRACT_OUTBOUND', 'SUBCONTRACT_ORDER_PREPARATION') OR NEW.supply_type IS DISTINCT FROM 'PRODUCTION_FINISHED_IN') IS NOT TRUE AND ((OLD.order_item_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.source, OLD.source_doc_type, OLD.source_doc_id, OLD.is_deleted, OLD.owner_type, OLD.owner_id, OLD.purpose, OLD.supply_type, OLD.supply_id) IS DISTINCT FROM (NEW.order_item_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.source, NEW.source_doc_type, NEW.source_doc_id, NEW.is_deleted, NEW.owner_type, NEW.owner_id, NEW.purpose, NEW.supply_type, NEW.supply_id))) EXECUTE FUNCTION fn_check_subcontract_qualified_preparation_reservation();

-- stock_reservations.trg_subcontract_receipt_reservation_conservation
DROP TRIGGER trg_subcontract_receipt_reservation_conservation ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_subcontract_receipt_reservation_conservation AFTER INSERT OR DELETE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_receipt_reservation();
CREATE CONSTRAINT TRIGGER trg_subcontract_receipt_reservation_conservation_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.order_item_id, OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.is_deleted, OLD.owner_type, OLD.purpose, OLD.demand_id, OLD.supply_type) IS DISTINCT FROM (NEW.order_item_id, NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.is_deleted, NEW.owner_type, NEW.purpose, NEW.demand_id, NEW.supply_type)) EXECUTE FUNCTION fn_check_subcontract_receipt_reservation();

-- stock_reservations.trg_validate_preplan_entitlement_reservation_balance
DROP TRIGGER trg_validate_preplan_entitlement_reservation_balance ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_entitlement_reservation_balance AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.owner_type <> 'PREPLAN_ANALYSIS') IS NOT TRUE) EXECUTE FUNCTION fn_validate_preplan_entitlement_conservation();
CREATE CONSTRAINT TRIGGER trg_validate_preplan_entitlement_reservation_balance_del AFTER DELETE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.owner_type <> 'PREPLAN_ANALYSIS') IS NOT TRUE) EXECUTE FUNCTION fn_validate_preplan_entitlement_conservation();
CREATE CONSTRAINT TRIGGER trg_validate_preplan_entitlement_reservation_balance_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.owner_type <> 'PREPLAN_ANALYSIS') IS NOT TRUE AND ((OLD.qty, OLD.consumed_qty, OLD.released_qty, OLD.status, OLD.is_deleted, OLD.owner_type) IS DISTINCT FROM (NEW.qty, NEW.consumed_qty, NEW.released_qty, NEW.status, NEW.is_deleted, NEW.owner_type))) EXECUTE FUNCTION fn_validate_preplan_entitlement_conservation();

-- stock_reservations.trg_workshop_source_reservation_quantity
DROP TRIGGER trg_workshop_source_reservation_quantity ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_workshop_source_reservation_quantity AFTER INSERT ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type IN ('PRODUCTION_MATERIAL_DEMAND', 'WORKSHOP_CUSTODY')) EXECUTE FUNCTION fn_assert_workshop_direct_source_allocation();
CREATE CONSTRAINT TRIGGER trg_workshop_source_reservation_quantity_upd AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type IN ('PRODUCTION_MATERIAL_DEMAND', 'WORKSHOP_CUSTODY') AND ((OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.qty, OLD.released_qty, OLD.status, OLD.source, OLD.created_at, OLD.is_deleted, OLD.owner_type) IS DISTINCT FROM (NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.qty, NEW.released_qty, NEW.status, NEW.source, NEW.created_at, NEW.is_deleted, NEW.owner_type))) EXECUTE FUNCTION fn_assert_workshop_direct_source_allocation();

-- stock_documents.trg_assert_stock_document_segment_sales_status
DROP TRIGGER trg_assert_stock_document_segment_sales_status ON stock_documents;
CREATE CONSTRAINT TRIGGER trg_assert_stock_document_segment_sales_status AFTER UPDATE OF status, is_deleted ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.status, NEW.is_deleted)) EXECUTE FUNCTION fn_assert_stock_document_segment_sales_status();

-- stock_documents.trg_guard_execution_segment_draw_approval
DROP TRIGGER trg_guard_execution_segment_draw_approval ON stock_documents;
CREATE TRIGGER trg_guard_execution_segment_draw_approval BEFORE UPDATE OF status ON stock_documents FOR EACH ROW WHEN ((NEW.doc_type <> 'DRAW' OR NEW.status IS DISTINCT FROM 1 OR OLD.status IS NOT DISTINCT FROM NEW.status) IS NOT TRUE) EXECUTE FUNCTION fn_guard_execution_segment_draw_approval();

-- stock_documents.trg_guard_execution_segment_finished_in
DROP TRIGGER trg_guard_execution_segment_finished_in ON stock_documents;
CREATE TRIGGER trg_guard_execution_segment_finished_in BEFORE UPDATE OF status ON stock_documents FOR EACH ROW WHEN (NEW.doc_type = 'FINISHED_IN' AND OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION fn_guard_execution_segment_finished_in();

-- stock_documents.trg_guard_production_linked_stock_document
-- 函数只在这 17 个身份列之一变化时才会拒绝，其余分支都是放行。
DROP TRIGGER trg_guard_production_linked_stock_document ON stock_documents;
CREATE TRIGGER trg_guard_production_linked_stock_document BEFORE DELETE ON stock_documents FOR EACH ROW EXECUTE FUNCTION fn_guard_production_linked_stock_document();
CREATE TRIGGER trg_guard_production_linked_stock_document_upd BEFORE UPDATE ON stock_documents FOR EACH ROW WHEN ((OLD.doc_type, OLD.bill_no, OLD.bill_date, OLD.warehouse_id, OLD.to_warehouse_id, OLD.supplier_id, OLD.client_id, OLD.worker_id, OLD.maker_id, OLD.plan_no, OLD.source_doc_no, OLD.department_id, OLD.ass_team, OLD.total_original, OLD.total_local, OLD.is_deleted, OLD.deleted_at) IS DISTINCT FROM (NEW.doc_type, NEW.bill_no, NEW.bill_date, NEW.warehouse_id, NEW.to_warehouse_id, NEW.supplier_id, NEW.client_id, NEW.worker_id, NEW.maker_id, NEW.plan_no, NEW.source_doc_no, NEW.department_id, NEW.ass_team, NEW.total_original, NEW.total_local, NEW.is_deleted, NEW.deleted_at)) EXECUTE FUNCTION fn_guard_production_linked_stock_document();

-- stock_documents.trg_make_receipt_stock_document_source
DROP TRIGGER trg_make_receipt_stock_document_source ON stock_documents;
CREATE CONSTRAINT TRIGGER trg_make_receipt_stock_document_source AFTER INSERT OR DELETE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_stock_document_source_upd AFTER UPDATE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_type, OLD.warehouse_id, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.doc_type, NEW.warehouse_id, NEW.status, NEW.is_deleted)) EXECUTE FUNCTION fn_check_make_receipt_source();

-- stock_documents.trg_purchase_draw_receipt_provenance
-- 被 trg_receipt_stock_document_provenance 完全包含：后者对这些分配所属预留做完整覆盖校验。
DROP TRIGGER trg_purchase_draw_receipt_provenance ON stock_documents;

-- stock_documents.trg_receipt_stock_document_provenance
DROP TRIGGER trg_receipt_stock_document_provenance ON stock_documents;
CREATE CONSTRAINT TRIGGER trg_receipt_stock_document_provenance AFTER INSERT OR DELETE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_receipt_draw_provenance();
CREATE CONSTRAINT TRIGGER trg_receipt_stock_document_provenance_upd AFTER UPDATE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_type, OLD.warehouse_id, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.doc_type, NEW.warehouse_id, NEW.status, NEW.is_deleted)) EXECUTE FUNCTION fn_check_receipt_draw_provenance();

-- stock_documents.trg_reconcile_segments_from_finished_in
DROP TRIGGER trg_reconcile_segments_from_finished_in ON stock_documents;
CREATE TRIGGER trg_reconcile_segments_from_finished_in AFTER UPDATE OF status ON stock_documents FOR EACH ROW WHEN (NEW.doc_type = 'FINISHED_IN' AND NEW.status IS DISTINCT FROM OLD.status) EXECUTE FUNCTION fn_reconcile_segments_from_finished_in();

-- stock_documents.trg_stock_documents_maker_current
DROP TRIGGER trg_stock_documents_maker_current ON stock_documents;
CREATE TRIGGER trg_stock_documents_maker_current BEFORE INSERT ON stock_documents FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_stock_documents_maker_current_upd BEFORE UPDATE OF maker_id ON stock_documents FOR EACH ROW WHEN (OLD.maker_id IS DISTINCT FROM NEW.maker_id) EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');

-- stock_documents.trg_subcontract_draw_provenance
DROP TRIGGER trg_subcontract_draw_provenance ON stock_documents;
CREATE CONSTRAINT TRIGGER trg_subcontract_draw_provenance AFTER INSERT OR DELETE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_draw_provenance_upd AFTER UPDATE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_type, OLD.warehouse_id, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.doc_type, NEW.warehouse_id, NEW.status, NEW.is_deleted)) EXECUTE FUNCTION fn_check_subcontract_receipt_provenance_source();

-- stock_documents.trg_subcontract_finished_custody_activation
DROP TRIGGER trg_subcontract_finished_custody_activation ON stock_documents;
CREATE CONSTRAINT TRIGGER trg_subcontract_finished_custody_activation AFTER INSERT ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.doc_type = 'FINISHED_IN' AND NEW.status IN (1, -1)) EXECUTE FUNCTION fn_check_subcontract_finished_custody_activation();
CREATE CONSTRAINT TRIGGER trg_subcontract_finished_custody_activation_upd AFTER UPDATE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.doc_type = 'FINISHED_IN' AND NEW.status IN (1, -1) AND ((OLD.doc_type, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.doc_type, NEW.status, NEW.is_deleted))) EXECUTE FUNCTION fn_check_subcontract_finished_custody_activation();

-- stock_documents.trg_subcontract_prep_finished_stock_doc_guard
DROP TRIGGER trg_subcontract_prep_finished_stock_doc_guard ON stock_documents;
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_stock_doc_guard AFTER INSERT OR DELETE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_stock_doc_guard_upd AFTER UPDATE ON stock_documents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_type, OLD.warehouse_id, OLD.status, OLD.is_deleted, OLD.source_daily_report_id) IS DISTINCT FROM (NEW.doc_type, NEW.warehouse_id, NEW.status, NEW.is_deleted, NEW.source_daily_report_id)) EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();

-- stock_document_items.trg_assert_finished_in_segment_sales_fact
DROP TRIGGER trg_assert_finished_in_segment_sales_fact ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_assert_finished_in_segment_sales_fact AFTER INSERT ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.execution_segment_sales_allocation_id IS NOT NULL) EXECUTE FUNCTION fn_assert_execution_segment_sales_fact_row();
CREATE CONSTRAINT TRIGGER trg_assert_finished_in_segment_sales_fact_del AFTER DELETE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.execution_segment_sales_allocation_id IS NOT NULL) EXECUTE FUNCTION fn_assert_execution_segment_sales_fact_row();
CREATE CONSTRAINT TRIGGER trg_assert_finished_in_segment_sales_fact_upd AFTER UPDATE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.execution_segment_sales_allocation_id IS NOT NULL OR NEW.execution_segment_sales_allocation_id IS NOT NULL) AND ((OLD.doc_id, OLD.qty, OLD.is_deleted, OLD.execution_segment_sales_allocation_id) IS DISTINCT FROM (NEW.doc_id, NEW.qty, NEW.is_deleted, NEW.execution_segment_sales_allocation_id))) EXECUTE FUNCTION fn_assert_execution_segment_sales_fact_row();

-- stock_document_items.trg_check_execution_segment_stock_item
DROP TRIGGER trg_check_execution_segment_stock_item ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_stock_item AFTER INSERT OR DELETE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_stock_item_upd AFTER UPDATE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_id, OLD.unit_rate, OLD.qty, OLD.base_qty, OLD.is_deleted, OLD.execution_segment_id) IS DISTINCT FROM (NEW.doc_id, NEW.unit_rate, NEW.qty, NEW.base_qty, NEW.is_deleted, NEW.execution_segment_id)) EXECUTE FUNCTION fn_check_execution_segment_integrity();

-- stock_document_items.trg_guard_production_draw_issue_requested_qty
DROP TRIGGER trg_guard_production_draw_issue_requested_qty ON stock_document_items;
CREATE TRIGGER trg_guard_production_draw_issue_requested_qty BEFORE UPDATE OF issued_qty ON stock_document_items FOR EACH ROW WHEN (COALESCE(NEW.issued_qty, 0) > COALESCE(OLD.issued_qty, 0)) EXECUTE FUNCTION fn_guard_production_draw_issue_requested_qty();
ALTER TABLE stock_document_items ENABLE ALWAYS TRIGGER trg_guard_production_draw_issue_requested_qty;

-- stock_document_items.trg_guard_production_linked_stock_document_item
-- 函数只在这些身份/数量列之一变化时才会拒绝，其余分支都是放行。
DROP TRIGGER trg_guard_production_linked_stock_document_item ON stock_document_items;
CREATE TRIGGER trg_guard_production_linked_stock_document_item BEFORE DELETE ON stock_document_items FOR EACH ROW EXECUTE FUNCTION fn_guard_production_linked_stock_document_item();
CREATE TRIGGER trg_guard_production_linked_stock_document_item_upd BEFORE UPDATE ON stock_document_items FOR EACH ROW WHEN ((OLD.doc_id, OLD.bill_type, OLD.bill_no, OLD.bill_date, OLD.line_no, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.unit_rate, OLD.qty, OLD.reported_qty, OLD.base_qty, OLD.price, OLD.amount_original, OLD.amount_local, OLD.weight, OLD.gift_qty, OLD.surplus_qty, OLD.count_qty, OLD.place, OLD.upstream_item_id, OLD.execution_segment_id, OLD.execution_segment_sales_allocation_id, OLD.source_daily_report_item_id, OLD.source_doc_no, OLD.remark, OLD.is_deleted, OLD.deleted_at) IS DISTINCT FROM (NEW.doc_id, NEW.bill_type, NEW.bill_no, NEW.bill_date, NEW.line_no, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.unit_rate, NEW.qty, NEW.reported_qty, NEW.base_qty, NEW.price, NEW.amount_original, NEW.amount_local, NEW.weight, NEW.gift_qty, NEW.surplus_qty, NEW.count_qty, NEW.place, NEW.upstream_item_id, NEW.execution_segment_id, NEW.execution_segment_sales_allocation_id, NEW.source_daily_report_item_id, NEW.source_doc_no, NEW.remark, NEW.is_deleted, NEW.deleted_at)) EXECUTE FUNCTION fn_guard_production_linked_stock_document_item();

-- stock_document_items.trg_make_receipt_stock_item_source
DROP TRIGGER trg_make_receipt_stock_item_source ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_make_receipt_stock_item_source AFTER INSERT OR DELETE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_stock_item_source_upd AFTER UPDATE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_id, OLD.bill_type, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.unit_rate, OLD.qty, OLD.base_qty, OLD.upstream_item_id, OLD.is_deleted, OLD.execution_segment_id, OLD.source_daily_report_item_id) IS DISTINCT FROM (NEW.doc_id, NEW.bill_type, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.unit_rate, NEW.qty, NEW.base_qty, NEW.upstream_item_id, NEW.is_deleted, NEW.execution_segment_id, NEW.source_daily_report_item_id)) EXECUTE FUNCTION fn_check_make_receipt_source();

-- stock_document_items.trg_purchase_draw_item_receipt_provenance
-- 被 trg_receipt_stock_document_item_provenance 完全包含(同上)。
DROP TRIGGER trg_purchase_draw_item_receipt_provenance ON stock_document_items;

-- stock_document_items.trg_receipt_stock_document_item_provenance
DROP TRIGGER trg_receipt_stock_document_item_provenance ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_receipt_stock_document_item_provenance AFTER INSERT OR DELETE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_receipt_draw_provenance();
CREATE CONSTRAINT TRIGGER trg_receipt_stock_document_item_provenance_upd AFTER UPDATE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_id, OLD.goods_id, OLD.color_id, OLD.unit_rate, OLD.qty, OLD.base_qty, OLD.is_deleted, OLD.execution_segment_id) IS DISTINCT FROM (NEW.doc_id, NEW.goods_id, NEW.color_id, NEW.unit_rate, NEW.qty, NEW.base_qty, NEW.is_deleted, NEW.execution_segment_id)) EXECUTE FUNCTION fn_check_receipt_draw_provenance();

-- stock_document_items.trg_subcontract_draw_item_provenance
DROP TRIGGER trg_subcontract_draw_item_provenance ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_subcontract_draw_item_provenance AFTER INSERT OR DELETE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_draw_item_provenance_upd AFTER UPDATE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_id, OLD.goods_id, OLD.color_id, OLD.unit_rate, OLD.qty, OLD.base_qty, OLD.is_deleted, OLD.execution_segment_id) IS DISTINCT FROM (NEW.doc_id, NEW.goods_id, NEW.color_id, NEW.unit_rate, NEW.qty, NEW.base_qty, NEW.is_deleted, NEW.execution_segment_id)) EXECUTE FUNCTION fn_check_subcontract_receipt_provenance_source();

-- stock_document_items.trg_subcontract_prep_finished_stock_item_guard
DROP TRIGGER trg_subcontract_prep_finished_stock_item_guard ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_stock_item_guard AFTER INSERT OR DELETE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_stock_item_guard_upd AFTER UPDATE ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.doc_id, OLD.bill_type, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.unit_rate, OLD.qty, OLD.base_qty, OLD.upstream_item_id, OLD.is_deleted, OLD.source_daily_report_item_id) IS DISTINCT FROM (NEW.doc_id, NEW.bill_type, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.unit_rate, NEW.qty, NEW.base_qty, NEW.upstream_item_id, NEW.is_deleted, NEW.source_daily_report_item_id)) EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();

-- stock_document_items.trg_validate_finished_in_execution_segment
DROP TRIGGER trg_validate_finished_in_execution_segment ON stock_document_items;
CREATE TRIGGER trg_validate_finished_in_execution_segment BEFORE INSERT ON stock_document_items FOR EACH ROW EXECUTE FUNCTION fn_validate_finished_in_execution_segment();
CREATE TRIGGER trg_validate_finished_in_execution_segment_upd BEFORE UPDATE OF execution_segment_id, execution_segment_sales_allocation_id, bill_type, upstream_item_id, goods_id, color_id, unit_id ON stock_document_items FOR EACH ROW WHEN ((OLD.execution_segment_id, OLD.execution_segment_sales_allocation_id, OLD.bill_type, OLD.upstream_item_id, OLD.goods_id, OLD.color_id, OLD.unit_id) IS DISTINCT FROM (NEW.execution_segment_id, NEW.execution_segment_sales_allocation_id, NEW.bill_type, NEW.upstream_item_id, NEW.goods_id, NEW.color_id, NEW.unit_id)) EXECUTE FUNCTION fn_validate_finished_in_execution_segment();

-- stock_document_items.trg_validate_finished_in_report_item_capacity
DROP TRIGGER trg_validate_finished_in_report_item_capacity ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_validate_finished_in_report_item_capacity AFTER INSERT ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.source_daily_report_item_id IS NOT NULL) EXECUTE FUNCTION fn_validate_finished_in_report_item_capacity();
CREATE CONSTRAINT TRIGGER trg_validate_finished_in_report_item_capacity_upd AFTER UPDATE OF qty, source_daily_report_item_id, is_deleted ON stock_document_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.source_daily_report_item_id IS NOT NULL AND ((OLD.qty, OLD.source_daily_report_item_id, OLD.is_deleted) IS DISTINCT FROM (NEW.qty, NEW.source_daily_report_item_id, NEW.is_deleted))) EXECUTE FUNCTION fn_validate_finished_in_report_item_capacity();

-- production_plan_items.trg_check_execution_segment_plan_item
DROP TRIGGER trg_check_execution_segment_plan_item ON production_plan_items;
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_plan_item AFTER INSERT OR DELETE ON production_plan_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_plan_item_upd AFTER UPDATE ON production_plan_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.plan_id, OLD.qty, OLD.is_deleted) IS DISTINCT FROM (NEW.plan_id, NEW.qty, NEW.is_deleted)) EXECUTE FUNCTION fn_check_execution_segment_integrity();

-- production_plan_items.trg_guard_material_analysis_plan_item_identity
DROP TRIGGER trg_guard_material_analysis_plan_item_identity ON production_plan_items;
CREATE TRIGGER trg_guard_material_analysis_plan_item_identity BEFORE INSERT OR DELETE ON production_plan_items FOR EACH ROW EXECUTE FUNCTION fn_guard_material_analysis_plan_item_identity();
CREATE TRIGGER trg_guard_material_analysis_plan_item_identity_upd BEFORE UPDATE ON production_plan_items FOR EACH ROW WHEN ((OLD.plan_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.unit_rate, OLD.sales_order_item_id, OLD.qty, OLD.is_deleted) IS DISTINCT FROM (NEW.plan_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.unit_rate, NEW.sales_order_item_id, NEW.qty, NEW.is_deleted)) EXECUTE FUNCTION fn_guard_material_analysis_plan_item_identity();

-- production_plan_items.trg_guard_production_plan_item_supply_update
DROP TRIGGER trg_guard_production_plan_item_supply_update ON production_plan_items;
CREATE CONSTRAINT TRIGGER trg_guard_production_plan_item_supply_update AFTER UPDATE OF id, plan_id, goods_id, color_id, unit_id, unit_rate, qty, is_deleted ON production_plan_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.id, OLD.plan_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.unit_rate, OLD.qty, OLD.is_deleted) IS DISTINCT FROM (NEW.id, NEW.plan_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.unit_rate, NEW.qty, NEW.is_deleted)) EXECUTE FUNCTION fn_guard_production_supply_source_item();
ALTER TABLE production_plan_items ENABLE ALWAYS TRIGGER trg_guard_production_plan_item_supply_update;

-- production_plan_items.trg_make_receipt_plan_item_source
DROP TRIGGER trg_make_receipt_plan_item_source ON production_plan_items;
CREATE CONSTRAINT TRIGGER trg_make_receipt_plan_item_source AFTER INSERT OR DELETE ON production_plan_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_plan_item_source_upd AFTER UPDATE ON production_plan_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.plan_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.unit_rate, OLD.qty, OLD.is_deleted) IS DISTINCT FROM (NEW.plan_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.unit_rate, NEW.qty, NEW.is_deleted)) EXECUTE FUNCTION fn_check_make_receipt_source();

-- production_plan_items.trg_subcontract_prep_finished_production_item_guard
DROP TRIGGER trg_subcontract_prep_finished_production_item_guard ON production_plan_items;
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_production_item_guard AFTER INSERT OR DELETE ON production_plan_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_production_item_guard_upd AFTER UPDATE ON production_plan_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.plan_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.unit_rate, OLD.qty, OLD.is_deleted) IS DISTINCT FROM (NEW.plan_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.unit_rate, NEW.qty, NEW.is_deleted)) EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();

-- production_execution_segments.trg_00_material_snapshot_product_qty
DROP TRIGGER trg_00_material_snapshot_product_qty ON production_execution_segments;
CREATE TRIGGER trg_00_material_snapshot_product_qty BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_material_snapshot_product_qty();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_00_material_snapshot_product_qty;
CREATE TRIGGER trg_00_material_snapshot_product_qty_upd BEFORE UPDATE ON production_execution_segments FOR EACH ROW WHEN (OLD.material_snapshot_product_qty IS DISTINCT FROM NEW.material_snapshot_product_qty) EXECUTE FUNCTION fn_guard_material_snapshot_product_qty();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_00_material_snapshot_product_qty_upd;

-- production_execution_segments.trg_assert_execution_segment_sales_allocation_segment
DROP TRIGGER trg_assert_execution_segment_sales_allocation_segment ON production_execution_segments;
CREATE CONSTRAINT TRIGGER trg_assert_execution_segment_sales_allocation_segment AFTER INSERT ON production_execution_segments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_execution_segment_sales_allocation_segment();
CREATE CONSTRAINT TRIGGER trg_assert_execution_segment_sales_allocation_segment_upd AFTER UPDATE ON production_execution_segments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.package_id, OLD.plan_id, OLD.source_plan_item_id, OLD.planned_qty, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.package_id, NEW.plan_id, NEW.source_plan_item_id, NEW.planned_qty, NEW.status, NEW.is_deleted)) EXECUTE FUNCTION fn_assert_execution_segment_sales_allocation_segment();

-- production_execution_segments.trg_check_execution_segment_row
-- lock_version 每次更新都由 trg_validate_production_execution_segment 递增，唯一读它的是已退役(CANCELLED)拆批源段的证明，所以 CANCELLED 行照旧每次都查。
DROP TRIGGER trg_check_execution_segment_row ON production_execution_segments;
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_row AFTER INSERT OR DELETE ON production_execution_segments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_row_upd AFTER UPDATE ON production_execution_segments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.package_id, OLD.plan_id, OLD.source_plan_item_id, OLD.segment_no, OLD.product_goods_id, OLD.product_color_id, OLD.product_unit_id, OLD.product_unit_rate, OLD.planned_qty, OLD.status, OLD.bom_fingerprint, OLD.is_deleted, OLD.completion_reopened, OLD.material_requirement_mode, OLD.material_snapshot_product_qty, OLD.source_segment_id, OLD.split_root_segment_id, OLD.split_start_qty, OLD.split_material_snapshot, OLD.continuous_supply) IS DISTINCT FROM (NEW.package_id, NEW.plan_id, NEW.source_plan_item_id, NEW.segment_no, NEW.product_goods_id, NEW.product_color_id, NEW.product_unit_id, NEW.product_unit_rate, NEW.planned_qty, NEW.status, NEW.bom_fingerprint, NEW.is_deleted, NEW.completion_reopened, NEW.material_requirement_mode, NEW.material_snapshot_product_qty, NEW.source_segment_id, NEW.split_root_segment_id, NEW.split_start_qty, NEW.split_material_snapshot, NEW.continuous_supply) OR NEW.status = 'CANCELLED') EXECUTE FUNCTION fn_check_execution_segment_integrity();

-- production_execution_segments.trg_execution_confirmed_route_start
DROP TRIGGER trg_execution_confirmed_route_start ON production_execution_segments;
CREATE TRIGGER trg_execution_confirmed_route_start BEFORE UPDATE ON production_execution_segments FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('DISPATCHED', 'IN_PROGRESS')) EXECUTE FUNCTION fn_guard_execution_confirmed_route_start();

-- production_execution_segments.trg_final_report_target_change
DROP TRIGGER trg_final_report_target_change ON production_execution_segments;
CREATE CONSTRAINT TRIGGER trg_final_report_target_change AFTER UPDATE ON production_execution_segments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.planned_qty IS DISTINCT FROM NEW.planned_qty) EXECUTE FUNCTION fn_check_final_report_target_change();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_final_report_target_change;

-- production_execution_segments.trg_guard_execution_segment_readiness_policy
DROP TRIGGER trg_guard_execution_segment_readiness_policy ON production_execution_segments;
CREATE TRIGGER trg_guard_execution_segment_readiness_policy BEFORE UPDATE OF auto_promote_when_ready ON production_execution_segments FOR EACH ROW WHEN (OLD.auto_promote_when_ready IS DISTINCT FROM NEW.auto_promote_when_ready) EXECUTE FUNCTION fn_guard_execution_segment_readiness_policy();

-- production_execution_segments.trg_guard_execution_segment_requirement_shape
DROP TRIGGER trg_guard_execution_segment_requirement_shape ON production_execution_segments;
CREATE TRIGGER trg_guard_execution_segment_requirement_shape BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_segment_requirement_shape();
CREATE TRIGGER trg_guard_execution_segment_requirement_shape_upd BEFORE UPDATE OF material_requirement_mode, zero_material_reason, zero_material_analysis_id, zero_material_exception_reason, zero_material_authorized_by, status ON production_execution_segments FOR EACH ROW WHEN ((NEW.material_requirement_mode = 'ZERO_MATERIAL' AND NEW.status = 'WAITING') OR (OLD.material_requirement_mode, OLD.zero_material_reason, OLD.zero_material_analysis_id, OLD.zero_material_exception_reason, OLD.zero_material_authorized_by) IS DISTINCT FROM (NEW.material_requirement_mode, NEW.zero_material_reason, NEW.zero_material_analysis_id, NEW.zero_material_exception_reason, NEW.zero_material_authorized_by)) EXECUTE FUNCTION fn_guard_execution_segment_requirement_shape();

-- production_execution_segments.trg_guard_execution_split_segment_identity
DROP TRIGGER trg_guard_execution_split_segment_identity ON production_execution_segments;
CREATE TRIGGER trg_guard_execution_split_segment_identity BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_split_history();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_split_segment_identity;
CREATE TRIGGER trg_guard_execution_split_segment_identity_upd BEFORE UPDATE ON production_execution_segments FOR EACH ROW WHEN ((OLD.source_segment_id, OLD.split_root_segment_id, OLD.split_start_qty, OLD.split_material_snapshot) IS DISTINCT FROM (NEW.source_segment_id, NEW.split_root_segment_id, NEW.split_start_qty, NEW.split_material_snapshot)) EXECUTE FUNCTION fn_guard_execution_split_history();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_split_segment_identity_upd;

-- production_execution_segments.trg_guard_execution_start_material_custody
DROP TRIGGER trg_guard_execution_start_material_custody ON production_execution_segments;
CREATE TRIGGER trg_guard_execution_start_material_custody BEFORE UPDATE OF status ON production_execution_segments FOR EACH ROW WHEN (NEW.status = 'IN_PROGRESS' AND OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION fn_guard_execution_start_material_custody();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_start_material_custody;

-- production_execution_segments.trg_guard_execution_workshop_material_custody
DROP TRIGGER trg_guard_execution_workshop_material_custody ON production_execution_segments;
CREATE TRIGGER trg_guard_execution_workshop_material_custody BEFORE UPDATE OF workshop_department_id ON production_execution_segments FOR EACH ROW WHEN (OLD.workshop_department_id IS DISTINCT FROM NEW.workshop_department_id) EXECUTE FUNCTION fn_guard_execution_workshop_material_custody();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_workshop_material_custody;

-- production_execution_segments.trg_guard_production_assignment_scope
DROP TRIGGER trg_guard_production_assignment_scope ON production_execution_segments;
CREATE TRIGGER trg_guard_production_assignment_scope BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_production_assignment_scope();
CREATE TRIGGER trg_guard_production_assignment_scope_upd BEFORE UPDATE OF workshop_department_id, team_department_id ON production_execution_segments FOR EACH ROW WHEN ((OLD.workshop_department_id, OLD.team_department_id) IS DISTINCT FROM (NEW.workshop_department_id, NEW.team_department_id)) EXECUTE FUNCTION fn_guard_production_assignment_scope();

-- production_material_analyses.trg_direct_subcontract_analysis_preparation
DROP TRIGGER trg_direct_subcontract_analysis_preparation ON production_material_analyses;
CREATE CONSTRAINT TRIGGER trg_direct_subcontract_analysis_preparation AFTER UPDATE ON production_material_analyses DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.warehouse_id, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.warehouse_id, NEW.status, NEW.is_deleted)) EXECUTE FUNCTION fn_check_direct_subcontract_preparation_owner();
ALTER TABLE production_material_analyses ENABLE ALWAYS TRIGGER trg_direct_subcontract_analysis_preparation;

-- production_material_analyses.trg_future_transfer_analysis
DROP TRIGGER trg_future_transfer_analysis ON production_material_analyses;
CREATE TRIGGER trg_future_transfer_analysis BEFORE UPDATE OF status, is_deleted ON production_material_analyses FOR EACH ROW WHEN ((OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.status, NEW.is_deleted) AND (NEW.status <> 'CANCELLED' AND NOT NEW.is_deleted) IS NOT TRUE) EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
ALTER TABLE production_material_analyses ENABLE ALWAYS TRIGGER trg_future_transfer_analysis;

-- production_material_analyses.trg_guard_preplan_exact_analysis_warehouse_v474
DROP TRIGGER trg_guard_preplan_exact_analysis_warehouse_v474 ON production_material_analyses;
CREATE TRIGGER trg_guard_preplan_exact_analysis_warehouse_v474 BEFORE UPDATE OF warehouse_id ON production_material_analyses FOR EACH ROW WHEN (OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id) EXECUTE FUNCTION fn_guard_preplan_exact_warehouse_identity_v474();

-- production_material_analyses.trg_production_analyses_maker_current
DROP TRIGGER trg_production_analyses_maker_current ON production_material_analyses;
CREATE TRIGGER trg_production_analyses_maker_current BEFORE INSERT ON production_material_analyses FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');
CREATE TRIGGER trg_production_analyses_maker_current_upd BEFORE UPDATE OF maker_id ON production_material_analyses FOR EACH ROW WHEN (OLD.maker_id IS DISTINCT FROM NEW.maker_id) EXECUTE FUNCTION fn_require_current_employee_reference('maker_id');

-- production_material_analyses.trg_validate_material_analysis_warehouses
DROP TRIGGER trg_validate_material_analysis_warehouses ON production_material_analyses;
CREATE TRIGGER trg_validate_material_analysis_warehouses BEFORE INSERT ON production_material_analyses FOR EACH ROW EXECUTE FUNCTION fn_validate_material_analysis_warehouses();
CREATE TRIGGER trg_validate_material_analysis_warehouses_upd BEFORE UPDATE OF warehouse_id, participating_warehouse_ids ON production_material_analyses FOR EACH ROW WHEN ((OLD.warehouse_id, OLD.participating_warehouse_ids) IS DISTINCT FROM (NEW.warehouse_id, NEW.participating_warehouse_ids) OR NEW.warehouse_id IS NULL OR NEW.participating_warehouse_ids IS NULL OR cardinality(NEW.participating_warehouse_ids) = 0) EXECUTE FUNCTION fn_validate_material_analysis_warehouses();

-- production_material_analyses.trg_validate_preplan_reallocation_analysis
DROP TRIGGER trg_validate_preplan_reallocation_analysis ON production_material_analyses;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_reallocation_analysis AFTER UPDATE OF warehouse_id, status, is_deleted ON production_material_analyses DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.warehouse_id, OLD.status, OLD.is_deleted) IS DISTINCT FROM (NEW.warehouse_id, NEW.status, NEW.is_deleted)) EXECUTE FUNCTION fn_validate_preplan_material_reallocation_endpoints();

-- production_material_analysis_items.trg_bind_direct_subcontract_preparation
DROP TRIGGER trg_bind_direct_subcontract_preparation ON production_material_analysis_items;
CREATE TRIGGER trg_bind_direct_subcontract_preparation BEFORE INSERT OR DELETE ON production_material_analysis_items FOR EACH ROW EXECUTE FUNCTION fn_bind_direct_subcontract_preparation();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_bind_direct_subcontract_preparation;
CREATE TRIGGER trg_bind_direct_subcontract_preparation_upd BEFORE UPDATE ON production_material_analysis_items FOR EACH ROW WHEN ((OLD.subcontract_order_item_id IS NOT NULL AND ((OLD.subcontract_order_item_id, OLD.subcontract_order_qty_base, OLD.source_ref, OLD.requested_qty) IS DISTINCT FROM (NEW.subcontract_order_item_id, NEW.subcontract_order_qty_base, NEW.source_ref, NEW.requested_qty))) OR (OLD.subcontract_order_item_id IS NULL AND (NEW.source_type <> 'SUBCONTRACT_PREPARATION' OR NEW.source_ref NOT LIKE 'SC-ORDER:%') IS NOT TRUE)) EXECUTE FUNCTION fn_bind_direct_subcontract_preparation();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_bind_direct_subcontract_preparation_upd;

-- production_material_analysis_items.trg_check_root_material_owner
DROP TRIGGER trg_check_root_material_owner ON production_material_analysis_items;
CREATE CONSTRAINT TRIGGER trg_check_root_material_owner AFTER INSERT ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.root_material_id IS NOT NULL) EXECUTE FUNCTION fn_check_root_material_owner();
CREATE CONSTRAINT TRIGGER trg_check_root_material_owner_upd AFTER UPDATE ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.root_material_id IS NOT NULL AND ((OLD.analysis_id, OLD.goods_id, OLD.color_id, OLD.root_material_id) IS DISTINCT FROM (NEW.analysis_id, NEW.goods_id, NEW.color_id, NEW.root_material_id))) EXECUTE FUNCTION fn_check_root_material_owner();

-- production_material_analysis_items.trg_check_root_output_quantity
DROP TRIGGER trg_check_root_output_quantity ON production_material_analysis_items;
CREATE CONSTRAINT TRIGGER trg_check_root_output_quantity AFTER INSERT ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_root_output_quantity();
CREATE CONSTRAINT TRIGGER trg_check_root_output_quantity_upd AFTER UPDATE ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.requested_qty, OLD.submitted_qty, OLD.approved_qty, OLD.root_material_id, OLD.root_fulfilled_qty) IS DISTINCT FROM (NEW.requested_qty, NEW.submitted_qty, NEW.approved_qty, NEW.root_material_id, NEW.root_fulfilled_qty)) EXECUTE FUNCTION fn_check_root_output_quantity();

-- production_material_analysis_items.trg_guard_preplan_direct_make_source_identity
DROP TRIGGER trg_guard_preplan_direct_make_source_identity ON production_material_analysis_items;
CREATE TRIGGER trg_guard_preplan_direct_make_source_identity BEFORE UPDATE ON production_material_analysis_items FOR EACH ROW WHEN ((OLD.analysis_id, OLD.source_type, OLD.parent_analysis_material_id, OLD.goods_id, OLD.color_id, OLD.unit_id) IS DISTINCT FROM (NEW.analysis_id, NEW.source_type, NEW.parent_analysis_material_id, NEW.goods_id, NEW.color_id, NEW.unit_id)) EXECUTE FUNCTION fn_guard_preplan_direct_make_source_identity();

-- production_material_analysis_items.trg_guard_root_material_pointer
DROP TRIGGER trg_guard_root_material_pointer ON production_material_analysis_items;
CREATE TRIGGER trg_guard_root_material_pointer BEFORE UPDATE OF root_material_id ON production_material_analysis_items FOR EACH ROW WHEN (OLD.root_material_id IS NOT NULL AND NEW.root_material_id IS DISTINCT FROM OLD.root_material_id) EXECUTE FUNCTION fn_guard_root_material_identity();

-- production_material_analysis_items.trg_guard_subcontract_qualified_child_identity
DROP TRIGGER trg_guard_subcontract_qualified_child_identity ON production_material_analysis_items;
CREATE TRIGGER trg_guard_subcontract_qualified_child_identity BEFORE UPDATE ON production_material_analysis_items FOR EACH ROW WHEN ((OLD.analysis_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.source_type, OLD.source_ref, OLD.parent_analysis_material_id, OLD.subcontract_order_item_id) IS DISTINCT FROM (NEW.analysis_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.source_type, NEW.source_ref, NEW.parent_analysis_material_id, NEW.subcontract_order_item_id)) EXECUTE FUNCTION fn_guard_subcontract_qualified_source_identity();

-- production_material_analysis_items.trg_subcontract_preparation_analysis_source_guard
DROP TRIGGER trg_subcontract_preparation_analysis_source_guard ON production_material_analysis_items;
CREATE CONSTRAINT TRIGGER trg_subcontract_preparation_analysis_source_guard AFTER INSERT OR DELETE ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_preparation_analysis_source();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_subcontract_preparation_analysis_source_guard;
CREATE CONSTRAINT TRIGGER trg_subcontract_preparation_analysis_source_guard_upd AFTER UPDATE ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.analysis_id, OLD.source_type, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.source_ref, OLD.requested_qty, OLD.is_deleted, OLD.subcontract_order_item_id, OLD.subcontract_order_qty_base) IS DISTINCT FROM (NEW.analysis_id, NEW.source_type, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.source_ref, NEW.requested_qty, NEW.is_deleted, NEW.subcontract_order_item_id, NEW.subcontract_order_qty_base)) EXECUTE FUNCTION fn_check_subcontract_preparation_analysis_source();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_subcontract_preparation_analysis_source_guard_upd;

-- production_material_analysis_items.trg_validate_make_component_source_dimension
DROP TRIGGER trg_validate_make_component_source_dimension ON production_material_analysis_items;
CREATE TRIGGER trg_validate_make_component_source_dimension BEFORE INSERT ON production_material_analysis_items FOR EACH ROW EXECUTE FUNCTION fn_validate_make_component_source_dimension();
CREATE TRIGGER trg_validate_make_component_source_dimension_upd BEFORE UPDATE OF source_type, parent_analysis_material_id, goods_id, color_id, unit_id ON production_material_analysis_items FOR EACH ROW WHEN ((NEW.source_type NOT IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')) IS NOT TRUE AND ((OLD.source_type, OLD.parent_analysis_material_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.analysis_id) IS DISTINCT FROM (NEW.source_type, NEW.parent_analysis_material_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.analysis_id))) EXECUTE FUNCTION fn_validate_make_component_source_dimension();

-- production_material_analysis_items.trg_validate_pma_item_borrow_endpoint
DROP TRIGGER trg_validate_pma_item_borrow_endpoint ON production_material_analysis_items;
CREATE CONSTRAINT TRIGGER trg_validate_pma_item_borrow_endpoint AFTER UPDATE OF analysis_id, is_deleted ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.analysis_id, OLD.is_deleted) IS DISTINCT FROM (NEW.analysis_id, NEW.is_deleted)) EXECUTE FUNCTION fn_validate_production_material_analysis_borrow_endpoint();

-- production_material_analysis_materials.trg_guard_pma_material_exact_peg_identity
DROP TRIGGER trg_guard_pma_material_exact_peg_identity ON production_material_analysis_materials;
CREATE TRIGGER trg_guard_pma_material_exact_peg_identity BEFORE UPDATE OF analysis_id, analysis_item_id, node_key, goods_id, color_id, unit_id ON production_material_analysis_materials FOR EACH ROW WHEN ((OLD.analysis_id, OLD.analysis_item_id, OLD.node_key, OLD.goods_id, OLD.color_id, OLD.unit_id) IS DISTINCT FROM (NEW.analysis_id, NEW.analysis_item_id, NEW.node_key, NEW.goods_id, NEW.color_id, NEW.unit_id)) EXECUTE FUNCTION fn_guard_pma_material_exact_peg_identity();

-- production_material_analysis_materials.trg_guard_preplan_subcontract_handoff_material_identity
DROP TRIGGER trg_guard_preplan_subcontract_handoff_material_identity ON production_material_analysis_materials;
CREATE TRIGGER trg_guard_preplan_subcontract_handoff_material_identity BEFORE UPDATE OF analysis_id, analysis_item_id, node_key, parent_node_key, bom_item_id, goods_id, color_id, unit_id ON production_material_analysis_materials FOR EACH ROW WHEN ((OLD.analysis_id, OLD.analysis_item_id, OLD.node_key, OLD.parent_node_key, OLD.bom_item_id, OLD.goods_id, OLD.color_id, OLD.unit_id) IS DISTINCT FROM (NEW.analysis_id, NEW.analysis_item_id, NEW.node_key, NEW.parent_node_key, NEW.bom_item_id, NEW.goods_id, NEW.color_id, NEW.unit_id)) EXECUTE FUNCTION fn_guard_preplan_subcontract_handoff_material_identity();

-- production_material_analysis_materials.trg_guard_root_material_identity
DROP TRIGGER trg_guard_root_material_identity ON production_material_analysis_materials;
CREATE TRIGGER trg_guard_root_material_identity BEFORE UPDATE ON production_material_analysis_materials FOR EACH ROW WHEN (OLD.node_role = 'ROOT_SUPPLY' AND ((OLD.analysis_id, OLD.analysis_item_id, OLD.node_role, OLD.depth, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.per_product_qty, OLD.node_key, OLD.path) IS DISTINCT FROM (NEW.analysis_id, NEW.analysis_item_id, NEW.node_role, NEW.depth, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.per_product_qty, NEW.node_key, NEW.path))) EXECUTE FUNCTION fn_guard_root_material_identity();

-- production_material_analysis_materials.trg_guard_root_supply_route
DROP TRIGGER trg_guard_root_supply_route ON production_material_analysis_materials;
CREATE TRIGGER trg_guard_root_supply_route BEFORE UPDATE OF confirmed_route ON production_material_analysis_materials FOR EACH ROW WHEN (NEW.node_role = 'ROOT_SUPPLY' AND COALESCE(NEW.confirmed_route, 'MAKE') IS DISTINCT FROM COALESCE(OLD.confirmed_route, 'MAKE')) EXECUTE FUNCTION fn_guard_root_supply_route();

-- production_material_analysis_materials.trg_validate_pma_material_borrow_endpoint
DROP TRIGGER trg_validate_pma_material_borrow_endpoint ON production_material_analysis_materials;
CREATE CONSTRAINT TRIGGER trg_validate_pma_material_borrow_endpoint AFTER UPDATE OF analysis_id, analysis_item_id, goods_id, color_id, unit_id, depth, control_stage, active ON production_material_analysis_materials DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.analysis_id, OLD.analysis_item_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.depth, OLD.control_stage, OLD.active) IS DISTINCT FROM (NEW.analysis_id, NEW.analysis_item_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.depth, NEW.control_stage, NEW.active)) EXECUTE FUNCTION fn_validate_production_material_analysis_borrow_endpoint();

-- production_material_analysis_materials.trg_validate_pma_material_exact_peg_endpoint
DROP TRIGGER trg_validate_pma_material_exact_peg_endpoint ON production_material_analysis_materials;
CREATE CONSTRAINT TRIGGER trg_validate_pma_material_exact_peg_endpoint AFTER INSERT ON production_material_analysis_materials DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_validate_pma_material_exact_peg_endpoint();
CREATE CONSTRAINT TRIGGER trg_validate_pma_material_exact_peg_endpoint_upd AFTER UPDATE ON production_material_analysis_materials DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.analysis_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.active) IS DISTINCT FROM (NEW.analysis_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.active)) EXECUTE FUNCTION fn_validate_pma_material_exact_peg_endpoint();

-- production_material_analysis_materials.trg_validate_preplan_reallocation_material
DROP TRIGGER trg_validate_preplan_reallocation_material ON production_material_analysis_materials;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_reallocation_material AFTER UPDATE OF analysis_id, analysis_item_id, goods_id, color_id, unit_id, control_stage, active ON production_material_analysis_materials DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.analysis_id, OLD.analysis_item_id, OLD.goods_id, OLD.color_id, OLD.unit_id, OLD.control_stage, OLD.active) IS DISTINCT FROM (NEW.analysis_id, NEW.analysis_item_id, NEW.goods_id, NEW.color_id, NEW.unit_id, NEW.control_stage, NEW.active)) EXECUTE FUNCTION fn_validate_preplan_material_reallocation_endpoints();

-- stock_value_nodes.trg_consumption_return_quantity
DROP TRIGGER trg_consumption_return_quantity ON stock_value_nodes;
CREATE CONSTRAINT TRIGGER trg_consumption_return_quantity AFTER INSERT ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.kind <> 'ISSUE_POSITION' OR NEW.owner_kind <> 'COST_WIP') IS NOT TRUE) EXECUTE FUNCTION fn_check_consumption_return();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_consumption_return_quantity;
CREATE CONSTRAINT TRIGGER trg_consumption_return_quantity_upd AFTER UPDATE ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.kind <> 'ISSUE_POSITION' OR NEW.owner_kind <> 'COST_WIP') IS NOT TRUE AND ((OLD.pool_id, OLD.kind, OLD.owner_kind, OLD.root_issue_id, OLD.quantity_basis, OLD.range_from, OLD.initial_known_value, OLD.creation_event_id, OLD.basis_value_local, OLD.active, OLD.returned_consumption_qty, OLD.consumption_return_head_id) IS DISTINCT FROM (NEW.pool_id, NEW.kind, NEW.owner_kind, NEW.root_issue_id, NEW.quantity_basis, NEW.range_from, NEW.initial_known_value, NEW.creation_event_id, NEW.basis_value_local, NEW.active, NEW.returned_consumption_qty, NEW.consumption_return_head_id))) EXECUTE FUNCTION fn_check_consumption_return();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_consumption_return_quantity_upd;

-- stock_value_nodes.trg_stock_value_exact_bounds
DROP TRIGGER trg_stock_value_exact_bounds ON stock_value_nodes;
CREATE CONSTRAINT TRIGGER trg_stock_value_exact_bounds AFTER INSERT ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.value_model <> 'EXACT_SOURCE_SHARES') IS NOT TRUE) EXECUTE FUNCTION fn_check_stock_value_exact_bounds();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_exact_bounds;
CREATE CONSTRAINT TRIGGER trg_stock_value_exact_bounds_upd AFTER UPDATE ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.value_model <> 'EXACT_SOURCE_SHARES') IS NOT TRUE AND ((OLD.kind, OLD.revision, OLD.value_model, OLD.source_initial_amount_exact, OLD.source_amount_exact, OLD.initial_bound_lower, OLD.initial_bound_upper, OLD.bound_lower, OLD.bound_upper, OLD.bound_revision) IS DISTINCT FROM (NEW.kind, NEW.revision, NEW.value_model, NEW.source_initial_amount_exact, NEW.source_amount_exact, NEW.initial_bound_lower, NEW.initial_bound_upper, NEW.bound_lower, NEW.bound_upper, NEW.bound_revision))) EXECUTE FUNCTION fn_check_stock_value_exact_bounds();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_exact_bounds_upd;

-- stock_value_nodes.trg_stock_value_cost_distribution
DROP TRIGGER trg_stock_value_cost_distribution ON stock_value_nodes;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_distribution AFTER INSERT ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_distribution();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_cost_distribution;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_distribution_upd AFTER UPDATE OF distributed_value_local ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (OLD.distributed_value_local IS DISTINCT FROM NEW.distributed_value_local) EXECUTE FUNCTION fn_check_stock_value_cost_distribution();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_cost_distribution_upd;

-- stock_value_nodes.trg_stock_value_exact_identity
DROP TRIGGER trg_stock_value_exact_identity ON stock_value_nodes;
CREATE TRIGGER trg_stock_value_exact_identity BEFORE UPDATE ON stock_value_nodes FOR EACH ROW WHEN ((OLD.value_model, OLD.source_initial_amount_exact, OLD.source_amount_exact) IS DISTINCT FROM (NEW.value_model, NEW.source_initial_amount_exact, NEW.source_amount_exact)) EXECUTE FUNCTION fn_guard_stock_value_exact_identity();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_exact_identity;

-- stock_value_nodes.trg_stock_value_node_lifecycle
DROP TRIGGER trg_stock_value_node_lifecycle ON stock_value_nodes;
CREATE CONSTRAINT TRIGGER trg_stock_value_node_lifecycle AFTER INSERT ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_node_lifecycle();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_node_lifecycle;
CREATE CONSTRAINT TRIGGER trg_stock_value_node_lifecycle_upd AFTER UPDATE ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.pool_id, OLD.kind, OLD.owner_kind, OLD.root_issue_id, OLD.quantity_basis, OLD.range_to, OLD.basis_value_local, OLD.active, OLD.return_head_id, OLD.returned_consumption_qty, OLD.reference_root_id) IS DISTINCT FROM (NEW.pool_id, NEW.kind, NEW.owner_kind, NEW.root_issue_id, NEW.quantity_basis, NEW.range_to, NEW.basis_value_local, NEW.active, NEW.return_head_id, NEW.returned_consumption_qty, NEW.reference_root_id)) EXECUTE FUNCTION fn_check_stock_value_node_lifecycle();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_node_lifecycle_upd;

-- stock_value_nodes.trg_stock_value_revision_fact
DROP TRIGGER trg_stock_value_revision_fact ON stock_value_nodes;
CREATE CONSTRAINT TRIGGER trg_stock_value_revision_fact AFTER UPDATE OF basis_value_local, pending_parents, revision, source_final ON stock_value_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((OLD.basis_value_local, OLD.pending_parents, OLD.revision, OLD.source_final) IS DISTINCT FROM (NEW.basis_value_local, NEW.pending_parents, NEW.revision, NEW.source_final)) EXECUTE FUNCTION fn_check_stock_value_node_revision();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_revision_fact;

-- stock_value_events.trg_consumption_return_event
DROP TRIGGER trg_consumption_return_event ON stock_value_events;
CREATE CONSTRAINT TRIGGER trg_consumption_return_event AFTER INSERT ON stock_value_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.operation = 'CONSUMPTION_RETURN') EXECUTE FUNCTION fn_check_consumption_return();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_consumption_return_event;

-- stock_value_events.trg_stock_value_position_event_complete
DROP TRIGGER trg_stock_value_position_event_complete ON stock_value_events;
CREATE CONSTRAINT TRIGGER trg_stock_value_position_event_complete AFTER INSERT ON stock_value_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.operation NOT IN ('POSITION_ACQUIRE', 'POSITION_MOVE', 'POSITION_STORE')) IS NOT TRUE) EXECUTE FUNCTION fn_check_stock_value_position_event();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_stock_value_position_event_complete;

-- stock_value_events.trg_stock_value_reverse_store
DROP TRIGGER trg_stock_value_reverse_store ON stock_value_events;
CREATE CONSTRAINT TRIGGER trg_stock_value_reverse_store AFTER INSERT ON stock_value_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.operation <> 'POSITION_STORE_REVERSE') IS NOT TRUE) EXECUTE FUNCTION fn_check_stock_value_reverse_store();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_stock_value_reverse_store;

-- stock_value_events.trg_subcontract_loss_position_fact
DROP TRIGGER trg_subcontract_loss_position_fact ON stock_value_events;
CREATE CONSTRAINT TRIGGER trg_subcontract_loss_position_fact AFTER INSERT ON stock_value_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.source_doc_type NOT IN ('SUBCONTRACT_WASTE_VALUE', 'SUBCONTRACT_NORMAL_LOSS', 'SUBCONTRACT_EXCESS_LOSS', 'SUBCONTRACT_NORMAL_LOSS_REVERSE', 'SUBCONTRACT_EXCESS_LOSS_REVERSE')) IS NOT TRUE) EXECUTE FUNCTION fn_check_subcontract_loss_position_fact();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_subcontract_loss_position_fact;

-- stock_value_events.trg_subcontract_material_unconsume
DROP TRIGGER trg_subcontract_material_unconsume ON stock_value_events;
CREATE CONSTRAINT TRIGGER trg_subcontract_material_unconsume AFTER INSERT ON stock_value_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NEW.source_doc_type <> 'SUBCONTRACT_RECEIPT_MATERIAL_UNCONSUME') IS NOT TRUE) EXECUTE FUNCTION fn_check_subcontract_material_unconsume();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_subcontract_material_unconsume;

-- preplan_stock_entitlement_events.trg_validate_preplan_entitlement_event_balance
DROP TRIGGER trg_validate_preplan_entitlement_event_balance ON preplan_stock_entitlement_events;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_entitlement_event_balance AFTER INSERT ON preplan_stock_entitlement_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.stock_reservation_id IS NOT NULL) EXECUTE FUNCTION fn_validate_preplan_entitlement_conservation();

-- preplan_stock_entitlement_events.trg_validate_preplan_make_delegation_events
DROP TRIGGER trg_validate_preplan_make_delegation_events ON preplan_stock_entitlement_events;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_make_delegation_events AFTER INSERT ON preplan_stock_entitlement_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.event_type IN ('MAKE_DELEGATE_OUT', 'MAKE_DELEGATE_IN', 'RELEASE', 'RESTORE')) EXECUTE FUNCTION fn_validate_preplan_make_delegation_totals();

-- preplan_stock_entitlement_events.trg_validate_preplan_reallocation_event_totals
DROP TRIGGER trg_validate_preplan_reallocation_event_totals ON preplan_stock_entitlement_events;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_reallocation_event_totals AFTER INSERT ON preplan_stock_entitlement_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.reallocation_id IS NOT NULL) EXECUTE FUNCTION fn_validate_preplan_reallocation_event_totals();

-- preplan_stock_entitlement_events.trg_validate_preplan_subcontract_handoff_events
DROP TRIGGER trg_validate_preplan_subcontract_handoff_events ON preplan_stock_entitlement_events;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_subcontract_handoff_events AFTER INSERT ON preplan_stock_entitlement_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.event_type IN ('SUBCONTRACT_HANDOFF_OUT', 'SUBCONTRACT_HANDOFF_IN', 'RELEASE', 'RESTORE')) EXECUTE FUNCTION fn_validate_preplan_subcontract_handoff_slice_totals();
