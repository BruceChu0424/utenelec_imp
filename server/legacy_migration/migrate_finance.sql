-- =====================================================================
-- Finance module migration: legacy M_* -> accounts/payment_styles
--                                  + ar_ap_ledger + 6 doc types + reconciliations
-- =====================================================================
-- Usage: bash server/legacy_migration/migrate.sh --finance --confirm-destructive
-- Pre: V50 (accounts/payment_styles) + V57 (finance docs) applied;
--      clients/suppliers/currencies migrated (V36/V38/V42).
-- Order: (1) master data accounts + payment_styles (docs reference accounts)
--        (2) ar_ap_ledger: M_in + M_out merged (direction derivation
--            + source_doc_type by BillNo prefix)
--        (3) finance_receipts/payments (main tables)
--        (4) back-fill ar_ap_ledger.source_doc_id (DIRECT_RECEIPT ->
--            finance_receipts, DIRECT_PAYMENT -> finance_payments)
--        (5) finance_expenses + items / finance_other_incomes + items
--        (6) finance_reconciliations (M_AllCheck, BStyle-routed JOIN)
--        (M_Bank legacy 0 rows: structure already in V57, no data to ingest)
-- Bootstrap-only: TRUNCATE finance transaction tables and accounts at start;
--                 payment_styles is upserted to preserve references held by
--                 fixed-assets/deferred-expense records. Only run before finance cutover,
--                 and always after the business-document modules whose UUIDs
--                 are referenced by ar_ap_ledger.source_doc_id.
-- Personnel (maker/approver/operator): V70 adds *_legacy_id + *_name columns.
--             maker/approver (MakeID/ApproverID → Sys_Operator) frozen as *_name
--             text (export JOIN fname; Sys_Operator 不入 employees 避免与 B_Worker 撞号);
--             operator/work (WorkID → B_Worker) 建 employees stub（legacy_id 融合键，
--             status=resigned，legacy_category=子类括注），报表 LEFT JOIN employees 出名。
--             与 V65-V69 + stock/subcontract stub 范式同构（四模块共用 P0 基础设施）。
-- settlement_style: M_in/M_out.PStyle → ar_ap_ledger.settlement_style_legacy（B_PStyle
--             字典未 dump，暂留 SMALLINT 原值，前端按字典常量渲染）。
-- department_id: SystemItem.ItemID <-> departments has no legacy_id mapping
--             (V02 table has no legacy_id column), leave NULL (open item
--             design doc 26 sec 9-8).
-- status: legacy 1->1 (approved), -1->-1 (red reversal), direct copy
--         (legacy has no draft state).
-- Money: float -> numeric(18,4); exchange rate -> numeric(18,6).
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE finance_reconciliations,
         finance_bank_transfer_lines, finance_bank_transfers,
         finance_other_income_items, finance_other_incomes,
         finance_expense_items, finance_expenses,
         finance_payment_lines, finance_payments,
         finance_receipt_lines, finance_receipts,
         finance_check_register,
         ar_ap_ledger,
         accounts;
SET session_replication_role = DEFAULT;

-- ---------------- staging (real types) ----------------
-- M_Acc (27 rows, 13 cols) -> accounts
CREATE TEMP TABLE m_acc_stage (
    legacy_id int, code text, name text, bank_account_no text,
    init_balance numeric(18,4), receipts_total numeric(18,4),
    payments_total numeric(18,4), balance_current numeric(18,4),
    remark text, parent_legacy_id int, status text,
    style_legacy_id int, a_style int);
\copy m_acc_stage FROM '/tmp/m_acc.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_Style (124 rows, 15 cols) -> payment_styles (tree)
CREATE TEMP TABLE m_style_stage (
    legacy_id int, style_class_id int, code text, name text, parent_legacy int,
    remark text, status int, dept_status boolean, next_number text,
    init_total numeric(18,4), q_status boolean,
    orient_status1 boolean, orient_status2 boolean, unit text, item_id int);
\copy m_style_stage FROM '/tmp/m_style.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_in (42,489 rows, 16 cols extracted) -> ar_ap_ledger (direction=AR)
CREATE TEMP TABLE m_in_stage (
    legacy_id int, bill_no text, client_legacy_id int, bill_date date, due_date date,
    total numeric(18,4), settled numeric(18,4), balance numeric(18,4),
    note text, paid_bit boolean, paid_date timestamptz,
    b_style int, p_style int, bill_legacy_id int,
    currency_legacy_id int, exchange_rate numeric(18,6));
\copy m_in_stage FROM '/tmp/m_in.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_out (44,534 rows, 16 cols extracted) -> ar_ap_ledger (direction=AP)
CREATE TEMP TABLE m_out_stage (
    legacy_id int, bill_no text, supplier_legacy_id int, bill_date date, due_date date,
    total numeric(18,4), settled numeric(18,4), balance numeric(18,4),
    note text, paid_bit boolean, paid_date timestamptz,
    b_style int, p_style int, bill_legacy_id int,
    currency_legacy_id int, exchange_rate numeric(18,6));
\copy m_out_stage FROM '/tmp/m_out.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_Get (7,804 rows) -> finance_receipts
CREATE TEMP TABLE m_get_stage (
    legacy_id int, bill_no text, bill_date date, client_legacy_id int, work_id int,
    rec_style int, total numeric(18,4), make_id int, approver_id int,
    status smallint, status2 smallint, remark text, rec_acc int,
    cancel_date timestamptz, source text, invoices_no text, mtotal numeric(18,4),
    cur_id int, crate numeric(18,6), step_id int, cancel boolean,
    slf numeric(18,4), qtfy numeric(18,4), qtfymc int, dfch int,
    maker_name text, approver_name text, work_name text);
\copy m_get_stage FROM '/tmp/m_get.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_Paid (4,545 rows) -> finance_payments
CREATE TEMP TABLE m_paid_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int, work_id int,
    paid_style int, total numeric(18,4), make_id int, approver_id int,
    status smallint, status2 smallint, remark text, paid_acc int,
    cancel_date timestamptz, source text, invoices_no text, mtotal numeric(18,4),
    cur_id int, crate numeric(18,6), step_id int, cancel boolean,
    dfzh int, jsr text,
    maker_name text, approver_name text, work_name text);
\copy m_paid_stage FROM '/tmp/m_paid.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_DPaid (1,125 rows) -> finance_expenses
CREATE TEMP TABLE m_dpaid_stage (
    legacy_id int, bill_no text, bill_date date, work_id int,
    total numeric(18,4), make_id int, approver_id int,
    status smallint, status2 smallint, remark text, paid_acc int,
    invoices_no text, cancel_date timestamptz, source text, paid_style int,
    mtotal numeric(18,4), cur_id int, crate numeric(18,6), cancel boolean, dfzh int,
    maker_name text, approver_name text, work_name text);
