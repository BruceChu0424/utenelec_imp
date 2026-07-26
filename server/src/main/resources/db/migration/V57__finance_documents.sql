-- =====================================================================
-- V57：钱流单据（应收应付台账 ar_ap_ledger + 6 类单据 + 核销对账 + 支票登记簿）
-- =====================================================================
-- 归属：钱流模块 V57（钱流管理 · 单据 + 台账）。
--
-- 老库 → 新库 链路（10 张老表 → 9 张新表）：
--   M_in (42,489)  ┐
--                  ├→ ar_ap_ledger          统一应收应付台账（direction 区分 AR/AP，跨模块立帐入口）
--   M_out (44,534) ┘                          取代老库 M_in/M_out 两张分立表
--   M_Get  + M_in(核销)   → finance_receipts(+lines)         销售收款（核销 AR）
--   M_Paid + M_out(核销)  → finance_payments(+lines)         采购付款（核销 AP）
--   M_DPaid + M_DPaidItem → finance_expenses(+items)         一般费用（按部门分摊）
--   M_OGet  + M_OGetItem  → finance_other_incomes(+items)    其它收入
--   M_Bank  + M_BankItem  → finance_bank_transfers(+lines)   银行存取款（空结构，老库 0 行）
--   M_AllCheck (30,626)   → finance_reconciliations          账户统一流水帐（核销对账）
--   M_Check (0)           → finance_check_register           支票登记簿（空结构，可选扩展）
--
-- 状态机：status 0=草稿 / 1=已审 / -1=红冲（贴老库"保存即生效"）；is_closed 结案（Service 派生）。
--   ar_ap_ledger.status 默认 1（直接立帐，跨模块 Service 调 postArAp 即时生效）。
--
-- 跨模块立帐入口（ar_ap_ledger 契约字段逐字照 27-DDL一致性契约 §四建，销售/采购/委外 Service 按此调用）：
--   销售 S_Out 审核    → postArAp(direction=AR, source_doc_type=SALES_SHIPMENT)
--   销售 S_Withdraw    → reverseArAp(...SALES_RETURN)
--   采购 P_In 审核     → postArAp(direction=AP, source_doc_type=PURCHASE_RECEIPT)
--   采购 P_Withdraw    → reverseArAp(...PURCHASE_RETURN)
--   委外 E_In 审核     → postArAp(direction=AP, source_doc_type=SUBCONTRACT_RECEIPT)
--   委外 E_WithDraw    → reverseArAp(...SUBCONTRACT_RETURN)
--   直接收款 M_Get     → postArAp(direction=AR, source_doc_type=DIRECT_RECEIPT, original=0)
--   直接付款 M_Paid    → postArAp(direction=AP, source_doc_type=DIRECT_PAYMENT, original=0)
--
-- 核销显式化（取代老库 M_in.M_In 数字累加 + BillID 推断）：
--   finance_receipt_lines.applied_ledger_id  → ar_ap_ledger.id（核销的 AR 行）
--   finance_payment_lines.applied_ledger_id  → ar_ap_ledger.id（核销的 AP 行）
--
-- 详见 docs/数据迁移/26-钱流管理-新库与迁移.md §四（DDL 蓝图）、§五（跨模块 Service 接口）。
-- 详见 docs/数据迁移/27-DDL一致性契约.md §二通用约定、§四 ar_ap_ledger 契约（逐字照建）、§五权限双 category、§八自检。
-- =====================================================================


