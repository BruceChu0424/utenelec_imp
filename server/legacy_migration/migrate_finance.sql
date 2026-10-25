-- =====================================================================
-- Finance module migration: legacy M_* -> accounts/payment_styles
--                                  + ar_ap_ledger + 6 doc types + reconciliations
-- =====================================================================
-- Usage: only as a module of the verified --bootstrap-all transaction.
-- Pre: V50 (accounts/payment_styles) + V57 (finance docs) applied;
--      clients/suppliers/currencies migrated (V36/V38/V42).
-- Order: (1) payment-style tree, final account UUID references, optional reverse links
--        (2) employee UUIDs, immutable original cash headers/items/flows
--        (3) M_In/M_Out source balances with exact source evidence or explicit
--            LEGACY_OPENING when the relationship cannot be uniquely proven
--        (M_Bank legacy 0 rows: structure already in V57, no data to ingest)
-- Bootstrap-only: FK-ordered DELETE of finance transaction tables/accounts;
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
--             原始字典已在受验 CSV 中，对照现行种子并保留源 SMALLINT 证据）。
-- department_id: SystemItem.ItemID <-> departments has no legacy_id mapping
--             (V02 table has no legacy_id column), leave NULL (open item
--             design doc 26 sec 9-8).
-- status: proved posted sources retain1; the exact reviewed historical unapproved sources remain archive-only, never modern reversals or drafts
--         (legacy has no draft state).
-- Money: float -> numeric(18,4); exchange rate -> numeric(18,6).
-- =====================================================================

-- V265 payment-style reference guards are immediate. The bootstrap loads
-- styles with their final account UUIDs, using a transaction-local import mode and
-- perform an explicit mapping reconciliation before COMMIT. The guard still
-- takes PAYMENT_STYLE_HIERARCHY for the whole migration transaction.
SELECT set_config(
    'uten.payment_style_reference_import',
    'legacy-finance-v1',
    true
);
SELECT set_config('uten.legacy_reference_import', 'legacy-finance-v273', true);
SELECT pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY',0));
SELECT pg_advisory_xact_lock(hashtextextended('ACCOUNT_MASTER_POPULATION',0));

DO $$
BEGIN
    IF (SELECT count(*) FROM system_master_category_registry) <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM system_master_category_registry registry
           JOIN client_categories client_category
             ON client_category.id = registry.client_category_id
           JOIN supplier_categories supplier_category
             ON supplier_category.id = registry.supplier_category_id
           WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid
             AND client_category.legacy_id = -1
             AND client_category.is_deleted = FALSE
             AND supplier_category.legacy_id = -1
             AND supplier_category.is_deleted = FALSE
       ) THEN
        RAISE EXCEPTION 'current system party-category UUID authority is missing or invalid';
    END IF;
END;
$$;

-- V267 adds payment_styles.linked_account_id -> accounts. Break that reverse
-- Preserve payment-style authority; FK-enforced DELETE refuses unsafe account reloads.
UPDATE payment_styles
SET linked_account_id = NULL
WHERE linked_account_id IS NOT NULL;
DELETE FROM finance_reconciliations;
DELETE FROM finance_bank_transfer_lines;
DELETE FROM finance_bank_transfers;
DELETE FROM finance_other_income_items;
DELETE FROM finance_other_incomes;
DELETE FROM finance_expense_items;
DELETE FROM finance_expenses;
DELETE FROM finance_payment_lines;
DELETE FROM finance_payments;
DELETE FROM finance_receipt_lines;
DELETE FROM finance_receipts;
DELETE FROM finance_check_register;
DELETE FROM ar_ap_ledger;
-- DELETE intentionally keeps FK checks. Any account reference missed by the
-- explicit cleanup above aborts the migration instead of being cascaded away.
DELETE FROM accounts;

-- ---------------- staging (real types) ----------------
-- RecStyle is a shared receipt/payment dictionary, independent from M_Style.
CREATE TEMP TABLE recstyle_stage (legacy_id int, name text);
\copy recstyle_stage FROM '/tmp/recstyle.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO finance_payment_methods (
    id, legacy_id, code, name, is_receipt, is_payment,
    legacy_name_confirmed, status, sort_order)
SELECT
    (substr(md5('uten.finance-payment-method:' || s.legacy_id),1,8) || '-' ||
     substr(md5('uten.finance-payment-method:' || s.legacy_id),9,4) || '-4' ||
     substr(md5('uten.finance-payment-method:' || s.legacy_id),14,3) || '-8' ||
     substr(md5('uten.finance-payment-method:' || s.legacy_id),18,3) || '-' ||
     substr(md5('uten.finance-payment-method:' || s.legacy_id),21,12))::uuid,
    s.legacy_id,
    'REC-' || lpad(s.legacy_id::text, 4, '0'),
    s.name,
    TRUE,
    TRUE,
    TRUE,
    '使用',
    s.legacy_id * 10
FROM recstyle_stage s
WHERE s.legacy_id > 0 AND NULLIF(btrim(s.name), '') IS NOT NULL
ON CONFLICT (legacy_id) DO UPDATE SET
    name = EXCLUDED.name,
    is_receipt = TRUE,
    is_payment = TRUE,
    legacy_name_confirmed = TRUE,
    status = EXCLUDED.status,
    sort_order = EXCLUDED.sort_order;

-- M_Acc (source inventory, 13 cols) -> accounts
CREATE TEMP TABLE m_acc_stage (
    legacy_id int, code text, name text, bank_account_no text,
    init_balance numeric(18,4), receipts_total numeric(18,4),
    payments_total numeric(18,4), balance_current numeric(18,4),
    remark text, parent_legacy_id int, status text,
    style_legacy_id int, a_style int);
\copy m_acc_stage FROM '/tmp/m_acc.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- M_Style (source inventory, 15 cols) -> payment_styles (tree)
CREATE TEMP TABLE m_style_stage (
    legacy_id int, style_class_id int, code text, name text, parent_legacy int,
    remark text, status int, dept_status boolean, next_number text,
    init_total numeric(18,4), q_status boolean,
    orient_status1 boolean, orient_status2 boolean, unit text, item_id int);
\copy m_style_stage FROM '/tmp/m_style.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- Display codes belong to the current platform namespace. Compute global
-- source-order sequences once, before depth-layered tree insertion; never reset
-- the sequence for each depth. Complete typed original rows stay in TEMP until
-- all V626 row proofs have finished, then are flushed to run source evidence.
CREATE TEMP TABLE finance_master_source_stage AS
SELECT 'M_STYLE'::text source_kind,s.legacy_id,
       'SK'||lpad(row_number() OVER(ORDER BY s.legacy_id)::text,6,'0') target_code,
       to_jsonb(s) typed_source,
       encode(digest(to_jsonb(s)::text,'sha256'),'hex') source_row_sha256
FROM m_style_stage s
UNION ALL
SELECT 'M_ACC',s.legacy_id,
       'ZH'||lpad(row_number() OVER(ORDER BY s.legacy_id)::text,6,'0'),
       to_jsonb(s),encode(digest(to_jsonb(s)::text,'sha256'),'hex')
FROM m_acc_stage s;
ALTER TABLE finance_master_source_stage ADD PRIMARY KEY(source_kind,legacy_id);
DO $$ BEGIN
    PERFORM fn_require_legacy_bootstrap(current_setting('uten.bootstrap_run_id')::uuid,'m_style.csv');
    PERFORM fn_require_legacy_bootstrap(current_setting('uten.bootstrap_run_id')::uuid,'m_acc.csv');
    IF (SELECT count(*) FROM m_style_stage)>999999 OR (SELECT count(*) FROM m_acc_stage)>999999 THEN
        RAISE EXCEPTION 'finance source master count exceeds the current six-digit namespace' USING ERRCODE='23514';
    END IF;
END; $$;

-- Snapshot existing system master/role state before source rows are inserted.
-- Independently captured fresh-seed JSON remains the external acceptance anchor.
CREATE TEMP TABLE finance_seed_before_stage AS
SELECT 'PAYMENT_STYLE'::text source_kind,p.id::text identity,
       to_jsonb(p)-ARRAY['created_at','updated_at','created_by','updated_by'] payload
FROM payment_styles p
UNION ALL
SELECT 'POSTING_ROLE',p.role_key,
       to_jsonb(p)-ARRAY['created_at','updated_at','created_by','updated_by']
