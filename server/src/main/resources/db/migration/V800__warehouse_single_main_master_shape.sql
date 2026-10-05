-- V800 (ADR-145): 仓库主档收敛成「唯一主仓 + 直属子仓」两层树, 禁用仓不可再选。
--
-- 主仓 = 编号 001「仓库(14年版)」: 只作汇总、负责人范围和导航, 不记账、不能被新单选中;
-- 其余仓(五金/塑胶/包材/成品/五金车间/轨道车间/两个不良品仓/各车间内料仓)全部是它的直属子仓。
-- 只有一个顶层仓、没有编号 001 的库(全新部署后第一次建仓、升级彩排夹具)以那个唯一顶层仓为主仓;
-- 有仓库却既没有 001 又有多个顶层仓时无法判断该挂到谁下面, 迁移中止交人工处理。
-- 全新空库(CI)只安装函数和守卫。
--
-- 收敛步骤(只改仓库主档的层级/状态, 不搬库存、不改任何单据):
--   1. 其余未删除的普通仓一律挂到主仓下; 内料仓必须已经在主仓下(有流水的内料仓不能改挂, 只能人工处理);
--   2. 禁用但仍是货品所属仓库或还有库存的仓改回「使用」(停用必须先清空, 见下面的守卫);
--      主仓本身必须是「使用」;
--   3. 禁用且没有任何引用(全部外键列 + 物料分析参与仓)的仓软删除;
--   4. 货品所属仓库指向主仓、不良品仓等不可选仓的, 置空(不猜仓, 由入库自动学习或人工重填);
--   5. 规范化名称(去空白、全角括号转半角、不分大小写)重名时中止并列出;
--   6. 安装守卫: 停用/删除前置条件、两层树、仓库用途(良品/不良品)变更条件、货品所属仓库只能是可选良品子仓;
--   7. 事后断言: 恰好一个顶层仓, 其余未删除仓都挂在它下面, 没有「禁用却有库存或被归属」的仓。

LOCK TABLE warehouses IN SHARE ROW EXCLUSIVE MODE;

-- ---------------------------------------------------------------------------
-- 共用函数(服务层与数据库守卫同一定义)
-- ---------------------------------------------------------------------------

-- 仓库名称比对键: 去掉全部空白(含全角空格)、全角括号转半角、不分大小写。
CREATE OR REPLACE FUNCTION fn_warehouse_name_key(p_name TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(translate(regexp_replace(COALESCE(p_name, ''), '\s+', '', 'g'),
                           '（）' || chr(12288), '()'))
$$;

-- 唯一主仓: 编号 001 的未删除仓; 没有 001 时取唯一的未删除普通顶层仓; 判断不了返回空。
CREATE OR REPLACE FUNCTION fn_warehouse_root_id()
RETURNS UUID LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT id FROM warehouses
          WHERE code = '001' AND NOT is_deleted AND NOT is_line_side
          ORDER BY parent_id NULLS FIRST, id LIMIT 1),
        (SELECT CASE WHEN count(*) = 1 THEN (array_agg(id))[1] END
           FROM warehouses
          WHERE parent_id IS NULL AND NOT is_deleted AND NOT is_line_side))
$$;

