-- V684 ADR-111 分类删除与「往分类里加东西」的并发闸
--
-- 背景：物料分类/模具分类删除会级联软删子树里的货品/模具(ADR-111 先做引用检查)；客户/供应商
-- 分类删除要求分类下已没有有效客户/供应商。这些检查都是「先读后删」，而往分类里新建货品、
-- 把货品挪进分类、在分类下新建子分类，读的都是提交前的快照：删除事务读完还没提交时有人把
-- 货品挪进来，提交后货品就挂在一个已删除的分类下，在分类树里再也找不到。
--
-- 做法：删除一方先对子树分类行 SELECT … FOR UPDATE(服务端)；往分类里加东西的一方在触发器里
-- 对目标分类 FOR KEY SHARE 读一次「未删除」。两把锁互斥：删除先拿锁，加东西的一方等它提交后
-- 按最新版本重读，看到已删除即拒绝；加东西的一方先拿锁，删除等它提交后才读子树里的货品，
-- 新货品自然在检查范围内。KEY SHARE 之间互不冲突，平时建货品、改客户不因此串行。
--
--   1) goods：新建或改分类时，目标物料分类必须未删除(新触发器，只在分类真的变化时触发)；
--   2) clients/suppliers/moulds：沿用 V272/V275 的 fn_assign_uncategorized_master_category，
--      只把「分类未删除」那次读改为 FOR KEY SHARE，并改报 23514 便于服务端给出中文原因；
--   3) 四棵分类树：新建子分类或挪动父分类时，父分类必须未删除。
--
-- 只新增函数/触发器，并 CREATE OR REPLACE 一个既有函数(行为只多一把锁、错误码改为 23514)。

CREATE OR REPLACE FUNCTION fn_guard_goods_live_category()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.category_id IS NULL OR NEW.is_deleted THEN
        RETURN NEW;
    END IF;
    PERFORM 1 FROM material_categories c
    WHERE c.id = NEW.category_id AND c.is_deleted = FALSE
    FOR KEY SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'goods_category_live',
            MESSAGE = 'goods category has been deleted',
            DETAIL = format('goods %s category %s', NEW.id, NEW.category_id);
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_guard_goods_live_category() IS
    'ADR-111: goods may only be created in, or moved into, a material category that is not deleted (KEY SHARE vs category delete FOR UPDATE).';

CREATE TRIGGER trg_goods_guard_live_category_insert
    BEFORE INSERT ON goods
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_goods_live_category();

CREATE TRIGGER trg_goods_guard_live_category_update
    BEFORE UPDATE OF category_id ON goods
    FOR EACH ROW
    WHEN (NEW.category_id IS DISTINCT FROM OLD.category_id)
    EXECUTE FUNCTION fn_guard_goods_live_category();

CREATE OR REPLACE FUNCTION fn_assign_uncategorized_master_category()
RETURNS TRIGGER AS $$
DECLARE
    v_category_id UUID;
BEGIN
    IF NEW.category_id IS NULL THEN
        SELECT CASE TG_ARGV[0]
                   WHEN 'material_categories' THEN registry.material_category_id
                   WHEN 'client_categories' THEN registry.client_category_id
                   WHEN 'mould_categories' THEN registry.mould_category_id
                   WHEN 'supplier_categories' THEN registry.supplier_category_id
               END
        INTO v_category_id
        FROM system_master_category_registry registry
        WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid;

        IF v_category_id IS NULL THEN
            RAISE EXCEPTION
                'system uncategorized category UUID missing for %', TG_ARGV[0];
        END IF;
        NEW.category_id := v_category_id;
    ELSIF NEW.is_deleted = FALSE THEN
        EXECUTE format(
            'SELECT id FROM %I WHERE id = $1 AND is_deleted = false FOR KEY SHARE', TG_ARGV[0])
        INTO v_category_id USING NEW.category_id;
        IF v_category_id IS NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                CONSTRAINT = 'master_category_live',
                MESSAGE = 'active master requires an active category',
                DETAIL = format('%s %s category %s', TG_TABLE_NAME, NEW.id, NEW.category_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_guard_live_parent_category()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_parent UUID;
BEGIN
    IF NEW.parent_id IS NULL OR NEW.is_deleted THEN
        RETURN NEW;
    END IF;
    EXECUTE format(
        'SELECT id FROM %I WHERE id = $1 AND is_deleted = false FOR KEY SHARE', TG_TABLE_NAME)
    INTO v_parent USING NEW.parent_id;
    IF v_parent IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'category_parent_live',
            MESSAGE = 'category parent has been deleted',
            DETAIL = format('%s %s parent %s', TG_TABLE_NAME, NEW.id, NEW.parent_id);
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_guard_live_parent_category() IS
    'ADR-111: a category may only be created under, or moved under, a parent category that is not deleted.';

CREATE TRIGGER trg_material_categories_guard_live_parent_insert
    BEFORE INSERT ON material_categories
    FOR EACH ROW EXECUTE FUNCTION fn_guard_live_parent_category();
CREATE TRIGGER trg_material_categories_guard_live_parent_update
    BEFORE UPDATE OF parent_id ON material_categories
    FOR EACH ROW WHEN (NEW.parent_id IS DISTINCT FROM OLD.parent_id)
    EXECUTE FUNCTION fn_guard_live_parent_category();

CREATE TRIGGER trg_mould_categories_guard_live_parent_insert
    BEFORE INSERT ON mould_categories
    FOR EACH ROW EXECUTE FUNCTION fn_guard_live_parent_category();
CREATE TRIGGER trg_mould_categories_guard_live_parent_update
    BEFORE UPDATE OF parent_id ON mould_categories
    FOR EACH ROW WHEN (NEW.parent_id IS DISTINCT FROM OLD.parent_id)
    EXECUTE FUNCTION fn_guard_live_parent_category();

CREATE TRIGGER trg_client_categories_guard_live_parent_insert
    BEFORE INSERT ON client_categories
    FOR EACH ROW EXECUTE FUNCTION fn_guard_live_parent_category();
CREATE TRIGGER trg_client_categories_guard_live_parent_update
    BEFORE UPDATE OF parent_id ON client_categories
    FOR EACH ROW WHEN (NEW.parent_id IS DISTINCT FROM OLD.parent_id)
    EXECUTE FUNCTION fn_guard_live_parent_category();

CREATE TRIGGER trg_supplier_categories_guard_live_parent_insert
    BEFORE INSERT ON supplier_categories
    FOR EACH ROW EXECUTE FUNCTION fn_guard_live_parent_category();
CREATE TRIGGER trg_supplier_categories_guard_live_parent_update
    BEFORE UPDATE OF parent_id ON supplier_categories
    FOR EACH ROW WHEN (NEW.parent_id IS DISTINCT FROM OLD.parent_id)
    EXECUTE FUNCTION fn_guard_live_parent_category();