FROM system_posting_style_roles p;

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
WITH candidates AS (
    SELECT DISTINCT party_legacy_id
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
), numbered AS (
    SELECT candidates.*, row_number() OVER (ORDER BY party_legacy_id) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM candidates
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'CLIENT', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO clients (
    legacy_id, category_id, code, name, status, remark, code_managed, code_sequence)
SELECT party_legacy_id,
       (SELECT client_category_id
        FROM system_master_category_registry
        WHERE id = '27500000-0000-4000-8000-000000000001'::uuid),
       'LEGACY-FIN-CL-' || party_legacy_id,
       U&'\94B1\6D41\5386\53F2\5BA2\6237\FF08\539FID ' || party_legacy_id::text || U&'\FF09',
       U&'\7981\7528',
       U&'\5386\53F2\94B1\6D41\81EA\52A8\8865\5F55\FF0C\771F\5B9E\4E3B\6863\7F3A\5931\FF0C\52FF\7528\4E8E\65B0\5355',
       FALSE, reserved.last_seq - numbered.allocation_count + numbered.seq_ordinal
FROM numbered CROSS JOIN reserved
ON CONFLICT (legacy_id) DO UPDATE
SET category_id = COALESCE(clients.category_id, EXCLUDED.category_id);

WITH candidates AS (
    SELECT DISTINCT party_legacy_id
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
), numbered AS (
    SELECT candidates.*, row_number() OVER (ORDER BY party_legacy_id) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM candidates
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'SUPPLIER', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO suppliers (
    legacy_id, category_id, code, name, status, remark, code_managed, code_sequence)
SELECT party_legacy_id,
       (SELECT supplier_category_id
        FROM system_master_category_registry
        WHERE id = '27500000-0000-4000-8000-000000000001'::uuid),
       'LEGACY-FIN-SP-' || party_legacy_id,
       U&'\94B1\6D41\5386\53F2\4F9B\5E94\5546\FF08\539FID ' || party_legacy_id::text || U&'\FF09',
       U&'\7981\7528',
       U&'\5386\53F2\94B1\6D41\81EA\52A8\8865\5F55\FF0C\771F\5B9E\4E3B\6863\7F3A\5931\FF0C\52FF\7528\4E8E\65B0\5355',
       FALSE, reserved.last_seq - numbered.allocation_count + numbered.seq_ordinal
FROM numbered CROSS JOIN reserved
ON CONFLICT (legacy_id) DO UPDATE
SET category_id = COALESCE(suppliers.category_id, EXCLUDED.category_id);


-- =====================================================================
-- (1) accounts master (M_Acc source rows -> accounts, account_type rebuilt
--     from AccName keyword CASE; AStyle degraded, ignored)
-- =====================================================================
-- The legacy DB stores AccName/Status as Chinese (GBK in MSSQL, UTF-8 after
-- export). The migrate matches Chinese substrings via chr(codepoint) to keep
-- the reviewed known-name rules remain ahead of the source-ancestry fallback;
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
DO $$
DECLARE
    v_match_count BIGINT;
BEGIN
    PERFORM 1
      FROM currencies
     WHERE legacy_id IN (1,3)
        OR id IN (
            SELECT account.currency_id
            FROM accounts account
            WHERE account.status=chr(20351) || chr(29992)
              AND COALESCE(account.is_deleted,FALSE)=FALSE
              AND account.currency_id IS NOT NULL)
     ORDER BY id
     FOR SHARE;

    IF EXISTS (
        SELECT 1 FROM m_acc_stage s
        WHERE s.name NOT LIKE '%' || chr(39321) || '%'
    ) THEN
        SELECT COUNT(*) INTO v_match_count
        FROM currencies
        WHERE legacy_id=1
          AND status=chr(20351) || chr(29992)
          AND COALESCE(is_deleted,FALSE)=FALSE;
        IF v_match_count<>1 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE=format(
                    'legacy RMB account import requires exactly one active currencies.legacy_id=1 row; found %s',
                    v_match_count);
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM m_acc_stage s
        WHERE s.name LIKE '%' || chr(39321) || '%'
    ) THEN
        SELECT COUNT(*) INTO v_match_count
        FROM currencies
        WHERE legacy_id=3
          AND status=chr(20351) || chr(29992)
          AND COALESCE(is_deleted,FALSE)=FALSE;
        IF v_match_count<>1 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE=format(
                    'legacy OFFSHORE account import requires exactly one active currencies.legacy_id=3 row; found %s',
                    v_match_count);
        END IF;
    END IF;
END $$;

-- =====================================================================
-- (2) payment_styles tree (M_Style source nodes -> payment_styles, by category)
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

-- Account type fallback follows the original source hierarchy, never current
-- SK display codes or a same-name/code child. Positive missing/cyclic source
-- ancestry is a review error; a bank-family root must be uniquely identified.
CREATE TEMP TABLE finance_account_lineage_stage AS
WITH RECURSIVE ancestry AS (
 SELECT account.legacy_id account_legacy_id,style.legacy_id style_legacy_id,
        style.parent_legacy,style.style_class_id,style.code,style.name,
        ARRAY[style.legacy_id]::integer[] visited,false cycle
 FROM m_acc_stage account
 LEFT JOIN m_style_stage style ON style.legacy_id=NULLIF(account.style_legacy_id,0)
 WHERE NULLIF(account.style_legacy_id,0) IS NOT NULL
 UNION ALL
 SELECT ancestry.account_legacy_id,parent.legacy_id,parent.parent_legacy,
        parent.style_class_id,parent.code,parent.name,
        ancestry.visited||parent.legacy_id,parent.legacy_id=ANY(ancestry.visited)
 FROM ancestry
 LEFT JOIN m_style_stage parent ON parent.legacy_id=ancestry.parent_legacy
 WHERE ancestry.style_legacy_id IS NOT NULL AND NOT ancestry.cycle
   AND ancestry.parent_legacy IS NOT NULL AND ancestry.parent_legacy<>0
)
SELECT * FROM ancestry;
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM finance_account_lineage_stage WHERE cycle OR style_legacy_id IS NULL) THEN
        RAISE EXCEPTION 'finance account source ancestry is missing or cyclic; reviewed source repair is required' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM finance_account_lineage_stage
              WHERE coalesce(parent_legacy,0)=0 AND style_class_id=1 AND btrim(code)='102')
       AND (SELECT count(*) FROM m_style_stage
             WHERE coalesce(parent_legacy,0)=0 AND style_class_id=1
               AND btrim(code)='102' AND btrim(name)='银行存款')<>1 THEN
        RAISE EXCEPTION 'finance account source bank root is missing or ambiguous; no name-only fallback is permitted' USING ERRCODE='23514';
    END IF;
END; $$;

DO $$
DECLARE d INT; maxd INT;
BEGIN
    SELECT COALESCE(MAX(depth), 0) INTO maxd FROM ps_depth;
    FOR d IN 0..maxd LOOP
        INSERT INTO payment_styles (
            legacy_id, code, name, category, level, sort_order, parent_id,
            is_departmental, is_receipt, is_payment,
            linked_account_legacy_id, linked_account_id, init_balance, status,
            legacy_source_code,legacy_source_item_id,legacy_source_import_run_id)
        SELECT
            s.legacy_id, source_master.target_code, s.name,
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
            NULL::integer, NULL::uuid, -- bind the optional reverse account link after final accounts exist
            s.init_total,
            chr(20351) || chr(29992), -- '使用'
            s.code,s.item_id,current_setting('uten.bootstrap_run_id')::uuid
        FROM m_style_stage s JOIN ps_depth n ON n.legacy_id = s.legacy_id
        JOIN finance_master_source_stage source_master
          ON source_master.source_kind='M_STYLE' AND source_master.legacy_id=s.legacy_id
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
            linked_account_id = EXCLUDED.linked_account_id,
            init_balance = EXCLUDED.init_balance,
            status = EXCLUDED.status,
            legacy_source_code=EXCLUDED.legacy_source_code,
            legacy_source_item_id=EXCLUDED.legacy_source_item_id,
            legacy_source_import_run_id=EXCLUDED.legacy_source_import_run_id;
    END LOOP;
END $$;

INSERT INTO accounts (
    legacy_id, code, name, bank_account_no, account_type,
    currency_id, style_id,
    init_balance, receipts_total, payments_total, balance_current,
    parent_legacy_id, style_legacy_id, status)
