-- =====================================================================
-- V1122：生产执行根视图共享一次段视图求值（2026-11-07 系统读取性能根治 W2）
--
-- v_production_execution_workbench_roots（V1094）的 8 个聚合各自展开一次
-- v_production_execution_workbench_segments：每次展开都重跑计划谱系递归、逐段
-- 谱系查找、需求/预留聚合与齐套函数，取数据页或单个根时整段视图被算 8 遍。
-- 本迁移沿用 V923/V1121 的锚点校验 + pg_get_viewdef 原地改写：段视图只在一个
-- MATERIALIZED CTE 里求值一次，8 个聚合共享同一份段事实；CTE 只取聚合实际读取
-- 的列，段视图里只供其他读者使用的列（如 blocked_reason 的物料保管函数、
-- 关联订单预览）不被多算。8 个聚合、根集合、状态口径、列集与列序都不变。
-- =====================================================================
DO $$
DECLARE
    definition text;
    shared_rows constant text :=
        'workbench_segment_facts AS MATERIALIZED ('
        || ' SELECT segment_id, plan_id, root_type, root_id, segment_code, segment_status,'
        || ' material_status, warehouse_ready, issued, reportable,'
        || ' workshop_department_id, workshop_name, product_goods_id, product_code,'
        || ' product_name, product_color_name, product_unit_name, planned_qty,'
        || ' reported_qty, fqc_pending_qty, fqc_passed_qty, fqc_failed_qty,'
        || ' finished_inbound_pending_qty, inbound_qty, planned_inbound_qty,'
        || ' plan_begin_date, plan_end_date'
        || ' FROM v_production_execution_workbench_segments shared_segment)';
    -- segment_rollup 的派生表在 V1094 里是 v_segments.* 加段号序号；pg_get_viewdef
    -- 把星号展开成当时段视图的全部列，改读共享 CTE 时还原成星号。
    rollup_rows constant text :=
        '\( SELECT v_segments\.segment_id,.*?'
        || 'row_number\(\) OVER \(PARTITION BY v_segments\.root_type, v_segments\.root_id'
        || ' ORDER BY v_segments\.segment_code\) AS code_position\s+'
        || 'FROM v_production_execution_workbench_segments v_segments\) task';
    segment_reads integer;
BEGIN
    SELECT pg_get_viewdef('v_production_execution_workbench_roots'::regclass, TRUE) INTO definition;
    segment_reads := (length(definition)
        - length(replace(definition, 'v_production_execution_workbench_segments', '')))
        / length('v_production_execution_workbench_segments');
    IF definition !~ '^\s*WITH analysis_roots AS \('
       OR segment_reads <> 8
       OR strpos(definition, 'workbench_segment_facts') > 0
       OR (SELECT count(*) FROM regexp_matches(definition, rollup_rows, 'g')) <> 1
       OR (length(definition)
           - length(replace(definition, 'FROM v_production_execution_workbench_segments task', '')))
           / length('FROM v_production_execution_workbench_segments task') <> 7 THEN
        RAISE EXCEPTION 'Execution workbench root rollup anchors changed';
    END IF;
    definition := regexp_replace(definition, rollup_rows,
        '( SELECT v_segments.*, row_number() OVER (PARTITION BY v_segments.root_type,'
        || ' v_segments.root_id ORDER BY v_segments.segment_code) AS code_position'
        || ' FROM workbench_segment_facts v_segments) task');
    definition := replace(definition,
        'FROM v_production_execution_workbench_segments task',
        'FROM workbench_segment_facts task');
    definition := regexp_replace(definition, '^\s*WITH analysis_roots AS \(',
        ' WITH ' || shared_rows || ', analysis_roots AS (');
    IF (length(definition)
        - length(replace(definition, 'v_production_execution_workbench_segments', '')))
        / length('v_production_execution_workbench_segments') <> 1 THEN
        RAISE EXCEPTION 'Execution workbench roots still expand the segment view per rollup';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW v_production_execution_workbench_roots AS ' || definition;
    EXECUTE format('COMMENT ON VIEW v_production_execution_workbench_roots IS %L',
        concat_ws(' ', obj_description('v_production_execution_workbench_roots'::regclass, 'pg_class'),
            'V1122: every rollup reads one materialized evaluation of the segment view'
            || ' (V1094 expanded the segment view once per rollup).'));
END;
$$;