\copy m_dpaid_stage FROM '/tmp/m_dpaid.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_DPaidItem (8,537 rows) -> finance_expense_items
CREATE TEMP TABLE m_dpaid_item_stage (
    legacy_id int, bill_legacy_id int, style_legacy_id int, total numeric(18,4),
    summary text, dept_legacy_id int, ctotal numeric(18,4), dfmc text,
    qty numeric(18,4), price numeric(18,4), acc_id int);
\copy m_dpaid_item_stage FROM '/tmp/m_dpaid_item.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_OGet (1,552 rows) -> finance_other_incomes
CREATE TEMP TABLE m_oget_stage (
    legacy_id int, bill_no text, bill_date date, work_id int,
    total numeric(18,4), make_id int, approver_id int,
    status smallint, status2 smallint, remark text, rec_acc int,
    invoices_no text, cancel_date timestamptz, source text, rec_style int,
    mtotal numeric(18,4), cur_id int, crate numeric(18,6), cancel boolean, dfzh int,
    maker_name text, approver_name text, work_name text);
\copy m_oget_stage FROM '/tmp/m_oget.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_OGetItem (1,551 rows) -> finance_other_income_items (NO QTY/Price in old schema)
CREATE TEMP TABLE m_oget_item_stage (
    legacy_id int, bill_legacy_id int, style_legacy_id int, total numeric(18,4),
    summary text, dept_legacy_id int, ctotal numeric(18,4), df text);
\copy m_oget_item_stage FROM '/tmp/m_oget_item.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_AllCheck (30,626 rows) -> finance_reconciliations
CREATE TEMP TABLE m_allcheck_stage (
    legacy_id int, bill_no text, check_no text, remark text, company text,
    in_total numeric(18,4), out_total numeric(18,4), bill_date timestamptz,
    out_date timestamptz, acc_id int, source text, b_style int, bill_id int);
\copy m_allcheck_stage FROM '/tmp/m_allcheck.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- Finance contains historical parties that were deleted from the surviving
-- B_Client/B_Provider master snapshots. Preserve the legacy identity as a
-- disabled stub instead of silently creating party-less ledger rows.
INSERT INTO clients (legacy_id, code, name, status, remark)
SELECT DISTINCT party_legacy_id,
       'LEGACY-FIN-CL-' || party_legacy_id,
       U&'\94B1\6D41\5386\53F2\5BA2\6237\FF08\539FID ' || party_legacy_id::text || U&'\FF09',
       U&'\7981\7528',
       U&'\5386\53F2\94B1\6D41\81EA\52A8\8865\5F55\FF0C\771F\5B9E\4E3B\6863\7F3A\5931\FF0C\52FF\7528\4E8E\65B0\5355'
FROM (
    SELECT client_legacy_id AS party_legacy_id FROM m_in_stage
    UNION
    SELECT client_legacy_id FROM m_get_stage
) missing
WHERE party_legacy_id IS NOT NULL
  AND party_legacy_id <> 0
  AND NOT EXISTS (
      SELECT 1 FROM clients c WHERE c.legacy_id = missing.party_legacy_id
  )
ON CONFLICT (legacy_id) DO NOTHING;

INSERT INTO suppliers (legacy_id, code, name, status, remark)
SELECT DISTINCT party_legacy_id,
       'LEGACY-FIN-SP-' || party_legacy_id,
       U&'\94B1\6D41\5386\53F2\4F9B\5E94\5546\FF08\539FID ' || party_legacy_id::text || U&'\FF09',
       U&'\7981\7528',
       U&'\5386\53F2\94B1\6D41\81EA\52A8\8865\5F55\FF0C\771F\5B9E\4E3B\6863\7F3A\5931\FF0C\52FF\7528\4E8E\65B0\5355'
FROM (
    SELECT supplier_legacy_id AS party_legacy_id FROM m_out_stage
    UNION
    SELECT supplier_legacy_id FROM m_paid_stage
) missing
WHERE party_legacy_id IS NOT NULL
  AND party_legacy_id <> 0
  AND NOT EXISTS (
      SELECT 1 FROM suppliers s WHERE s.legacy_id = missing.party_legacy_id
  )
ON CONFLICT (legacy_id) DO NOTHING;


-- =====================================================================
-- (1) accounts master (M_Acc 27 rows -> accounts, account_type rebuilt
--     from AccName keyword CASE; AStyle degraded, ignored)
-- =====================================================================
-- The legacy DB stores AccName/Status as Chinese (GBK in MSSQL, UTF-8 after
-- export). The migrate matches Chinese substrings via chr(codepoint) to keep
-- this SQL file pure ASCII. Keyword list below covers all 27 sample accounts;
-- if a future account uses a new keyword, append a new WHEN branch.
--
-- account_type rebuild rules (AStyle all=1, type recognized by AccName):
--   Xianggang (Hong Kong)        -> OFFSHORE         chr(39319) = Xiang
--   Wei Xin / Zhi Fu Bao         -> THIRD_PARTY      chr(24494) = Wei ;
--                                                   chr(25903)||chr(20184)||chr(23453) = Zhi+Fu+Bao
--   Xian Jin (cash)              -> CASH             chr(29616)||chr(37329) = Xian+Jin
--   Zhi Piao + Jin Yong (disable)-> CHECK            chr(25903)||chr(31080) = Zhi+Piao,
--                                                   chr(31105)||chr(29992) = Jin+Yong
--   Zhi Piao + other Status      -> FOREIGN_CHECK    (legacy ID=56 row, foreign cheque)
--   Yi Ban Zhang Hu (general)    -> GENERAL          chr(19968)||chr(33324)||chr(24080)||chr(25143)
--   Bank keyword                 -> BANK             (farm/ICBC/CCB/BCM/CMB/postal/credit
--                                                     coop/Industrial/Bank of China/CGB/basic)
--   other                        -> GENERAL
INSERT INTO accounts (
    legacy_id, code, name, bank_account_no, account_type,
    init_balance, receipts_total, payments_total, balance_current,
    parent_legacy_id, style_legacy_id, status)