SELECT
    s.legacy_id, source_master.target_code, s.name, NULLIF(s.bank_account_no, ''),
    CASE
        -- Chinese keyword mapping (AccName is Chinese in the live legacy DB)
        WHEN s.name LIKE '%' || chr(39321) || '%'                                       THEN 'OFFSHORE'        -- Xianggang (Hong Kong)
        WHEN s.name LIKE '%' || chr(24494) || '%'                                       THEN 'THIRD_PARTY'     -- Wei Xin (WeChat)
        WHEN s.name LIKE '%' || chr(25903) || chr(20184) || chr(23453) || '%'           THEN 'THIRD_PARTY'     -- Zhi Fu Bao (Alipay)
        WHEN s.name LIKE '%' || chr(29616) || chr(37329) || '%'                         THEN 'CASH'            -- Xian Jin (cash)
        WHEN s.name = chr(25903) || chr(31080) AND s.status = chr(31105) || chr(29992) THEN 'CHECK'           -- Zhi Piao + Jin Yong
        WHEN s.name = chr(25903) || chr(31080) THEN 'FOREIGN_CHECK'                     -- Zhi Piao + other
        WHEN s.name IN ('一般账户','一般帐户') THEN 'GENERAL' -- preserve both reviewed generic-account spellings before bank ancestry fallback
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
        WHEN EXISTS(SELECT 1 FROM finance_account_lineage_stage root
                    WHERE root.account_legacy_id=s.legacy_id AND coalesce(root.parent_legacy,0)=0
                      AND root.style_class_id=1 AND btrim(root.code)='102' AND btrim(root.name)='银行存款')
         AND NOT EXISTS(SELECT 1 FROM finance_account_lineage_stage ancestor
                        WHERE ancestor.account_legacy_id=s.legacy_id AND ancestor.style_class_id IS DISTINCT FROM 1)
        THEN 'BANK'
        ELSE 'GENERAL'
    END,
    CASE
        WHEN s.name LIKE '%' || chr(39321) || '%' THEN (
            SELECT currency.id FROM currencies currency
            WHERE currency.legacy_id=3
              AND currency.status=chr(20351) || chr(29992)
              AND COALESCE(currency.is_deleted,FALSE)=FALSE)
        ELSE (
            SELECT currency.id FROM currencies currency
            WHERE currency.legacy_id=1
              AND currency.status=chr(20351) || chr(29992)
              AND COALESCE(currency.is_deleted,FALSE)=FALSE)
    END,
    (SELECT style.id FROM payment_styles style WHERE style.legacy_id = NULLIF(s.style_legacy_id, 0)),
    COALESCE(s.init_balance, 0), COALESCE(s.receipts_total, 0),
    COALESCE(s.payments_total, 0), COALESCE(s.balance_current, 0),
    NULLIF(s.parent_legacy_id, 0), NULLIF(s.style_legacy_id, 0),
    COALESCE(NULLIF(s.status, ''), chr(20351) || chr(29992))  -- 'Shi Yong' (In Use) default
FROM m_acc_stage s JOIN finance_master_source_stage source_master
  ON source_master.source_kind='M_ACC' AND source_master.legacy_id=s.legacy_id;


-- Accounts require final active ACCOUNT leaf UUIDs at insertion (V277).
-- Once they exist, resolve the style's optional reverse account reference;
-- no approved money fact or historical account authority is patched later.
UPDATE payment_styles style
SET linked_account_legacy_id = CASE
        WHEN source.item_id>0 AND style.category='ACCOUNT' AND account.status='使用' AND NOT account.is_deleted
        THEN account.legacy_id ELSE NULL END,
    linked_account_id = CASE
        WHEN source.item_id>0 AND style.category='ACCOUNT' AND account.status='使用' AND NOT account.is_deleted
        THEN account.id ELSE NULL END
FROM m_style_stage source
LEFT JOIN accounts account ON account.legacy_id = NULLIF(source.item_id, 0)
WHERE style.legacy_id = source.legacy_id;

-- Keep every original reference, including NULL/0 and unavailable accounts.
-- This is source review evidence, never a live account or monetary approval.
CREATE TEMP TABLE finance_master_reference_review_stage AS
SELECT source.legacy_id,CASE
    WHEN source.item_id IS NULL OR source.item_id=0 THEN 'NO_SOURCE_REFERENCE'
    WHEN source.item_id<0 THEN 'INVALID_SOURCE_REFERENCE'
    WHEN source.style_class_id IS DISTINCT FROM 1 THEN 'NON_ACCOUNT_CLASS'
    WHEN account.id IS NULL THEN 'MISSING_ACCOUNT'
    WHEN account.is_deleted THEN 'ACCOUNT_DELETED'
    WHEN account.status IS DISTINCT FROM '使用' THEN 'ACCOUNT_DISABLED'
    ELSE 'BOUND' END reference_reason
FROM m_style_stage source
LEFT JOIN accounts account ON account.legacy_id=source.item_id;

-- =====================================================================
-- Historical employee identity before immutable finance source rows：B_Worker → employees stub（融合键 legacy_id，经手人/收款人）
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
-- (4) finance_receipts (M_Get) + finance_payments (M_Paid)
-- =====================================================================
-- V21 source-specific historical unapproved cash headers remain complete
-- source archives. A source -1 is not a modern reversal or a current draft.
-- The portable policy is rendered by the reviewed coordinator, before this
-- module's original typed stages are loaded. No user identity is impersonated.
CREATE TEMP TABLE bootstrap_finance_cash_archive ON COMMIT DROP AS
SELECT policy.*,to_jsonb(source.*) AS typed_source,
       encode(digest(to_jsonb(source.*)::text,'sha256'),'hex') AS actual_source_row_sha256
FROM m_get_stage source JOIN bootstrap_finance_cash_policy policy
 ON policy.source_file='m_get.csv' AND policy.source_kind='RECEIPT' AND policy.source_legacy_id=source.legacy_id
UNION ALL
SELECT policy.*,to_jsonb(source.*),encode(digest(to_jsonb(source.*)::text,'sha256'),'hex')
FROM m_paid_stage source JOIN bootstrap_finance_cash_policy policy
 ON policy.source_file='m_paid.csv' AND policy.source_kind='PAYMENT' AND policy.source_legacy_id=source.legacy_id;

