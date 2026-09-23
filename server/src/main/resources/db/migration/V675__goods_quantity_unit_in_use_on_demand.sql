-- V675 ADR-106 货品基本单位「已被数量引用则不能改」改为改单位时按需检查
--
-- 背景(审计 db-schema-13 / perf-warehouse-quality-13)：V498 在 52 张数量来源表上各挂了
-- INSERT / UPDATE 两个语句级触发器(共 104 个)，每条写入语句都带过渡表跑一段动态 SQL，
-- 只为了把 goods.quantity_unit_locked 置成 TRUE；UPDATE 版本受过渡表限制不能加列过滤，
-- 预留、余额、分析物料的每次数量更新都要白跑一遍。而这个标志只在「改货品基本单位」这种
-- 罕见操作上才用得到。
--
-- 做法：删掉 104 个触发器、置位函数和 goods.quantity_unit_locked 列。「是否已被数量引用」
-- 改由 fn_goods_quantity_unit_in_use 在需要时现查：沿用 V498 的来源清单
-- fn_goods_quantity_reference_sources()(同一个事实源，含取消、红冲、软删的历史行)，
-- 拼成一条 UNION ALL 的 EXISTS，命中第一行即止；各来源货品列的领头索引由 V676 补齐。
-- 货品改单位守卫 fn_guard_goods_quantity_unit 只在单位真的变化时起跳：
--   1. 先对本货品行加 FOR UPDATE，等正在写引用的事务结束——外键检查与
--      GoodsQuantityBasisLocks 都对货品行持 FOR KEY SHARE，二者互斥；
--   2. 再用新快照判定是否已被引用，已引用就按 V498 同一文案拒绝。
-- 反方向(先改单位、后写引用)：写引用方的 FOR KEY SHARE 等改单位事务提交后读到新单位。
-- 串行化的前提是「一行变成引用」必经外键检查：60 个来源货品列都有不可延迟外键；唯一带行条件的来源
-- legacy_measurement_profile_snapshots(distinct_document_count > 0)自 V442 起只追加(UPDATE/DELETE 一律拒绝)，
-- 只能经 INSERT 变成引用，同样过外键检查。两条前提由 SchemaIndexHygieneContractTest 在迁移到头的库上钉住。
--
-- 口径变化(见 ADR-106 §2.3，推翻 V498「用过即终身锁定」)：引用被硬删除(草稿明细删除、清空业务数据)
-- 或草稿明细改指别的货品之后，原货品若已没有任何数量行就不再算「已使用」，可以改单位；软删、取消、
-- 红冲的历史行仍算使用。组装清单(goods_bom_items)是主档，清空业务数据后仍锁定。

-- 按「挂的是置位函数」逐个删，而不是按来源清单拼名字：并行迁移重建过某张来源表时，它上面的
-- 触发器可能已不在(或换了名字)；删完若还有漏网的，下面的 DROP FUNCTION 会因依赖而失败，不会静默残留。
DO $drop$
DECLARE
    lock_trigger RECORD;
BEGIN
    FOR lock_trigger IN
        SELECT t.tgname, t.tgrelid::regclass AS relation
        FROM pg_trigger t
        WHERE NOT t.tgisinternal
          AND t.tgparentid = 0 -- 分区上的克隆随父表触发器一起删
          AND t.tgfoid = 'fn_lock_goods_quantity_unit_from_references()'::regprocedure
        ORDER BY t.tgrelid::regclass::text, t.tgname
    LOOP
        EXECUTE format('DROP TRIGGER %I ON %s', lock_trigger.tgname, lock_trigger.relation);
    END LOOP;
END;
$drop$;

DROP FUNCTION fn_lock_goods_quantity_unit_from_references();

CREATE FUNCTION fn_goods_quantity_unit_in_use(p_goods_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE AS $in_use$
DECLARE
    source RECORD;
    column_name TEXT;
    goods_match TEXT;
    probe_sql TEXT := '';
    in_use BOOLEAN;
BEGIN
    IF p_goods_id IS NULL THEN
        RETURN FALSE;
    END IF;
    -- 清单是唯一事实源：新加数量来源表只改 fn_goods_quantity_reference_sources()。
    FOR source IN SELECT * FROM fn_goods_quantity_reference_sources() ORDER BY relation_name LOOP
        goods_match := '';
        FOREACH column_name IN ARRAY source.goods_columns LOOP
            goods_match := goods_match || CASE WHEN goods_match = '' THEN '' ELSE ' OR ' END
                || format('n.%I = $1', column_name);
        END LOOP;
        probe_sql := probe_sql || CASE WHEN probe_sql = '' THEN '' ELSE ' UNION ALL ' END
            || format('SELECT 1 FROM %I n WHERE (%s) AND (%s)',
                source.relation_name, goods_match, source.row_predicate);
    END LOOP;
    EXECUTE 'SELECT EXISTS (' || probe_sql || ')' INTO in_use USING p_goods_id;
    RETURN in_use;
END;
$in_use$;

COMMENT ON FUNCTION fn_goods_quantity_unit_in_use(UUID) IS
    'True when any quantity source in fn_goods_quantity_reference_sources() references the goods; the basic unit is then immutable';

CREATE OR REPLACE FUNCTION fn_guard_goods_quantity_unit() RETURNS trigger
LANGUAGE plpgsql AS $guard$
BEGIN
    -- 等正在写引用的事务结束(它们对本行持 FOR KEY SHARE)，再用新快照判定。
    PERFORM 1 FROM goods WHERE id = OLD.id FOR UPDATE;
    IF fn_goods_quantity_unit_in_use(OLD.id) THEN
        IF OLD.unit_id IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '23514', CONSTRAINT = 'goods_quantity_unit_immutable',
                MESSAGE = '该货品已有数量记录，但历史基本单位尚未核对，不能在普通编辑中补选或改写单位。请先由管理员按原始单据受控核对。';
        END IF;
        RAISE EXCEPTION USING ERRCODE = '23514', CONSTRAINT = 'goods_quantity_unit_immutable',
            MESSAGE = '该货品已有数量记录或组装引用，基本单位不能再改。请保留原单位；不同计量规格请新建货品。';
    END IF;
    RETURN NEW;
END;
$guard$;

-- 与 V498 一样不设列清单(JPA 整行更新会把所有列写进 SET)，只按最终行判定单位是否真的变化。
DROP TRIGGER trg_goods_quantity_unit_immutable ON goods;
CREATE TRIGGER trg_goods_quantity_unit_immutable
    BEFORE UPDATE ON goods
    FOR EACH ROW
    WHEN (OLD.unit_id IS DISTINCT FROM NEW.unit_id
          OR (OLD.unit_id IS NULL AND OLD.unit_legacy_id IS DISTINCT FROM NEW.unit_legacy_id))
    EXECUTE FUNCTION fn_guard_goods_quantity_unit();

ALTER TABLE goods DROP COLUMN quantity_unit_locked;
