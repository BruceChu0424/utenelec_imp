-- =====================================================================
-- V50：钱流基础资料主档（账户 accounts + 收付款类别 payment_styles）
-- =====================================================================
-- 归属：钱流模块 V50（基础资料 · 账户/收付款类别，全公司共用基础资料）。
--   * accounts 扁平主档（对齐 V42 currency 风格）—— 老库 M_Acc（27 行）。
--   * payment_styles 邻接表+物化路径树（对齐 V31 material_categories 范式）—— 老库 M_Style（124 节点混合树）。
--
-- 老库 → 新库 链路：
--   M_Acc (27)     → accounts        扁平账户主档（account_type 枚举重建，AStyle 退化丢弃）
--   M_Style (124)  → payment_styles  收付款类别混合树（StyleClassid→category 五大根 + METHOD 备用）
--
-- account_type 重建规则（AStyle 全为 1，类型靠 AccName 字符串识别）：
--   农行/工行/建行/招商/交通/邮政/信用社/工商牡丹/兴业/中国/广发/基本户/一般帐户 → BANK
--   现金                                                                  → CASH
--   支票（本公司，Status=禁用）                                             → CHECK
--   支票（外来，Status=使用）                                              → FOREIGN_CHECK
--   微信/支付宝                                                           → THIRD_PARTY
--   香港公司帐号                                                          → OFFSHORE
--   一般帐户（未指明银行，区别 BANK）                                       → GENERAL
--   迁移时 CASE WHEN 关键字映射；运行时录账户由前端枚举下拉。
--
-- 状态机：账户/类别无单据状态机，仅 status 文本（使用/禁用，贴老库语义）。
--   账户余额 balance_current = init_balance + receipts_total − payments_total
--   （Service 维护，取代老库 M_Acc 触发器；详见 design doc 26 §五 Service 层断言）。
--
-- 详见 docs/数据迁移/26-钱流管理-新库与迁移.md §三（accounts §3.1、payment_styles §3.2）。
-- 详见 docs/数据迁移/27-DDL一致性契约.md §一文件归属、§二通用约定、§五权限 seed 规则、§八自检。
-- =====================================================================


-- ====================== 账户主档 accounts（扁平，对齐 V42 currency） ======================
CREATE TABLE accounts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- M_Acc.ID（迁移溯源+重跑幂等）
    code            TEXT,                              -- Number（001~009 / UT00101 含币种前缀）
    name            TEXT NOT NULL,                     -- AccName（农业银行/现金/微信/支票/基本户...）
    bank_account_no TEXT,                              -- AccNode（银行账号尾号，仅基本户填）
    account_type    TEXT NOT NULL DEFAULT 'BANK',      -- 枚举见下方 CHECK 约束（取代退化字段 AStyle）
    currency_id     UUID REFERENCES currencies(id),    -- 币种（多币种账户：香港=USD，其它=RMB）
    init_balance    NUMERIC(18,4) NOT NULL DEFAULT 0,  -- InitTotal（期初金额）
    receipts_total  NUMERIC(18,4) NOT NULL DEFAULT 0,  -- GetTotal（收入累计，Service 维护）
    payments_total  NUMERIC(18,4) NOT NULL DEFAULT 0,  -- PaidTotal（支出累计，Service 维护）
    balance_current NUMERIC(18,4) NOT NULL DEFAULT 0,  -- FactTotal = init + receipts − payments（冗余，Service 维护）
    parent_legacy_id INT,                              -- M_Acc.ParentID（→SystemItem，保留 legacy 不 FK）
    style_legacy_id INT,                               -- M_Acc.StyleID（→M_Style.ID，账户类叶节点）
    status          TEXT NOT NULL DEFAULT '使用',      -- Status（使用/禁用）
    auto_created    BOOLEAN NOT NULL DEFAULT FALSE,    -- 单据迁移/运行时自动补录标记

    -- 审计 + 软删（与 currencies/warehouses 同构）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ,

    -- account_type 枚举约束（AStyle 退化，运行时由前端枚举下拉选择）
    CONSTRAINT accounts_account_type_chk
        CHECK (account_type IN ('BANK','CASH','CHECK','FOREIGN_CHECK','THIRD_PARTY','OFFSHORE','GENERAL'))
);