DO $cash_source_archive_guard$
DECLARE meta jsonb;source_name text;source_count bigint;source_ids text;expected jsonb;
BEGIN
 SELECT payload INTO STRICT meta FROM bootstrap_finance_cash_policy_meta;
 IF jsonb_typeof(meta) IS DISTINCT FROM 'object'
    OR NOT (meta ?& ARRAY['format','policy_sha256','source_cutoff_utc','raw_manifest_sha256','source_backup_sha256',
       'source_semantics_sha256','reviewed_dispositions_sha256','native_typed_source_sha256','derived_manifest_sha256',
       'source_files','package_files','partitions'])
    OR meta->>'format' IS DISTINCT FROM 'finance-cash-source-archive-policy-v1'
    OR jsonb_typeof(meta->'source_files') IS DISTINCT FROM 'object'
    OR jsonb_typeof(meta->'package_files') IS DISTINCT FROM 'object'
    OR jsonb_typeof(meta->'partitions') IS DISTINCT FROM 'object'
    OR jsonb_typeof(meta->'source_cutoff_utc') IS DISTINCT FROM 'string'
 THEN RAISE EXCEPTION 'cash policy mandatory metadata is absent or malformed';END IF;
 IF (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(meta->'package_files') key)
       IS DISTINCT FROM ARRAY['finance_cash_reviewed_dispositions.json','finance_cash_source_policy.json','finance_cash_source_semantics.json','finance_cash_typed_source_receipt.json']::text[]
    OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(meta->'source_files') key)
       IS DISTINCT FROM ARRAY['m_allcheck.csv','m_dpaid.csv','m_get.csv','m_in.csv','m_oget.csv','m_out.csv','m_paid.csv']::text[]
    OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(meta->'partitions') key)
       IS DISTINCT FROM ARRAY['m_dpaid.csv','m_get.csv','m_oget.csv','m_paid.csv']::text[]
 THEN RAISE EXCEPTION 'cash policy package/source/partition key population differs';END IF;
 FOREACH source_name IN ARRAY ARRAY['policy_sha256','raw_manifest_sha256','source_backup_sha256','source_semantics_sha256',
       'reviewed_dispositions_sha256','native_typed_source_sha256','derived_manifest_sha256'] LOOP
  IF COALESCE((meta->>source_name)~'^[0-9a-f]{64}$',FALSE) IS NOT TRUE
  THEN RAISE EXCEPTION 'cash policy required fingerprint is absent or malformed';END IF;
 END LOOP;
 FOR source_name IN SELECT jsonb_object_keys(meta->'package_files') LOOP
  expected:=meta#>ARRAY['package_files',source_name];
  IF jsonb_typeof(expected) IS DISTINCT FROM 'object' OR NOT(expected ?& ARRAY['sha256','bytes'])
      OR COALESCE((expected->>'sha256')~'^[0-9a-f]{64}$',FALSE) IS NOT TRUE
      OR jsonb_typeof(expected->'bytes') IS DISTINCT FROM 'number' OR (expected->>'bytes')::bigint<=0
  THEN RAISE EXCEPTION 'cash policy package fingerprint/byte size is absent or malformed';END IF;
 END LOOP;
 FOR source_name IN SELECT jsonb_object_keys(meta->'source_files') LOOP
  expected:=meta#>ARRAY['source_files',source_name];
  IF jsonb_typeof(expected) IS DISTINCT FROM 'object' OR NOT(expected ?& ARRAY['sha256','rows'])
      OR COALESCE((expected->>'sha256')~'^[0-9a-f]{64}$',FALSE) IS NOT TRUE
      OR jsonb_typeof(expected->'rows') IS DISTINCT FROM 'number' OR (expected->>'rows')::bigint<0
  THEN RAISE EXCEPTION 'cash policy complete source fingerprint/count is absent or malformed';END IF;
 END LOOP;
 FOR source_name IN SELECT jsonb_object_keys(meta->'partitions') LOOP
  expected:=meta#>ARRAY['partitions',source_name];
  IF jsonb_typeof(expected) IS DISTINCT FROM 'object' OR NOT(expected ?& ARRAY['source_rows','active_rows','archive_rows','source_ids_sha256','active_ids_sha256','archive_ids_sha256'])
     OR jsonb_typeof(expected->'source_rows') IS DISTINCT FROM 'number'
     OR jsonb_typeof(expected->'active_rows') IS DISTINCT FROM 'number'
     OR jsonb_typeof(expected->'archive_rows') IS DISTINCT FROM 'number'
     OR (expected->>'source_rows')::bigint<0 OR (expected->>'active_rows')::bigint<0 OR (expected->>'archive_rows')::bigint<0
     OR (expected->>'source_rows')::bigint IS DISTINCT FROM (expected->>'active_rows')::bigint+(expected->>'archive_rows')::bigint
     OR COALESCE((expected->>'source_ids_sha256')~'^[0-9a-f]{64}$',FALSE) IS NOT TRUE
     OR COALESCE((expected->>'active_ids_sha256')~'^[0-9a-f]{64}$',FALSE) IS NOT TRUE
     OR COALESCE((expected->>'archive_ids_sha256')~'^[0-9a-f]{64}$',FALSE) IS NOT TRUE
  THEN RAISE EXCEPTION 'cash policy exact partition count/fingerprint is absent or malformed';END IF;
 END LOOP;
 IF current_setting('TimeZone') IS DISTINCT FROM 'Asia/Shanghai' OR meta->>'format' IS DISTINCT FROM 'finance-cash-source-archive-policy-v1'
 OR NOT EXISTS(SELECT 1 FROM legacy_migration_runs run WHERE run.run_id=current_setting('uten.bootstrap_run_id')::uuid
     AND run.status='RUNNING' AND run.target='--bootstrap-all' AND run.migration_mode='BOOTSTRAP'
     AND run.export_manifest_sha256::text=meta->>'derived_manifest_sha256'
     AND run.checksum_manifest_sha256::text=meta->>'derived_manifest_sha256'
     AND run.source_backup_sha256::text=meta->>'source_backup_sha256'
     AND run.reconciliation_summary->>'rawManifestSha256'=meta->>'raw_manifest_sha256'
     AND (run.reconciliation_summary->>'sourceSnapshotAsOfUtc')::timestamptz=(meta->>'source_cutoff_utc')::timestamptz)
 THEN RAISE EXCEPTION 'cash source archive policy does not bind this exact initializing source run';END IF;
 FOR source_name IN SELECT jsonb_object_keys(meta->'package_files') LOOP
  IF NOT EXISTS(SELECT 1 FROM legacy_migration_run_files file WHERE file.run_id=current_setting('uten.bootstrap_run_id')::uuid
      AND file.file_name=source_name AND file.sha256::text=meta#>>ARRAY['package_files',source_name,'sha256']
      AND file.byte_size=(meta#>>ARRAY['package_files',source_name,'bytes'])::bigint)
  THEN RAISE EXCEPTION 'cash policy package file is not registered with its exact SHA and bytes';END IF;
 END LOOP;
 FOR source_name IN SELECT jsonb_object_keys(meta->'source_files') LOOP
  IF NOT EXISTS(SELECT 1 FROM legacy_migration_run_files file
       WHERE file.run_id=current_setting('uten.bootstrap_run_id')::uuid AND file.file_name=source_name
         AND file.sha256::text=meta#>>ARRAY['source_files',source_name,'sha256'])
  THEN RAISE EXCEPTION 'cash archive original or related source file differs';END IF;
  EXECUTE format('SELECT count(*) FROM %I',replace(source_name,'.csv','_stage')) INTO source_count;
  IF source_count IS DISTINCT FROM (meta#>>ARRAY['source_files',source_name,'rows'])::bigint
  THEN RAISE EXCEPTION 'cash archive complete typed source stage row count differs';END IF;
 END LOOP;
 IF (SELECT count(*) FROM bootstrap_finance_cash_archive)<>(SELECT count(*) FROM bootstrap_finance_cash_policy)
    OR EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive GROUP BY source_file,source_legacy_id HAVING count(*)<>1)
    OR EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a WHERE
       a.actual_source_row_sha256 IS DISTINCT FROM a.source_row_sha256
       OR a.typed_source::text IS DISTINCT FROM a.typed_source_jsonb_text
       OR encode(digest(a.typed_source_jsonb_text,'sha256'),'hex') IS DISTINCT FROM a.source_row_sha256
       OR a.typed_source->>'status' IS DISTINCT FROM '-1' OR a.typed_source->>'status2' IS DISTINCT FROM '-1'
       OR (a.typed_source->>'cancel')::boolean IS DISTINCT FROM FALSE
       OR COALESCE((a.typed_source->>'approver_id')::int,0)<>0 OR NULLIF(a.typed_source->>'approver_name','') IS NOT NULL)
 THEN RAISE EXCEPTION 'cash archive lost or changed an exact reviewed complete typed source identity';END IF;
 IF EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a WHERE
      a.source_row_number IS NULL OR a.source_row_number<2 OR a.activity_age_days IS NULL OR a.activity_age_days<=0
      OR a.source_file_sha256 IS DISTINCT FROM meta#>>ARRAY['source_files',a.source_file,'sha256']
      OR COALESCE(a.raw_source_file_sha256~'^[0-9a-f]{64}$',FALSE) IS NOT TRUE
      OR jsonb_typeof(a.reason_codes) IS DISTINCT FROM 'array' OR jsonb_typeof(a.lifecycle) IS DISTINCT FROM 'object'
      OR (SELECT array_agg(reason ORDER BY reason) FROM jsonb_array_elements_text(a.reason_codes) reason)
           IS DISTINCT FROM ARRAY['EXACT_HISTORICAL_SOURCE_ROW_REVIEWED_AS_OF_CUTOFF','NO_PROVEN_MODERN_GL_POSTING_OR_REVERSAL','NO_SOURCE_ALLOCATION_ROWS','NO_SOURCE_APPROVER','NO_SOURCE_CASH_OR_AR_AP_EFFECT','ONLY_CREATION_IN_AVAILABLE_SOURCE_LOGS','SOURCE_DEFAULT_AND_DICTIONARY_UNAPPROVED','SOURCE_STATUS_EQUALS_STATUS2_MINUS_ONE']::text[]
      OR NOT(a.lifecycle ?& ARRAY['LogsID','source_beijing_time','EContext'])
      OR COALESCE((a.lifecycle->>'LogsID')::bigint,0)<=0
      OR COALESCE(strpos(a.lifecycle->>'EContext',a.typed_source->>'bill_no'),0)<=0
      OR COALESCE(strpos(a.lifecycle->>'EContext','增加'),0)<=0
      OR COALESCE((a.lifecycle->>'EContext')~'(审核|反审|修改|删除|撤销)',FALSE)
      OR (((meta->>'source_cutoff_utc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date-(a.lifecycle->>'source_beijing_time')::timestamp::date) IS DISTINCT FROM a.activity_age_days)
 THEN RAISE EXCEPTION 'cash archive exact source file, reason, ordinal or historical lifecycle proof differs';END IF;

 IF EXISTS(SELECT 1 FROM m_get_stage source WHERE
       (source.status=1 AND source.status2=1 AND source.cancel IS FALSE AND COALESCE(source.approver_id,0)>0) IS NOT TRUE
       AND NOT EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a WHERE a.source_file='m_get.csv' AND a.source_legacy_id=source.legacy_id))
 OR EXISTS(SELECT 1 FROM m_paid_stage source WHERE
       (source.status=1 AND source.status2=1 AND source.cancel IS FALSE AND COALESCE(source.approver_id,0)>0) IS NOT TRUE
       AND NOT EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a WHERE a.source_file='m_paid.csv' AND a.source_legacy_id=source.legacy_id))
 OR EXISTS(SELECT 1 FROM m_dpaid_stage WHERE (status=1 AND status2=1 AND cancel IS FALSE AND COALESCE(approver_id,0)>0) IS NOT TRUE)
 OR EXISTS(SELECT 1 FROM m_oget_stage WHERE (status=1 AND status2=1 AND cancel IS FALSE AND COALESCE(approver_id,0)>0) IS NOT TRUE)
 THEN RAISE EXCEPTION 'unknown nonposted cash source requires an independent early classification';END IF;
 IF EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a JOIN m_allcheck_stage flow
     ON flow.b_style=CASE a.source_file WHEN 'm_get.csv' THEN 20 ELSE 21 END AND flow.bill_id=a.source_legacy_id)
 OR EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a JOIN m_in_stage ledger
     ON a.source_file='m_get.csv' AND ledger.b_style=20 AND ledger.bill_legacy_id=a.source_legacy_id)
 OR EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a JOIN m_out_stage ledger
     ON a.source_file='m_paid.csv' AND ledger.b_style=21 AND ledger.bill_legacy_id=a.source_legacy_id)
 THEN RAISE EXCEPTION 'reviewed unapproved cash header has an actual original cash or AR/AP effect';END IF;
 FOR source_name IN SELECT jsonb_object_keys(meta->'partitions') LOOP
  EXECUTE format('SELECT count(*),encode(digest(COALESCE(string_agg(legacy_id::text||chr(10),'''' ORDER BY legacy_id),''''),''sha256''),''hex'') FROM %I',
    replace(source_name,'.csv','_stage')) INTO source_count,source_ids;
  expected:=meta#>ARRAY['partitions',source_name];
  IF source_count IS DISTINCT FROM (expected->>'source_rows')::bigint OR source_ids IS DISTINCT FROM expected->>'source_ids_sha256'
  THEN RAISE EXCEPTION 'cash source full identity population differs from its prepared partition';END IF;
 END LOOP;