-- ====================== 应收应付台账 ar_ap_ledger（核心 · 跨模块枢纽） ======================
-- 契约：27-DDL一致性契约 §四 字段逐字照建（销售/采购/委外 Service 按此调用 postArAp）。
-- 取代老库 M_in（应收 42,489）+ M_out（应付 44,534）两张分立表，统一 direction 区分 AR/AP。
-- 设计文档 26 §4.2 在契约基础上扩展运行字段（bill_no/due_date/amount_original/settlement_type_id/status），
--   不破坏契约 —— 跨模块调用仍按契约字段名（direction/source_doc_type/source_doc_id/amount_original_local 等）。
CREATE TABLE ar_ap_ledger (
    -- === 跨模块契约字段（27-DDL一致性契约 §四，逐字照建） ===
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    direction         TEXT NOT NULL,                     -- 'AR' 应收 / 'AP' 应付
    source_doc_type   TEXT NOT NULL,                     -- SALES_SHIPMENT/SALES_RETURN/PURCHASE_RECEIPT/PURCHASE_RETURN/
                                                         -- SUBCONTRACT_RECEIPT/SUBCONTRACT_RETURN/DIRECT_RECEIPT/DIRECT_PAYMENT
    source_doc_id     UUID,                              -- 来源单据 id（跨模块，不建 FK）
    source_doc_no     TEXT,                              -- 来源单号（跨模块查询用，契约 §四字段）
    bill_date         DATE NOT NULL,                     -- 立帐/到期日基准
    client_id         UUID REFERENCES clients(id),       -- AR 落此（direction=AR 时填）
    supplier_id       UUID REFERENCES suppliers(id),     -- AP 落此（direction=AP 时填）
    currency_id       UUID REFERENCES currencies(id),
    exchange_rate     NUMERIC(18,6) DEFAULT 1,
    amount_original_local NUMERIC(18,4) NOT NULL,        -- 原始金额（本币，退货为负；DIRECT_RECEIPT/PAYMENT 为 0）
    amount_settled    NUMERIC(18,4) NOT NULL DEFAULT 0,  -- 已核销金额（累加，本币）
    amount_balance    NUMERIC(18,4) NOT NULL,            -- = original_local − settled（Service 维护；预付款可负）
    is_settled        BOOLEAN NOT NULL DEFAULT FALSE,    -- Paid（balance ≤ 0 时 Service 置位，取代老库 TRI_GatheringCheck）
    settled_date      DATE,                              -- PaidDate 结清日期（契约 §四 DATE 类型）
    -- 老库 M_in/M_out 双表合并溯源（解 ID 冲突）：
    legacy_source     TEXT,                              -- 'M_in' / 'M_out'
    legacy_id         INT,
    legacy_bstyle     SMALLINT,                          -- 老库 BStyle（3/18/20 应收侧，1/17/30/21 应付侧）
    remark            TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID, updated_by UUID,
    is_deleted        BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,

    -- === 设计文档 26 §4.2 扩展字段（运行所需，不影响跨模块契约） ===
    bill_no           TEXT NOT NULL,                     -- 立帐单号（XC/XT/CJ/CT/EJ/XS/CF 前缀， migration = source_doc_no）
    due_date          DATE,                              -- Last_Date 收款/付款限期
    amount_original   NUMERIC(18,4) NOT NULL DEFAULT 0,  -- 原额（原币，多币种场景；默认 0 兼容单币种）
    settlement_type_id UUID,                             -- PStyle 结算方式（暂不 FK，老库 B_PStyle 字典未 dump，存疑 design doc 26 §九-6）
    status            SMALLINT NOT NULL DEFAULT 1,       -- 0草稿/1已审/-1红冲（跨模块立帐默认 1=已生效）

    -- 枚举约束（契约 §四 direction；source_doc_type 8 值枚举自 design doc 26 §4.2 表）
    CONSTRAINT ar_ap_ledger_direction_chk
        CHECK (direction IN ('AR','AP')),
    CONSTRAINT ar_ap_ledger_source_doc_type_chk
        CHECK (source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN','PURCHASE_RECEIPT','PURCHASE_RETURN',
                                   'SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN','DIRECT_RECEIPT','DIRECT_PAYMENT')),

    -- 单号唯一（按 direction 区分，避免 AR/AP 单号空间重叠；契约 §四索引 (legacy_source, legacy_id) 解 M_in/M_out ID 冲突）
    UNIQUE (bill_no, direction)
);

-- 索引（契约 §四规定 + 报表常用）
CREATE INDEX idx_arap_direction   ON ar_ap_ledger(direction);
CREATE INDEX idx_arap_direction_date ON ar_ap_ledger(direction, bill_date);
CREATE INDEX idx_arap_source      ON ar_ap_ledger(source_doc_type, source_doc_id);
CREATE INDEX idx_arap_client      ON ar_ap_ledger(client_id) WHERE direction = 'AR';
CREATE INDEX idx_arap_supplier    ON ar_ap_ledger(supplier_id) WHERE direction = 'AP';
CREATE INDEX idx_arap_date        ON ar_ap_ledger(bill_date);
CREATE INDEX idx_arap_settled     ON ar_ap_ledger(is_settled);
CREATE INDEX idx_arap_status      ON ar_ap_ledger(status);
CREATE INDEX idx_arap_legacy      ON ar_ap_ledger(legacy_source, legacy_id);
CREATE INDEX idx_arap_legacy_id   ON ar_ap_ledger(legacy_id);
CREATE INDEX idx_arap_bill_no     ON ar_ap_ledger(bill_no);