SELECT
    s.legacy_id, NULLIF(s.code, ''), s.name, NULLIF(s.bank_account_no, ''),
    CASE
        -- Chinese keyword mapping (AccName is Chinese in the live legacy DB)
        WHEN s.name LIKE '%' || chr(39321) || '%'                                       THEN 'OFFSHORE'        -- Xianggang (Hong Kong)
        WHEN s.name LIKE '%' || chr(24494) || '%'                                       THEN 'THIRD_PARTY'     -- Wei Xin (WeChat)
        WHEN s.name LIKE '%' || chr(25903) || chr(20184) || chr(23453) || '%'           THEN 'THIRD_PARTY'     -- Zhi Fu Bao (Alipay)
        WHEN s.name LIKE '%' || chr(29616) || chr(37329) || '%'                         THEN 'CASH'            -- Xian Jin (cash)
        WHEN s.name = chr(25903) || chr(31080) AND s.status = chr(31105) || chr(29992) THEN 'CHECK'           -- Zhi Piao + Jin Yong
        WHEN s.name = chr(25903) || chr(31080) THEN 'FOREIGN_CHECK'                     -- Zhi Piao + other
        WHEN s.name = chr(19968) || chr(33324) || chr(24080) || chr(25143) THEN 'GENERAL'  -- Yi Ban Zhang Hu
        WHEN s.name LIKE '%' || chr(20892) || '%'
             OR s.name LIKE '%' || chr(24037) || chr(21830) || '%'
             OR s.name LIKE '%' || chr(24037) || chr(34892) || '%'
             OR s.name LIKE '%' || chr(24314) || chr(35774) || '%'
             OR s.name LIKE '%' || chr(24314) || chr(34892) || '%'
             OR s.name LIKE '%' || chr(20132) || chr(36890) || '%'
             OR s.name LIKE '%' || chr(20132) || chr(34892) || '%'
             OR s.name LIKE '%' || chr(25307) || chr(21830) || '%'
             OR s.name LIKE '%' || chr(25307) || chr(34892) || '%'
             OR s.name LIKE '%' || chr(37038) || chr(25919) || '%'
             OR s.name LIKE '%' || chr(20449) || chr(29992) || chr(31038) || '%'
             OR s.name LIKE '%' || chr(20852) || chr(19994) || '%'
             OR s.name = chr(20013) || chr(22269) || chr(38134) || chr(34892)
             OR s.name LIKE '%' || chr(20013) || chr(34892) || '%'
             OR s.name LIKE '%' || chr(24191) || chr(21457) || '%'
             OR s.name = chr(22522) || chr(26412) || chr(25143) THEN 'BANK'
        ELSE 'GENERAL'
    END,
    COALESCE(s.init_balance, 0), COALESCE(s.receipts_total, 0),
    COALESCE(s.payments_total, 0), COALESCE(s.balance_current, 0),
    NULLIF(s.parent_legacy_id, 0), NULLIF(s.style_legacy_id, 0),
    COALESCE(NULLIF(s.status, ''), chr(20351) || chr(29992))  -- 'Shi Yong' (In Use) default
FROM m_acc_stage s;


-- =====================================================================
-- (2) payment_styles tree (M_Style 124 nodes -> payment_styles, by category)
-- =====================================================================
-- category mapping: StyleClassid 1->ACCOUNT / 2->LIABILITY / 3->EQUITY /
--                   4->EXPENSE / 5->INCOME
-- level recomputed via recursive CTE by parent chain (legacy Level absent/
--       unreliable; root=0)
-- path maintained by V50 trigger trg_payment_style_path (session is in
--       DEFAULT role now, so trigger fires normally)
-- sort_order from NextNumber digits extracted ('01'->1)
-- is_departmental/is_receipt/is_payment three bools copied verbatim
-- Depth-layered INSERT: depth 0 (roots) first so path trigger can see
--                       parent path when inserting children
CREATE TEMP TABLE ps_depth AS
WITH RECURSIVE t AS (
    SELECT s.legacy_id, 0 AS depth
    FROM m_style_stage s
    WHERE s.parent_legacy = 0 OR s.parent_legacy IS NULL
       OR NOT EXISTS (SELECT 1 FROM m_style_stage p WHERE p.legacy_id = s.parent_legacy)
    UNION ALL
    SELECT s.legacy_id, t.depth + 1
    FROM m_style_stage s JOIN t ON s.parent_legacy = t.legacy_id
    WHERE s.parent_legacy <> 0 AND s.parent_legacy IS NOT NULL
)
SELECT legacy_id, MIN(depth) AS depth FROM t GROUP BY legacy_id;

DO $$
DECLARE d INT; maxd INT;
BEGIN
    SELECT COALESCE(MAX(depth), 0) INTO maxd FROM ps_depth;
    FOR d IN 0..maxd LOOP
        INSERT INTO payment_styles (
            legacy_id, code, name, category, level, sort_order, parent_id,
            is_departmental, is_receipt, is_payment,
            linked_account_legacy_id, init_balance, status)
        SELECT
            s.legacy_id, s.code, s.name,
            CASE s.style_class_id
                WHEN 1 THEN 'ACCOUNT'
                WHEN 2 THEN 'LIABILITY'
                WHEN 3 THEN 'EQUITY'
                WHEN 4 THEN 'EXPENSE'
                WHEN 5 THEN 'INCOME'
                ELSE 'METHOD'
            END,
            n.depth,
            COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(s.next_number, ''), '[^0-9]', '', 'g'), '')::int, 0),
            CASE WHEN n.depth = 0 THEN NULL::uuid
                 ELSE (SELECT id FROM payment_styles WHERE legacy_id = s.parent_legacy) END,
            COALESCE(s.dept_status, FALSE),
            COALESCE(s.orient_status1, FALSE),
            COALESCE(s.orient_status2, FALSE),
            NULLIF(s.item_id, 0),
            s.init_total,
            'In Use'
        FROM m_style_stage s JOIN ps_depth n ON n.legacy_id = s.legacy_id
        WHERE n.depth = d
        ON CONFLICT (legacy_id) DO UPDATE SET
            code = EXCLUDED.code,
            name = EXCLUDED.name,
            category = EXCLUDED.category,
            level = EXCLUDED.level,
            sort_order = EXCLUDED.sort_order,
            parent_id = EXCLUDED.parent_id,
            is_departmental = EXCLUDED.is_departmental,
            is_receipt = EXCLUDED.is_receipt,
            is_payment = EXCLUDED.is_payment,
            linked_account_legacy_id = EXCLUDED.linked_account_legacy_id,
            init_balance = EXCLUDED.init_balance,
            status = EXCLUDED.status;
    END LOOP;
END $$;


-- =====================================================================
-- (3) ar_ap_ledger (M_in 42,489 UNION ALL M_out 44,534 -> unified ledger)
-- =====================================================================
-- direction / source_doc_type derivation:
--   M_in  -> direction='AR', source_doc_type by BillNo prefix:
--            XC=SALES_SHIPMENT / XT=SALES_RETURN / XS=DIRECT_RECEIPT
--   M_out -> direction='AP', source_doc_type by BillNo prefix:
--            CJ=PURCHASE_RECEIPT / CT=PURCHASE_RETURN /
--            EJ=SUBCONTRACT_RECEIPT / CF=DIRECT_PAYMENT
-- amount_original_local = Total (local currency)
-- amount_settled = M_In / M_Out (received/paid accumulated)
-- amount_balance = M_Rare; is_settled is derived from the canonical balance
--                  equation (legacy Paid bit is inconsistent on historical
--                  rows); status default 1 (posting is immediately effective)
-- legacy_source + legacy_id + legacy_bstyle three fields for traceability
--   (resolves M_in/M_out ID collision)
-- amount_original temporarily equals amount_original_local (reverse-dividing
--   Total by CRate for original-currency has precision risk; we keep Total
--   in amount_original_local and CRate in exchange_rate, design doc 26 sec 9-14)
-- source_doc_id back-filled in step (4) (depends on finance_receipts/payments)

