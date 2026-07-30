-- =====================================================================
-- V34：模具主档 moulds（基础资料 · 模具资料 → 具体模具）
-- =====================================================================
-- 来源：老库 B_Mould（1605 条），B_Mould.ParentID → SystemItem.ItemID
--   （ItemclassID=18 模具分类），由 migrate.sh 的 mould-data 步骤迁移灌入。
-- 字段：B_Mould 全 12 字段（除 ParentID 转 category_id 外）。
--   * legacy_id = B_Mould.ID，迁移溯源 + 重跑幂等。
--   * 关联字段（系列分类）用 category_id → mould_categories（已建 FK）。
--   * 19 条 ParentID 悬空（指向已删 SystemItem）→ category_id 置 NULL。
-- 语义说明（老库字段名有误导，新库起清晰名）：
--   * B_Mould.MStatus 实为「制造年月」日期串（如 2018年7月）→ mstatus。
--   * B_Mould.[Status] 才是生命周期（使用/报废）→ status。
--   * B_Mould.summary 实存「保管人」人名 → keeper。
--   * B_Mould.Place 为车间/位置（注塑车间为主）→ place。
-- 详见 docs/数据迁移/05-模具资料-新库与迁移.md。
-- =====================================================================

CREATE TABLE moulds (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Mould.ID
    category_id     UUID REFERENCES mould_categories(id) ON DELETE RESTRICT,  -- B_Mould.ParentID → 模具分类

    -- 标识 / 名称
    name            TEXT,                              -- MouldName（模具名称）
    code            TEXT,                              -- Number（模具编号，如 C20-001【B3-12】）
    mnumber         TEXT,                              -- Mnumber（备用编号）

    -- 数量
    qty             TEXT,                              -- QTY（varchar，如 "1+1"）
    tqty            NUMERIC(18,4),                     -- TQTY（总数量）

    -- 状态
    mstatus         TEXT,                              -- MStatus（制造年月，如 2018年7月）
    status          TEXT,                              -- [Status]（生命周期：使用/禁用）
    place           TEXT,                              -- Place（车间/位置，如 注塑车间）
    keeper          TEXT,                              -- summary（保管人）
    remark          TEXT,                              -- Remark（备注）

    -- 审计 + 软删
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_moulds_category    ON moulds(category_id);
CREATE INDEX idx_moulds_legacy_id   ON moulds(legacy_id);
CREATE INDEX idx_moulds_code        ON moulds(code);
CREATE INDEX idx_moulds_status      ON moulds(status);

COMMENT ON TABLE  moulds IS '模具主档（基础资料-模具资料），老库 B_Mould 全字段迁移';
COMMENT ON COLUMN moulds.legacy_id   IS '老库 B_Mould.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN moulds.category_id IS '所属模具分类（mould_categories.id，源自 B_Mould.ParentID→SystemItem.ItemID ItemclassID=18）';
COMMENT ON COLUMN moulds.mstatus     IS '制造年月（源 B_Mould.MStatus，日期串如 2018年7月；非状态）';
COMMENT ON COLUMN moulds.status      IS '生命周期（源 B_Mould.Status：使用/禁用）';
COMMENT ON COLUMN moulds.keeper      IS '保管人（源 B_Mould.summary）';

-- 权限点（查看/维护模具，category「主数据」，sort_order 接 mould_category 之后）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('mould:view', '查看模具', '主数据', 32),
    ('mould:edit', '维护模具', '主数据', 33)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'mould:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给生产部（模具由生产部维护；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PROD' AND p.code = 'mould:edit'
ON CONFLICT DO NOTHING;