COMMENT ON TABLE  ar_ap_ledger IS '应收应付统一台账（钱流管理），合并老库 M_in(应收)+M_out(应付)；跨模块立帐入口（销售/采购/委外 Service 调 postArAp）';
COMMENT ON COLUMN ar_ap_ledger.direction IS 'AR 应收 / AP 应付（合并老库 M_in/M_out 两张分立表）';
COMMENT ON COLUMN ar_ap_ledger.source_doc_type IS '立帐来源单据类型（取代老库 BStyle int 字典）：SALES_SHIPMENT/SALES_RETURN/PURCHASE_RECEIPT/PURCHASE_RETURN/SUBCONTRACT_RECEIPT/SUBCONTRACT_RETURN/DIRECT_RECEIPT/DIRECT_PAYMENT';
COMMENT ON COLUMN ar_ap_ledger.source_doc_id IS '来源单据 id（跨模块，不建 FK；按 source_doc_type 分流 JOIN）';
COMMENT ON COLUMN ar_ap_ledger.source_doc_no IS '来源单号（跨模块查询用，契约 §四字段）';
COMMENT ON COLUMN ar_ap_ledger.bill_no IS '立帐单号（XC/XT/CJ/CT/EJ/XS/CF 前缀，migration = source_doc_no）';
COMMENT ON COLUMN ar_ap_ledger.amount_original IS '原额（原币，多币种场景）';
COMMENT ON COLUMN ar_ap_ledger.amount_original_local IS '原始金额（本币，退货为负；DIRECT_RECEIPT/PAYMENT 为 0）';
COMMENT ON COLUMN ar_ap_ledger.amount_settled IS '已核销金额（累加，本币；收款/付款审核时 Service 回写）';
COMMENT ON COLUMN ar_ap_ledger.amount_balance IS '未核销余额 = original_local − settled（Service 维护；预付款可负）';
COMMENT ON COLUMN ar_ap_ledger.is_settled IS '是否结清（balance ≤ 0 时 Service 置位，取代老库 TRI_GatheringCheck）';
COMMENT ON COLUMN ar_ap_ledger.settlement_type_id IS 'PStyle 结算方式 id（老库 B_PStyle 字典未 dump，暂不 FK）';
COMMENT ON COLUMN ar_ap_ledger.legacy_source IS '老库溯源表名（M_in/M_out，解 ID 冲突）';
COMMENT ON COLUMN ar_ap_ledger.legacy_id IS '老库 M_in.ID 或 M_out.ID（按 legacy_source 区分）';
COMMENT ON COLUMN ar_ap_ledger.legacy_bstyle IS '老库 BStyle int（3/18/20 应收侧，1/17/30/21 应付侧；保留校验）';


-- ====================== 销售收款 finance_receipts + finance_receipt_lines（核销 AR） ======================
-- 源老库：M_Get（主表 7,804 行）+ M_in 中 BStyle=20（DIRECT_RECEIPT 核销部分）。
-- 收款审核 → Service settleReceipt：核销 AR / 累加账户余额 / 写 finance_reconciliations / 自动结清。
CREATE TABLE finance_receipts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- M_Get.ID
    bill_no         TEXT NOT NULL,                     -- BillNo（XS 前缀 = 直接收款，XC 前缀走 SALES_SHIPMENT 立帐）
    bill_date       DATE NOT NULL,                     -- GetDate
    client_id       UUID REFERENCES clients(id),       -- ClientID
    account_id      UUID REFERENCES accounts(id),      -- RecAcc 收款账户
    counterpart_account_id UUID REFERENCES accounts(id),-- dfch 对方账户
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    amount_original NUMERIC(18,4) DEFAULT 0,           -- MTotal 原币总额
    amount_local    NUMERIC(18,4) DEFAULT 0,           -- Total 本币实收
    bank_fee        NUMERIC(18,4) DEFAULT 0,           -- slf 手续费
    other_fee       NUMERIC(18,4) DEFAULT 0,           -- qtfy 其它费用
    other_fee_style_id UUID REFERENCES payment_styles(id), -- qtfymc 其它费用项目
    receipt_method_id UUID,                            -- RecStyle 收款方式（暂不 FK，老库 RecStyle 独立字典未 dump）
    receipt_method_legacy_id INT,                      -- RecStyle 老库 int 暂留
    invoice_no      TEXT,                              -- InvoicesNo 发票号/支票号
    cancel_date     TIMESTAMPTZ,                       -- CancelDate 核销日期
    operator_id     UUID,                              -- WorkID 经手人（无 FK，迁移留空）
    maker_id        UUID,                              -- MakeID 制单（无 FK）
    approver_id     UUID,                              -- ApproverID 审批（无 FK）
    source_remark   TEXT,                              -- Source 来源备注
    remark          TEXT,
    status          SMALLINT NOT NULL DEFAULT 0,       -- 0草稿/1已审/-1红冲
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,    -- 结案（Service 派生）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