-- (3-a) M_in -> AR
INSERT INTO ar_ap_ledger (
    direction, source_doc_type, source_doc_no, bill_no, bill_date, due_date,
    client_id, supplier_id, currency_id, exchange_rate,
    amount_original, amount_original_local, amount_settled, amount_balance,
    is_settled, settled_date, status, remark,
    legacy_source, legacy_id, legacy_bstyle, settlement_style_legacy)
SELECT
    'AR',
    CASE
        WHEN s.bill_no LIKE 'XC%' THEN 'SALES_SHIPMENT'
        WHEN s.bill_no LIKE 'XT%' THEN 'SALES_RETURN'
        WHEN s.bill_no LIKE 'XS%' THEN 'DIRECT_RECEIPT'
        ELSE 'SALES_SHIPMENT'
    END,
    s.bill_no, s.bill_no, s.bill_date, s.due_date,
    (SELECT id FROM clients WHERE legacy_id = s.client_legacy_id),
    NULL::uuid,
    (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
    COALESCE(NULLIF(s.exchange_rate, 0), 1),
    s.total,         -- amount_original (same as local for now, see note above)
    s.total,         -- amount_original_local (local)
    COALESCE(s.settled, 0),
    COALESCE(s.balance, s.total - COALESCE(s.settled, 0)),
    COALESCE(s.balance, s.total - COALESCE(s.settled, 0)) = 0,
    CASE
        WHEN COALESCE(s.balance, s.total - COALESCE(s.settled, 0)) = 0
            THEN COALESCE(s.paid_date::date, s.bill_date)
        ELSE NULL
    END,
    1, NULLIF(s.note, ''),
    'M_in', s.legacy_id, s.b_style::smallint,
    NULLIF(s.p_style, 0)::smallint
FROM m_in_stage s;

-- (3-b) M_out -> AP
INSERT INTO ar_ap_ledger (
    direction, source_doc_type, source_doc_no, bill_no, bill_date, due_date,
    client_id, supplier_id, currency_id, exchange_rate,
    amount_original, amount_original_local, amount_settled, amount_balance,
    is_settled, settled_date, status, remark,
    legacy_source, legacy_id, legacy_bstyle, settlement_style_legacy)
SELECT
    'AP',
    CASE
        WHEN s.bill_no LIKE 'CJ%' THEN 'PURCHASE_RECEIPT'
        WHEN s.bill_no LIKE 'CT%' THEN 'PURCHASE_RETURN'
        WHEN s.bill_no LIKE 'EJ%' THEN 'SUBCONTRACT_RECEIPT'
        WHEN s.bill_no LIKE 'CF%' THEN 'DIRECT_PAYMENT'
        ELSE 'PURCHASE_RECEIPT'
    END,
    s.bill_no, s.bill_no, s.bill_date, s.due_date,
    NULL::uuid,
    (SELECT id FROM suppliers WHERE legacy_id = s.supplier_legacy_id),
    (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
    COALESCE(NULLIF(s.exchange_rate, 0), 1),
    s.total,
    s.total,
    COALESCE(s.settled, 0),
    COALESCE(s.balance, s.total - COALESCE(s.settled, 0)),
    COALESCE(s.balance, s.total - COALESCE(s.settled, 0)) = 0,
    CASE
        WHEN COALESCE(s.balance, s.total - COALESCE(s.settled, 0)) = 0
            THEN COALESCE(s.paid_date::date, s.bill_date)
        ELSE NULL
    END,
    1, NULLIF(s.note, ''),
    'M_out', s.legacy_id, s.b_style::smallint,
    NULLIF(s.p_style, 0)::smallint
FROM m_out_stage s;


-- =====================================================================
-- (4) finance_receipts (M_Get) + finance_payments (M_Paid)
-- =====================================================================
INSERT INTO finance_receipts (
    legacy_id, bill_no, bill_date, client_id, account_id, counterpart_account_id,
    currency_id, exchange_rate, amount_original, amount_local,
    bank_fee, other_fee, other_fee_style_id, receipt_method_legacy_id,
    invoice_no, cancel_date, source_remark, remark, status,
    maker_legacy_id, approver_legacy_id, operator_legacy_id,
    maker_name, approver_name, operator_name)
SELECT
    s.legacy_id, s.bill_no, s.bill_date,
    (SELECT id FROM clients    WHERE legacy_id = s.client_legacy_id),
    (SELECT id FROM accounts   WHERE legacy_id = s.rec_acc),
    (SELECT id FROM accounts   WHERE legacy_id = NULLIF(s.dfch, 0)),
    (SELECT id FROM currencies WHERE legacy_id = s.cur_id),
    COALESCE(NULLIF(s.crate, 0), 1),
    COALESCE(s.mtotal, 0), COALESCE(s.total, 0),
    COALESCE(s.slf, 0), COALESCE(s.qtfy, 0),
    (SELECT id FROM payment_styles WHERE legacy_id = NULLIF(s.qtfymc, 0)),
    NULLIF(s.rec_style, 0),
    NULLIF(s.invoices_no, ''), s.cancel_date,
    NULLIF(s.source, ''), NULLIF(s.remark, ''), COALESCE(s.status, 0),
    NULLIF(s.make_id,0), NULLIF(s.approver_id,0), NULLIF(s.work_id,0),
    NULLIF(s.maker_name,''), NULLIF(s.approver_name,''), NULLIF(s.work_name,'')
FROM m_get_stage s;

INSERT INTO finance_payments (
    legacy_id, bill_no, bill_date, supplier_id, account_id, counterpart_account_id,
    currency_id, exchange_rate, amount_original, amount_local,
    payment_method_legacy_id, invoice_no, cancel_date,
    operator_name, source_remark, remark, status,
    maker_legacy_id, approver_legacy_id, operator_legacy_id,
    maker_name, approver_name)
SELECT
    s.legacy_id, s.bill_no, s.bill_date,
    (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
    (SELECT id FROM accounts   WHERE legacy_id = s.paid_acc),
    (SELECT id FROM accounts   WHERE legacy_id = NULLIF(s.dfzh, 0)),
    (SELECT id FROM currencies WHERE legacy_id = s.cur_id),
    COALESCE(NULLIF(s.crate, 0), 1),
    COALESCE(s.mtotal, 0), COALESCE(s.total, 0),
    NULLIF(s.paid_style, 0),
    NULLIF(s.invoices_no, ''), s.cancel_date,
    NULLIF(s.jsr, ''),
    NULLIF(s.source, ''), NULLIF(s.remark, ''), COALESCE(s.status, 0),
    NULLIF(s.make_id,0), NULLIF(s.approver_id,0), NULLIF(s.work_id,0),
    NULLIF(s.maker_name,''), NULLIF(s.approver_name,'')
FROM m_paid_stage s;


-- =====================================================================
-- (5) ar_ap_ledger.source_doc_id back-fill
--     (DIRECT_RECEIPT/PAYMENT -> finance_receipts/payments)
-- =====================================================================
-- Cross-module sources (BStyle=3/1/17/18/30 postings from sales/purchase/
-- subcontract docs) stay source_doc_id=NULL until those modules land and
-- call postArAp explicitly.
-- Direct receipt/payment (BStyle=20/21) sources are finance_receipts/payments
-- which are already migrated here; precise back-fill is possible.
UPDATE ar_ap_ledger a
SET source_doc_id = r.id
FROM finance_receipts r, m_in_stage s
WHERE a.legacy_source = 'M_in' AND a.legacy_id = s.legacy_id
  AND s.b_style = 20 AND s.bill_legacy_id = r.legacy_id;

UPDATE ar_ap_ledger a
SET source_doc_id = p.id
FROM finance_payments p, m_out_stage s
WHERE a.legacy_source = 'M_out' AND a.legacy_id = s.legacy_id
  AND s.b_style = 21 AND s.bill_legacy_id = p.legacy_id;


-- =====================================================================
-- (6) finance_expenses + items (M_DPaid + M_DPaidItem, by department)
-- =====================================================================
INSERT INTO finance_expenses (
    legacy_id, bill_no, bill_date, account_id, counterpart_account_id,
    currency_id, exchange_rate, amount_original, amount_local, status, remark,
    maker_legacy_id, approver_legacy_id, operator_legacy_id,
    maker_name, approver_name, operator_name)
SELECT
    s.legacy_id, s.bill_no, s.bill_date,
    (SELECT id FROM accounts   WHERE legacy_id = s.paid_acc),
    (SELECT id FROM accounts   WHERE legacy_id = NULLIF(s.dfzh, 0)),
    (SELECT id FROM currencies WHERE legacy_id = s.cur_id),
    COALESCE(NULLIF(s.crate, 0), 1),
    COALESCE(s.mtotal, 0), COALESCE(s.total, 0),
    COALESCE(s.status, 0), NULLIF(s.remark, ''),
    NULLIF(s.make_id,0), NULLIF(s.approver_id,0), NULLIF(s.work_id,0),
    NULLIF(s.maker_name,''), NULLIF(s.approver_name,''), NULLIF(s.work_name,'')
FROM m_dpaid_stage s;

INSERT INTO finance_expense_items (
    legacy_id, expense_id, bill_no, bill_date,
    expense_style_id, department_id, counterpart_account_id, counterpart_name,
    qty, price, amount_original, amount_local, summary, line_no)
SELECT
    s.legacy_id,
    (SELECT id FROM finance_expenses WHERE legacy_id = s.bill_legacy_id),
    e.bill_no, e.bill_date,
    (SELECT id FROM payment_styles WHERE legacy_id = NULLIF(s.style_legacy_id, 0)),
    NULL::uuid,  -- department_id: SystemItem<->departments not aligned, NULL (open item 26 sec 9-8)
    (SELECT id FROM accounts WHERE legacy_id = NULLIF(s.acc_id, 0)),
    NULLIF(s.dfmc, ''),
    s.qty, s.price, COALESCE(s.ctotal, 0), COALESCE(s.total, 0),
    NULLIF(s.summary, ''),
    ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id)
FROM m_dpaid_item_stage s
JOIN finance_expenses e ON e.legacy_id = s.bill_legacy_id;


-- =====================================================================
-- (7) finance_other_incomes + items (M_OGet + M_OGetItem)
-- =====================================================================
INSERT INTO finance_other_incomes (
    legacy_id, bill_no, bill_date, account_id, counterpart_account_id,
    currency_id, exchange_rate, amount_original, amount_local,
    receipt_method_legacy_id, status, remark,
    maker_legacy_id, approver_legacy_id, operator_legacy_id,
    maker_name, approver_name, operator_name)
SELECT
    s.legacy_id, s.bill_no, s.bill_date,
    (SELECT id FROM accounts   WHERE legacy_id = s.rec_acc),
    (SELECT id FROM accounts   WHERE legacy_id = NULLIF(s.dfzh, 0)),
    (SELECT id FROM currencies WHERE legacy_id = s.cur_id),
    COALESCE(NULLIF(s.crate, 0), 1),
    COALESCE(s.mtotal, 0), COALESCE(s.total, 0),
    NULLIF(s.rec_style, 0),
    COALESCE(s.status, 0), NULLIF(s.remark, ''),
    NULLIF(s.make_id,0), NULLIF(s.approver_id,0), NULLIF(s.work_id,0),
    NULLIF(s.maker_name,''), NULLIF(s.approver_name,''), NULLIF(s.work_name,'')
FROM m_oget_stage s;

INSERT INTO finance_other_income_items (
    legacy_id, income_id, bill_no, bill_date,
    income_style_id, department_id, counterpart_name,
    qty, price, amount_original, amount_local, summary, line_no)
SELECT
    s.legacy_id,
    (SELECT id FROM finance_other_incomes WHERE legacy_id = s.bill_legacy_id),
    o.bill_no, o.bill_date,
    (SELECT id FROM payment_styles WHERE legacy_id = NULLIF(s.style_legacy_id, 0)),
    NULL::uuid,  -- department_id: same as expenses, NULL
    NULLIF(s.df, ''),
    NULL::numeric, NULL::numeric,  -- legacy M_OGetItem has no QTY/Price columns
    COALESCE(s.ctotal, 0), COALESCE(s.total, 0),
    NULLIF(s.summary, ''),
    ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id)
FROM m_oget_item_stage s
JOIN finance_other_incomes o ON o.legacy_id = s.bill_legacy_id;


-- =====================================================================
-- (8) finance_reconciliations (M_AllCheck 30,626 rows -> account register)
-- =====================================================================
-- source_doc_type routed by BStyle
--   (20->RECEIPT / 21->PAYMENT / 22->INCOME / 23->EXPENSE / 27->BANK_TRANSFER);
--   posting BStyles (3/18/1/17/30) do NOT write M_AllCheck in the legacy DB
--   (design doc 25 sec 4.2); fallback to RECEIPT (most common source).
-- source_doc_id JOINed by BStyle to the right finance doc table legacy_id;
--   no match -> NULL (tolerates historical dirty rows).
INSERT INTO finance_reconciliations (
    legacy_id, bill_no, source_doc_type, source_doc_id, account_id, check_no,
    counterpart_name, in_amount, out_amount, bill_date, settled_date,
    source_remark, remark, legacy_bstyle)
SELECT
    s.legacy_id, s.bill_no,
    CASE s.b_style
        WHEN 20 THEN 'RECEIPT'
        WHEN 21 THEN 'PAYMENT'
        WHEN 22 THEN 'INCOME'
        WHEN 23 THEN 'EXPENSE'
        WHEN 27 THEN 'BANK_TRANSFER'
        ELSE 'RECEIPT'  -- fallback: abnormal legacy BStyle bucketed as RECEIPT (most common)
    END,
    CASE s.b_style
        WHEN 20 THEN (SELECT id FROM finance_receipts       WHERE legacy_id = s.bill_id)
        WHEN 21 THEN (SELECT id FROM finance_payments       WHERE legacy_id = s.bill_id)
        WHEN 22 THEN (SELECT id FROM finance_other_incomes  WHERE legacy_id = s.bill_id)
        WHEN 23 THEN (SELECT id FROM finance_expenses       WHERE legacy_id = s.bill_id)
        WHEN 27 THEN NULL::uuid  -- M_Bank 0 rows, not migrated this batch, leave NULL
        ELSE NULL::uuid
    END,
    (SELECT id FROM accounts WHERE legacy_id = s.acc_id),
    NULLIF(s.check_no, ''),
    NULLIF(s.company, ''),
    COALESCE(s.in_total, 0), COALESCE(s.out_total, 0),
    s.bill_date, s.out_date,
    NULLIF(s.source, ''), NULLIF(s.remark, ''),
    s.b_style
FROM m_allcheck_stage s;


-- =====================================================================
-- (9) finance_bank_transfers (M_Bank legacy 0 rows -> empty structure)
-- =====================================================================
-- Legacy M_Bank/M_BankItem 0 rows (never activated); V57 has the empty
-- structure preserving the Service skeleton (cross-currency conversion).
-- Future activation: export M_Bank/M_BankItem + add INSERT here
-- (mirror the receipt/payment pattern in step 4).


-- =====================================================================
-- (10) 人员补录：B_Worker → employees stub（融合键 legacy_id，经手人/收款人）
-- =====================================================================
-- 用户钦定"老库有、新库没有就在员工表添加、显示名字（名字后带（子类）括注）"。
-- operator/work（WorkID → B_Worker）：建 employees stub，legacy_id=B_Worker.ID（融合键），
--   full_name=Emp_Name，code='LEGACY-W-<id>'，status='resigned'（老库很多人离职，默认离职；
--   用户以后在员工档案激活/补全真实信息），department_id=DEPT_HR（HR 负责后续清理/分配真实部门），
--   hire_date 占位，employment_type='regular'，legacy_category=子类括注（sub_class 当前 NULL，
--   B_Worker 子类字段待确认后回填；确认列名即贯通）。
--   报表 LEFT JOIN employees ON e.legacy_id=t.operator_legacy_id 出名 + 子类括注；HR 真名单不覆盖。
-- maker/approver（MakeID/ApproverID → Sys_Operator）不入 employees（避免与 B_Worker 撞号 +
--   登录账号非员工档案实体），其 fname 已在 step (4)/(6)/(7) 冻结进 *_name 文本列。
-- NOT EXISTS 守卫：用户已录真员工（同 legacy_id）优先，绝不覆盖；故重跑幂等、与真名单可融合。
-- legacy_workers.csv 由 export_legacy.ps1 导出（B_Worker 全量，仓库/委外已共用）。
CREATE TEMP TABLE finance_worker_stage (legacy_id int, name text, sub_class text);
\copy finance_worker_stage FROM '/tmp/legacy_workers.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO employees (legacy_id, code, full_name, id_type, department_id, hire_date, status, employment_type, legacy_category)
SELECT w.legacy_id, 'LEGACY-W-' || w.legacy_id, NULLIF(w.name,''), '其他',
       (SELECT id FROM departments WHERE code = 'DEPT_HR'), DATE '2000-01-01', 'resigned', 'regular',
       NULLIF(w.sub_class,'')
FROM finance_worker_stage w
WHERE w.legacy_id IS NOT NULL AND w.legacy_id <> 0 AND NULLIF(w.name,'') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.legacy_id = w.legacy_id);

