-- Every hierarchy-backed master record must remain reachable from its tree.
-- legacy_id = -1 is the stable, per-domain identity of the protected system
-- "uncategorized" root.  Its code_prefix stays NULL so existing fallback
-- number prefixes remain CLIENT=KH, MOULD=MJ and SUPPLIER=GY.

INSERT INTO client_categories (
    legacy_id, code, remark, legacy_code_snapshot, code_prefix, name,
    parent_id, level, sort_order, is_deleted, deleted_at)
VALUES (
    -1, 'SYS_UNCATEGORIZED_CLIENT', 'SYSTEM_UNCATEGORIZED',
    'SYSTEM_UNCATEGORIZED', NULL, '未分类', NULL, 0, 2147483647, FALSE, NULL)
ON CONFLICT (legacy_id) DO UPDATE SET
    code = EXCLUDED.code,
    remark = EXCLUDED.remark,
    legacy_code_snapshot = EXCLUDED.legacy_code_snapshot,
    code_prefix = NULL,
    name = EXCLUDED.name,
    parent_id = NULL,
    level = 0,
    sort_order = EXCLUDED.sort_order,
    is_deleted = FALSE,
    deleted_at = NULL,
    version = client_categories.version + 1;

INSERT INTO mould_categories (
    legacy_id, code, remark, legacy_code_snapshot, code_prefix, name,
    parent_id, level, sort_order, is_deleted, deleted_at)
VALUES (
    -1, 'SYS_UNCATEGORIZED_MOULD', 'SYSTEM_UNCATEGORIZED',
    'SYSTEM_UNCATEGORIZED', NULL, '未分类', NULL, 0, 2147483647, FALSE, NULL)
ON CONFLICT (legacy_id) DO UPDATE SET
    code = EXCLUDED.code,
    remark = EXCLUDED.remark,
    legacy_code_snapshot = EXCLUDED.legacy_code_snapshot,
    code_prefix = NULL,
    name = EXCLUDED.name,
    parent_id = NULL,
    level = 0,
    sort_order = EXCLUDED.sort_order,
    is_deleted = FALSE,
    deleted_at = NULL,
    version = mould_categories.version + 1;

INSERT INTO supplier_categories (
    legacy_id, code, remark, legacy_code_snapshot, code_prefix, name,
    parent_id, level, sort_order, is_deleted, deleted_at)
VALUES (
    -1, 'SYS_UNCATEGORIZED_SUPPLIER', 'SYSTEM_UNCATEGORIZED',
    'SYSTEM_UNCATEGORIZED', NULL, '未分类', NULL, 0, 2147483647, FALSE, NULL)
ON CONFLICT (legacy_id) DO UPDATE SET
    code = EXCLUDED.code,
    remark = EXCLUDED.remark,
    legacy_code_snapshot = EXCLUDED.legacy_code_snapshot,
    code_prefix = NULL,
    name = EXCLUDED.name,
    parent_id = NULL,
    level = 0,
    sort_order = EXCLUDED.sort_order,
    is_deleted = FALSE,
    deleted_at = NULL,
    version = supplier_categories.version + 1;

-- If an earlier legacy run had already created legacy_id=-1, normalizing its
-- code changes its materialized path. Rebuild every descendant from parent_id.
WITH RECURSIVE rebuilt(id, new_level, new_path, visited) AS (
    SELECT id, 0, ('/' || code || '/')::text, ARRAY[id]
    FROM client_categories WHERE legacy_id = -1
    UNION ALL
    SELECT child.id, parent.new_level + 1,
           (parent.new_path || child.code || '/')::text, parent.visited || child.id
    FROM client_categories child JOIN rebuilt parent ON child.parent_id = parent.id
    WHERE NOT child.id = ANY(parent.visited)
)
UPDATE client_categories c
SET level = rebuilt.new_level, path = rebuilt.new_path
FROM rebuilt WHERE c.id = rebuilt.id;

WITH RECURSIVE rebuilt(id, new_level, new_path, visited) AS (
    SELECT id, 0, ('/' || code || '/')::text, ARRAY[id]
    FROM mould_categories WHERE legacy_id = -1
    UNION ALL
    SELECT child.id, parent.new_level + 1,
           (parent.new_path || child.code || '/')::text, parent.visited || child.id
    FROM mould_categories child JOIN rebuilt parent ON child.parent_id = parent.id
    WHERE NOT child.id = ANY(parent.visited)
)
UPDATE mould_categories c
SET level = rebuilt.new_level, path = rebuilt.new_path
FROM rebuilt WHERE c.id = rebuilt.id;