-- 收款核销明细（每行 = 一次核销一笔 AR；显式 applied_ledger_id 取代老库 M_in 累加推断）
CREATE TABLE finance_receipt_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                               -- M_in.ID（仅 DIRECT_RECEIPT 行有；运行时核销行新库独有，无 legacy）
    receipt_id      UUID NOT NULL REFERENCES finance_receipts(id) ON DELETE CASCADE,
    bill_no         TEXT NOT NULL,                     -- 冗余（查询裁剪 + 报表免 JOIN 主表）
    bill_date       DATE NOT NULL,                     -- 冗余（裁剪索引）
    applied_ledger_id UUID REFERENCES ar_ap_ledger(id),-- 核销的 AR 行（显式关联，取代 M_in.M_In 累加推断）
    applied_bill_no TEXT,                              -- SellID 老库核销立帐单号（XC*）
    client_id       UUID REFERENCES clients(id),
    line_no         INT,
    amount_original NUMERIC(18,4) NOT NULL,            -- NowReceive 本次收款（原币）
    amount_local    NUMERIC(18,4) NOT NULL,            -- CNReceive 本次核销（本币）
    exchange_diff   NUMERIC(18,4) DEFAULT 0,           -- RTotal 汇兑差
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_frt_bill_no     ON finance_receipts(bill_no);
CREATE INDEX idx_frt_date        ON finance_receipts(bill_date);
CREATE INDEX idx_frt_client      ON finance_receipts(client_id);
CREATE INDEX idx_frt_account     ON finance_receipts(account_id);
CREATE INDEX idx_frt_status      ON finance_receipts(status);
CREATE INDEX idx_frt_legacy      ON finance_receipts(legacy_id);
CREATE INDEX idx_frl_receipt     ON finance_receipt_lines(receipt_id);
CREATE INDEX idx_frl_applied     ON finance_receipt_lines(applied_ledger_id);
CREATE INDEX idx_frl_client      ON finance_receipt_lines(client_id);
CREATE INDEX idx_frl_date        ON finance_receipt_lines(bill_date);
CREATE INDEX idx_frl_legacy      ON finance_receipt_lines(legacy_id);


-- ====================== 采购付款 finance_payments + finance_payment_lines（核销 AP） ======================
-- 与 finance_receipts 完全对称（Client↔Vend、receipt↔payment、AR↔AP）。
-- 源老库：M_Paid（主表 4,545 行）+ M_out 中 BStyle=21（DIRECT_PAYMENT 核销部分）。
CREATE TABLE finance_payments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- M_Paid.ID
    bill_no         TEXT NOT NULL,                     -- BillNo（CF 前缀 = 直接付款）
    bill_date       DATE NOT NULL,                     -- PaidDate
    supplier_id     UUID REFERENCES suppliers(id),     -- VendID
    account_id      UUID REFERENCES accounts(id),      -- PaidAcc 付款账户
    counterpart_account_id UUID REFERENCES accounts(id),-- dfzh 对方账户
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    amount_original NUMERIC(18,4) DEFAULT 0,           -- MTotal 原币
    amount_local    NUMERIC(18,4) DEFAULT 0,           -- Total 本币
    payment_method_id UUID,                            -- PaidStyle 付款方式（暂不 FK）
    payment_method_legacy_id INT,                      -- PaidStyle 老库 int 暂留
    invoice_no      TEXT,                              -- InvoicesNo 发票号/支票号
    cancel_date     TIMESTAMPTZ,                       -- CancelDate 核销日期
    operator_name   TEXT,                              -- jsr 经手人姓名（老库文本，非 FK）
    operator_id     UUID,                              -- 运行时录入（UUID，无 FK）
    maker_id        UUID,                              -- MakeID 制单（无 FK）
    approver_id     UUID,                              -- ApproverID 审批（无 FK）
    source_remark   TEXT,
    remark          TEXT,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