-- =====================================================================
-- 刷新钱流应收应付物化视图（防汇总报表 Z/B/D 空数据，同 sales/stock 修复）
-- =====================================================================
-- finance_ar_ap_mv 服务 Z 应收应付汇总 + B 应收汇总 + D 应付汇总；V58 建表时 ar_ap_ledger
-- 为空 → MV 0 行，迁完 ar_ap_ledger 灌入 8.7 万行后须刷新 MV 才有汇总数据（四模块里钱流此前
-- 漏刷，是汇总报表空的根因，本次补齐）。非 CONCURRENTLY 全量刷新（迁移一次性，brief lock 可接受）。
REFRESH MATERIALIZED VIEW finance_ar_ap_mv;


-- =====================================================================
-- Validation (design doc 26 sec 8.4 -- all must pass)
-- =====================================================================
SELECT '==== Row count reconciliation ====' AS section;

SELECT 'accounts (expect 27)                ' || COUNT(*) FROM accounts;
SELECT 'payment_styles (expect 124)         ' || COUNT(*) FROM payment_styles;
SELECT 'ar_ap_ledger total (= current stages)' || COUNT(*) FROM ar_ap_ledger;
SELECT 'ar_ap_ledger.AR (= current M_in)      ' || COUNT(*) FROM ar_ap_ledger WHERE direction='AR';
SELECT 'ar_ap_ledger.AP (= current M_out)     ' || COUNT(*) FROM ar_ap_ledger WHERE direction='AP';
SELECT 'finance_receipts (expect 7804)      ' || COUNT(*) FROM finance_receipts;
SELECT 'finance_payments (expect 4545)      ' || COUNT(*) FROM finance_payments;
SELECT 'finance_expenses (expect 1125)      ' || COUNT(*) FROM finance_expenses;
SELECT 'finance_expense_items (expect 8537) ' || COUNT(*) FROM finance_expense_items;
SELECT 'finance_other_incomes (expect 1552) ' || COUNT(*) FROM finance_other_incomes;
SELECT 'finance_other_income_items (1551)   ' || COUNT(*) FROM finance_other_income_items;
SELECT 'finance_reconciliations (expect30626)' || COUNT(*) FROM finance_reconciliations;

