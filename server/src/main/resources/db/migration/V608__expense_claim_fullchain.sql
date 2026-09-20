-- ============ 报销链路完整化（2026-09-19）============
-- 背景：原报销域只有单据头+明细，审批轨迹靠前端时间戳合成、发票无结构化登记、
-- 驳回即终点（不能修订重提）、无正式单据号。本迁移补齐四件事（ADR-094）：
--   1. 报销单号 BX + YYYYMMDD + 6 位日流水（V279 DocNumberService 口径，终身占号），
--      仅缺号存量单按创建日回填，保留既有号码、终身占号及更高日流水；
--   2. 发票登记表 expense_claim_invoices：数电票 20 位号码 / 老票 8 位号码 + 10/12 位
--      代码（国家税务总局公告 2024 年第 11 号），价税合计/税额/购销双方要素；
--      「代码+号码」在存活报销单间唯一索引 = 防重复报销硬约束（财会〔2020〕6 号
--      「系统能够防止重复入账」）；草稿删除级联释放号码，驳回重提同单保留；
--   3. 审批事件表 expense_claim_events：提交/撤回/通过/驳回/打款/编辑逐笔留痕
--      （操作人姓名快照），存量单按既有时间戳回填事件；
--   4. 状态机放开 REJECTED → 提交（修订重提，不新增列：reject_reason 复位即重提）。

-- ① 单号命名空间（DocNumberPrefix.EXPENSE_CLAIM 镜像）。
INSERT INTO business_identifier_namespaces (
    namespace_key, identifier_family, fixed_prefix,
    source_table, identifier_column, discriminator_value)
VALUES ('EXPENSE_CLAIM', 'DOCUMENT', 'BX',
        'expense_claims', 'claim_no', NULL)
ON CONFLICT (namespace_key) DO NOTHING;

-- V608 尚未登记成功的开发库可能已有部分 DDL；补齐对象，不删除表或重编已有号。
ALTER TABLE expense_claims ADD COLUMN IF NOT EXISTS claim_no TEXT;

DO $claim_numbers$
DECLARE
    claim RECORD;
    number_text TEXT;
    number_date DATE;
    number_seq BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM business_identifier_namespaces
        WHERE namespace_key = 'EXPENSE_CLAIM' AND identifier_family = 'DOCUMENT'
          AND fixed_prefix = 'BX' AND source_table = 'expense_claims'
          AND identifier_column = 'claim_no' AND discriminator_value IS NULL
    ) THEN
        RAISE EXCEPTION 'V608 expense claim namespace does not match its contract';
    END IF;

    -- 先保留真实历史身份；与另一单据碰撞时整笔迁移失败，不覆盖对方占号。
    FOR claim IN SELECT id, claim_no FROM expense_claims
                 WHERE claim_no IS NOT NULL ORDER BY claim_no, id LOOP
        IF claim.claim_no !~ '^BX[0-9]{14}$' THEN
            RAISE EXCEPTION 'V608 found an invalid existing expense claim number';
        END IF;
        PERFORM fn_claim_global_business_identifier(
            claim.claim_no, 'EXPENSE_CLAIM', claim.id, NULL, 'expense_claims');
    END LOOP;

    -- 以号码内业务日为准，包含已删草稿仍保留的占号；既有更高流水不回退。
    FOR number_text IN
        SELECT normalized_identifier FROM business_identifier_reservations
        WHERE normalized_identifier ~ '^BX[0-9]{14}$'
        ORDER BY normalized_identifier
    LOOP
        number_date := to_date(substring(number_text FROM 3 FOR 8), 'YYYYMMDD');
        number_seq := right(number_text, 6)::bigint;
        IF to_char(number_date, 'YYYYMMDD') <> substring(number_text FROM 3 FOR 8)
           OR number_seq NOT BETWEEN 1 AND 999999 THEN
            RAISE EXCEPTION 'V608 found an invalid reserved expense claim date or sequence';
        END IF;
        INSERT INTO business_document_sequences (namespace_key, sequence_date, last_seq)
        VALUES ('EXPENSE_CLAIM', number_date, number_seq)
        ON CONFLICT (namespace_key, sequence_date) DO UPDATE
        SET last_seq = greatest(business_document_sequences.last_seq, excluded.last_seq);
    END LOOP;

    FOR claim IN SELECT id, (created_at AT TIME ZONE 'Asia/Shanghai')::date AS business_date
                 FROM expense_claims WHERE claim_no IS NULL ORDER BY created_at, id LOOP
        INSERT INTO business_document_sequences (namespace_key, sequence_date, last_seq)
        VALUES ('EXPENSE_CLAIM', claim.business_date, 1)
        ON CONFLICT (namespace_key, sequence_date) DO UPDATE
        SET last_seq = business_document_sequences.last_seq + 1
        RETURNING last_seq INTO number_seq;
        number_text := 'BX' || to_char(claim.business_date, 'YYYYMMDD')
                       || lpad(number_seq::text, 6, '0');
        PERFORM fn_claim_global_business_identifier(
            number_text, 'EXPENSE_CLAIM', claim.id, NULL, 'expense_claims');
        UPDATE expense_claims SET claim_no = number_text WHERE id = claim.id;
    END LOOP;
