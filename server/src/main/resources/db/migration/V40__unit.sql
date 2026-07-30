-- =====================================================================
-- V40：基本单位主档 units（基础资料 · 基本单位 → 具体单位）
-- =====================================================================
-- 来源：老库 B_Unit（66 条），由 migrate.sh 的 --unit-data 步骤迁移灌入。
-- 老库 B_Unit 与 B_Color 同构（ID/Unit_Name/Number/ParentID/Status），同样实测为扁平表
--   （ParentID 全 0），故本表无分类树。
-- 字段映射：B_Unit.ID→legacy_id、Number→code、Unit_Name→name、Status→status。
--   * name（老库 Unit_Name）有前导空白（" 套"）、1 条空串，及若干噪音条目（"1"/"0.1" 换算系数、
--     "单联单控开关7" 等非单位污染）；迁移时 trim 首尾空白，其余原样保留（保证货品
--     unit_legacy_id 引用不悬空，噪音行用户可在 UI 禁用/删除）。
--   * status 老库全为 使用(66)，无 禁用；列保留 使用/禁用 双值供后续维护。
-- 货品 goods.unit_legacy_id 即指向本表 legacy_id（task：货品单位名称解析据此 LEFT JOIN）。
-- 详见 docs/数据迁移/13-基本单位-新库与迁移.md。
-- =====================================================================

CREATE TABLE units (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Unit.ID
    code            TEXT,                              -- Number（编号）
    name            TEXT,                              -- Unit_Name（单位名称）
    status          TEXT,                              -- Status（使用/禁用）

    -- 审计 + 软删（与 colors/goods/... 同构）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_units_legacy_id ON units(legacy_id);
CREATE INDEX idx_units_code      ON units(code);
CREATE INDEX idx_units_status    ON units(status);

COMMENT ON TABLE  units IS '基本单位主档（基础资料-基本单位），老库 B_Unit 迁移（扁平表，无分类树）';
COMMENT ON COLUMN units.legacy_id IS '老库 B_Unit.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN units.code   IS '单位编号（源 B_Unit.Number）';
COMMENT ON COLUMN units.name   IS '单位名称（源 B_Unit.Unit_Name，如 个/套/只/kg）';
COMMENT ON COLUMN units.status IS '生命周期（源 B_Unit.Status：使用/禁用）';

-- 权限点（查看/维护单位，category「主数据」，sort_order 接颜色 60/61 之后）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('unit:view', '查看单位', '主数据', 70),
    ('unit:edit', '维护单位', '主数据', 71)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'unit:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（基础主数据归仓储/采购口维护，同货品/供应商/颜色；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'unit:edit'
ON CONFLICT DO NOTHING;
