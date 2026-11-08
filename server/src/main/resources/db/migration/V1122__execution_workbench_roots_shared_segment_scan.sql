-- =====================================================================
-- V1122：生产执行根视图共享一次段视图求值（2026-11-07 系统读取性能根治 W2；
-- 2026-11-08 合入 main 时按 V1115 的根视图形状重新锚定）
--
-- v_production_execution_workbench_roots 的聚合各自展开一次
-- v_production_execution_workbench_segments：每次展开都重跑计划谱系递归、逐段
-- 谱系查找、需求/预留聚合与齐套函数，取数据页或单个根时整段视图被算多遍。
-- V1115 把顶层完工进度与顶层产品/颜色摘要改读公共顶层口径
-- （v_production_workbench_top_level_segments，Java 完工计数共用同一口径），根视图里
-- 仍有 5 处直接展开段视图：段汇总、关联订单、车间计数、车间预览、数量摘要。
-- 本迁移沿用 V923/V1121 的锚点校验 + pg_get_viewdef 原地改写：这 5 处改读同一个
-- MATERIALIZED CTE，段视图在根视图里只直接求值一次；CTE 只取这些聚合实际读取的列，
-- 段视图里只供其他读者使用的列（如 blocked_reason 的物料保管函数、关联订单预览）
-- 不被多算。两处顶层口径读取原样保留，不在根视图里另抄一份顶层判定。
-- 聚合、根集合、状态口径、列集与列序都不变。
-- =====================================================================
DO $$
DECLARE
    definition text;
    shared_rows constant text :=
        'workbench_segment_facts AS MATERIALIZED ('
        || ' SELECT segment_id, plan_id, root_type, root_id, segment_code, segment_status,'
        || ' material_status, warehouse_ready, issued, reportable,'
        || ' workshop_department_id, workshop_name, product_unit_name, planned_qty,'
        || ' reported_qty, fqc_pending_qty, fqc_passed_qty, fqc_failed_qty,'
        || ' finished_inbound_pending_qty, inbound_qty, plan_begin_date, plan_end_date'
        || ' FROM v_production_execution_workbench_segments shared_segment)';
    -- segment_rollup 的派生表是 v_segments.* 加段号序号；pg_get_viewdef 把星号展开成
    -- 当时段视图的全部列，改读共享 CTE 时还原成星号。
    rollup_rows constant text :=
        '\( SELECT v_segments\.segment_id,.*?'
        || 'row_number\(\) OVER \(PARTITION BY v_segments\.root_type, v_segments\.root_id'
        || ' ORDER BY v_segments\.segment_code\) AS code_position\s+'
        || 'FROM v_production_execution_workbench_segments v_segments\) task';
    segment_view constant text := 'v_production_execution_workbench_segments';
    segment_task_reads constant text := 'FROM v_production_execution_workbench_segments task';
    top_level_reads constant text := 'FROM v_production_workbench_top_level_segments task';
BEGIN
    SELECT pg_get_viewdef('v_production_execution_workbench_roots'::regclass, TRUE) INTO definition;
    -- V1115 形状：段汇总 1 处 + 关联订单/车间计数/车间预览/数量摘要 4 处直接读段视图，
    -- 顶层完工进度与顶层产品事实 2 处读公共顶层口径。
    IF definition !~ '^\s*WITH analysis_roots AS \('
       OR (length(definition) - length(replace(definition, segment_view, ''))) / length(segment_view) <> 5
       OR (length(definition) - length(replace(definition, segment_task_reads, '')))
           / length(segment_task_reads) <> 4
       OR (length(definition) - length(replace(definition, top_level_reads, '')))
           / length(top_level_reads) <> 2
       OR strpos(definition, 'workbench_segment_facts') > 0
       OR (SELECT count(*) FROM regexp_matches(definition, rollup_rows, 'g')) <> 1 THEN
        RAISE EXCEPTION 'Execution workbench root rollup anchors changed';
    END IF;
    definition := regexp_replace(definition, rollup_rows,
        '( SELECT v_segments.*, row_number() OVER (PARTITION BY v_segments.root_type,'
        || ' v_segments.root_id ORDER BY v_segments.segment_code) AS code_position'
        || ' FROM workbench_segment_facts v_segments) task');
    definition := replace(definition, segment_task_reads, 'FROM workbench_segment_facts task');
    definition := regexp_replace(definition, '^\s*WITH analysis_roots AS \(',
        ' WITH ' || shared_rows || ', analysis_roots AS (');
    IF (length(definition) - length(replace(definition, segment_view, ''))) / length(segment_view) <> 1 THEN
        RAISE EXCEPTION 'Execution workbench roots still expand the segment view per rollup';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW v_production_execution_workbench_roots AS ' || definition;
    EXECUTE format('COMMENT ON VIEW v_production_execution_workbench_roots IS %L',
        concat_ws(' ', obj_description('v_production_execution_workbench_roots'::regclass, 'pg_class'),
            'V1122: the direct segment-view rollups read one materialized evaluation'
            || ' (V1115 expanded the segment view once per rollup); the top-level caliber'
            || ' reads stay on v_production_workbench_top_level_segments.'));
END;
$$;