SELECT '==== ar_ap_ledger.direction x source_doc_type distribution ====' AS section;
SELECT direction, source_doc_type, COUNT(*) AS cnt
FROM ar_ap_ledger
GROUP BY direction, source_doc_type
ORDER BY direction, source_doc_type;

SELECT '==== ar_ap_ledger.legacy_bstyle distribution (no UNKNOWN after BStyle->source_doc_type) ====' AS section;
SELECT legacy_source, legacy_bstyle, source_doc_type, COUNT(*) AS cnt
FROM ar_ap_ledger
GROUP BY legacy_source, legacy_bstyle, source_doc_type
ORDER BY legacy_source, legacy_bstyle;

SELECT '==== accounts.account_type rebuild distribution (AStyle degradation check) ====' AS section;
SELECT account_type, COUNT(*) AS cnt FROM accounts GROUP BY account_type ORDER BY cnt DESC;

SELECT '==== Consistency checks (broken counts expect 0) ====' AS section;

-- Ledger balance equation: amount_balance = amount_original_local - amount_settled
-- (DIRECT_RECEIPT/PAYMENT may carry negative balance)
SELECT 'ar_ap_ledger balance equation broken (expect 0)  ' ||
       COUNT(*) FROM ar_ap_ledger
WHERE amount_balance <> amount_original_local - amount_settled;

