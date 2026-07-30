-- =====================================================================
-- V31：物料分类树 material_categories（基础资料 · 货品资料）
-- =====================================================================
-- 仿 departments：邻接表(parent_id) + 物化路径(path,触发器自动维护) + 软删除 + 审计。
-- 与 departments 的差异：
--   * code 无 UNIQUE——老库编码大量重复（如"白色"x31、"灰色"x23、"SJ"/"WJ"/"OEM"多处复用）；
--     定位一律用 id / legacy_id，path 仅辅助排序与子树查询。
--   * level 为 INT 真实深度——老库 SystemItem.Level 不可靠，迁移时按 parent 链重算（根=0）。
--   * 无 manager_id / headcount——物料分类无负责人/人数。
--   * 加 legacy_id——老库 SystemItem.ItemID，迁移溯源 + 重跑/增量幂等。
-- 数据来源：老库 YTDQ_2023.SystemItem WHERE ItemclassID=1（货品分类，9 根/881 连通节点/最大 5 层），
--   由 com.uten.imp.legacy.migration.MaterialCategoryMigrator 迁移灌入。
-- 详见 docs/06-老系统融合/06-货品资料分类树-老库溯源.md。
-- =====================================================================

CREATE TABLE material_categories (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id    INT  UNIQUE,
    code         TEXT NOT NULL,
    name         TEXT NOT NULL,
    parent_id    UUID REFERENCES material_categories(id) ON DELETE RESTRICT,
    level        INT  NOT NULL DEFAULT 0,
    sort_order   INT  NOT NULL DEFAULT 0,
    path         TEXT NOT NULL DEFAULT '/',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);
CREATE INDEX idx_matcat_parent      ON material_categories(parent_id);
CREATE INDEX idx_matcat_parent_sort ON material_categories(parent_id, sort_order);
CREATE INDEX idx_matcat_path        ON material_categories(path text_ops);
CREATE INDEX idx_matcat_legacy_id   ON material_categories(legacy_id);

COMMENT ON TABLE  material_categories IS '物料分类树（基础资料：货品/模具/颜色分类），邻接表+物化路径+软删除';
COMMENT ON COLUMN material_categories.legacy_id IS '老库 SystemItem.ItemID（迁移溯源+重跑幂等；手工新建的为空）';
COMMENT ON COLUMN material_categories.level     IS '真实深度（根=0），由迁移/触发器维护，非老库 Level';

-- path 自动维护：path = 父path || code || '/'（根节点 '/code/'）。
-- 注意：code 可能重复 → path 不要求唯一；排序用 (path, sort_order)。
CREATE OR REPLACE FUNCTION fn_matcat_path() RETURNS TRIGGER AS $$
DECLARE v_parent_path TEXT;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.path := '/' || NEW.code || '/';
    ELSE
        SELECT path INTO v_parent_path FROM material_categories WHERE id = NEW.parent_id;
        NEW.path := COALESCE(v_parent_path, '/') || NEW.code || '/';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_matcat_path
    BEFORE INSERT OR UPDATE OF parent_id, code ON material_categories
    FOR EACH ROW EXECUTE FUNCTION fn_matcat_path();

-- =====================================================================
-- 权限点（category 中文「主数据」，参照 V30）
--   material_category:view — 查看物料分类树（默认登录即可见，路由层不拦）
--   material_category:edit — 维护分类（新增/改名/移动/删除/排序）
-- =====================================================================
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('material_category:view', '查看物料分类', '主数据', 10),
    ('material_category:edit', '维护物料分类', '主数据', 11)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查；访客不在 departments 表，拿不到）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE p.code = 'material_category:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（仓储/物料归属）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'material_category:edit'
ON CONFLICT DO NOTHING;