-- 付款核销明细（每行 = 一次核销一笔 AP；显式 applied_ledger_id 取代老库 M_out 累加推断）
CREATE TABLE finance_payment_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                               -- M_out.ID（仅 DIRECT_PAYMENT 行）
    payment_id      UUID NOT NULL REFERENCES finance_payments(id) ON DELETE CASCADE,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    applied_ledger_id UUID REFERENCES ar_ap_ledger(id),-- 核销的 AP 行
    applied_bill_no TEXT,                              -- Purc_ID 老库核销立帐单号（CJ*/EJ*）
    supplier_id     UUID REFERENCES suppliers(id),
    line_no         INT,
    amount_original NUMERIC(18,4) NOT NULL,            -- NowPaid
    amount_local    NUMERIC(18,4) NOT NULL,            -- CNPaid
    exchange_diff   NUMERIC(18,4) DEFAULT 0,           -- RTotal 汇兑差
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_fpm_bill_no     ON finance_payments(bill_no);
CREATE INDEX idx_fpm_date        ON finance_payments(bill_date);
CREATE INDEX idx_fpm_supplier    ON finance_payments(supplier_id);
CREATE INDEX idx_fpm_account     ON finance_payments(account_id);
CREATE INDEX idx_fpm_status      ON finance_payments(status);
CREATE INDEX idx_fpm_legacy      ON finance_payments(legacy_id);
CREATE INDEX idx_fpl_payment     ON finance_payment_lines(payment_id);
CREATE INDEX idx_fpl_applied     ON finance_payment_lines(applied_ledger_id);
CREATE INDEX idx_fpl_supplier    ON finance_payment_lines(supplier_id);
CREATE INDEX idx_fpl_date        ON finance_payment_lines(bill_date);
CREATE INDEX idx_fpl_legacy      ON finance_payment_lines(legacy_id);


-- ====================== 一般费用 finance_expenses + finance_expense_items（按部门分摊） ======================
-- 源老库：M_DPaid（主表 1,125 行）+ M_DPaidItem（明细 8,537 行）。
-- 费用审核 → Service approveExpense：扣减账户余额 / 写 finance_reconciliations（不涉 AR/AP 核销）。
CREATE TABLE finance_expenses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- M_DPaid.ID
    bill_no         TEXT NOT NULL,                     -- BillNo（YF 前缀）
    bill_date       DATE NOT NULL,                     -- PaidDate
    account_id      UUID REFERENCES accounts(id),      -- PaidAcc 付款账户
    counterpart_account_id UUID REFERENCES accounts(id),-- dfzh 对方账户
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    amount_original NUMERIC(18,4) DEFAULT 0,           -- MTotal 原币
    amount_local    NUMERIC(18,4) DEFAULT 0,           -- Total 本币（老库样本 Total=0 只填 MTotal，存疑 design doc 26 §九-9）
    operator_id     UUID,                              -- WorkID 经手人（无 FK）
    maker_id        UUID,                              -- 制单（无 FK）
    approver_id     UUID,                              -- 审批（无 FK）
    remark          TEXT,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

-- 费用分摊明细（按 dept 分摊；StyleID→payment_styles(category=EXPENSE)）
CREATE TABLE finance_expense_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                               -- M_DPaidItem.ID
    expense_id      UUID NOT NULL REFERENCES finance_expenses(id) ON DELETE CASCADE,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    expense_style_id UUID REFERENCES payment_styles(id),-- StyleID 费用项目（办公费/差旅费/房租...）
    department_id   UUID REFERENCES departments(id),   -- DeptID 分摊部门
    counterpart_account_id UUID REFERENCES accounts(id),-- AccID 对方账户
    counterpart_name TEXT,                             -- dfmc 对方名称
    qty             NUMERIC(18,4),                     -- QTY
    price           NUMERIC(18,4),                     -- Price
    amount_original NUMERIC(18,4),                     -- CTotal 原币
    amount_local    NUMERIC(18,4),                     -- Total 本币
    summary         TEXT,                              -- Summary 摘要
    line_no         INT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_fexp_bill_no     ON finance_expenses(bill_no);
CREATE INDEX idx_fexp_date        ON finance_expenses(bill_date);
CREATE INDEX idx_fexp_account     ON finance_expenses(account_id);
CREATE INDEX idx_fexp_status      ON finance_expenses(status);
CREATE INDEX idx_fexp_legacy      ON finance_expenses(legacy_id);
CREATE INDEX idx_fexi_expense     ON finance_expense_items(expense_id);
CREATE INDEX idx_fexi_style       ON finance_expense_items(expense_style_id);
CREATE INDEX idx_fexi_dept        ON finance_expense_items(department_id);
CREATE INDEX idx_fexi_date        ON finance_expense_items(bill_date);
CREATE INDEX idx_fexi_legacy      ON finance_expense_items(legacy_id);