CREATE INDEX idx_accounts_legacy_id ON accounts(legacy_id);
CREATE INDEX idx_accounts_code      ON accounts(code);
CREATE INDEX idx_accounts_type      ON accounts(account_type);
CREATE INDEX idx_accounts_status    ON accounts(status);
CREATE INDEX idx_accounts_currency  ON accounts(currency_id);

COMMENT ON TABLE  accounts IS '账户主档（基础资料-账户资料），老库 M_Acc 迁移；account_type 枚举重建（AStyle 退化）';
COMMENT ON COLUMN accounts.legacy_id IS '老库 M_Acc.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN accounts.code IS '账户编号（源 M_Acc.Number：001~009 / UT00101 含币种前缀）';
COMMENT ON COLUMN accounts.name IS '账户名称（源 M_Acc.AccName：农业银行/现金/微信/支票/基本户...）';
COMMENT ON COLUMN accounts.bank_account_no IS '银行账号尾号（源 M_Acc.AccNode，仅基本户填）';
COMMENT ON COLUMN accounts.account_type IS '账户类型枚举（取代老库 M_Acc.AStyle 退化字段，运行时由前端枚举下拉）';
COMMENT ON COLUMN accounts.currency_id IS '币种（多币种账户：香港=USD，其它=RMB）';
COMMENT ON COLUMN accounts.init_balance IS '期初金额（源 M_Acc.InitTotal，仅基本户/现金有非零值）';
COMMENT ON COLUMN accounts.receipts_total IS '收入累计（源 M_Acc.GetTotal，Service 累加）';
COMMENT ON COLUMN accounts.payments_total IS '支出累计（源 M_Acc.PaidTotal，Service 累加）';
COMMENT ON COLUMN accounts.balance_current IS '当前余额 = init + receipts − payments（冗余，源 M_Acc.FactTotal，Service 维护）';
COMMENT ON COLUMN accounts.parent_legacy_id IS '老库父节点 ID（M_Acc.ParentID→SystemItem，保留 legacy 不 FK）';
COMMENT ON COLUMN accounts.style_legacy_id IS '老库字典叶节点 ID（M_Acc.StyleID→M_Style.ID，账户类叶节点）';
COMMENT ON COLUMN accounts.auto_created IS '是否单据迁移/运行时自动补录（事后人工补全）';


-- ====================== 收付款类别 payment_styles（树，对齐 V31 material_categories） ======================
-- 邻接表(parent_id) + 物化路径(path,触发器自动维护) + level/sort_order + 软删除 + 审计。
-- 老库 M_Style 124 节点混合树，按 category 分根（由 StyleClassid 映射）：
--   1→ACCOUNT（账户类叶节点，挂 accounts） / 2→LIABILITY（应付科目） / 3→EQUITY（资本）
--   4→EXPENSE（费用项目，被 finance_expense_items 引用） / 5→INCOME（收入项目，被 finance_other_income_items 引用）
--   另预留 METHOD（结算方式，老库 RecStyle/PaidStyle 独立字典未 dump，存疑 design doc 26 §九-5）
CREATE TABLE payment_styles (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id    INT  UNIQUE,                          -- M_Style.ID
    code         TEXT NOT NULL,                        -- StyleNumber（101/102/041/031...，可能重复，定位用 id）
    name         TEXT NOT NULL,                        -- StyleName（现金/银行存款/办公费用/销售收入...）
    category     TEXT NOT NULL,                        -- ACCOUNT/LIABILITY/EQUITY/EXPENSE/INCOME/METHOD（由 StyleClassid 映射）
    parent_id    UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    level        INT  NOT NULL DEFAULT 0,              -- 真实深度（根=0），迁移按 parent 链重算
    sort_order   INT  NOT NULL DEFAULT 0,              -- 由 NextNumber 转换（同级排序 + 编号生成辅助）
    path         TEXT NOT NULL DEFAULT '/',            -- 物化路径（触发器维护）
    is_departmental BOOLEAN NOT NULL DEFAULT FALSE,    -- DeptStatus（部门级核算标志，一般费用/其它收入按部门分摊用）
    is_receipt   BOOLEAN NOT NULL DEFAULT FALSE,       -- OrientStatus1（收方向）
    is_payment   BOOLEAN NOT NULL DEFAULT FALSE,       -- OrientStatus2（付方向）
    linked_account_legacy_id INT,                      -- ItemID（账户类叶节点→M_Acc.ID，仅 ACCOUNT 类有值）
    init_balance NUMERIC(18,4),                        -- InitTotal（仅账户类叶节点有意义）
    status       TEXT NOT NULL DEFAULT '使用',
    auto_created BOOLEAN NOT NULL DEFAULT FALSE,

    -- 审计 + 软删（与 material_categories 同构）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ,

    -- category 枚举约束（覆盖老库 StyleClassid 1-5 + METHODS 备用）
    CONSTRAINT payment_styles_category_chk
        CHECK (category IN ('ACCOUNT','LIABILITY','EQUITY','EXPENSE','INCOME','METHOD'))
);

