-- =====================================================================
-- V38：供应商主档 suppliers（基础资料 · 供应商资料 → 具体供应商）
-- =====================================================================
-- 来源：老库 B_Provider（386 条），B_Provider.ParentID → SystemItem.ItemID
--   （ItemclassID=3 供应商分类），由 migrate.sh 的 supplier-data 步骤迁移灌入。
-- 字段：B_Provider 全 29 字段逐字照搬（除 ID→legacy_id、ParentID→category_id 外）。
--   * legacy_id = B_Provider.ID，迁移溯源 + 重跑幂等。
--   * category_id 源自 B_Provider.ParentID→SystemItem.ItemID（ItemclassID=3）。
--   * 老库 386 条全部已分组（无 ParentID=0），故 category_id 无 NULL。
-- 语义说明（老库字段名起清晰列名）：
--   * Vend_Name→name、Number→code、Vend_Desc→description(避保留字 desc)、Vend_Place→place。
--   * Juri_Per→legal_person(法人)、Link_Man→linkman、Link_Addr→address、Post→postcode。
--   * Vend_Bank→bank、Vend_BankNo→bank_account、Http→website、Shipvia→ship_via、Ship_Addr→ship_address。
--   * InitTotal/InitTotal2→init_total/init_total2(期初应付)、CRate→exchange_rate(疑似汇率)、
--     TDay→tday(结算天数)、PStyle→price_style。Status→status(使用/禁用)、Remark→remark。
--   * Emp_ID→emp_id(业务员 legacy id 文本)、Tax_ID→tax_id。
-- 详见 docs/数据迁移/09-供应商资料-新库与迁移.md。
-- =====================================================================

CREATE TABLE suppliers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Provider.ID
    category_id     UUID REFERENCES supplier_categories(id) ON DELETE RESTRICT,  -- B_Provider.ParentID → 供应商分类

    -- 标识 / 名称
    name            TEXT,                              -- Vend_Name（供应商名称，如 洪武）
    code            TEXT,                              -- Number（编号，如 WJ0001 / SL0003）
    description     TEXT,                              -- Vend_Desc（描述/全称，避保留字 desc）
    place           TEXT,                              -- Vend_Place（地区）

    -- 联系
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
    bank            TEXT,                              -- Vend_Bank（开户行）
    bank_account    TEXT,                              -- Vend_BankNo（银行账号）
    tax_id          TEXT,                              -- Tax_ID（税号）

    -- 财务
    init_total      NUMERIC(18,4),                     -- InitTotal（期初应付）
    init_total2     NUMERIC(18,4),                     -- InitTotal2（期初应付2）
    exchange_rate   NUMERIC(18,6),                     -- CRate（疑似汇率，含义待确认）
    tday            INT,                               -- TDay（结算天数）
    price_style     INT,                               -- PStyle（价格样式）

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

CREATE INDEX idx_suppliers_category    ON suppliers(category_id);
CREATE INDEX idx_suppliers_legacy_id   ON suppliers(legacy_id);
CREATE INDEX idx_suppliers_code        ON suppliers(code);
CREATE INDEX idx_suppliers_status      ON suppliers(status);

COMMENT ON TABLE  suppliers IS '供应商主档（基础资料-供应商资料），老库 B_Provider 全字段迁移';
COMMENT ON COLUMN suppliers.legacy_id   IS '老库 B_Provider.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN suppliers.category_id IS '所属供应商分类（supplier_categories.id，源自 B_Provider.ParentID→SystemItem.ItemID ItemclassID=3）';
COMMENT ON COLUMN suppliers.status      IS '生命周期（源 B_Provider.Status：使用/禁用）';

-- 权限点（查看/维护供应商，category「主数据」，sort_order 接 supplier_category 之后）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('supplier:view', '查看供应商', '主数据', 52),
    ('supplier:edit', '维护供应商', '主数据', 53)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'supplier:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（供应商由仓储/采购口维护，同货品；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'supplier:edit'
ON CONFLICT DO NOTHING;