-- ====================== 其它收入 finance_other_incomes + finance_other_income_items ======================
-- 与 finance_expenses 对称（收入侧、account_id 取 RecAcc、QS 前缀）。
-- 源老库：M_OGet（主表 1,552 行）+ M_OGetItem（明细 1,551 行）。
CREATE TABLE finance_other_incomes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- M_OGet.ID
    bill_no         TEXT NOT NULL,                     -- BillNo（QS 前缀）
    bill_date       DATE NOT NULL,                     -- GetDate
    account_id      UUID REFERENCES accounts(id),      -- RecAcc 收款账户
    counterpart_account_id UUID REFERENCES accounts(id),-- dfzh 对方账户
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    amount_original NUMERIC(18,4) DEFAULT 0,           -- MTotal
    amount_local    NUMERIC(18,4) DEFAULT 0,           -- Total
    receipt_method_id UUID,                            -- RecStyle（暂不 FK）
    receipt_method_legacy_id INT,                      -- RecStyle 老库 int 暂留
    operator_id     UUID,
    maker_id        UUID, approver_id UUID,
    remark          TEXT,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

-- 收入分摊明细（StyleID→payment_styles(category=INCOME)）
CREATE TABLE finance_other_income_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                               -- M_OGetItem.ID
    income_id       UUID NOT NULL REFERENCES finance_other_incomes(id) ON DELETE CASCADE,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    income_style_id UUID REFERENCES payment_styles(id),-- StyleID 收入项目
    department_id   UUID REFERENCES departments(id),
    counterpart_account_id UUID REFERENCES accounts(id),
    counterpart_name TEXT,                             -- df 对方名称
    qty             NUMERIC(18,4), price NUMERIC(18,4),
    amount_original NUMERIC(18,4),                     -- CTotal
    amount_local    NUMERIC(18,4),                     -- Total
    summary         TEXT,
    line_no         INT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_foi_bill_no      ON finance_other_incomes(bill_no);
CREATE INDEX idx_foi_date         ON finance_other_incomes(bill_date);
CREATE INDEX idx_foi_account      ON finance_other_incomes(account_id);
CREATE INDEX idx_foi_status       ON finance_other_incomes(status);
CREATE INDEX idx_foi_legacy       ON finance_other_incomes(legacy_id);
CREATE INDEX idx_foii_income      ON finance_other_income_items(income_id);
CREATE INDEX idx_foii_style       ON finance_other_income_items(income_style_id);
CREATE INDEX idx_foii_dept        ON finance_other_income_items(department_id);
CREATE INDEX idx_foii_date        ON finance_other_income_items(bill_date);
CREATE INDEX idx_foii_legacy      ON finance_other_income_items(legacy_id);


-- ====================== 银行存取款 finance_bank_transfers + finance_bank_transfer_lines（空结构） ======================
-- 源老库：M_Bank（0 行）+ M_BankItem（0 行）。建 0 行结构保 Service 骨架（跨币种换算最复杂核销触发器之一）。
-- 审核逻辑（取代 TRI_BankItem）：游标多行存款账户，每个 in_account.receipts_total += amount × 跨币种汇率换算，
--   out_account.payments_total += amount，每账户写一行 finance_reconciliations(source='BANK_TRANSFER')。
CREATE TABLE finance_bank_transfers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- M_Bank.ID（老库 0 行）
    bill_no         TEXT NOT NULL,                     -- BillNo（YC 前缀推测）
    bill_date       DATE NOT NULL,
    out_account_id  UUID REFERENCES accounts(id),      -- OutAcc 取款账户
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    amount_original NUMERIC(18,4) DEFAULT 0,           -- Total
    amount_local    NUMERIC(18,4) DEFAULT 0,
    invoice_no      TEXT,                              -- InvoicesNo（关联支票号）
    operator_id     UUID,                              -- WorkID 经办人（无 FK）
    maker_id        UUID, approver_id UUID,
    remark          TEXT,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE finance_bank_transfer_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id     UUID NOT NULL REFERENCES finance_bank_transfers(id) ON DELETE CASCADE,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    in_account_id   UUID REFERENCES accounts(id),      -- AccID 存款账户
    occur_date      DATE,                              -- FDate 发生日期
    amount_original NUMERIC(18,4),                     -- CTotal（含跨币种换算 OCRate/CRate）
    amount_local    NUMERIC(18,4),                     -- Total
    line_no         INT,
    summary         TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_fbt_bill_no      ON finance_bank_transfers(bill_no);