END;
$claim_numbers$;

ALTER TABLE expense_claims ALTER COLUMN claim_no SET NOT NULL;
DO $claim_constraints$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'expense_claims'::regclass
                     AND conname = 'expense_claims_claim_no_uk') THEN
        ALTER TABLE expense_claims ADD CONSTRAINT expense_claims_claim_no_uk UNIQUE (claim_no);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'expense_claims'::regclass
                     AND conname = 'expense_claims_claim_no_chk') THEN
        ALTER TABLE expense_claims ADD CONSTRAINT expense_claims_claim_no_chk
            CHECK (claim_no ~ '^BX[0-9]{14}$');
    END IF;
END;
$claim_constraints$;

CREATE OR REPLACE TRIGGER trg_business_document_expense_claims
    BEFORE INSERT OR UPDATE OF claim_no ON expense_claims
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier(
        'EXPENSE_CLAIM', 'claim_no', '');

-- ② 发票登记表。
CREATE TABLE IF NOT EXISTS expense_claim_invoices (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id         UUID NOT NULL
        REFERENCES expense_claims(id) ON DELETE CASCADE,
    line_no          INTEGER NOT NULL,
    -- GENERAL=增值税电子普通发票 SPECIAL=增值税专用发票 DIGITAL=数电票（全电）
    -- PAPER_GENERAL=纸质普票 PAPER_SPECIAL=纸质专票 OTHER=其他票据（行程单/定额票等）
    invoice_type     TEXT NOT NULL DEFAULT 'GENERAL',
    invoice_code     TEXT,
    invoice_no       TEXT NOT NULL,
    issue_date       DATE,
    seller_name      TEXT,
    seller_tax_no    TEXT,
    buyer_name       TEXT,
    amount_excl_tax  NUMERIC(18,2),
    tax_amount       NUMERIC(18,2),
    total_amount     NUMERIC(18,2) NOT NULL,
    -- UNCHECKED=未查验 VERIFIED_MANUAL=人工核对通过 MISMATCH=票面勾稽不符
    check_state      TEXT NOT NULL DEFAULT 'UNCHECKED',
    attachment_id    UUID REFERENCES attachments(id) ON DELETE SET NULL,
    remark           TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by       UUID,
    updated_by       UUID,
    CONSTRAINT expense_claim_invoices_line_uk UNIQUE (claim_id, line_no),
    CONSTRAINT expense_claim_invoices_line_chk CHECK (line_no > 0),
    CONSTRAINT expense_claim_invoices_type_chk CHECK (
        invoice_type IN (
            'GENERAL', 'SPECIAL', 'DIGITAL',
            'PAPER_GENERAL', 'PAPER_SPECIAL', 'OTHER')),
    -- 数电票 20 位号码（无代码）；老票 8 位号码（配套 10/12 位代码）。
    CONSTRAINT expense_claim_invoices_no_chk CHECK (
        invoice_no ~ '^[0-9]{8}$' OR invoice_no ~ '^[0-9]{20}$'),
    CONSTRAINT expense_claim_invoices_code_chk CHECK (
        invoice_code IS NULL OR char_length(invoice_code) IN (10, 12)),
    -- 数电票强制无代码；老票必须带代码。
    CONSTRAINT expense_claim_invoices_code_shape_chk CHECK (
        (invoice_no ~ '^[0-9]{20}$' AND invoice_code IS NULL)
        OR (invoice_no ~ '^[0-9]{8}$' AND invoice_code IS NOT NULL)),
    CONSTRAINT expense_claim_invoices_amounts_chk CHECK (
        total_amount > 0
        AND (amount_excl_tax IS NULL OR amount_excl_tax >= 0)
        AND (tax_amount IS NULL OR tax_amount >= 0)),
    CONSTRAINT expense_claim_invoices_text_len_chk CHECK (
        (seller_name IS NULL OR char_length(seller_name) <= 200)
        AND (buyer_name IS NULL OR char_length(buyer_name) <= 200)
        AND (remark IS NULL OR char_length(remark) <= 500)),
    CONSTRAINT expense_claim_invoices_tax_no_len_chk CHECK (
        seller_tax_no IS NULL OR char_length(seller_tax_no) <= 20)
);

