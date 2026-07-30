-- =====================================================================
-- V43：仓库主档 warehouses（基础资料 · 仓库资料）
-- =====================================================================
-- 来源：老库 B_Storage（6 条：成品仓/五金仓/原材料不良仓/轨道车间...），migrate.sh --warehouse-data 迁移。
-- 老库 B_Storage 扁平表（ParentID 全 0），无分类树。
-- 字段映射：B_Storage.ID→legacy_id、Number→code、Storage_Name→name、Location→location、
--   Remark→remark、IsCal→is_accountable（是否参与核算）、WorkID→workshop_legacy_id（车间 legacy，暂不 FK）、Status→status。
--   * auto_created：单据迁移/运行时自动补录标记（默认 false，见 15 号文档 §3.3）。
-- 采购收货/退货单据 warehouse_id 引用本表；库存 stock_movements/balances 亦按仓库维度记账。
-- 详见 docs/数据迁移/15-采购模块-新库与迁移.md §3.2。
-- =====================================================================

CREATE TABLE warehouses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Storage.ID
    code            TEXT,                              -- Number（C01/C04...）
    name            TEXT,                              -- Storage_Name（成品仓库/五金仓库...）
    location        TEXT,                              -- Location（总仓库/轨道仓...）
    remark          TEXT,                              -- Remark
    is_accountable  BOOLEAN NOT NULL DEFAULT TRUE,     -- IsCal（是否参与库存核算）
    workshop_legacy_id INT,                            -- WorkID（所属车间 legacy，暂不建 FK）
    status          TEXT,                              -- Status（使用/禁用）
    auto_created    BOOLEAN NOT NULL DEFAULT FALSE,    -- 单据迁移/运行时自动补录标记

    -- 审计 + 软删（与 colors/units/currencies 同构）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_warehouses_legacy_id ON warehouses(legacy_id);
CREATE INDEX idx_warehouses_code      ON warehouses(code);
CREATE INDEX idx_warehouses_status    ON warehouses(status);

COMMENT ON TABLE  warehouses IS '仓库主档（基础资料-仓库资料），老库 B_Storage 迁移（扁平表，无分类树）';
COMMENT ON COLUMN warehouses.legacy_id IS '老库 B_Storage.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN warehouses.code IS '仓库编号（源 B_Storage.Number：C01/C04...）';
COMMENT ON COLUMN warehouses.name IS '仓库名称（源 B_Storage.Storage_Name）';
COMMENT ON COLUMN warehouses.location IS '仓库位置（源 B_Storage.Location）';
COMMENT ON COLUMN warehouses.is_accountable IS '是否参与库存核算（源 B_Storage.IsCal）';
COMMENT ON COLUMN warehouses.workshop_legacy_id IS '所属车间 legacy id（源 B_Storage.WorkID，暂不建 FK）';
COMMENT ON COLUMN warehouses.auto_created IS '是否单据迁移/运行时自动补录（事后人工补全）';

-- 权限点（查看/维护仓库，category「主数据」，sort_order 接币种 80/81 之后）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('warehouse:view', '查看仓库', '主数据', 90),
    ('warehouse:edit', '维护仓库', '主数据', 91)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'warehouse:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（仓库归仓储/采购口维护，同货品/供应商/颜色/单位/币种；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'warehouse:edit'
ON CONFLICT DO NOTHING;