END;
$cash_source_archive_guard$;

SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'RECEIPT', to_jsonb(legacy_row.*))
FROM m_get_stage legacy_row WHERE NOT EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a
 WHERE a.source_file='m_get.csv' AND a.source_legacy_id=legacy_row.legacy_id) ORDER BY legacy_row.legacy_id;

SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'PAYMENT', to_jsonb(legacy_row.*))
FROM m_paid_stage legacy_row WHERE NOT EXISTS(SELECT 1 FROM bootstrap_finance_cash_archive a
 WHERE a.source_file='m_paid.csv' AND a.source_legacy_id=legacy_row.legacy_id) ORDER BY legacy_row.legacy_id;

-- Conserve complete source identities: live legacy facts plus the separately
-- reviewed immutable source archive. Archived headers have no modern target,
-- V626 target proof, approval, settlement allocation, GL or workflow claim.
DO $cash_source_archive_conservation$
DECLARE meta jsonb;source_name text;target_name text;kind_name text;actual_count bigint;actual_ids text;expected jsonb;
BEGIN
 SELECT payload INTO STRICT meta FROM bootstrap_finance_cash_policy_meta;
 FOR source_name,target_name,kind_name IN VALUES
    ('m_get.csv','finance_receipts','RECEIPT'),('m_paid.csv','finance_payments','PAYMENT') LOOP
  expected:=meta#>ARRAY['partitions',source_name];
  EXECUTE format('SELECT count(*),encode(digest(COALESCE(string_agg(legacy_id::text||chr(10),'''' ORDER BY legacy_id),''''),''sha256''),''hex'') FROM %I WHERE legacy_id IS NOT NULL',target_name)
    INTO actual_count,actual_ids;
  IF actual_count IS DISTINCT FROM (expected->>'active_rows')::bigint OR actual_ids IS DISTINCT FROM expected->>'active_ids_sha256'
  THEN RAISE EXCEPTION 'cash active targets do not exactly equal the reviewed original active source identities';END IF;
  IF (SELECT count(*) FROM bootstrap_finance_cash_archive WHERE source_file=source_name)<>(expected->>'archive_rows')::bigint
     OR (SELECT encode(digest(COALESCE(string_agg(source_legacy_id::text||chr(10),'' ORDER BY source_legacy_id),''),'sha256'),'hex')
         FROM bootstrap_finance_cash_archive WHERE source_file=source_name)<>expected->>'archive_ids_sha256'
  THEN RAISE EXCEPTION 'cash archive is missing, duplicated or contains an extra source identity';END IF;
  IF EXISTS(SELECT 1 FROM legacy_finance_import_sources proof JOIN bootstrap_finance_cash_archive archived
        ON archived.source_kind=proof.source_kind AND archived.source_legacy_id=proof.source_legacy_id
        WHERE proof.run_id=current_setting('uten.bootstrap_run_id')::uuid)
  THEN RAISE EXCEPTION 'archive-only cash source incorrectly acquired a live V626 target proof';END IF;
 END LOOP;
END;
$cash_source_archive_conservation$;

UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object(
 'financeCashSourceArchive',jsonb_build_object('format','finance-cash-source-archive-only-v1',
   'source_policy',(SELECT payload FROM bootstrap_finance_cash_policy_meta),
   'session_timezone',current_setting('TimeZone'),
   'entries',(SELECT COALESCE(jsonb_agg(to_jsonb(a)-ARRAY['actual_source_row_sha256','typed_source_jsonb_text']
       ||jsonb_build_object('disposition','ARCHIVE_ONLY_UNAPPROVED_HISTORICAL_SOURCE') ORDER BY source_file,source_legacy_id),'[]'::jsonb)
      FROM bootstrap_finance_cash_archive a)))
WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid;

DO $cash_archive_ops_audit$
DECLARE previous_actor text:=current_setting('app.actor_id',true);
        previous_account text:=current_setting('app.actor_account',true);
BEGIN
 PERFORM set_config('app.actor_id','',true);
 PERFORM set_config('app.actor_account','ops:legacy_finance_cash_archive',true);
 INSERT INTO audit_log(actor_id,actor_account,action,target_type,target_id,"after",result,request_id,
    event_source,risk_level,event_category,device_capture_status)
 SELECT NULL,'ops:legacy_finance_cash_archive','legacy_finance_cash_source_archive','legacy_finance_source',
     source_file||':'||source_legacy_id::text,
     jsonb_build_object('run_id',current_setting('uten.bootstrap_run_id'),
       'source_file',source_file,'source_legacy_id',source_legacy_id,'source_kind',source_kind,
       'source_file_sha256',source_file_sha256,'raw_source_file_sha256',raw_source_file_sha256,
       'source_row_sha256',source_row_sha256,'source_row_number',source_row_number,
       'reason_codes',reason_codes,'disposition','ARCHIVE_ONLY_UNAPPROVED_HISTORICAL_SOURCE',
       'source_policy_sha256',(SELECT payload->>'policy_sha256' FROM bootstrap_finance_cash_policy_meta),
       'source_semantics_sha256',(SELECT payload->>'source_semantics_sha256' FROM bootstrap_finance_cash_policy_meta),
       'raw_manifest_sha256',(SELECT payload->>'raw_manifest_sha256' FROM bootstrap_finance_cash_policy_meta),
       'source_backup_sha256',(SELECT payload->>'source_backup_sha256' FROM bootstrap_finance_cash_policy_meta),
       'database_current_user',current_user,'database_session_user',session_user,
       'target_money_document_created',false,'target_GL_or_settlement_created',false,'workflow_claim_created',false),
     'success',current_setting('uten.bootstrap_run_id')::uuid,'system','high','data_change','missing'
 FROM bootstrap_finance_cash_archive;
 PERFORM set_config('app.actor_id',COALESCE(previous_actor,''),true);
 PERFORM set_config('app.actor_account',COALESCE(previous_account,''),true);