WITH RECURSIVE rebuilt(id, new_level, new_path, visited) AS (
    SELECT id, 0, ('/' || code || '/')::text, ARRAY[id]
    FROM supplier_categories WHERE legacy_id = -1
    UNION ALL
    SELECT child.id, parent.new_level + 1,
           (parent.new_path || child.code || '/')::text, parent.visited || child.id
    FROM supplier_categories child JOIN rebuilt parent ON child.parent_id = parent.id
    WHERE NOT child.id = ANY(parent.visited)
)
UPDATE supplier_categories c
SET level = rebuilt.new_level, path = rebuilt.new_path
FROM rebuilt WHERE c.id = rebuilt.id;

UPDATE clients
SET category_id = (SELECT id FROM client_categories WHERE legacy_id = -1)
WHERE category_id IS NULL;

UPDATE clients master
SET category_id = (SELECT id FROM client_categories WHERE legacy_id = -1),
    code_managed = FALSE,
    code_prefix_category_id = NULL
FROM client_categories category
WHERE master.category_id = category.id
  AND master.is_deleted = FALSE
  AND category.is_deleted = TRUE;

UPDATE moulds
SET category_id = (SELECT id FROM mould_categories WHERE legacy_id = -1)
WHERE category_id IS NULL;

UPDATE moulds master
SET category_id = (SELECT id FROM mould_categories WHERE legacy_id = -1),
    code_managed = FALSE,
    code_prefix_category_id = NULL
FROM mould_categories category
WHERE master.category_id = category.id
  AND master.is_deleted = FALSE
  AND category.is_deleted = TRUE;

UPDATE suppliers
SET category_id = (SELECT id FROM supplier_categories WHERE legacy_id = -1)
WHERE category_id IS NULL;

UPDATE suppliers master
SET category_id = (SELECT id FROM supplier_categories WHERE legacy_id = -1),
    code_managed = FALSE,
    code_prefix_category_id = NULL
FROM supplier_categories category
WHERE master.category_id = category.id
  AND master.is_deleted = FALSE
  AND category.is_deleted = TRUE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM clients master
        JOIN client_categories category ON category.id = master.category_id
        WHERE master.is_deleted = FALSE AND category.is_deleted = TRUE
    ) OR EXISTS (
        SELECT 1 FROM moulds master
        JOIN mould_categories category ON category.id = master.category_id
        WHERE master.is_deleted = FALSE AND category.is_deleted = TRUE
    ) OR EXISTS (
        SELECT 1 FROM suppliers master
        JOIN supplier_categories category ON category.id = master.category_id
        WHERE master.is_deleted = FALSE AND category.is_deleted = TRUE
    ) THEN
        RAISE EXCEPTION 'active master records still reference deleted categories';
    END IF;
END;
$$;

-- Raw/internal writers are fail-safe: a missing category is normalized to the
-- same real root before the NOT NULL constraint is evaluated. Public APIs still
-- require categoryId explicitly, except the website inquiry adapter which binds
-- the client system root itself.
CREATE OR REPLACE FUNCTION fn_assign_uncategorized_master_category()
RETURNS TRIGGER AS $$
DECLARE
    v_category_id UUID;
BEGIN
    IF NEW.category_id IS NULL THEN
        EXECUTE format('SELECT id FROM %I WHERE legacy_id = -1 AND is_deleted = false', TG_ARGV[0])
        INTO v_category_id;
        IF v_category_id IS NULL THEN
            RAISE EXCEPTION 'system uncategorized category missing in %', TG_ARGV[0];
        END IF;
        NEW.category_id := v_category_id;
    ELSIF NEW.is_deleted = FALSE THEN
        EXECUTE format(
            'SELECT id FROM %I WHERE id = $1 AND is_deleted = false', TG_ARGV[0])
        INTO v_category_id USING NEW.category_id;
        IF v_category_id IS NULL THEN
            RAISE EXCEPTION 'active master category is missing or deleted in %', TG_ARGV[0];
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_clients_assign_uncategorized_category
    BEFORE INSERT OR UPDATE OF category_id, is_deleted ON clients
    FOR EACH ROW EXECUTE FUNCTION fn_assign_uncategorized_master_category('client_categories');
CREATE TRIGGER trg_moulds_assign_uncategorized_category
    BEFORE INSERT OR UPDATE OF category_id, is_deleted ON moulds
    FOR EACH ROW EXECUTE FUNCTION fn_assign_uncategorized_master_category('mould_categories');
CREATE TRIGGER trg_suppliers_assign_uncategorized_category
    BEFORE INSERT OR UPDATE OF category_id, is_deleted ON suppliers
    FOR EACH ROW EXECUTE FUNCTION fn_assign_uncategorized_master_category('supplier_categories');