-- 防重复报销（财会〔2020〕6 号）：发票代码（可空→''）+号码在存活报销单间唯一。
-- 草稿物理删除 → 级联删发票行 → 号码释放；驳回重提不删行 → 同单保留自己登记的票。
CREATE UNIQUE INDEX IF NOT EXISTS expense_claim_invoices_dedup_uq
    ON expense_claim_invoices (COALESCE(invoice_code, ''), invoice_no);

CREATE INDEX IF NOT EXISTS idx_expense_claim_invoices_claim
    ON expense_claim_invoices (claim_id, line_no);

-- ③ 审批事件表（逐笔留痕；列表/详情的时间线不再前端合成）。
CREATE TABLE IF NOT EXISTS expense_claim_events (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id            UUID NOT NULL
        REFERENCES expense_claims(id) ON DELETE CASCADE,
    -- CREATED/SUBMITTED/WITHDRAWN/EDITED/APPROVED/REJECTED/PAID
    event_type          TEXT NOT NULL,
    actor_employee_id   UUID REFERENCES employees(id) ON DELETE RESTRICT,
    actor_name_snapshot TEXT NOT NULL,
    remark              TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by          UUID,
    updated_by          UUID,
    CONSTRAINT expense_claim_events_type_chk CHECK (
        event_type IN (
            'CREATED', 'SUBMITTED', 'WITHDRAWN', 'EDITED',
            'APPROVED', 'REJECTED', 'PAID')),
    CONSTRAINT expense_claim_events_text_len_chk CHECK (
        char_length(actor_name_snapshot) BETWEEN 1 AND 100
        AND (remark IS NULL OR char_length(remark) <= 1000))
);

CREATE INDEX IF NOT EXISTS idx_expense_claim_events_claim
    ON expense_claim_events (claim_id, created_at, id);