-- Historical deleted parties are represented by disabled stubs, never NULL.
SELECT 'AR rows with NULL client_id (expect 0)          ' ||
       COUNT(*) FROM ar_ap_ledger WHERE direction='AR' AND client_id IS NULL;

-- AP rows must have supplier_id (B_Provider is more complete than B_Client)
SELECT 'AP rows with NULL supplier_id (expect 0)        ' ||
       COUNT(*) FROM ar_ap_ledger WHERE direction='AP' AND supplier_id IS NULL;

-- Account balance conservation: balance_current = init + receipts - payments
SELECT 'accounts balance conservation broken (expect 0) ' ||
       COUNT(*) FROM accounts
WHERE balance_current <> init_balance + receipts_total - payments_total;

SELECT '==== Account balance reconciliation (new DB vs legacy M_in/M_out) ====' AS section;

-- AR side: SUM(M_in.Total) vs SUM(ar_ap_ledger AR amount_original_local)
SELECT 'M_in.Total sum (legacy)                        ' || COALESCE(SUM(total), 0)::text
FROM m_in_stage;

SELECT 'ar_ap_ledger AR amount_original_local          ' || COALESCE(SUM(amount_original_local), 0)::text
FROM ar_ap_ledger WHERE direction='AR';

-- AP side: SUM(M_out.Total) vs SUM(ar_ap_ledger AP amount_original_local)
SELECT 'M_out.Total sum (legacy)                       ' || COALESCE(SUM(total), 0)::text
FROM m_out_stage;

SELECT 'ar_ap_ledger AP amount_original_local          ' || COALESCE(SUM(amount_original_local), 0)::text
FROM ar_ap_ledger WHERE direction='AP';

-- ---------------- 跨模块 source_doc_id 回填（P0-3，修历史红冲校验） ----------------
-- 历史 M_in/M_out 行只记 source_doc_no；按单号 JOIN 各业务单据表回填 source_doc_id，
-- 使 reverseArAp(sourceDocId,type) 对历史单据也能命中。幂等（WHERE source_doc_id IS NULL）。
-- 未命中的=单号在新表不存在（超迁移范围/它类），保留 NULL。
UPDATE ar_ap_ledger a SET source_doc_id = s.id FROM sales_shipments s
WHERE a.source_doc_type='SALES_SHIPMENT' AND a.source_doc_no = s.bill_no
  AND a.source_doc_id IS DISTINCT FROM s.id;
UPDATE ar_ap_ledger a SET source_doc_id = s.id FROM sales_returns s
WHERE a.source_doc_type='SALES_RETURN' AND a.source_doc_no = s.bill_no
  AND a.source_doc_id IS DISTINCT FROM s.id;
UPDATE ar_ap_ledger a SET source_doc_id = s.id FROM subcontract_receipts s
WHERE a.source_doc_type='SUBCONTRACT_RECEIPT' AND a.source_doc_no = s.bill_no
  AND a.source_doc_id IS DISTINCT FROM s.id;
UPDATE ar_ap_ledger a SET source_doc_id = s.id FROM subcontract_returns s
WHERE a.source_doc_type='SUBCONTRACT_RETURN' AND a.source_doc_no = s.bill_no
  AND a.source_doc_id IS DISTINCT FROM s.id;
UPDATE ar_ap_ledger a SET source_doc_id = s.id FROM purchase_receipts s
WHERE a.source_doc_type='PURCHASE_RECEIPT' AND a.source_doc_no = s.bill_no
  AND a.source_doc_id IS DISTINCT FROM s.id;
UPDATE ar_ap_ledger a SET source_doc_id = s.id FROM purchase_returns s
WHERE a.source_doc_type='PURCHASE_RETURN' AND a.source_doc_no = s.bill_no
  AND a.source_doc_id IS DISTINCT FROM s.id;
-- DIRECT_RECEIPT/PAYMENT 回填（指向 finance_receipts/payments）
UPDATE ar_ap_ledger a SET source_doc_id = r.id FROM finance_receipts r
WHERE a.source_doc_type='DIRECT_RECEIPT' AND a.source_doc_no = r.bill_no
  AND a.source_doc_id IS DISTINCT FROM r.id;
UPDATE ar_ap_ledger a SET source_doc_id = p.id FROM finance_payments p
WHERE a.source_doc_type='DIRECT_PAYMENT' AND a.source_doc_no = p.bill_no
  AND a.source_doc_id IS DISTINCT FROM p.id;

-- source_doc_id 回填命中率（全部 8 类）
SELECT 'source_doc_id hit rate by type                ' || source_doc_type || '  ' ||
       COUNT(*) FILTER (WHERE source_doc_id IS NOT NULL) || ' / ' || COUNT(*)
FROM ar_ap_ledger
WHERE source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN','SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN',
                          'PURCHASE_RECEIPT','PURCHASE_RETURN','DIRECT_RECEIPT','DIRECT_PAYMENT')
GROUP BY source_doc_type ORDER BY source_doc_type;

