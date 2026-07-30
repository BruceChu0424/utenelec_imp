-- =====================================================================
-- V37：供应商分类树 supplier_categories（基础资料 · 供应商资料）
-- =====================================================================
-- 与 V31/V33/V35 完全同构（邻接表 parent_id + 物化路径 path + 软删除 + 审计 + legacy_id），
-- 独立成表——与货品/模具/客户分类物理隔离。
--   * code 无 UNIQUE——老库 SystemItem.Number 在本树有重复（如 CL「金属材料类」与
--     「表面处理类」各一条）；定位一律用 id / legacy_id。
--   * legacy_id = 老库 SystemItem.ItemID（ItemclassID=3），迁移溯源 + 重跑幂等。
-- 数据来源：老库 YTDQ_2023.SystemItem WHERE ItemclassID=3（供应商/材质分类，
--   15 个扁平根：五金类/塑胶原料/塑胶件 001/玻璃面板/轨道配件/电子类…），
--   由 com.uten.imp.legacy.migration.SupplierCategoryMigrator 迁移灌入；
--   离线 shell 路径见 server/legacy_migration/migrate_supplier.sql。
-- 详见 docs/数据迁移/08-供应商资料-老库溯源.md、09-供应商资料-新库与迁移.md。
-- =====================================================================

CREATE TABLE supplier_categories (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id    INT  UNIQUE,
    code         TEXT NOT NULL,
    name         TEXT NOT NULL,
    parent_id    UUID REFERENCES supplier_categories(id) ON DELETE RESTRICT,
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
CREATE INDEX idx_suppliercat_parent      ON supplier_categories(parent_id);
CREATE INDEX idx_suppliercat_parent_sort ON supplier_categories(parent_id, sort_order);
CREATE INDEX idx_suppliercat_path        ON supplier_categories(path text_ops);
CREATE INDEX idx_suppliercat_legacy_id   ON supplier_categories(legacy_id);

COMMENT ON TABLE  supplier_categories IS '供应商分类树（基础资料-供应商资料），邻接表+物化路径+软删除；与 material/mould/client_categories 同构、独立';
COMMENT ON COLUMN supplier_categories.legacy_id IS '老库 SystemItem.ItemID（ItemclassID=3；迁移溯源+重跑幂等；手工新建的为空）';
COMMENT ON COLUMN supplier_categories.level     IS '真实深度（根=0），由迁移/触发器维护，非老库 Level';

-- path 自动维护：path = 父path || code || '/'（根节点 '/code/'）。逻辑同 fn_matcat_path。
CREATE OR REPLACE FUNCTION fn_suppliercat_path() RETURNS TRIGGER AS $$
DECLARE v_parent_path TEXT;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.path := '/' || NEW.code || '/';
    ELSE
        SELECT path INTO v_parent_path FROM supplier_categories WHERE id = NEW.parent_id;
        NEW.path := COALESCE(v_parent_path, '/') || NEW.code || '/';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_suppliercat_path
    BEFORE INSERT OR UPDATE OF parent_id, code ON supplier_categories
    FOR EACH ROW EXECUTE FUNCTION fn_suppliercat_path();

-- =====================================================================
-- 权限点（category 中文「主数据」）
--   supplier_category:view — 查看供应商分类树（默认登录即可见，路由层不拦）
--   supplier_category:edit — 维护供应商分类（新增/改名/移动/删除/排序）
-- sort_order：客户 40/41/42/43、供应商接 50/51。
-- =====================================================================
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('supplier_category:view', '查看供应商分类', '主数据', 50),
    ('supplier_category:edit', '维护供应商分类', '主数据', 51)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（基础资料全员可查）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE p.code = 'supplier_category:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（供应商由仓储/采购口维护，同货品；超管恒有；可后续在权限管理页调整）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'supplier_category:edit'
ON CONFLICT DO NOTHING;
