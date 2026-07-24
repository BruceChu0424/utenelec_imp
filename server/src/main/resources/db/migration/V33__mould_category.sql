-- =====================================================================
-- V33：模具分类树 mould_categories（基础资料 · 模具资料）
-- =====================================================================
-- 与 V31 material_categories 完全同构（邻接表 parent_id + 物化路径 path +
-- 软删除 + 审计 + legacy_id），独立成表——与货品分类物理隔离，互不影响。
--   * code 无 UNIQUE——老库 SystemItem.Number 重复（如 118、Q120 各两条）；
--     定位一律用 id / legacy_id，path 仅辅助排序与子树查询。
--   * level 为 INT 真实深度——老库 SystemItem.Level 不可靠，迁移按 parent 链重算。
--   * legacy_id = 老库 SystemItem.ItemID（ItemclassID=18），迁移溯源 + 重跑幂等。
-- 数据来源：老库 YTDQ_2023.SystemItem WHERE ItemclassID=18（模具系列，65 个扁平根），
--   由 com.uten.imp.legacy.migration.MouldCategoryMigrator 迁移灌入；
--   离线 shell 路径见 server/legacy_migration/migrate_mould.sql。
-- 详见 docs/数据迁移/05-模具资料-新库与迁移.md。
-- =====================================================================

CREATE TABLE mould_categories (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id    INT  UNIQUE,
    code         TEXT NOT NULL,
    name         TEXT NOT NULL,
    parent_id    UUID REFERENCES mould_categories(id) ON DELETE RESTRICT,
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
CREATE INDEX idx_mouldcat_parent      ON mould_categories(parent_id);
CREATE INDEX idx_mouldcat_parent_sort ON mould_categories(parent_id, sort_order);
CREATE INDEX idx_mouldcat_path        ON mould_categories(path text_ops);
CREATE INDEX idx_mouldcat_legacy_id   ON mould_categories(legacy_id);

COMMENT ON TABLE  mould_categories IS '模具分类树（基础资料-模具资料），邻接表+物化路径+软删除；与 material_categories 同构、独立';
COMMENT ON COLUMN mould_categories.legacy_id IS '老库 SystemItem.ItemID（ItemclassID=18；迁移溯源+重跑幂等；手工新建的为空）';
COMMENT ON COLUMN mould_categories.level     IS '真实深度（根=0），由迁移/触发器维护，非老库 Level';

-- path 自动维护：path = 父path || code || '/'（根节点 '/code/'）。
-- code 可能重复 → path 不要求唯一；排序用 (path, sort_order)。逻辑同 fn_matcat_path。
CREATE OR REPLACE FUNCTION fn_mouldcat_path() RETURNS TRIGGER AS $$
DECLARE v_parent_path TEXT;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.path := '/' || NEW.code || '/';
    ELSE
        SELECT path INTO v_parent_path FROM mould_categories WHERE id = NEW.parent_id;
        NEW.path := COALESCE(v_parent_path, '/') || NEW.code || '/';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mouldcat_path
    BEFORE INSERT OR UPDATE OF parent_id, code ON mould_categories
    FOR EACH ROW EXECUTE FUNCTION fn_mouldcat_path();

-- =====================================================================
-- 权限点（category 中文「主数据」，参照 V30/V31/V32）
--   mould_category:view — 查看模具分类树（默认登录即可见，路由层不拦）
--   mould_category:edit — 维护模具分类（新增/改名/移动/删除/排序）
-- sort_order：material_category 10/11、goods 20/21、模具接 30/31。
-- =====================================================================
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('mould_category:view', '查看模具分类', '主数据', 30),
    ('mould_category:edit', '维护模具分类', '主数据', 31)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查；访客不在 departments 表，拿不到）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE p.code = 'mould_category:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给生产部（模具=生产工装，由生产部维护；超管恒有；可后续在权限管理页调整）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE d.code = 'DEPT_PROD' AND p.code = 'mould_category:edit'
ON CONFLICT DO NOTHING;