-- =====================================================================
-- 人员列回填命中 + 物化视图刷新校验（V70 + 刷MV）
-- =====================================================================
SELECT '==== Finance person *_legacy_id / *_name hit rate (V70) ====' AS section;
SELECT 'finance_receipts.maker_legacy_id      ' || COUNT(*) FILTER (WHERE maker_legacy_id IS NOT NULL)    || ' / ' || COUNT(*) FROM finance_receipts;
SELECT 'finance_receipts.operator_legacy_id   ' || COUNT(*) FILTER (WHERE operator_legacy_id IS NOT NULL) || ' / ' || COUNT(*) FROM finance_receipts;
SELECT 'finance_receipts.maker_name (frozen)  ' || COUNT(*) FILTER (WHERE maker_name IS NOT NULL AND maker_name <> '') || ' / ' || COUNT(*) FROM finance_receipts;
SELECT 'finance_payments.maker_name (frozen)  ' || COUNT(*) FILTER (WHERE maker_name IS NOT NULL AND maker_name <> '') || ' / ' || COUNT(*) FROM finance_payments;
SELECT 'finance_payments.approver_name(frozen)' || COUNT(*) FILTER (WHERE approver_name IS NOT NULL AND approver_name <> '') || ' / ' || COUNT(*) FROM finance_payments;
SELECT 'finance_expenses.operator_legacy_id   ' || COUNT(*) FILTER (WHERE operator_legacy_id IS NOT NULL) || ' / ' || COUNT(*) FROM finance_expenses;
SELECT 'finance_other_incomes.operator_legacy ' || COUNT(*) FILTER (WHERE operator_legacy_id IS NOT NULL) || ' / ' || COUNT(*) FROM finance_other_incomes;
SELECT 'employees legacy stubs (B_Worker)     ' || COUNT(*) FROM employees WHERE code LIKE 'LEGACY-W-%';

SELECT '==== ar_ap_ledger.settlement_style_legacy (PStyle) ====' AS section;
SELECT COALESCE(settlement_style_legacy::text,'NULL') || '  ' || COUNT(*) AS pstyle_dist
FROM ar_ap_ledger GROUP BY settlement_style_legacy ORDER BY COUNT(*) DESC;

SELECT '==== finance_ar_ap_mv refresh (expect > 0) ====' AS section;
SELECT 'finance_ar_ap_mv rows                 ' || COUNT(*) FROM finance_ar_ap_mv;
SELECT 'MV AR rows                            ' || COUNT(*) FROM finance_ar_ap_mv WHERE direction='AR';
SELECT 'MV AP rows                            ' || COUNT(*) FROM finance_ar_ap_mv WHERE direction='AP';

-- =====================================================================
-- Blocking reconciliation: any mismatch aborts the entire transaction.
-- Diagnostic SELECTs above remain useful to operators, but are not relied on
-- for correctness.
-- =====================================================================
DO $$
DECLARE
    broken_count BIGINT;
    expected_count BIGINT;
    actual_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO expected_count FROM m_in_stage;
    SELECT COUNT(*) INTO actual_count FROM ar_ap_ledger WHERE direction = 'AR';
    IF actual_count <> expected_count THEN
        RAISE EXCEPTION 'finance migration AR count mismatch: expected %, actual %',
            expected_count, actual_count;
    END IF;

    SELECT COUNT(*) INTO expected_count FROM m_out_stage;
    SELECT COUNT(*) INTO actual_count FROM ar_ap_ledger WHERE direction = 'AP';
    IF actual_count <> expected_count THEN
        RAISE EXCEPTION 'finance migration AP count mismatch: expected %, actual %',
            expected_count, actual_count;
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM ar_ap_ledger
    WHERE amount_balance <> amount_original_local - amount_settled;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION 'finance migration balance equation violations: %', broken_count;
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM ar_ap_ledger
    WHERE is_settled IS DISTINCT FROM (amount_balance = 0)
       OR (is_settled AND settled_date IS NULL)
       OR (NOT is_settled AND settled_date IS NOT NULL);
    IF broken_count <> 0 THEN
        RAISE EXCEPTION 'finance migration settlement-state violations: %', broken_count;
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM ar_ap_ledger
    WHERE NOT (
        (direction = 'AR' AND client_id IS NOT NULL AND supplier_id IS NULL)
        OR
        (direction = 'AP' AND supplier_id IS NOT NULL AND client_id IS NULL)
    );
    IF broken_count <> 0 THEN
        RAISE EXCEPTION 'finance migration party-shape violations: %', broken_count;
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM accounts
    WHERE balance_current <> init_balance + receipts_total - payments_total;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION 'finance migration account-balance violations: %', broken_count;
    END IF;

    SELECT
        (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN sales_shipments d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'SALES_SHIPMENT'
           AND a.source_doc_id IS DISTINCT FROM d.id)
      + (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN sales_returns d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'SALES_RETURN'
           AND a.source_doc_id IS DISTINCT FROM d.id)
      + (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN subcontract_receipts d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'SUBCONTRACT_RECEIPT'
           AND a.source_doc_id IS DISTINCT FROM d.id)
      + (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN subcontract_returns d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'SUBCONTRACT_RETURN'
           AND a.source_doc_id IS DISTINCT FROM d.id)
      + (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN purchase_receipts d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'PURCHASE_RECEIPT'
           AND a.source_doc_id IS DISTINCT FROM d.id)
      + (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN purchase_returns d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'PURCHASE_RETURN'
           AND a.source_doc_id IS DISTINCT FROM d.id)
      + (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN finance_receipts d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'DIRECT_RECEIPT'
           AND a.source_doc_id IS DISTINCT FROM d.id)
      + (SELECT COUNT(*) FROM ar_ap_ledger a
         JOIN finance_payments d ON d.bill_no = a.source_doc_no
         WHERE a.source_doc_type = 'DIRECT_PAYMENT'
           AND a.source_doc_id IS DISTINCT FROM d.id)
    INTO broken_count;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION 'finance migration logical source UUID mismatches: %', broken_count;
    END IF;

    IF (SELECT COUNT(*) FROM finance_receipts)
       <> (SELECT COUNT(*) FROM m_get_stage) THEN
        RAISE EXCEPTION 'finance_receipts row count mismatch';
    END IF;
    IF (SELECT COUNT(*) FROM finance_payments)
       <> (SELECT COUNT(*) FROM m_paid_stage) THEN
        RAISE EXCEPTION 'finance_payments row count mismatch';
    END IF;
    IF (SELECT COUNT(*) FROM finance_expenses)
       <> (SELECT COUNT(*) FROM m_dpaid_stage) THEN
        RAISE EXCEPTION 'finance_expenses row count mismatch';
    END IF;
    IF (SELECT COUNT(*) FROM finance_expense_items)
       <> (SELECT COUNT(*) FROM m_dpaid_item_stage) THEN
        RAISE EXCEPTION 'finance_expense_items row count mismatch';
    END IF;
    IF (SELECT COUNT(*) FROM finance_other_incomes)
       <> (SELECT COUNT(*) FROM m_oget_stage) THEN
        RAISE EXCEPTION 'finance_other_incomes row count mismatch';
    END IF;
    IF (SELECT COUNT(*) FROM finance_other_income_items)
       <> (SELECT COUNT(*) FROM m_oget_item_stage) THEN
        RAISE EXCEPTION 'finance_other_income_items row count mismatch';
    END IF;
    IF (SELECT COUNT(*) FROM finance_reconciliations)
       <> (SELECT COUNT(*) FROM m_allcheck_stage) THEN
        RAISE EXCEPTION 'finance_reconciliations row count mismatch';
    END IF;
END
$$;

COMMIT;