-- 新单可选的良品子仓(字典 selectableForNew 的唯一定义): 启用、记账、作业叶仓、
-- 祖先链全部启用、不是车间内料仓、不是不良品仓。
CREATE OR REPLACE FUNCTION fn_warehouse_is_good_stock_leaf(p_warehouse UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE(fn_warehouse_is_active_accounting_leaf(p_warehouse)
        AND NOT EXISTS (SELECT 1 FROM warehouses WHERE id = p_warehouse AND is_defective), FALSE)
$$;

-- 一个仓退出「新单可选」之前必须满足的条件(停用、删除、改成不核算、改成不良品仓四条路同一口径);
-- 返回给人看的原因(空数组 = 可以)。ADR-145 不变量「货品所属仓库一定是可选良品子仓」靠它守住。
CREATE OR REPLACE FUNCTION fn_warehouse_selection_exit_blockers(p_warehouse UUID)
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
    SELECT array_remove(ARRAY[
        (SELECT '还有 ' || count(DISTINCT balance.goods_id) || ' 种货品有库存'
           FROM stock_balances balance
          WHERE balance.warehouse_id = p_warehouse AND balance.qty <> 0
         HAVING count(*) > 0),
        (SELECT '还是 ' || count(*) || ' 个货品的所属仓库'
           FROM goods
          WHERE goods.owning_warehouse_id = p_warehouse AND NOT goods.is_deleted
         HAVING count(*) > 0),
        (SELECT '还有 ' || count(*) || ' 条没结束的库存预留'
           FROM stock_reservations reservation
          WHERE reservation.warehouse_id = p_warehouse AND reservation.status = 0
            AND NOT reservation.is_deleted
            AND reservation.qty - reservation.consumed_qty - reservation.released_qty > 0
         HAVING count(*) > 0),
        (SELECT '是已开启整批领料的车间内料仓'
           FROM workshop_material_settings setting
          WHERE setting.periodic_bin_warehouse_id = p_warehouse AND setting.periodic_enabled
          LIMIT 1)
    ], NULL)
$$;

-- 停用/删除一个仓之前必须满足的条件 = 主仓永远不能停用/删除(下面挂着子仓的仓同样不行) + 退出新选的条件。
CREATE OR REPLACE FUNCTION fn_warehouse_retirement_blockers(p_warehouse UUID)
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
    SELECT array_remove(ARRAY[
        (SELECT CASE WHEN p_warehouse = fn_warehouse_root_id()
                     THEN '它是主仓(全公司仓库的汇总), 不能停用或删除'
                     ELSE '它是主仓, 下面还有 ' || count(*) || ' 个子仓' END
           FROM warehouses child
          WHERE child.parent_id = p_warehouse AND NOT child.is_deleted
         HAVING count(*) > 0 OR p_warehouse = fn_warehouse_root_id())
    ], NULL) || fn_warehouse_selection_exit_blockers(p_warehouse)
$$;

-- ---------------------------------------------------------------------------
-- 存量收敛(全新空库跳过)
-- ---------------------------------------------------------------------------
DO $migration$
DECLARE
    root UUID;
    misplaced TEXT;
    duplicates TEXT;
    candidate RECORD;
    reference RECORD;
    referenced BOOLEAN;
    cleared INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM warehouses WHERE NOT is_deleted) THEN
        RETURN;
    END IF;
    root := fn_warehouse_root_id();
    IF root IS NULL THEN
        RAISE EXCEPTION 'V800: 仓库主档没有编号 001 的主仓, 又有多个顶层仓, 无法判断子仓该挂到哪里; 请先确定主仓再升级';
    END IF;
    IF EXISTS (SELECT 1 FROM warehouses WHERE id = root AND is_defective) THEN
        RAISE EXCEPTION 'V800: 主仓不能是不良品仓';
    END IF;

    -- 主仓自身: 顶层、启用。
    UPDATE warehouses SET parent_id = NULL, updated_at = now()
     WHERE id = root AND parent_id IS NOT NULL;
    UPDATE warehouses SET status = '使用', updated_at = now()
     WHERE id = root AND status IS DISTINCT FROM '使用';

    -- 内料仓必须已在主仓下(有流水的内料仓不能改挂, 只能人工处理)。
    SELECT string_agg(COALESCE(code, id::text), ', ' ORDER BY code) INTO misplaced
      FROM warehouses
     WHERE NOT is_deleted AND is_line_side AND parent_id IS DISTINCT FROM root;
    IF misplaced IS NOT NULL THEN
        RAISE EXCEPTION 'V800: 这些车间内料仓不在主仓下面, 请先人工处理: %', misplaced;
    END IF;

    -- 其余普通仓全部挂到主仓下(只有两层)。
    UPDATE warehouses SET parent_id = root, updated_at = now()
     WHERE NOT is_deleted AND id <> root AND NOT is_line_side
       AND parent_id IS DISTINCT FROM root;

    -- 禁用但仍被货品归属或还有库存的仓 -> 使用。
    UPDATE warehouses warehouse SET status = '使用', updated_at = now()
     WHERE NOT warehouse.is_deleted AND warehouse.status = '禁用'
       AND (EXISTS (SELECT 1 FROM goods
                     WHERE goods.owning_warehouse_id = warehouse.id AND NOT goods.is_deleted)
            OR EXISTS (SELECT 1 FROM stock_balances balance
                        WHERE balance.warehouse_id = warehouse.id AND balance.qty <> 0));

    -- 禁用且没有任何引用的仓 -> 软删除。外键全部是单列引用 warehouses(id)。
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE confrelid = 'warehouses'::regclass AND contype = 'f'
                  AND cardinality(conkey) <> 1) THEN
        RAISE EXCEPTION 'V800: 发现多列外键引用仓库, 请先更新本迁移的引用检查';
    END IF;
    FOR candidate IN
        SELECT id FROM warehouses
         WHERE NOT is_deleted AND status = '禁用' AND id <> root
         ORDER BY id
    LOOP
        referenced := EXISTS (SELECT 1 FROM production_material_analyses analysis
                               WHERE candidate.id = ANY(analysis.participating_warehouse_ids));
        IF NOT referenced THEN
            FOR reference IN
                SELECT constraint_row.conrelid::regclass AS table_name, attribute.attname AS column_name
                  FROM pg_constraint constraint_row
                  JOIN pg_attribute attribute
                    ON attribute.attrelid = constraint_row.conrelid
                   AND attribute.attnum = constraint_row.conkey[1]
                 WHERE constraint_row.confrelid = 'warehouses'::regclass
                   AND constraint_row.contype = 'f'
            LOOP
                EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE %I = $1)',
                               reference.table_name, reference.column_name)
                   INTO referenced USING candidate.id;
                EXIT WHEN referenced;
            END LOOP;
        END IF;
        IF NOT referenced THEN
            UPDATE warehouses
               SET is_deleted = TRUE, deleted_at = now(), updated_at = now()
             WHERE id = candidate.id;
        END IF;
    END LOOP;

    -- 货品所属仓库只能是可选的良品子仓; 指向主仓/不良品仓等的置空(不猜仓)。
    -- 判定只取决于仓库, 按仓算一次(逐货品调用要扫上万次函数, 克隆库实测 10 秒 -> 20 毫秒)。
    UPDATE goods SET owning_warehouse_id = NULL, updated_at = now()
     WHERE NOT goods.is_deleted
       AND owning_warehouse_id IN (SELECT id FROM warehouses
                                    WHERE NOT fn_warehouse_is_good_stock_leaf(id));
    GET DIAGNOSTICS cleared = ROW_COUNT;
    IF cleared > 0 THEN
        RAISE NOTICE 'V800: % 个货品的所属仓库原来指向主仓/不良品仓/停用仓, 已置空', cleared;
    END IF;

    -- 规范化名称重名(未删除范围)。
    SELECT string_agg(names, '; ') INTO duplicates FROM (
        SELECT string_agg(COALESCE(code, '?') || ' ' || COALESCE(name, ''), ' / ' ORDER BY code) AS names
          FROM warehouses
         WHERE NOT is_deleted
         GROUP BY fn_warehouse_name_key(name)
        HAVING count(*) > 1) duplicate_groups;
    IF duplicates IS NOT NULL THEN
        RAISE EXCEPTION 'V800: 仓库名称重复(去空白、括号全半角视为相同), 请先改名或合并: %', duplicates;
    END IF;