CREATE INDEX idx_fbt_date         ON finance_bank_transfers(bill_date);
CREATE INDEX idx_fbt_out_account  ON finance_bank_transfers(out_account_id);
CREATE INDEX idx_fbt_status       ON finance_bank_transfers(status);
CREATE INDEX idx_fbt_legacy       ON finance_bank_transfers(legacy_id);
CREATE INDEX idx_fbtl_transfer    ON finance_bank_transfer_lines(transfer_id);
CREATE INDEX idx_fbtl_in_account  ON finance_bank_transfer_lines(in_account_id);
CREATE INDEX idx_fbtl_date        ON finance_bank_transfer_lines(bill_date);


-- ====================== 核销对账 / 账户流水 finance_reconciliations（迁 M_AllCheck 30,626 行） ======================
-- 老库 M_AllCheck 是账户统一流水帐（bank register），不分单据类型，每条 = 一次账户进/出动作。
-- 是报表 S 帐户进出流水帐和 Z 应收应付的核心来源。运行时由各 finance_*审核 Service 写入。
CREATE TABLE finance_reconciliations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                               -- M_AllCheck.ID
    bill_no         TEXT NOT NULL,                     -- 来源单号（冗余便于查询）
    source_doc_type TEXT NOT NULL,                     -- 替代 BStyle：RECEIPT/PAYMENT/EXPENSE/INCOME/BANK_TRANSFER
    source_doc_id   UUID,                              -- → finance_receipts/payments/expenses/other_incomes/bank_transfers.id（多态，不 FK）
    account_id      UUID REFERENCES accounts(id),      -- AccID 流水挂账户
    check_no        TEXT,                              -- CheckNo 支票号/发票号
    counterpart_name TEXT,                             -- Company 对方公司名（客户名/供应商名，迁移时 JOIN 拉取）
    in_amount       NUMERIC(18,4) DEFAULT 0,           -- InTotal 收入金额
    out_amount      NUMERIC(18,4) DEFAULT 0,           -- OutTotal 支出金额
    bill_date       TIMESTAMPTZ,                       -- BillDate 发生日期
    settled_date    TIMESTAMPTZ,                       -- OutDate 核销/支票核销日
    source_remark   TEXT,                              -- Source 来源备注
    remark          TEXT,
    legacy_bstyle   INT,                               -- 老库 BStyle（20/21/22/23/27，保留校验）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,

    -- source_doc_type 枚举约束（替代老库 BStyle，对应 5 类钱流单据）
    CONSTRAINT finance_reconciliations_source_doc_type_chk
        CHECK (source_doc_type IN ('RECEIPT','PAYMENT','EXPENSE','INCOME','BANK_TRANSFER'))
);

CREATE INDEX idx_frec_account    ON finance_reconciliations(account_id);
CREATE INDEX idx_frec_source     ON finance_reconciliations(source_doc_type, source_doc_id);
CREATE INDEX idx_frec_date       ON finance_reconciliations(bill_date);
CREATE INDEX idx_frec_bill_no    ON finance_reconciliations(bill_no);
CREATE INDEX idx_frec_legacy     ON finance_reconciliations(legacy_id);


