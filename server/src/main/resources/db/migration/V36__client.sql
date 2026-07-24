-- =====================================================================
-- V36：客户主档 clients（基础资料 · 客户资料 → 具体客户）
-- =====================================================================
-- 来源：老库 B_Client（260 条），B_Client.ParentID → SystemItem.ItemID
--   （ItemclassID=2 客户分类），由 migrate.sh 的 client-data 步骤迁移灌入。
-- 字段：B_Client 全 34 字段逐字照搬（除 ID→legacy_id、ParentID→category_id 外）。
--   * legacy_id = B_Client.ID，迁移溯源 + 重跑幂等。
--   * category_id 源自 B_Client.ParentID→SystemItem.ItemID（ItemclassID=2）。
--   * 6 条 ParentID=0（未分组客户）→ category_id 置 NULL（前端"全部客户"视图可见）。
-- 语义说明（老库字段名起清晰列名）：
--   * Client_Name→name、Number→code、Full_Name→full_name、Client_Rank→client_rank。
--   * Juri_Per→legal_person(法人)、Link_Man→linkman、Link_Addr→address、Post→postcode。
--   * Client_Bank→bank、Client_BankNo→bank_account、Http→website、Shipvia→ship_via、
--     Ship_Addr→ship_address、QYName→region(区域文本如 外贸/内销南区)、ClientXZ→client_xz(性质)。
--   * Credit→credit(信用额度)、InitTotal/InitTotal2→init_total/init_total2(期初应收)、
--     CRate→exchange_rate(疑似汇率)、TDay→tday(结算天数)、PStyle→price_style、ZJID→zj_id(含义待确认)。
--   * Status→status(使用/禁用)、Remark→remark。PlaceID→place_id(地区文本如"四川省")、Emp_ID→emp_id(业务员 legacy id 文本)。
-- 详见 docs/数据迁移/07-客户资料-新库与迁移.md。
-- =====================================================================

CREATE TABLE clients (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Client.ID
    category_id     UUID REFERENCES client_categories(id) ON DELETE RESTRICT,  -- B_Client.ParentID → 客户分类

    -- 标识 / 名称
    name            TEXT,                              -- Client_Name（客户名称）
    code            TEXT,                              -- Number（客户编号，如 WM001 / 川0002）
    full_name       TEXT,                              -- Full_Name（全称）
    client_rank     TEXT,                              -- Client_Rank（等级）

    -- 联系
    place_id        TEXT,                              -- PlaceID（地区文本，如"四川省"）
    emp_id          TEXT,                              -- Emp_ID（业务员 legacy id，文本保原值）
    legal_person    TEXT,                              -- Juri_Per（法人）
    linkman         TEXT,                              -- Link_Man（联系人）
    mobile          TEXT,                              -- Mobile
    phone           TEXT,                              -- Phone
    phone2          TEXT,                              -- Phone2
    fax             TEXT,                              -- Fax
    postcode        TEXT,                              -- Post（邮编）
    address         TEXT,                              -- Link_Addr（地址）
    email           TEXT,                              -- Email
    website         TEXT,                              -- Http（网址）

    -- 收货
    ship_via        TEXT,                              -- Shipvia（运输方式）
    ship_address    TEXT,                              -- Ship_Addr（收货地址）

    -- 银行 / 税务
    bank            TEXT,                              -- Client_Bank（开户行）
    bank_account    TEXT,                              -- Client_BankNo（银行账号）
    tax_id          TEXT,                              -- Tax_ID（税号）

    -- 财务
    credit          NUMERIC(18,4),                     -- Credit（信用额度）
    init_total      NUMERIC(18,4),                     -- InitTotal（期初应收）
    init_total2     NUMERIC(18,4),                     -- InitTotal2（期初应收2）
    exchange_rate   NUMERIC(18,6),                     -- CRate（疑似汇率，含义待确认）
    tday            INT,                               -- TDay（结算天数）
    price_style     INT,                               -- PStyle（价格样式）
    zj_id           INT,                               -- ZJID（含义待确认，样本 545/546）

    -- 分类 / 性质（文本冗余：与 ParentID 分组并存的另一种业务表达）
    region          TEXT,                              -- QYName（区域，如 外贸/内销南区/OEM）
    client_xz       TEXT,                              -- ClientXZ（客户性质）

    -- 状态 / 备注
    status          TEXT,                              -- Status（使用/禁用）
    remark          TEXT,                              -- Remark（备注）

    -- 审计 + 软删
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_clients_category    ON clients(category_id);
CREATE INDEX idx_clients_legacy_id   ON clients(legacy_id);
CREATE INDEX idx_clients_code        ON clients(code);
CREATE INDEX idx_clients_status      ON clients(status);

COMMENT ON TABLE  clients IS '客户主档（基础资料-客户资料），老库 B_Client 全字段迁移';
COMMENT ON COLUMN clients.legacy_id     IS '老库 B_Client.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN clients.category_id   IS '所属客户分类（client_categories.id，源自 B_Client.ParentID→SystemItem.ItemID ItemclassID=2；6 条未分组为 NULL）';
COMMENT ON COLUMN clients.status        IS '生命周期（源 B_Client.Status：使用/禁用）';
COMMENT ON COLUMN clients.region        IS '区域文本（源 B_Client.QYName，如 外贸/内销南区/OEM；与 ParentID 分组冗余）';

-- 权限点（查看/维护客户，category「主数据」，sort_order 接 client_category 之后）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('client:view', '查看客户', '主数据', 42),
    ('client:edit', '维护客户', '主数据', 43)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'client:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给综合营销部（客户由销售口维护；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_SALES' AND p.code = 'client:edit'
ON CONFLICT DO NOTHING;