END;
$migration$;

-- ---------------------------------------------------------------------------
-- 守卫: 停用/删除前置条件、改成不核算/不良品仓(退出新选)的前置条件、两层树、仓库用途变更条件
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_warehouse_master_lifecycle()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    label TEXT := COALESCE(NULLIF(btrim(NEW.name), ''), NEW.code, '该仓库');
    reasons TEXT[];
BEGIN
    IF (NEW.status = '禁用' AND OLD.status IS DISTINCT FROM '禁用')
       OR (NEW.is_deleted AND NOT OLD.is_deleted) THEN
        reasons := fn_warehouse_retirement_blockers(NEW.id);
        IF cardinality(reasons) > 0 THEN
            RAISE EXCEPTION '仓库「%」现在不能%: %', label,
                CASE WHEN NEW.is_deleted AND NOT OLD.is_deleted THEN '删除' ELSE '停用' END,
                array_to_string(reasons, '; ')
                USING ERRCODE = '23514', CONSTRAINT = 'warehouse_master_lifecycle_guard';
        END IF;
    END IF;

    -- 改成「不核算」或改成不良品仓, 同样让这个仓退出新单可选: 与停用同一组前置条件(主仓本身不受影响,
    -- 它从来不是可选子仓)。
    IF (OLD.is_accountable AND NOT NEW.is_accountable)
       OR (NEW.is_defective AND NOT OLD.is_defective) THEN
        reasons := fn_warehouse_selection_exit_blockers(NEW.id);
        IF cardinality(reasons) > 0 THEN
            RAISE EXCEPTION '仓库「%」现在不能%: %', label,
                CASE WHEN NEW.is_defective AND NOT OLD.is_defective THEN '改成不良品仓' ELSE '改成不核算' END,
                array_to_string(reasons, '; ')
                USING ERRCODE = '23514', CONSTRAINT = 'warehouse_master_use_guard';
        END IF;
    END IF;

    IF NEW.parent_id IS DISTINCT FROM OLD.parent_id THEN
        IF NEW.parent_id IS NULL THEN
            RAISE EXCEPTION '仓库「%」是子仓, 不能改成独立的顶层仓 (全公司只有一个主仓)', label
                USING ERRCODE = '23514', CONSTRAINT = 'warehouse_master_shape_guard';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM warehouses parent
                        WHERE parent.id = NEW.parent_id AND parent.parent_id IS NULL
                          AND NOT parent.is_deleted AND NOT parent.is_line_side) THEN
            RAISE EXCEPTION '仓库「%」只能挂在主仓下面 (仓库只有主仓和子仓两层)', label
                USING ERRCODE = '23514', CONSTRAINT = 'warehouse_master_shape_guard';
        END IF;
        IF EXISTS (SELECT 1 FROM warehouses child
                    WHERE child.parent_id = NEW.id AND NOT child.is_deleted) THEN
            RAISE EXCEPTION '仓库「%」下面还有子仓, 不能再挂到别的仓库下面', label
                USING ERRCODE = '23514', CONSTRAINT = 'warehouse_master_shape_guard';
        END IF;
    END IF;

    IF NEW.is_defective IS DISTINCT FROM OLD.is_defective THEN
        IF EXISTS (SELECT 1 FROM stock_balances balance
                    WHERE balance.warehouse_id = NEW.id AND balance.qty <> 0) THEN
            RAISE EXCEPTION '仓库「%」还有库存, 不能改仓库用途 (良品仓/不良品仓), 请先把库存转走', label
                USING ERRCODE = '23514', CONSTRAINT = 'warehouse_master_use_guard';
        END IF;
        IF NEW.is_defective AND EXISTS (SELECT 1 FROM warehouses child
                                         WHERE child.parent_id = NEW.id AND NOT child.is_deleted) THEN
            RAISE EXCEPTION '仓库「%」下面还有子仓, 不良品仓只能是子仓', label
                USING ERRCODE = '23514', CONSTRAINT = 'warehouse_master_use_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_warehouse_master_lifecycle
    BEFORE UPDATE OF status, is_deleted, parent_id, is_defective, is_accountable ON warehouses
    FOR EACH ROW EXECUTE FUNCTION fn_guard_warehouse_master_lifecycle();

