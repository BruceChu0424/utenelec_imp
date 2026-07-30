-- V122 · 总账子系统（C3）：凭证 + 分录。科目复用 payment_styles 树（INCOME/EXPENSE/ACCOUNT/LIABILITY/EQUITY）。
-- 分录由 GlPostingService 按源单生成（source='AUTO'，幂等重生成）；后续 C6 在审核节点插钩实时过账。
-- 审计列一次带全（V94 教训）：created_at/updated_at/created_by/updated_by/is_deleted/deleted_at。

CREATE TABLE gl_vouchers (
    id            uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    voucher_no    text        NOT NULL,                 -- 源单单号（成本结转单号带 -CB 后缀；月度汇总单 M-YYYY-MM-XX）
    period        char(7)     NOT NULL,                 -- 会计期间 YYYY-MM
    voucher_date  date        NOT NULL,
    source        text        NOT NULL DEFAULT 'AUTO',  -- AUTO=系统生成 / MANUAL=手工凭证
    source_type   text,                                 -- RECEIPT/PAYMENT/EXPENSE/INCOME/AR_POST/AP_POST/COST_CARRY/MANUAL
    remark        text,
    status        smallint    NOT NULL DEFAULT 1,       -- 1 有效 / -1 作废
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_by    uuid,
    is_deleted    boolean     NOT NULL DEFAULT false,
    deleted_at    timestamptz,
    UNIQUE (voucher_no, source_type)
);
CREATE INDEX idx_glv_period ON gl_vouchers (period);
CREATE INDEX idx_glv_date   ON gl_vouchers (voucher_date);

CREATE TABLE gl_entries (
    id              uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    voucher_id      uuid        NOT NULL REFERENCES gl_vouchers(id) ON DELETE CASCADE,
    line_no         integer     NOT NULL DEFAULT 1,
    style_id        uuid        NOT NULL REFERENCES payment_styles(id),  -- 科目（payment_styles 树节点）
    direction       smallint    NOT NULL,               -- 1 借 / -1 贷
    amount          numeric(18,4) NOT NULL,             -- 正数；负值业务用红字（同向负金额）不反向
    entry_date      date        NOT NULL,
    period          char(7)     NOT NULL,
    source_doc_type text,                               -- 源单类型（ar_ap_ledger.source_doc_type / 模块名）
    source_doc_id   uuid,
    source_bill_no  text,
    summary         text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    updated_by      uuid,
    is_deleted      boolean     NOT NULL DEFAULT false,
    deleted_at      timestamptz
);
CREATE INDEX idx_gle_voucher ON gl_entries (voucher_id);
CREATE INDEX idx_gle_period  ON gl_entries (period);
CREATE INDEX idx_gle_style_date ON gl_entries (style_id, entry_date);
CREATE INDEX idx_gle_source  ON gl_entries (source_doc_type, source_doc_id);

-- 账户→科目 解析：accounts.style_legacy_id→payment_styles.legacy_id；无挂接 CASH→/101/，其余→/102/。
CREATE OR REPLACE FUNCTION account_style_id(p_account_id uuid) RETURNS uuid AS $$
    SELECT COALESCE(
        (SELECT ps.id FROM accounts a JOIN payment_styles ps ON ps.legacy_id = a.style_legacy_id
         WHERE a.id = p_account_id AND ps.is_deleted=false LIMIT 1),
        (SELECT ps.id FROM accounts a JOIN payment_styles ps
           ON ps.path = CASE WHEN a.account_type='CASH' THEN '/101/' ELSE '/102/' END
         WHERE a.id = p_account_id LIMIT 1),
        (SELECT id FROM payment_styles WHERE path='/102/'));
$$ LANGUAGE SQL STABLE;