CREATE INDEX idx_ps_parent      ON payment_styles(parent_id);
CREATE INDEX idx_ps_parent_sort ON payment_styles(parent_id, sort_order);
CREATE INDEX idx_ps_path        ON payment_styles(path text_ops);
CREATE INDEX idx_ps_category    ON payment_styles(category);
CREATE INDEX idx_ps_legacy_id   ON payment_styles(legacy_id);

COMMENT ON TABLE  payment_styles IS '收付款类别混合树（基础资料-收付款类别），老库 M_Style 迁移；邻接表+物化路径（同 material_categories）';
COMMENT ON COLUMN payment_styles.legacy_id IS '老库 M_Style.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN payment_styles.code IS '类别编号（源 M_Style.StyleNumber：101/102/041/031...，可能重复，定位用 id）';
COMMENT ON COLUMN payment_styles.name IS '类别名称（源 M_Style.StyleName：现金/银行存款/办公费用/销售收入...）';
COMMENT ON COLUMN payment_styles.category IS '大类（由 StyleClassid 映射）：ACCOUNT/LIABILITY/EQUITY/EXPENSE/INCOME/METHOD';
COMMENT ON COLUMN payment_styles.parent_id IS '父节点（邻接表；根节点为 NULL）';
COMMENT ON COLUMN payment_styles.level IS '真实深度（根=0），由迁移按 parent 链重算（老库 SystemItem.Level 不可靠）';
COMMENT ON COLUMN payment_styles.path IS '物化路径（触发器维护）：path = 父path || code || /，根节点 /code/';
COMMENT ON COLUMN payment_styles.is_departmental IS '是否部门级核算（源 M_Style.DeptStatus，一般费用/其它收入按部门分摊时用）';
COMMENT ON COLUMN payment_styles.is_receipt IS '收方向标志（源 M_Style.OrientStatus1）';
COMMENT ON COLUMN payment_styles.is_payment IS '付方向标志（源 M_Style.OrientStatus2）';
COMMENT ON COLUMN payment_styles.linked_account_legacy_id IS '账户类叶节点关联的账户 legacy id（源 M_Style.ItemID→M_Acc.ID，仅 ACCOUNT 类有值）';
COMMENT ON COLUMN payment_styles.init_balance IS '期初金额（源 M_Style.InitTotal，仅账户类叶节点有意义）';

-- path 自动维护触发器（与 V31 fn_matcat_path 同构）
-- path = 父path || code || '/'（根节点 '/code/'）；code 可能重复 → path 不要求唯一；排序用 (path, sort_order)。
CREATE OR REPLACE FUNCTION fn_payment_style_path() RETURNS TRIGGER AS $$
DECLARE v_parent_path TEXT;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.path := '/' || NEW.code || '/';
    ELSE
        SELECT path INTO v_parent_path FROM payment_styles WHERE id = NEW.parent_id;
        NEW.path := COALESCE(v_parent_path, '/') || NEW.code || '/';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_style_path
    BEFORE INSERT OR UPDATE OF parent_id, code ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_payment_style_path();


-- ====================== 权限点（基础资料，edit 挂 DEPT_FIN） ======================
-- 账户/收付款类别归「基础资料」category，sort_order 接仓库 90/91 之后（与 design doc 26 §3.1/§3.2 一致）。
-- view 给全员（基础资料全员可查）；edit 挂财税部 DEPT_FIN（账户/收付款类别归财务口维护）。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('account:view',        '查看账户',       '基础资料', 100),
    ('account:edit',        '维护账户',       '基础资料', 101),
    ('payment_style:view',  '查看收付款类别', '基础资料', 110),
    ('payment_style:edit',  '维护收付款类别', '基础资料', 111)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code IN ('account:view','payment_style:view') AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给财税部（账户/收付款类别归财务口维护；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_FIN'
  AND p.code IN ('account:edit','payment_style:edit')
ON CONFLICT DO NOTHING;