-- 货品所属仓库只能是可选的良品子仓(新写入或值变化时才判定; 值没变的普通改档不受影响)。
-- 仍锁住仓库行, 与仓库停用/改用途互斥。
CREATE OR REPLACE FUNCTION fn_guard_goods_ordinary_owning_warehouse()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.owning_warehouse_id IS NULL THEN RETURN NEW; END IF;
    IF TG_OP = 'UPDATE' AND NEW.owning_warehouse_id IS NOT DISTINCT FROM OLD.owning_warehouse_id THEN
        RETURN NEW;
    END IF;
    PERFORM 1 FROM warehouses WHERE id = NEW.owning_warehouse_id FOR SHARE;
    IF NOT fn_warehouse_is_good_stock_leaf(NEW.owning_warehouse_id) THEN
        RAISE EXCEPTION '货品的所属仓库只能选启用中的良品子仓, 不能是主仓、停用仓、不良品仓或车间内料仓'
            USING ERRCODE = '23514', CONSTRAINT = 'goods_ordinary_owning_warehouse_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 事后断言
-- ---------------------------------------------------------------------------
DO $assert$
DECLARE
    root UUID;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM warehouses WHERE NOT is_deleted) THEN
        RETURN;
    END IF;
    IF (SELECT count(*) FROM warehouses WHERE NOT is_deleted AND parent_id IS NULL) <> 1 THEN
        RAISE EXCEPTION 'V800 assertion: exactly one top-level warehouse is required';
    END IF;
    root := fn_warehouse_root_id();
    IF root IS NULL OR EXISTS (SELECT 1 FROM warehouses
                                WHERE NOT is_deleted AND id <> root
                                  AND parent_id IS DISTINCT FROM root) THEN
        RAISE EXCEPTION 'V800 assertion: every other warehouse must be a direct child of the main warehouse';
    END IF;
    IF EXISTS (SELECT 1 FROM warehouses warehouse
                WHERE NOT warehouse.is_deleted AND warehouse.status = '禁用'
                  AND (EXISTS (SELECT 1 FROM goods
                                WHERE goods.owning_warehouse_id = warehouse.id AND NOT goods.is_deleted)
                       OR EXISTS (SELECT 1 FROM stock_balances balance
                                   WHERE balance.warehouse_id = warehouse.id AND balance.qty <> 0))) THEN
        RAISE EXCEPTION 'V800 assertion: a disabled warehouse still owns goods or stock';
    END IF;
