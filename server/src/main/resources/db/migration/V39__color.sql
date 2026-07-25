-- =====================================================================
-- V39：颜色主档 colors（基础资料 · 颜色资料 → 具体颜色）
-- =====================================================================
-- 来源：老库 B_Color（151 条），由 migrate.sh 的 --color-data 步骤迁移灌入。
-- 老库 B_Color 实测为扁平表（ParentID 全 0，非文档早先误称的"自引用树"），
--   故本表无分类树、无 parent_id，仅 legacy_id/code/name/status 四个业务列。
-- 字段映射：B_Color.ID→legacy_id、Number→code、ColorName→name、Status→status。
--   * legacy_id = B_Color.ID，迁移溯源 + 重跑幂等。
--   * code（老库 Number）大量重复（"01"×18 等）→ 不设 UNIQUE，仅建普通索引。
--   * name（老库 ColorName）有 1 条空串、个别带尾点/中文逗号；迁移时 trim 首尾空白，
--     其余原样保留（噪音行用户可在 UI 禁用/删除，保证货品 color_legacy_id 引用不悬空）。
--   * status 源值 使用(141)/禁用(10)，与主数据约定一致。
-- 货品 goods.color_legacy_id 即指向本表 legacy_id（task：货品颜色名称解析据此 LEFT JOIN）。
-- 详见 docs/数据迁移/11-颜色资料-新库与迁移.md。
-- =====================================================================

CREATE TABLE colors (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Color.ID
    code            TEXT,                              -- Number（编号，重复多 → 不 UNIQUE）
    name            TEXT,                              -- ColorName（颜色名称）
    status          TEXT,                              -- Status（使用/禁用）

    -- 审计 + 软删（与 goods/mould/client/suppliers 同构）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_colors_legacy_id ON colors(legacy_id);
CREATE INDEX idx_colors_code      ON colors(code);
CREATE INDEX idx_colors_status    ON colors(status);

COMMENT ON TABLE  colors IS '颜色主档（基础资料-颜色资料），老库 B_Color 迁移（扁平表，无分类树）';
COMMENT ON COLUMN colors.legacy_id IS '老库 B_Color.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN colors.code   IS '颜色编号（源 B_Color.Number；老库重复多，不唯一）';
COMMENT ON COLUMN colors.name   IS '颜色名称（源 B_Color.ColorName）';
COMMENT ON COLUMN colors.status IS '生命周期（源 B_Color.Status：使用/禁用）';

-- 权限点（查看/维护颜色，category「主数据」，sort_order 接供应商 52/53 之后）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('color:view', '查看颜色', '主数据', 60),
    ('color:edit', '维护颜色', '主数据', 61)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'color:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（基础主数据归仓储/采购口维护，同货品/供应商；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'color:edit'
ON CONFLICT DO NOTHING;