END;
$cash_archive_ops_audit$;

-- Approved historical money facts are inserted with final UUID references.
-- A later UPDATE would correctly be rejected by the modern immutability guard.


-- =====================================================================
-- (6) finance_expenses + items (M_DPaid + M_DPaidItem, by department)
-- =====================================================================
SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'EXPENSE', to_jsonb(legacy_row.*))
FROM m_dpaid_stage legacy_row ORDER BY legacy_row.legacy_id;

SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'EXPENSE_ITEM', to_jsonb(legacy_row.*),
    (row_number() OVER (PARTITION BY legacy_row.bill_legacy_id ORDER BY legacy_row.legacy_id))::integer)
FROM m_dpaid_item_stage legacy_row ORDER BY legacy_row.bill_legacy_id, legacy_row.legacy_id;


-- =====================================================================
-- (7) finance_other_incomes + items (M_OGet + M_OGetItem)
-- =====================================================================
SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'INCOME', to_jsonb(legacy_row.*))
FROM m_oget_stage legacy_row ORDER BY legacy_row.legacy_id;

SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'INCOME_ITEM', to_jsonb(legacy_row.*),
    (row_number() OVER (PARTITION BY legacy_row.bill_legacy_id ORDER BY legacy_row.legacy_id))::integer)
FROM m_oget_item_stage legacy_row ORDER BY legacy_row.bill_legacy_id, legacy_row.legacy_id;


-- =====================================================================
-- (8) finance_reconciliations (M_AllCheck 30,626 rows -> account register)
-- =====================================================================
-- source_doc_type routed by BStyle
--   (20->RECEIPT / 21->PAYMENT / 22->INCOME / 23->EXPENSE / 27->BANK_TRANSFER);
--   posting BStyles (3/18/1/17/30) do NOT write M_AllCheck in the legacy DB
--   (design doc 25 sec 4.2); unsupported source kinds require source reconciliation.
-- source_doc_id JOINed by BStyle to the right finance doc table legacy_id;
--   no match -> NULL (tolerates historical dirty rows).
-- A missing original account or unsupported original family cannot become
-- active cash history. Preserve its complete typed source with this run;
-- never create a current account, balance, posting or approval to make it fit.
SELECT fn_require_legacy_bootstrap(current_setting('uten.bootstrap_run_id')::uuid,'m_allcheck.csv');

CREATE TEMP TABLE bootstrap_finance_archive_only AS
SELECT 'm_allcheck.csv'::text AS source_file, source.legacy_id AS source_legacy_id,
       (row_number() OVER (ORDER BY source.legacy_id) + 1)::bigint AS source_row_number,
       source.acc_id AS legacy_account_id, source.b_style AS legacy_bstyle,
       to_jsonb(source.*) AS typed_source,
       encode(digest(to_jsonb(source.*)::text,'sha256'),'hex') AS source_row_sha256,
       file.sha256::text AS source_file_sha256,
       array_remove(ARRAY[
           CASE WHEN NOT EXISTS(SELECT 1 FROM m_acc_stage account WHERE account.legacy_id=source.acc_id)
                THEN 'MISSING_ORIGINAL_ACCOUNT' END,
           CASE WHEN source.b_style IS NULL OR source.b_style NOT IN(20,21,22,23,27)
                THEN 'UNSUPPORTED_ORIGINAL_DOCUMENT_FAMILY' END],NULL)::text[] AS reason_codes,
       'ARCHIVE_ONLY'::text AS disposition
FROM m_allcheck_stage source CROSS JOIN legacy_migration_run_files file
WHERE file.run_id=current_setting('uten.bootstrap_run_id')::uuid AND file.file_name='m_allcheck.csv';
DELETE FROM bootstrap_finance_archive_only WHERE cardinality(reason_codes)=0;
ALTER TABLE bootstrap_finance_archive_only ADD PRIMARY KEY(source_legacy_id);

DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM m_acc_stage source WHERE NOT EXISTS(
        SELECT 1 FROM accounts target WHERE target.legacy_id=source.legacy_id))
       OR EXISTS(SELECT 1 FROM accounts target WHERE target.legacy_id IS NULL OR NOT EXISTS(
        SELECT 1 FROM m_acc_stage source WHERE source.legacy_id=target.legacy_id)) THEN
        RAISE EXCEPTION 'finance source account identities do not exactly match active imported accounts';
    END IF;
END; $$;

SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'ACCOUNT_FLOW', to_jsonb(legacy_row.*))
FROM m_allcheck_stage legacy_row
WHERE NOT EXISTS(SELECT 1 FROM bootstrap_finance_archive_only archived
                 WHERE archived.source_legacy_id=legacy_row.legacy_id)
ORDER BY legacy_row.legacy_id;

-- Individual historical deltas can be signed. The existing native CHECK is
-- about the final Shanghai account/currency/month SUM, never a changed source.
DO $$ BEGIN
    IF EXISTS(
        SELECT 1 FROM finance_reconciliations flow
        WHERE NOT COALESCE(flow.is_deleted,FALSE)
        GROUP BY flow.account_id,flow.account_currency_id,
                 date_trunc('month',flow.bill_date AT TIME ZONE 'Asia/Shanghai')::date
        HAVING SUM(COALESCE(flow.in_amount,0))<0 OR SUM(COALESCE(flow.out_amount,0))<0
    ) THEN
        RAISE EXCEPTION 'source account-flow final monthly aggregate is negative; preserve source and review before import'
            USING ERRCODE='23514',CONSTRAINT='legacy_account_flow_final_monthly_nonnegative';
    END IF;
END; $$;
SELECT fn_rebuild_account_flow_monthly_summaries(NULL);
SELECT fn_assert_account_flow_monthly_integrity(NULL);

DO $$ BEGIN
    IF (SELECT count(*) FROM m_allcheck_stage)<>(SELECT count(*) FROM finance_reconciliations WHERE legacy_id IS NOT NULL)
            +(SELECT count(*) FROM bootstrap_finance_archive_only)
       OR EXISTS(SELECT 1 FROM bootstrap_finance_archive_only archived JOIN finance_reconciliations target
                 ON target.legacy_id=archived.source_legacy_id)
       OR EXISTS(SELECT 1 FROM bootstrap_finance_archive_only archived JOIN legacy_finance_import_sources proof
                 ON proof.run_id=current_setting('uten.bootstrap_run_id')::uuid AND proof.source_kind='ACCOUNT_FLOW'
                    AND proof.source_legacy_id=archived.source_legacy_id) THEN
        RAISE EXCEPTION 'finance active/account-flow source/archive-only identities do not reconcile';
    END IF;
END; $$;

-- compose_bootstrap removes module staging tables; retain the explicit source
-- disposition in the existing run summary before that cleanup, with no new DDL.
UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object(
    'financeArchiveOnly',jsonb_build_object('format','finance-source-archive-only-v1',
        'source_file','m_allcheck.csv','source_file_sha256',(
            SELECT sha256::text FROM legacy_migration_run_files
            WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid AND file_name='m_allcheck.csv'),
        'source_count',(SELECT count(*) FROM m_allcheck_stage),
        'active_count',(SELECT count(*) FROM finance_reconciliations WHERE legacy_id IS NOT NULL),
        'archived_count',(SELECT count(*) FROM bootstrap_finance_archive_only),
        'session_timezone',current_setting('TimeZone'),
        'entries',(SELECT COALESCE(jsonb_agg(to_jsonb(archived) ORDER BY source_legacy_id),'[]'::jsonb)
                   FROM bootstrap_finance_archive_only archived)))
WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid;


-- Verified source open items come after all original cash headers so actual
-- BillID/party/number relationships can be resolved without later rebinding.
-- The database importer preserves unresolved relationships as LEGACY_OPENING;
-- raw settled totals are historical opening facts, never invented payment lines.
SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'AR_OPENING', to_jsonb(legacy_row.*))
FROM m_in_stage legacy_row ORDER BY legacy_row.legacy_id;
SELECT fn_import_legacy_finance_source(
    current_setting('uten.bootstrap_run_id')::uuid, 'AP_OPENING', to_jsonb(legacy_row.*))
FROM m_out_stage legacy_row ORDER BY legacy_row.legacy_id;

-- =====================================================================
-- (9) finance_bank_transfers (M_Bank legacy 0 rows -> empty structure)
-- =====================================================================
-- Legacy M_Bank/M_BankItem 0 rows (never activated); V57 has the empty
-- structure preserving the Service skeleton (cross-currency conversion).
-- A nonempty M_Bank export is rejected before import; a future protocol must
-- define its own source proof before supporting these historical rows.


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

SELECT 'accounts source/target ' || (SELECT count(*) FROM m_acc_stage) || ' / ' || COUNT(*) FROM accounts;
SELECT 'payment_styles source/total ' || (SELECT count(*) FROM m_style_stage) || ' / ' || COUNT(*) FROM payment_styles;
SELECT 'ar_ap_ledger total (= current stages)' || COUNT(*) FROM ar_ap_ledger;
SELECT 'ar_ap_ledger.AR (= current M_in)      ' || COUNT(*) FROM ar_ap_ledger WHERE direction='AR';
SELECT 'ar_ap_ledger.AP (= current M_out)     ' || COUNT(*) FROM ar_ap_ledger WHERE direction='AP';
SELECT 'finance_receipts                   ' || COUNT(*) FROM finance_receipts;
SELECT 'finance_payments                   ' || COUNT(*) FROM finance_payments;
SELECT 'finance_expenses                   ' || COUNT(*) FROM finance_expenses;
SELECT 'finance_expense_items              ' || COUNT(*) FROM finance_expense_items;
SELECT 'finance_other_incomes              ' || COUNT(*) FROM finance_other_incomes;
SELECT 'finance_other_income_items (1551)   ' || COUNT(*) FROM finance_other_income_items;
SELECT 'finance_reconciliations (active legacy snapshots)' || COUNT(*) FROM finance_reconciliations;
SELECT 'finance source archive-only (no active account/flow)' || COUNT(*) FROM bootstrap_finance_archive_only;

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

-- Account balance conservation: balance_current = init + receipts - payments + adjustments
SELECT 'accounts balance conservation broken (expect 0) ' ||
       COUNT(*) FROM accounts
WHERE balance_current <> init_balance + receipts_total - payments_total
                              + balance_adjustments_total;

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
-- V626 preserves an unknown historical paid date when the original balance
-- is already zero. Only complete typed original rows from this transaction's
-- exact AR/AP source namespace can authorize that one missing-date case.
-- Build the small candidate set once; never re-project every opening row.
ANALYZE public.legacy_finance_import_sources;
ANALYZE public.ar_ap_ledger;
CREATE TEMP TABLE finance_verified_missing_settlement_date_stage (
    ledger_id uuid PRIMARY KEY
) ON COMMIT DROP;
INSERT INTO finance_verified_missing_settlement_date_stage(ledger_id)
WITH source_candidates AS MATERIALIZED (
    SELECT 'AR_OPENING'::text source_kind,'m_in.csv'::text source_file,
           source.legacy_id,to_jsonb(source.*) typed_source
    FROM m_in_stage source WHERE source.balance=0 AND source.paid_date IS NULL
    UNION ALL
    SELECT 'AP_OPENING','m_out.csv',source.legacy_id,to_jsonb(source.*)
    FROM m_out_stage source WHERE source.balance=0 AND source.paid_date IS NULL
), candidate_projections AS MATERIALIZED (
    SELECT ledger.id,proof.target_fields,proof.target_snapshot_sha256,
           to_jsonb(ledger.*) actual_payload,
           fn_legacy_finance_opening_projection(source.source_kind,source.typed_source)
             ||jsonb_build_object('id',ledger.id,'legacy_import_run_id',proof.run_id) expected_payload
    FROM source_candidates source
    JOIN public.legacy_finance_import_sources proof
      ON proof.run_id=current_setting('uten.bootstrap_run_id')::uuid
     AND proof.source_kind=source.source_kind AND proof.source_file=source.source_file
     AND proof.source_legacy_id=source.legacy_id AND proof.target_table='ar_ap_ledger'
     AND proof.issued_txid=txid_current()
     AND proof.source_row_sha256=encode(digest(source.typed_source::text,'sha256'),'hex')
    JOIN public.legacy_migration_run_files file ON file.run_id=proof.run_id
     AND file.file_name=source.source_file AND file.sha256=proof.source_file_sha256
    JOIN public.ar_ap_ledger ledger ON ledger.id=proof.target_id
     AND ledger.legacy_import_run_id=proof.run_id AND ledger.legacy_id=source.legacy_id
     AND ledger.direction=CASE source.source_kind WHEN 'AR_OPENING' THEN 'AR' ELSE 'AP' END
     AND ledger.legacy_source=CASE source.source_kind WHEN 'AR_OPENING' THEN 'M_in' ELSE 'M_out' END
     AND ledger.is_settled AND ledger.amount_balance=0 AND ledger.settled_date IS NULL
)
SELECT candidate.id FROM candidate_projections candidate
CROSS JOIN LATERAL (
    SELECT array_agg(key ORDER BY key) fields FROM jsonb_object_keys(candidate.expected_payload) key
) expected
WHERE candidate.target_fields=expected.fields
  AND candidate.target_snapshot_sha256=encode(digest(
        fn_legacy_finance_snapshot(candidate.expected_payload,expected.fields)::text,'sha256'),'hex')
  AND candidate.target_snapshot_sha256=encode(digest(
        fn_legacy_finance_snapshot(candidate.actual_payload,expected.fields)::text,'sha256'),'hex');
