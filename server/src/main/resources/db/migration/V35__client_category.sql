-- =====================================================================
-- V35：客户分类树 client_categories（基础资料 · 客户资料）
-- =====================================================================
-- 与 V31 material_categories / V33 mould_categories 完全同构（邻接表 parent_id +
-- 物化路径 path + 软删除 + 审计 + legacy_id），独立成表——与货品/模具分类物理隔离。
--   * code 无 UNIQUE——老库 SystemItem.Number 在本树有重复（如 GD「内销轨道」在
--     外贸苏/内销轨道王下各一条、CL 两条）；定位一律用 id / legacy_id。
--   * level 为 INT 真实深度——老库 SystemItem.Level 不可靠，迁移按 parent 链重算。
--   * legacy_id = 老库 SystemItem.ItemID（ItemclassID=2），迁移溯源 + 重跑幂等。
-- 数据来源：老库 YTDQ_2023.SystemItem WHERE ItemclassID=2（客户/业务区域分组，
--   10 根 / 40 节点 / 最大深 3：外贸钟/苏/刘/罗、OEM苏、南区/北区→省份→分销商），
--   由 com.uten.imp.legacy.migration.ClientCategoryMigrator 迁移灌入；
--   离线 shell 路径见 server/legacy_migration/migrate_client.sql。
-- 详见 docs/数据迁移/06-客户资料-老库溯源.md、07-客户资料-新库与迁移.md。
-- =====================================================================

CREATE TABLE client_categories (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id    INT  UNIQUE,
    code         TEXT NOT NULL,
    name         TEXT NOT NULL,
    parent_id    UUID REFERENCES client_categories(id) ON DELETE RESTRICT,
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
CREATE INDEX idx_clientcat_parent      ON client_categories(parent_id);
CREATE INDEX idx_clientcat_parent_sort ON client_categories(parent_id, sort_order);
CREATE INDEX idx_clientcat_path        ON client_categories(path text_ops);
CREATE INDEX idx_clientcat_legacy_id   ON client_categories(legacy_id);

COMMENT ON TABLE  client_categories IS '客户分类树（基础资料-客户资料），邻接表+物化路径+软删除；与 material_categories/mould_categories 同构、独立';
COMMENT ON COLUMN client_categories.legacy_id IS '老库 SystemItem.ItemID（ItemclassID=2；迁移溯源+重跑幂等；手工新建的为空）';
COMMENT ON COLUMN client_categories.level     IS '真实深度（根=0），由迁移/触发器维护，非老库 Level';

-- path 自动维护：path = 父path || code || '/'（根节点 '/code/'）。
-- code 可能重复 → path 不要求唯一；排序用 (path, sort_order)。逻辑同 fn_matcat_path / fn_mouldcat_path。
CREATE OR REPLACE FUNCTION fn_clientcat_path() RETURNS TRIGGER AS $$
DECLARE v_parent_path TEXT;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.path := '/' || NEW.code || '/';
    ELSE
        SELECT path INTO v_parent_path FROM client_categories WHERE id = NEW.parent_id;
        NEW.path := COALESCE(v_parent_path, '/') || NEW.code || '/';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_clientcat_path
    BEFORE INSERT OR UPDATE OF parent_id, code ON client_categories
    FOR EACH ROW EXECUTE FUNCTION fn_clientcat_path();

-- =====================================================================
-- 权限点（category 中文「主数据」，参照 V30/V31/V33）
--   client_category:view — 查看客户分类树（默认登录即可见，路由层不拦）
--   client_category:edit — 维护客户分类（新增/改名/移动/删除/排序）
-- sort_order：material_category 10/11、goods 20/21、mould_category 30/31、mould 32/33、客户接 40/41。
-- =====================================================================
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('client_category:view', '查看客户分类', '主数据', 40),
    ('client_category:edit', '维护客户分类', '主数据', 41)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查；访客不在 departments 表，拿不到）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE p.code = 'client_category:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给综合营销部（客户由销售口维护；超管恒有；可后续在权限管理页调整）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE d.code = 'DEPT_SALES' AND p.code = 'client_category:edit'
ON CONFLICT DO NOTHING;
