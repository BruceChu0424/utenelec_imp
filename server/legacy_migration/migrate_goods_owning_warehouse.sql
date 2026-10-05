-- =====================================================================
-- 货品所属仓库(ADR-145)：交易模块之前先填好 goods.owning_warehouse_id
-- =====================================================================
-- 用法：全量导入 migrate.sh --bootstrap-all 在货品主档之后、采购/仓库等交易模块之前自动执行。
-- 为什么要在交易模块之前：老库主仓 132「仓库(14年版)」承载了几乎全部原料单据和余额，新库里
--   主仓 001 只作汇总不能记账，所以 132 上的库存明细、流水、余额要按货品所属子仓拆分
--   (见 migrate_stock_docs.sql)，拆分时所属仓库必须已经有值。
-- 来源：data/goods_owning_warehouse.csv(goods_legacy_id|warehouse_code)，由
--   python server/legacy_migration/import_product_lists.py --emit-owning-csv <路径>
--   从新 ERP 产品列表按产品名称生成(与 import_product_lists --apply 写所属仓库同一套匹配)，
--   仓库编号来自 warehouse_crosswalk.csv 的目标子仓。
-- 规则：只填空(已有所属仓库的货品不动)；仓库必须是主仓下的可选良品子仓，否则整体中止；
--   清单里找不到的老库货品不报错(老库已删除的货品本来就不在新 ERP 产品列表里)。
-- =====================================================================

SELECT set_config('app.business_identifier_legacy_import', 'on', true);

CREATE TEMP TABLE goods_owning_stage (
    goods_legacy_id int,
    warehouse_code  text
) ON COMMIT DROP;
\copy goods_owning_stage FROM '/tmp/goods_owning_warehouse.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

DO $$
DECLARE
    problem TEXT;
BEGIN
    SELECT string_agg(goods_legacy_id::text, ', ') INTO problem FROM (
        SELECT goods_legacy_id FROM goods_owning_stage
         GROUP BY goods_legacy_id HAVING count(DISTINCT warehouse_code) > 1) conflicting;
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'goods_owning_warehouse.csv names more than one warehouse for goods: %', problem;
    END IF;
    SELECT string_agg(DISTINCT stage.warehouse_code, ', ') INTO problem
      FROM goods_owning_stage stage
     WHERE NOT EXISTS (SELECT 1 FROM warehouses target
                        WHERE target.code = stage.warehouse_code AND NOT target.is_deleted
                          AND fn_warehouse_is_good_stock_leaf(target.id));
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'goods owning warehouses must be enabled good-stock sub-warehouses: %', problem;
    END IF;
END;
$$;

UPDATE goods
SET owning_warehouse_id = target.id,
    updated_at = now()
FROM goods_owning_stage stage
JOIN warehouses target ON target.code = stage.warehouse_code AND NOT target.is_deleted
WHERE goods.legacy_id = stage.goods_legacy_id
  AND NOT goods.is_deleted
  AND goods.owning_warehouse_id IS NULL;

SELECT '✔ 货品所属仓库：清单 ' || (SELECT count(*) FROM goods_owning_stage) ||
       ' 条，已有所属仓库的货品 ' ||
       (SELECT count(*) FROM goods WHERE owning_warehouse_id IS NOT NULL AND NOT is_deleted) ||
       '，仍为空 ' ||
       (SELECT count(*) FROM goods WHERE owning_warehouse_id IS NULL AND NOT is_deleted) AS 结果;