ALTER TABLE clients ALTER COLUMN category_id SET NOT NULL;
ALTER TABLE moulds ALTER COLUMN category_id SET NOT NULL;
ALTER TABLE suppliers ALTER COLUMN category_id SET NOT NULL;

ALTER TABLE client_categories ADD CONSTRAINT client_categories_system_uncategorized_chk
    CHECK (legacy_id IS DISTINCT FROM -1 OR (
        code = 'SYS_UNCATEGORIZED_CLIENT' AND name = '未分类'
        AND parent_id IS NULL AND level = 0 AND code_prefix IS NULL
        AND is_deleted = FALSE AND deleted_at IS NULL));
ALTER TABLE mould_categories ADD CONSTRAINT mould_categories_system_uncategorized_chk
    CHECK (legacy_id IS DISTINCT FROM -1 OR (
        code = 'SYS_UNCATEGORIZED_MOULD' AND name = '未分类'
        AND parent_id IS NULL AND level = 0 AND code_prefix IS NULL
        AND is_deleted = FALSE AND deleted_at IS NULL));
ALTER TABLE supplier_categories ADD CONSTRAINT supplier_categories_system_uncategorized_chk
    CHECK (legacy_id IS DISTINCT FROM -1 OR (
        code = 'SYS_UNCATEGORIZED_SUPPLIER' AND name = '未分类'
        AND parent_id IS NULL AND level = 0 AND code_prefix IS NULL
        AND is_deleted = FALSE AND deleted_at IS NULL));

CREATE OR REPLACE FUNCTION fn_protect_uncategorized_master_category()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.legacy_id = -1 THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'system uncategorized category cannot be deleted';
        END IF;
        IF NEW.legacy_id IS DISTINCT FROM -1
           OR NEW.code IS DISTINCT FROM TG_ARGV[0]
           OR NEW.name IS DISTINCT FROM '未分类'
           OR NEW.parent_id IS NOT NULL
           OR NEW.level IS DISTINCT FROM 0
           OR NEW.code_prefix IS NOT NULL
           OR NEW.is_deleted IS DISTINCT FROM FALSE
           OR NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'system uncategorized category is immutable';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_client_categories_protect_uncategorized
    BEFORE UPDATE OR DELETE ON client_categories
    FOR EACH ROW EXECUTE FUNCTION fn_protect_uncategorized_master_category('SYS_UNCATEGORIZED_CLIENT');
CREATE TRIGGER trg_mould_categories_protect_uncategorized
    BEFORE UPDATE OR DELETE ON mould_categories
    FOR EACH ROW EXECUTE FUNCTION fn_protect_uncategorized_master_category('SYS_UNCATEGORIZED_MOULD');
CREATE TRIGGER trg_supplier_categories_protect_uncategorized
    BEFORE UPDATE OR DELETE ON supplier_categories
    FOR EACH ROW EXECUTE FUNCTION fn_protect_uncategorized_master_category('SYS_UNCATEGORIZED_SUPPLIER');

-- Client/supplier category deletion is non-cascading. Prevent soft deletion of
-- a leaf that still owns active masters, which would otherwise hide live rows
-- from the tree while leaving the FK technically valid.
CREATE OR REPLACE FUNCTION fn_guard_category_soft_delete_with_active_masters()
RETURNS TRIGGER AS $$
DECLARE
    v_referenced BOOLEAN;
BEGIN
    IF OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE THEN
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I WHERE category_id = $1 AND is_deleted = false)',
            TG_ARGV[0])
        INTO v_referenced USING OLD.id;
        IF v_referenced THEN
            RAISE EXCEPTION 'category still owns active master records';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_client_categories_guard_active_masters
    BEFORE UPDATE OF is_deleted ON client_categories
    FOR EACH ROW EXECUTE FUNCTION fn_guard_category_soft_delete_with_active_masters('clients');
CREATE TRIGGER trg_supplier_categories_guard_active_masters
    BEFORE UPDATE OF is_deleted ON supplier_categories
    FOR EACH ROW EXECUTE FUNCTION fn_guard_category_soft_delete_with_active_masters('suppliers');

COMMENT ON COLUMN clients.category_id IS
    '所属客户分类（必填；历史/系统未归类数据挂 legacy_id=-1 的未分类根）';
COMMENT ON COLUMN moulds.category_id IS
    '所属模具分类（必填；历史孤儿挂 legacy_id=-1 的未分类根）';
COMMENT ON COLUMN suppliers.category_id IS
    '所属供应商分类（必填；历史/系统未归类数据挂 legacy_id=-1 的未分类根）';
