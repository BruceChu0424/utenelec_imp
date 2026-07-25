-- =====================================================================
-- V42：币种主档 currencies（基础资料 · 币种资料）
-- =====================================================================
-- 来源：老库 B_Currency（3 条：人民币/美金/港币），由 migrate.sh --currency-data 迁移。
-- 老库 B_Currency 实测为扁平表（ParentID 全 0），无分类树。
-- 字段映射：B_Currency.ID→legacy_id、Number→code、CurName→name、ExRate→exchange_rate、Status→status。
--   * exchange_rate 老库 ExRate 多为 0（实际汇率记在采购单据 CRate 上），本列作"参考汇率"保留。
--   * 确有进口/出口采购（美金/港币），采购订货/收货/退货主表 currency_id 引用本表。
--   * auto_created：单据迁移/运行时自动补录标记（默认 false，见 15 号文档 §3.3）。
-- 详见 docs/数据迁移/15-采购模块-新库与迁移.md §3.1。
-- =====================================================================

CREATE TABLE currencies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Currency.ID
    code            TEXT,                              -- Number（001/002/003）
    name            TEXT,                              -- CurName（人民币/美金/港币）
    exchange_rate   NUMERIC(18,6) DEFAULT 1,           -- ExRate（参考汇率；实际以单据 exchange_rate 为准）
    status          TEXT,                              -- Status（使用/禁用）
    auto_created    BOOLEAN NOT NULL DEFAULT FALSE,    -- 单据迁移/运行时自动补录标记

    -- 审计 + 软删（与 colors/units 同构）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_currencies_legacy_id ON currencies(legacy_id);
CREATE INDEX idx_currencies_code      ON currencies(code);
CREATE INDEX idx_currencies_status    ON currencies(status);

COMMENT ON TABLE  currencies IS '币种主档（基础资料-币种资料），老库 B_Currency 迁移（扁平表，无分类树）';
COMMENT ON COLUMN currencies.legacy_id IS '老库 B_Currency.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN currencies.code IS '币种编号（源 B_Currency.Number：001/002/003）';
COMMENT ON COLUMN currencies.name IS '币种名称（源 B_Currency.CurName：人民币/美金/港币）';
COMMENT ON COLUMN currencies.exchange_rate IS '参考汇率（源 B_Currency.ExRate；实际汇率以单据 exchange_rate 为准）';
COMMENT ON COLUMN currencies.auto_created IS '是否单据迁移/运行时自动补录（事后人工补全）';

-- 权限点（查看/维护币种，category「主数据」，sort_order 接单位 70/71 之后）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('currency:view', '查看币种', '主数据', 80),
    ('currency:edit', '维护币种', '主数据', 81)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'currency:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（基础主数据归仓储/采购口维护，同货品/供应商/颜色/单位；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'currency:edit'
ON CONFLICT DO NOTHING;