ANALYZE finance_verified_missing_settlement_date_stage;

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
    FROM public.ar_ap_ledger ledger
    LEFT JOIN finance_verified_missing_settlement_date_stage verified ON verified.ledger_id=ledger.id
    WHERE ledger.is_settled IS DISTINCT FROM (ledger.amount_balance = 0)
       OR (ledger.is_settled AND ledger.settled_date IS NULL AND verified.ledger_id IS NULL)
       OR (NOT ledger.is_settled AND ledger.settled_date IS NOT NULL);
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
    WHERE balance_current <> init_balance + receipts_total - payments_total
                                  + balance_adjustments_total;
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

    -- Original fee identity is not authority to reinterpret an income node
    -- as an expense. Preserve its raw ID and exact fee; only the original
    -- existing EXPENSE identity may occupy the typed expense UUID.
    SELECT COUNT(*) INTO broken_count
    FROM finance_receipts receipt
    JOIN m_get_stage source_row ON source_row.legacy_id=receipt.legacy_id
    WHERE receipt.other_fee_style_legacy_id IS DISTINCT FROM
            CASE WHEN source_row.qtfymc>0 THEN source_row.qtfymc ELSE NULL END
       OR receipt.other_fee IS DISTINCT FROM source_row.qtfy
       OR receipt.other_fee_style_id IS DISTINCT FROM
            (SELECT style.id FROM payment_styles style
             WHERE style.legacy_id=NULLIF(source_row.qtfymc,0) AND style.category='EXPENSE');
    IF broken_count<>0 THEN
        RAISE EXCEPTION 'finance migration original other-fee identity or amount mismatches: %',broken_count;
    END IF;

    IF (SELECT COUNT(*) FROM finance_receipts)+(SELECT COUNT(*) FROM bootstrap_finance_cash_archive WHERE source_file='m_get.csv')
       <> (SELECT COUNT(*) FROM m_get_stage) THEN
        RAISE EXCEPTION 'finance_receipts active plus exact typed source archive row count mismatch';
    END IF;
    IF (SELECT COUNT(*) FROM finance_payments)+(SELECT COUNT(*) FROM bootstrap_finance_cash_archive WHERE source_file='m_paid.csv')
       <> (SELECT COUNT(*) FROM m_paid_stage) THEN
        RAISE EXCEPTION 'finance_payments active plus exact typed source archive row count mismatch';
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
    IF (SELECT COUNT(*) FROM finance_reconciliations)+(SELECT COUNT(*) FROM bootstrap_finance_archive_only)
       <> (SELECT COUNT(*) FROM m_allcheck_stage) THEN
        RAISE EXCEPTION 'finance_reconciliations plus explicit source archive row count mismatch';
    END IF;

    -- The import mode only relaxes runtime active/leaf rules. Existence and
    -- category mappings must still be exact before this transaction may commit.
    SELECT
        (SELECT COUNT(*)
           FROM accounts a
           LEFT JOIN payment_styles s
             ON s.legacy_id = a.style_legacy_id
            AND COALESCE(s.is_deleted, false) = false
          WHERE COALESCE(a.is_deleted, false) = false
            AND a.style_legacy_id IS NOT NULL
            AND (s.id IS NULL OR s.category <> 'ACCOUNT'))
      + (SELECT COUNT(*)
           FROM accounts a
           LEFT JOIN payment_styles s ON s.id = a.style_id
          WHERE COALESCE(a.is_deleted, false) = false
            AND a.style_legacy_id IS NOT NULL
            AND (s.id IS NULL
                 OR s.legacy_id IS DISTINCT FROM a.style_legacy_id
                 OR s.category <> 'ACCOUNT'
                 OR s.status <> chr(20351) || chr(29992)
                 OR COALESCE(s.is_deleted, false) = true
                 OR EXISTS (
                     SELECT 1 FROM payment_styles child
                     WHERE child.parent_id = s.id
                       AND COALESCE(child.is_deleted, false) = false)))
      + (SELECT COUNT(*)
           FROM finance_receipts r
           LEFT JOIN payment_styles s
             ON s.id = r.other_fee_style_id
            AND COALESCE(s.is_deleted, false) = false
          WHERE COALESCE(r.is_deleted, false) = false
            AND r.other_fee_style_id IS NOT NULL
            AND (s.id IS NULL OR s.category <> 'EXPENSE'))
      + (SELECT COUNT(*)
           FROM finance_expense_items i
           LEFT JOIN payment_styles s
             ON s.id = i.expense_style_id
            AND COALESCE(s.is_deleted, false) = false
          WHERE COALESCE(i.is_deleted, false) = false
            AND i.expense_style_id IS NOT NULL
            AND (s.id IS NULL OR s.category <> 'EXPENSE'))
      + (SELECT COUNT(*)
           FROM finance_other_income_items i
           LEFT JOIN payment_styles s
             ON s.id = i.income_style_id
            AND COALESCE(s.is_deleted, false) = false
          WHERE COALESCE(i.is_deleted, false) = false
            AND i.income_style_id IS NOT NULL
            AND (s.id IS NULL OR s.category <> 'INCOME'))
    INTO broken_count;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION
            'finance migration payment-style mapping violations: %',
            broken_count;
    END IF;
END
$$;

SELECT set_config(
    'uten.payment_style_reference_import',
    'off',
    true
);

-- ADR-112: 科目导入完成、引用守卫恢复正常之后, 按默认科目名单为还没有任何绑定的
-- 总账附表/经营损益表行补默认绑定(幂等: 已有绑定的行不动; 只绑费用类末级科目)。
SELECT fn_finance_report_line_bindings_seed_defaults();

-- Explicit empty-role initialization from this batch's true typed source roots.
-- Existing system configuration is authoritative and is never overwritten.
-- No source ID, display SK code, or account/category name is a lookup key.
CREATE TEMP TABLE finance_source_role_candidates_stage AS
SELECT policy.role_key,policy.category,source.legacy_id,style.id style_id
FROM (VALUES ('INVENTORY_ASSET','ACCOUNT','123'),
             ('SALES_COST','EXPENSE','041'),
             ('SALES_REVENUE','INCOME','031')) policy(role_key,category,raw_root_code)
JOIN m_style_stage source ON btrim(source.code)=policy.raw_root_code
 AND (source.parent_legacy IS NULL OR source.parent_legacy=0)
JOIN payment_styles style ON style.legacy_id=source.legacy_id
 AND style.legacy_source_import_run_id=current_setting('uten.bootstrap_run_id')::uuid
 AND style.legacy_source_code IS NOT DISTINCT FROM source.code
 AND style.parent_id IS NULL AND style.category=policy.category
 AND style.status='使用' AND NOT style.is_deleted
WHERE CASE source.style_class_id WHEN 1 THEN 'ACCOUNT' WHEN 2 THEN 'LIABILITY'
 WHEN 3 THEN 'EQUITY' WHEN 4 THEN 'EXPENSE' WHEN 5 THEN 'INCOME' ELSE 'METHOD' END=policy.category;
CREATE TEMP TABLE finance_source_roles_bound_stage AS
WITH unique_candidates AS (
 SELECT role_key,min(category) category,min(legacy_id) legacy_id,
        (array_agg(style_id))[1] style_id
 FROM finance_source_role_candidates_stage GROUP BY role_key HAVING count(*)=1
), bound AS (
 UPDATE system_posting_style_roles role SET style_id=candidate.style_id
 FROM unique_candidates candidate
 WHERE role.role_key=candidate.role_key AND role.style_id IS NULL
   AND role.required_category=candidate.category
 RETURNING role.role_key,role.style_id
)
SELECT bound.*,candidate.legacy_id source_style_legacy_id
FROM bound JOIN unique_candidates candidate USING(role_key,style_id);

-- All V626 source registrations above are finished. Only now flush the complete
-- typed master source rows; putting this JSON in summary earlier would add work
-- to every financial provenance registration. This is run source evidence, not
-- a newly invented immutable table or approval of an unavailable association.
UPDATE legacy_migration_runs run
SET reconciliation_summary=run.reconciliation_summary||jsonb_build_object(
 'financeMasterSources',jsonb_build_object(
  'format','finance-master-sources-v1','run_id',run.run_id,
  'manifest_sha256',run.export_manifest_sha256,'frozen_commit',run.migration_repository_commit,
  'seed_baseline_sha256',run.reconciliation_summary->>'financeSeedBaselineSha256',
  'style_file_sha256',(SELECT sha256 FROM legacy_migration_run_files WHERE run_id=run.run_id AND file_name='m_style.csv'),
  'account_file_sha256',(SELECT sha256 FROM legacy_migration_run_files WHERE run_id=run.run_id AND file_name='m_acc.csv'),
  'style_source_count',(SELECT count(*) FROM m_style_stage),
  'account_source_count',(SELECT count(*) FROM m_acc_stage),
  'styles',(SELECT coalesce(jsonb_object_agg(source.legacy_id::text,jsonb_build_object(
    'typed_source',source.typed_source,'source_row_sha256',source.source_row_sha256,
    'target_id',target.id,'target_code',target.code,'reference_reason',review.reference_reason)
    ORDER BY source.legacy_id),'{}'::jsonb)
   FROM finance_master_source_stage source
   JOIN payment_styles target ON target.legacy_id=source.legacy_id
   JOIN finance_master_reference_review_stage review ON review.legacy_id=source.legacy_id
   WHERE source.source_kind='M_STYLE'),
  'accounts',(SELECT coalesce(jsonb_object_agg(source.legacy_id::text,jsonb_build_object(
    'typed_source',source.typed_source,'source_row_sha256',source.source_row_sha256,
    'target_id',target.id,'target_code',target.code) ORDER BY source.legacy_id),'{}'::jsonb)
   FROM finance_master_source_stage source JOIN accounts target ON target.legacy_id=source.legacy_id
   WHERE source.source_kind='M_ACC'),
  'seed_before',(SELECT coalesce(jsonb_agg(to_jsonb(before_row) ORDER BY source_kind,identity),'[]'::jsonb)
    FROM finance_seed_before_stage before_row),
  'role_source_bindings',(SELECT coalesce(jsonb_agg(to_jsonb(binding) ORDER BY role_key),'[]'::jsonb)
    FROM finance_source_roles_bound_stage binding)
 ))
WHERE run.run_id=current_setting('uten.bootstrap_run_id')::uuid;