DROP TRIGGER IF EXISTS trg_audit_expense_claim_invoices ON expense_claim_invoices;
CREATE TRIGGER trg_audit_expense_claim_invoices AFTER INSERT OR UPDATE OR DELETE
ON expense_claim_invoices FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE expense_claim_invoices ENABLE ALWAYS TRIGGER trg_audit_expense_claim_invoices;
DROP TRIGGER IF EXISTS trg_audit_expense_claim_events ON expense_claim_events;
CREATE TRIGGER trg_audit_expense_claim_events AFTER INSERT OR UPDATE OR DELETE
ON expense_claim_events FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE expense_claim_events ENABLE ALWAYS TRIGGER trg_audit_expense_claim_events;

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V608 cannot extend business-data reset policy safely';
    END IF;
    IF position('(''expense_claim_events'', ''CLEAR'')' IN definition)=0 THEN
        definition := replace(definition,anchor,anchor
            || E',\n            (''expense_claim_events'', ''CLEAR'')');
    END IF;
    IF position('(''expense_claim_invoices'', ''CLEAR'')' IN definition)=0 THEN
        definition := replace(definition,anchor,anchor
            || E',\n            (''expense_claim_invoices'', ''CLEAR'')');
    END IF;
    EXECUTE definition;
END;
$reset_policy$;

-- 存量报销单按既有时间戳回填事件（老单轨迹由此落地；撤回在老模型不留痕，无法回填）。
INSERT INTO expense_claim_events (
    claim_id, event_type, actor_employee_id, actor_name_snapshot, remark, created_at)
SELECT c.id, 'CREATED', c.applicant_id, c.applicant_name_snapshot, NULL, c.created_at
FROM expense_claims c
WHERE NOT EXISTS (SELECT 1 FROM expense_claim_events e
                  WHERE e.claim_id=c.id AND e.event_type='CREATED'
                    AND e.actor_employee_id=c.applicant_id AND e.created_at=c.created_at);

INSERT INTO expense_claim_events (
    claim_id, event_type, actor_employee_id, actor_name_snapshot, remark, created_at)
SELECT c.id, 'SUBMITTED', c.submitted_by, c.applicant_name_snapshot, NULL, c.submitted_at
FROM expense_claims c
WHERE c.submitted_at IS NOT NULL AND c.submitted_by IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM expense_claim_events e
                  WHERE e.claim_id=c.id AND e.event_type='SUBMITTED'
                    AND e.actor_employee_id=c.submitted_by AND e.created_at=c.submitted_at);

INSERT INTO expense_claim_events (
    claim_id, event_type, actor_employee_id, actor_name_snapshot, remark, created_at)
SELECT c.id, 'APPROVED', c.approved_by,
       coalesce(e.full_name, c.applicant_name_snapshot), NULL, c.approved_at
FROM expense_claims c
LEFT JOIN employees e ON e.id = c.approved_by
WHERE c.approved_at IS NOT NULL AND c.approved_by IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM expense_claim_events event
                  WHERE event.claim_id=c.id AND event.event_type='APPROVED'
                    AND event.actor_employee_id=c.approved_by AND event.created_at=c.approved_at);

INSERT INTO expense_claim_events (
    claim_id, event_type, actor_employee_id, actor_name_snapshot, remark, created_at)
SELECT c.id, 'REJECTED', c.rejected_by,
       coalesce(e.full_name, c.applicant_name_snapshot), c.reject_reason, c.rejected_at
FROM expense_claims c
LEFT JOIN employees e ON e.id = c.rejected_by
WHERE c.rejected_at IS NOT NULL AND c.rejected_by IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM expense_claim_events event
                  WHERE event.claim_id=c.id AND event.event_type='REJECTED'
                    AND event.actor_employee_id=c.rejected_by AND event.created_at=c.rejected_at);

INSERT INTO expense_claim_events (
    claim_id, event_type, actor_employee_id, actor_name_snapshot, remark, created_at)
SELECT c.id, 'PAID', c.paid_by,
       coalesce(e.full_name, c.applicant_name_snapshot), NULL, c.paid_at
FROM expense_claims c
LEFT JOIN employees e ON e.id = c.paid_by
WHERE c.paid_at IS NOT NULL AND c.paid_by IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM expense_claim_events event
                  WHERE event.claim_id=c.id AND event.event_type='PAID'
                    AND event.actor_employee_id=c.paid_by AND event.created_at=c.paid_at);
