-- V586 清库策略补登记：V583 报工实耗表与 V584 车间直送三张表
--
-- 背景：business_data_reset() 是 fail-closed 的——函数里那份 (表名, CLEAR/PRESERVE)
-- 清单必须**逐表覆盖**当前库里的全部业务表，遇到未登记的表直接 RAISE 并整体拒绝执行。
-- V583 建了 production_daily_report_material_usages、V584 建了车间直送三张表，
-- 两个迁移都没有按惯例补这份清单，于是任何一次清库都会在
-- 「ops/reset_business_data.sql 与本库不一致」上失败（com.uten.imp.ops.** 整包红）。
--
-- 四张都是纯业务事实（报工登记的实耗、车间内部直送单/行/撤回），系统测试重置时
-- 应当与报工、领料、库存事实一起清空，因此分类为 CLEAR。
--
-- 本迁移不建表、不改任何既有行，只把这四张登记进函数定义（沿用 V474 起的
-- 「读取已安装函数定义 + 锚点替换」补丁方式，锚点不存在或表已分类即失败关闭）。

DO $reset_policy$
DECLARE
    definition TEXT;
    needle TEXT := '(''stock_movements'', ''CLEAR'')';
    addition TEXT := E',\n            (''production_daily_report_material_usages'', ''CLEAR'')'
        || E',\n            (''production_workshop_direct_transfer_items'', ''CLEAR'')'
        || E',\n            (''production_workshop_direct_transfer_reversals'', ''CLEAR'')'
        || E',\n            (''production_workshop_direct_transfers'', ''CLEAR'')';
    table_name TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle) <> 1 THEN
        RAISE EXCEPTION 'V586 cannot extend business_data_reset policy safely';
    END IF;
    FOREACH table_name IN ARRAY ARRAY[
        'production_daily_report_material_usages',
        'production_workshop_direct_transfer_items',
        'production_workshop_direct_transfer_reversals',
        'production_workshop_direct_transfers'
    ] LOOP
        IF to_regclass(format('public.%I',table_name)) IS NULL
           OR position(format('(%L, %L)',table_name,'CLEAR') IN definition)>0
           OR position(format('(%L, %L)',table_name,'PRESERVE') IN definition)>0 THEN
            RAISE EXCEPTION 'V586 reset policy source missing or already classified: %', table_name;
        END IF;
    END LOOP;
    EXECUTE replace(definition,needle,needle || addition);
END;
$reset_policy$;