-- ====================== 支票登记簿 finance_check_register（可选扩展，迁 M_Check 空结构） ======================
-- 老库 M_Check 0 行（触发器维护），建 0 行结构保 Service 骨架。
-- 运行时 Service：收/付款审核带 invoice_no（支票号）时自动 INSERT 一行（source='收'/'付'）。
-- 前端"支票管理(A)/外来支票(G)"报表 = 按 accounts.account_type IN (CHECK, FOREIGN_CHECK) 过滤的收付款流水 + 登记簿视图。
CREATE TABLE finance_check_register (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                               -- M_Check.ID（老库 0 行）
    check_no        TEXT NOT NULL,                     -- CheckNo 支票号
    amount          NUMERIC(18,4) DEFAULT 0,           -- Total
    account_id      UUID REFERENCES accounts(id),      -- AccID 银行账户
    source          TEXT,                              -- Source '收'/'付' 收/付方向
    status          TEXT,                              -- Status '已用'/'未用'
    issue_date      TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_fcr_check_no ON finance_check_register(check_no);
CREATE INDEX idx_fcr_account  ON finance_check_register(account_id);


-- ====================== 表注释 ======================
COMMENT ON TABLE  finance_receipts           IS '销售收款单主表（钱流管理），源 M_Get；审核→核销 AR / 累加账户余额 / 写流水';
COMMENT ON TABLE  finance_receipt_lines      IS '销售收款核销明细，源 M_in(核销部分)；applied_ledger_id→ar_ap_ledger 显式核销关联';
COMMENT ON TABLE  finance_payments           IS '采购付款单主表（钱流管理），源 M_Paid；审核→核销 AP / 扣减账户余额 / 写流水';
COMMENT ON TABLE  finance_payment_lines      IS '采购付款核销明细，源 M_out(核销部分)；applied_ledger_id→ar_ap_ledger 显式核销关联';
COMMENT ON TABLE  finance_expenses           IS '一般费用单主表（钱流管理），源 M_DPaid；审核→扣减账户余额 / 写流水（不涉 AR/AP）';
COMMENT ON TABLE  finance_expense_items      IS '一般费用明细分摊，源 M_DPaidItem；按 department_id 分摊，expense_style_id→payment_styles(EXPENSE)';
COMMENT ON TABLE  finance_other_incomes      IS '其它收入单主表（钱流管理），源 M_OGet；审核→累加账户余额 / 写流水';
COMMENT ON TABLE  finance_other_income_items IS '其它收入明细分摊，源 M_OGetItem；income_style_id→payment_styles(INCOME)';
COMMENT ON TABLE  finance_bank_transfers     IS '银行存取款单主表（钱流管理），源 M_Bank（0 行空结构）；保跨币种换算 Service 骨架';
COMMENT ON TABLE  finance_bank_transfer_lines IS '银行存取款明细，源 M_BankItem（0 行空结构）；每行=一个存款账户的存入';
COMMENT ON TABLE  finance_reconciliations    IS '账户统一流水帐（钱流管理），源 M_AllCheck（30,626 行）；不分单据类型，每条=一次账户进/出';
COMMENT ON TABLE  finance_check_register     IS '支票登记簿（钱流管理，可选扩展），源 M_Check（0 行空结构）；运行时由收/付款审核带支票号触发';


-- ====================== 权限点（双 category：钱流管理 500-579 / 钱流报表 580-599，挂 DEPT_FIN） ======================
-- 27-DDL一致性契约 §五：钱流 sort_order 段 500–579（单据 view+edit）/ 580–599（报表 view）；edit 挂 DEPT_FIN。
-- ar_ap_ledger/finance_reconciliations 是跨模块/Service 派生的台账与流水，用户只读 → 仅 :view，无 :edit。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    -- 钱流管理（单据类 500-579）
    ('ar_ap_ledger:view',          '查看应收应付',   '钱流管理', 500),
    ('finance_receipt:view',       '查看销售收款',   '钱流管理', 510),
    ('finance_receipt:edit',       '维护销售收款',   '钱流管理', 511),
    ('finance_payment:view',       '查看采购付款',   '钱流管理', 520),
    ('finance_payment:edit',       '维护采购付款',   '钱流管理', 521),
    ('finance_expense:view',       '查看一般费用',   '钱流管理', 530),
    ('finance_expense:edit',       '维护一般费用',   '钱流管理', 531),
    ('finance_other_income:view',  '查看其它收入',   '钱流管理', 540),
    ('finance_other_income:edit',  '维护其它收入',   '钱流管理', 541),
    ('finance_bank_transfer:view', '查看银行存取',   '钱流管理', 550),
    ('finance_bank_transfer:edit', '维护银行存取',   '钱流管理', 551),
    ('finance_reconciliation:view','查看账户流水',   '钱流管理', 560),
    ('finance_check_register:view','查看支票登记簿', '钱流管理', 570),
    ('finance_check_register:edit','维护支票登记簿', '钱流管理', 571),
    -- 钱流报表（580-599）
    ('finance_report:view',        '查看钱流报表',   '钱流报表', 580)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（钱流数据内部可见；超管恒有全权限，无需 seed）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code IN ('ar_ap_ledger:view','finance_receipt:view','finance_payment:view',
                 'finance_expense:view','finance_other_income:view',
                 'finance_bank_transfer:view','finance_reconciliation:view',
                 'finance_check_register:view','finance_report:view')
  AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给财税部（钱流单据操作归财务）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_FIN'
  AND p.code IN ('finance_receipt:edit','finance_payment:edit','finance_expense:edit',
                 'finance_other_income:edit','finance_bank_transfer:edit',
                 'finance_check_register:edit')
ON CONFLICT DO NOTHING;