END;
$assert$;

COMMENT ON FUNCTION fn_warehouse_name_key(TEXT) IS
    'V800 仓库名称比对键: 去空白、全角括号转半角、不分大小写; 服务层重名校验与迁移断言共用';
COMMENT ON FUNCTION fn_warehouse_root_id() IS
    'V800 唯一主仓: 编号 001; 没有 001 时取唯一的普通顶层仓; 判断不了返回空';
COMMENT ON FUNCTION fn_warehouse_is_good_stock_leaf(UUID) IS
    'V800 新单可选良品子仓 = 启用记账作业叶仓且非不良品仓; 字典 selectableForNew 的唯一定义';
COMMENT ON FUNCTION fn_warehouse_selection_exit_blockers(UUID) IS
    'V800 仓库退出新单可选(停用/删除/改不核算/改不良品仓)的前置条件: 库存、货品所属、未结预留、已开启整批领料的内料仓';
COMMENT ON FUNCTION fn_warehouse_retirement_blockers(UUID) IS
    'V800 停用/删除仓库的前置条件: 主仓永远不能停用删除、下面还有子仓, 加上退出新选的前置条件';
COMMENT ON FUNCTION fn_guard_warehouse_master_lifecycle() IS
    'V800 仓库主档守卫: 停用/删除与改不核算/改不良品仓的前置条件、主仓加子仓两层、仓库用途变更条件';
COMMENT ON FUNCTION fn_guard_goods_ordinary_owning_warehouse() IS
    'V800 货品所属仓库只能是可选良品子仓(新写入或值变化时判定)';
COMMENT ON COLUMN warehouses.parent_id IS
    'V800 上级仓库: 只有主仓(编号 001)没有上级, 其余仓都是它的直属子仓';
COMMENT ON COLUMN warehouses.is_defective IS
    'V800 仓库用途: TRUE=不良品仓(只能是子仓, 有库存时不能改用途), FALSE=良品仓';
COMMENT ON COLUMN goods.owning_warehouse_id IS
    'V800 货品所属仓库: 只能是启用中的良品子仓; 入库自动学习不学不良品仓和不可选仓';
