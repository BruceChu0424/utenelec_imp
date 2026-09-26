-- V719 物料分析编号（2026-09-25 用户口径「计划单号改成数字，同一天不同分析不同号」）：
-- 物料分析此前没有单号，各处以 '物料分析 ' || id前8位 现算标签，采购/委外来源又只落
-- 「计划前物料分析 <日期>」字符串——同日多张分析无法区分也无法排序。本迁移：
--   ① 注册 WL 命名空间（V279 DocNumberService 口径：WL+YYYYMMDD+6位日流水，终身占号）；
--   ② production_material_analyses 增加 analysis_no，存量按上海日期逐日回填序号；
--   ③ 把日流水播种进 business_document_sequences，新分配从存量之后继续；
--   ④ 把采购/委外链上能经 preplan_supply_actions / 订货行来源表精确回溯到分析的
--      「计划前物料分析 <日期>」展示字符串回写成编号（无法唯一回溯的保留原标签）；
--   ⑤ 执行工作台根视图 root_label 优先显示编号（无编号的测试夹具行回退旧短号）。
-- analysis_no 允许 NULL：测试夹具直接 INSERT 最小列集，且预览入口是唯一生产写入方
--（preview 总是带号）；完整性由 UNIQUE + 格式 CHECK 保证，不挂 V279 逐表占号触发器。

-- ① 单号命名空间（DocNumberPrefix.MATERIAL_ANALYSIS 镜像）。
INSERT INTO business_identifier_namespaces (
    namespace_key, identifier_family, fixed_prefix,
    source_table, identifier_column, discriminator_value)
VALUES ('MATERIAL_ANALYSIS', 'DOCUMENT', 'WL',
        'production_material_analyses', 'analysis_no', NULL)
ON CONFLICT (namespace_key) DO NOTHING;

-- ② 列 + 存量回填：同一上海日内按 analyzed_at, id 升序 1..n。
ALTER TABLE production_material_analyses ADD COLUMN analysis_no TEXT;

WITH ranked AS (
    SELECT id,
           row_number() OVER (
               PARTITION BY (analyzed_at AT TIME ZONE 'Asia/Shanghai')::date
               ORDER BY analyzed_at, id) AS seq,
           (analyzed_at AT TIME ZONE 'Asia/Shanghai')::date AS seq_date
    FROM production_material_analyses
    WHERE analysis_no IS NULL
)
UPDATE production_material_analyses analysis
SET analysis_no = 'WL' || to_char(ranked.seq_date, 'YYYYMMDD')
                  || lpad(ranked.seq::text, 6, '0')
FROM ranked
WHERE ranked.id = analysis.id;

ALTER TABLE production_material_analyses
    ADD CONSTRAINT production_material_analysis_no_uk UNIQUE (analysis_no),
    ADD CONSTRAINT production_material_analysis_no_chk CHECK (
        analysis_no IS NULL OR analysis_no ~ '^WL[0-9]{14}$');

COMMENT ON COLUMN production_material_analyses.analysis_no IS
    '分析编号 WL+YYYYMMDD+6位日流水（V279 口径）；只用于识别/搜索/来源展示，关联与幂等始终用 UUID；preview 是唯一生产写入方';

-- ③ 日流水播种：每个有存量的日期把 last_seq 推到已回填的最大序号。
INSERT INTO business_document_sequences (namespace_key, sequence_date, last_seq)
SELECT 'MATERIAL_ANALYSIS',
       (analyzed_at AT TIME ZONE 'Asia/Shanghai')::date,
       COUNT(*)
FROM production_material_analyses
WHERE analysis_no IS NOT NULL
GROUP BY (analyzed_at AT TIME ZONE 'Asia/Shanghai')::date
ON CONFLICT (namespace_key, sequence_date)
DO UPDATE SET last_seq = GREATEST(
    business_document_sequences.last_seq, EXCLUDED.last_seq);

-- ④ 谱系展示字符串回写。映射源 = preplan_supply_actions(分析 → 外部单据)；
--    订货/收货行经 V463 来源分配表回到申请行再回分析。多来源合并且指向不同分析的
--    行没有唯一归属，保留原日期标签。
WITH request_owner AS (
    SELECT DISTINCT action.external_document_id AS request_id,
           analysis.analysis_no
    FROM preplan_supply_actions action
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    WHERE action.external_document_type = 'PURCHASE_REQUEST'
      AND action.external_document_id IS NOT NULL
)
UPDATE purchase_requests request
SET source_doc_no = request_owner.analysis_no,
    remark = regexp_replace(request.remark,
        '^计划前物料分析 [0-9]{4}-[0-9]{2}-[0-9]{2}', request_owner.analysis_no)
FROM request_owner
WHERE request.id = request_owner.request_id
  AND (request.source_doc_no LIKE '计划前物料分析 %'
       OR request.remark LIKE '计划前物料分析 %');

WITH request_owner AS (
    SELECT DISTINCT action.external_document_id AS request_id,
           analysis.analysis_no
    FROM preplan_supply_actions action
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    WHERE action.external_document_type = 'PURCHASE_REQUEST'
      AND action.external_document_id IS NOT NULL
)
UPDATE purchase_request_items item
SET source_doc_no = request_owner.analysis_no,
    production_plan_no = request_owner.analysis_no
FROM request_owner
WHERE item.request_id = request_owner.request_id
  AND (item.source_doc_no LIKE '计划前物料分析 %'
       OR item.production_plan_no LIKE '计划前物料分析 %');

-- 订货行（多来源行须唯一归属才回写）。
WITH order_item_owner AS (
    SELECT source.order_item_id,
           MIN(analysis.analysis_no) AS analysis_no
    FROM purchase_order_item_sources source
    JOIN purchase_request_items request_item
      ON request_item.id = source.request_item_id
    JOIN preplan_supply_actions action
      ON action.external_document_type = 'PURCHASE_REQUEST'
     AND action.external_document_id = request_item.request_id
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    GROUP BY source.order_item_id
    HAVING COUNT(DISTINCT analysis.analysis_no) = 1
)
UPDATE purchase_order_items item
SET source_doc_no = order_item_owner.analysis_no,
    production_plan_no = order_item_owner.analysis_no
FROM order_item_owner
WHERE item.id = order_item_owner.order_item_id
  AND (item.source_doc_no LIKE '计划前物料分析 %'
       OR item.production_plan_no LIKE '计划前物料分析 %');

WITH order_owner AS (
    SELECT item.order_id,
           MIN(analysis.analysis_no) AS analysis_no
    FROM purchase_order_items item
    JOIN purchase_order_item_sources source ON source.order_item_id = item.id
    JOIN purchase_request_items request_item
      ON request_item.id = source.request_item_id
    JOIN preplan_supply_actions action
      ON action.external_document_type = 'PURCHASE_REQUEST'
     AND action.external_document_id = request_item.request_id
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    GROUP BY item.order_id
    HAVING COUNT(DISTINCT analysis.analysis_no) = 1
)
UPDATE purchase_orders "order"
SET source_doc_no = order_owner.analysis_no
FROM order_owner
WHERE "order".id = order_owner.order_id
  AND "order".source_doc_no LIKE '计划前物料分析 %';

-- 收货行经订货行回到来源分配。
WITH receipt_item_owner AS (
    SELECT receipt_item.id AS receipt_item_id,
           MIN(analysis.analysis_no) AS analysis_no
    FROM purchase_receipt_items receipt_item
    JOIN purchase_order_items order_item ON order_item.id = receipt_item.order_item_id
    JOIN purchase_order_item_sources source ON source.order_item_id = order_item.id
    JOIN purchase_request_items request_item
      ON request_item.id = source.request_item_id
    JOIN preplan_supply_actions action
      ON action.external_document_type = 'PURCHASE_REQUEST'
     AND action.external_document_id = request_item.request_id
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    GROUP BY receipt_item.id
    HAVING COUNT(DISTINCT analysis.analysis_no) = 1
)
UPDATE purchase_receipt_items item
SET source_doc_no = receipt_item_owner.analysis_no,
    production_plan_no = receipt_item_owner.analysis_no
FROM receipt_item_owner
WHERE item.id = receipt_item_owner.receipt_item_id
  AND (item.source_doc_no LIKE '计划前物料分析 %'
       OR item.production_plan_no LIKE '计划前物料分析 %');

-- 委外申请（SUBCONTRACT_APPLICATION）同链路；委外明细只有 source_doc_no。
WITH application_owner AS (
    SELECT DISTINCT action.external_document_id AS application_id,
           analysis.analysis_no
    FROM preplan_supply_actions action
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    WHERE action.external_document_type = 'SUBCONTRACT_APPLICATION'
      AND action.external_document_id IS NOT NULL
)
UPDATE subcontract_applications application
SET source_doc_no = application_owner.analysis_no,
    remark = regexp_replace(application.remark,
        '^计划前物料分析 [0-9]{4}-[0-9]{2}-[0-9]{2}', application_owner.analysis_no)
FROM application_owner
WHERE application.id = application_owner.application_id
  AND (application.source_doc_no LIKE '计划前物料分析 %'
       OR application.remark LIKE '计划前物料分析 %');

WITH application_owner AS (
    SELECT DISTINCT action.external_document_id AS application_id,
           analysis.analysis_no
    FROM preplan_supply_actions action
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    WHERE action.external_document_type = 'SUBCONTRACT_APPLICATION'
      AND action.external_document_id IS NOT NULL
)
UPDATE subcontract_application_items item
SET source_doc_no = application_owner.analysis_no
FROM application_owner
WHERE item.application_id = application_owner.application_id
  AND item.source_doc_no LIKE '计划前物料分析 %';

WITH order_item_owner AS (
    SELECT source.order_item_id,
           MIN(analysis.analysis_no) AS analysis_no
    FROM subcontract_order_item_sources source
    JOIN subcontract_application_items application_item
      ON application_item.id = source.application_item_id
    JOIN preplan_supply_actions action
      ON action.external_document_type = 'SUBCONTRACT_APPLICATION'
     AND action.external_document_id = application_item.application_id
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    GROUP BY source.order_item_id
    HAVING COUNT(DISTINCT analysis.analysis_no) = 1
)
UPDATE subcontract_order_items item
SET source_doc_no = order_item_owner.analysis_no
FROM order_item_owner
WHERE item.id = order_item_owner.order_item_id
  AND item.source_doc_no LIKE '计划前物料分析 %';

WITH order_owner AS (
    SELECT item.order_id,
           MIN(analysis.analysis_no) AS analysis_no
    FROM subcontract_order_items item
    JOIN subcontract_order_item_sources source ON source.order_item_id = item.id
    JOIN subcontract_application_items application_item
      ON application_item.id = source.application_item_id
    JOIN preplan_supply_actions action
      ON action.external_document_type = 'SUBCONTRACT_APPLICATION'
     AND action.external_document_id = application_item.application_id
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    GROUP BY item.order_id
    HAVING COUNT(DISTINCT analysis.analysis_no) = 1
)
UPDATE subcontract_orders "order"
SET source_doc_no = order_owner.analysis_no
FROM order_owner
WHERE "order".id = order_owner.order_id
  AND "order".source_doc_no LIKE '计划前物料分析 %';

WITH receipt_item_owner AS (
    SELECT receipt_item.id AS receipt_item_id,
           MIN(analysis.analysis_no) AS analysis_no
    FROM subcontract_receipt_items receipt_item
    JOIN subcontract_order_items order_item ON order_item.id = receipt_item.order_item_id
    JOIN subcontract_order_item_sources source ON source.order_item_id = order_item.id
    JOIN subcontract_application_items application_item
      ON application_item.id = source.application_item_id
    JOIN preplan_supply_actions action
      ON action.external_document_type = 'SUBCONTRACT_APPLICATION'
     AND action.external_document_id = application_item.application_id
    JOIN production_material_analyses analysis
      ON analysis.id = action.analysis_id
    GROUP BY receipt_item.id
    HAVING COUNT(DISTINCT analysis.analysis_no) = 1
)
UPDATE subcontract_receipt_items item
SET source_doc_no = receipt_item_owner.analysis_no
FROM receipt_item_owner
WHERE item.id = receipt_item_owner.receipt_item_id
  AND item.source_doc_no LIKE '计划前物料分析 %';

-- ⑤ 执行工作台根视图：分析根优先显示编号（V696 全量重建，仅 root_label 一处改动）。
CREATE OR REPLACE VIEW v_production_execution_workbench_roots AS
WITH analysis_roots AS (
    SELECT 'ANALYSIS'::text AS root_type,
           analysis.id AS root_id,
           analysis.maker_id AS owner_employee_id,
           maker.full_name AS owner_employee_name,
           COALESCE(analysis.analysis_no,
                    '物料分析 ' || left(analysis.id::text, 8)) AS root_label,
           analysis.status AS source_status,
           analysis.analyzed_at
    FROM production_material_analyses analysis
    LEFT JOIN employees maker ON maker.id = analysis.maker_id
    WHERE analysis.is_deleted = FALSE AND analysis.status <> 'CANCELLED'
), legacy_roots AS (
    SELECT 'PLAN'::text AS root_type,
           plan.id AS root_id,
           plan.maker_id AS owner_employee_id,
           maker.full_name AS owner_employee_name,
           COALESCE(plan.bill_no,
                    '历史计划 ' || left(plan.id::text, 8)) AS root_label,
           plan.status::text AS source_status,
           plan.created_at AS analyzed_at
    FROM production_plans plan
    LEFT JOIN employees maker ON maker.id = plan.maker_id
    WHERE plan.is_deleted = FALSE AND plan.material_analysis_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM subplan_links parent_link
          WHERE parent_link.subplan_id = plan.id
            AND parent_link.is_deleted = FALSE)
), roots AS (
    SELECT * FROM analysis_roots
    UNION ALL
    SELECT * FROM legacy_roots
),
-- 根分析行（顶层产品）：锚点子件行（MAKE_COMPONENT / SUBCONTRACT_MAKE）与
-- 其余带父行都不是顶层；顶层进度只统计这些行的计划段。
root_analysis_items AS (
    SELECT item.analysis_id, item.id
    FROM production_material_analysis_items item
    WHERE item.is_deleted = FALSE
      AND item.parent_analysis_material_id IS NULL
      AND item.source_type NOT IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
),
-- 顶层完工进度：只聚合根分析行（PLAN 根全量）的计划/实收入库数量。
-- 子件锚点段与委外前置段的完工不冒充顶层产品进度。
root_progress_rollup AS (
    SELECT task.root_type, task.root_id,
           SUM(task.planned_qty) AS root_planned_qty,
           SUM(LEAST(task.planned_inbound_qty, task.planned_qty))
               AS root_inbound_qty
    FROM v_production_execution_workbench_segments task
    JOIN production_plans plan
      ON plan.id = task.plan_id AND plan.is_deleted = FALSE
    LEFT JOIN root_analysis_items root_item
      ON root_item.analysis_id = plan.material_analysis_id
     AND root_item.id = plan.material_analysis_item_id
    WHERE task.root_type = 'PLAN'
       OR (task.root_type = 'ANALYSIS' AND root_item.id IS NOT NULL)
    GROUP BY task.root_type, task.root_id
),
-- 单趟段聚合：全部计数与工单号预览来自一次段视图扫描（V470 每根各扫一次）。
segment_rollup AS (
    SELECT task.root_type,
           task.root_id,
           COUNT(DISTINCT task.plan_id)::integer AS plan_count,
           COUNT(*)::integer AS segment_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED'))::integer AS open_segment_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'WAITING')::integer AS waiting_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'READY')::integer AS ready_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'DISPATCHED')::integer AS dispatched_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'IN_PROGRESS')::integer AS in_progress_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'COMPLETED')::integer AS completed_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED')
               AND task.material_status = 'KIT_READY')::integer AS material_ready_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED') AND task.warehouse_ready)::integer
               AS warehouse_ready_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED') AND task.issued)::integer AS issued_count,
           COUNT(*) FILTER (WHERE task.reportable)::integer AS reportable_count,
           COUNT(*) FILTER (WHERE task.fqc_pending_qty > 0)::integer AS fqc_pending_count,
           COUNT(*) FILTER (WHERE task.finished_inbound_pending_qty > 0)::integer
               AS finished_pending_count,
           MIN(task.plan_begin_date) AS earliest_begin_date,
           MAX(task.plan_end_date) AS latest_end_date,
           string_agg(task.segment_code, ' / ' ORDER BY task.segment_code)
               FILTER (WHERE task.code_position <= 3) AS work_order_preview
    FROM (
        SELECT v_segments.*,
               row_number() OVER (
                   PARTITION BY v_segments.root_type, v_segments.root_id
                   ORDER BY v_segments.segment_code) AS code_position
        FROM v_production_execution_workbench_segments v_segments
    ) task
    GROUP BY task.root_type, task.root_id
),
-- 关联订单：段→销售分摊 + 分析来源行，两路合并后按订单去重、按根聚合。
sales_order_rollup AS (
    SELECT source.root_type, source.root_id,
           COUNT(*)::integer AS total,
           string_agg(source.bill_no, ' / ' ORDER BY source.bill_no)
               FILTER (WHERE source.position <= 3) AS preview
    FROM (
        SELECT grouped.root_type, grouped.root_id, grouped.order_id,
               MIN(grouped.bill_no) AS bill_no,
               row_number() OVER (
                   PARTITION BY grouped.root_type, grouped.root_id
                   ORDER BY MIN(grouped.bill_no), grouped.order_id) AS position
        FROM (
            SELECT task.root_type, task.root_id,
                   sales_order.id AS order_id, sales_order.bill_no
            FROM v_production_execution_workbench_segments task
            JOIN execution_segment_sales_allocations allocation
              ON allocation.execution_segment_id = task.segment_id
            JOIN sales_order_items sales_item
              ON sales_item.id = allocation.sales_order_item_id
            JOIN sales_orders sales_order ON sales_order.id = sales_item.order_id
            UNION ALL
            SELECT 'ANALYSIS', analysis_item.analysis_id,
                   sales_order.id, sales_order.bill_no
            FROM production_material_analysis_items analysis_item
            JOIN sales_order_items sales_item
              ON sales_item.id = analysis_item.sales_order_item_id
            JOIN sales_orders sales_order ON sales_order.id = sales_item.order_id
            WHERE analysis_item.is_deleted = FALSE
        ) grouped
        GROUP BY grouped.root_type, grouped.root_id, grouped.order_id
    ) source
    GROUP BY source.root_type, source.root_id
),
-- 生产车间：计数按车间部门去重；预览按车间名去重取前三个（两套口径与 V470 相同）。
workshop_count_rollup AS (
    SELECT task.root_type, task.root_id,
           COUNT(DISTINCT task.workshop_department_id)::integer AS total
    FROM v_production_execution_workbench_segments task
    GROUP BY task.root_type, task.root_id
), workshop_preview_rollup AS (
    SELECT distinct_ws.root_type, distinct_ws.root_id,
           string_agg(distinct_ws.workshop_name, ' / '
                      ORDER BY distinct_ws.workshop_name)
               FILTER (WHERE distinct_ws.position <= 3) AS preview
    FROM (
        SELECT ranked.root_type, ranked.root_id, ranked.workshop_name,
               row_number() OVER (
                   PARTITION BY ranked.root_type, ranked.root_id
                   ORDER BY ranked.workshop_name) AS position
        FROM (
            SELECT DISTINCT task.root_type, task.root_id, task.workshop_name
            FROM v_production_execution_workbench_segments task
            WHERE task.workshop_name IS NOT NULL
        ) ranked
    ) distinct_ws
    GROUP BY distinct_ws.root_type, distinct_ws.root_id
),
-- 产品颜色：两路原始行合并去重取前三个（V490 前保持与 V470 完全同源）。
color_rollup AS (
    SELECT distinct_colors.root_type, distinct_colors.root_id,
           string_agg(distinct_colors.color_name, ' / '
                      ORDER BY distinct_colors.color_name)
               FILTER (WHERE distinct_colors.position <= 3) AS preview
    FROM (
        SELECT ranked.root_type, ranked.root_id, ranked.color_name,
               row_number() OVER (
                   PARTITION BY ranked.root_type, ranked.root_id
                   ORDER BY ranked.color_name) AS position
        FROM (
            SELECT DISTINCT task.root_type, task.root_id, task.product_color_name AS color_name
            FROM v_production_execution_workbench_segments task
            WHERE task.product_color_name IS NOT NULL
            UNION
            SELECT 'ANALYSIS', analysis_item.analysis_id, color.name
            FROM production_material_analysis_items analysis_item
            JOIN colors color ON color.id = analysis_item.color_id
            WHERE analysis_item.is_deleted = FALSE AND color.name IS NOT NULL
        ) ranked
    ) distinct_colors
    GROUP BY distinct_colors.root_type, distinct_colors.root_id
),
-- 产品：分析来源行 + 段产品两路合并，按货品去重（编码/名称取 MIN，与 V470 相同）。
product_rollup AS (
    SELECT grouped.root_type, grouped.root_id,
           COUNT(*)::integer AS total,
           string_agg(grouped.code, ' / ' ORDER BY grouped.code)
               FILTER (WHERE grouped.position <= 3) AS code_preview,
           string_agg(grouped.name, ' / ' ORDER BY grouped.name)
               FILTER (WHERE grouped.position <= 3) AS name_preview
    FROM (
        SELECT inner_grouped.root_type, inner_grouped.root_id,
               inner_grouped.goods_id, MIN(inner_grouped.code) AS code,
               MIN(inner_grouped.name) AS name,
               row_number() OVER (
                   PARTITION BY inner_grouped.root_type, inner_grouped.root_id
                   ORDER BY MIN(inner_grouped.code), inner_grouped.goods_id) AS position
        FROM (
            SELECT 'ANALYSIS' AS root_type, analysis_item.analysis_id AS root_id,
                   analysis_item.goods_id, goods.code, goods.name
            FROM production_material_analysis_items analysis_item
            JOIN goods ON goods.id = analysis_item.goods_id
            WHERE analysis_item.is_deleted = FALSE
            UNION ALL
            SELECT task.root_type, task.root_id, task.product_goods_id,
                   task.product_code, task.product_name
            FROM v_production_execution_workbench_segments task
        ) inner_grouped
        GROUP BY inner_grouped.root_type, inner_grouped.root_id, inner_grouped.goods_id
    ) grouped
    GROUP BY grouped.root_type, grouped.root_id
),
-- 数量摘要：段按单位聚合；无段的分析根回退按分析行需求聚合（反连已算好的
-- segment_rollup，不再逐行探测段视图）。
quantity_rollup AS (
    SELECT ranked.root_type, ranked.root_id,
           COUNT(*)::integer AS total_units,
           string_agg(
               COALESCE(ranked.unit_name,'单位未维护') || ': 计划 ' || ranked.planned_qty::text
               || ' / 报工 ' || ranked.reported_qty::text
               || ' / FQC待检 ' || ranked.fqc_pending_qty::text
               || ' / 通过 ' || ranked.fqc_passed_qty::text
               || ' / 失败 ' || ranked.fqc_failed_qty::text
               || ' / 待点收 ' || ranked.inbound_pending_qty::text
               || ' / 实收 ' || ranked.inbound_qty::text,
               ' / ' ORDER BY ranked.unit_name) FILTER (WHERE ranked.position <= 3)
               AS preview
    FROM (
        SELECT unit_totals.root_type, unit_totals.root_id,
               unit_totals.unit_name, unit_totals.planned_qty,
               unit_totals.reported_qty, unit_totals.fqc_pending_qty,
               unit_totals.fqc_passed_qty, unit_totals.fqc_failed_qty,
               unit_totals.inbound_pending_qty, unit_totals.inbound_qty,
               row_number() OVER (
                   PARTITION BY unit_totals.root_type, unit_totals.root_id
                   ORDER BY unit_totals.unit_name) AS position
        FROM (
            SELECT task.root_type, task.root_id,
                   task.product_unit_name AS unit_name,
                   SUM(task.planned_qty) AS planned_qty,
                   SUM(task.reported_qty) AS reported_qty,
                   SUM(task.fqc_pending_qty) AS fqc_pending_qty,
                   SUM(task.fqc_passed_qty) AS fqc_passed_qty,
                   SUM(task.fqc_failed_qty) AS fqc_failed_qty,
                   SUM(task.finished_inbound_pending_qty) AS inbound_pending_qty,
                   SUM(task.inbound_qty) AS inbound_qty
            FROM v_production_execution_workbench_segments task
            GROUP BY task.root_type, task.root_id, task.product_unit_name
            UNION ALL
            SELECT 'ANALYSIS', item.analysis_id, unit.name,
                   SUM(item.requested_qty), 0, 0, 0, 0, 0, 0
            FROM production_material_analysis_items item
            JOIN units unit ON unit.id = item.unit_id
            WHERE item.is_deleted = FALSE
              AND NOT EXISTS (
                  SELECT 1 FROM segment_rollup rolled
                  WHERE rolled.root_type = 'ANALYSIS'
                    AND rolled.root_id = item.analysis_id)
            GROUP BY item.analysis_id, unit.name
        ) unit_totals
    ) ranked
    GROUP BY ranked.root_type, ranked.root_id
)
SELECT root.root_type, root.root_id, root.owner_employee_id, root.root_label,
       CASE
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(plan.open_count, 0) > 0 THEN 'PLAN_PENDING'
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(action.open_count, 0) > 0 THEN 'PREPARING'
           WHEN COALESCE(segment.segment_count, 0) = 0 THEN 'ANALYZING'
           WHEN COALESCE(demand.remaining_qty, 0) > 0
             THEN 'PARTIALLY_SCHEDULED'
           WHEN COALESCE(segment.in_progress_count, 0) > 0 THEN 'IN_PROGRESS'
           WHEN COALESCE(segment.issued_count, 0)
               = COALESCE(segment.open_segment_count, 0)
               AND COALESCE(segment.open_segment_count, 0) > 0 THEN 'PREPARED'
           WHEN COALESCE(segment.material_ready_count, 0)
               < COALESCE(segment.open_segment_count, 0) THEN 'KIT_SHORT'
           ELSE 'KIT_READY_PREPARING'
       END AS status,
       sales.preview AS sales_order_preview,
       COALESCE(sales.total, 0)::integer AS sales_order_count,
       COALESCE(sales.total, 0) > 3 AS sales_order_has_more,
       segment.work_order_preview AS work_order_preview,
       COALESCE(segment.segment_count, 0)::integer AS work_order_count,
       COALESCE(segment.segment_count, 0) > 3 AS work_order_has_more,
       workshop_preview.preview AS workshop_preview,
       COALESCE(workshop_count.total, 0)::integer AS workshop_count,
       COALESCE(workshop_count.total, 0) > 3 AS workshop_has_more,
       product.code_preview AS product_code_preview,
       product.name_preview AS product_name_preview,
       color.preview AS product_color_preview,
       COALESCE(product.total, 0)::integer AS product_count,
       COALESCE(product.total, 0) > 3 AS product_has_more,
       quantity.preview AS quantity_summary,
       COALESCE(quantity.total_units, 0) > 1 AS mixed_units,
       COALESCE(quantity.total_units, 0)::integer AS execution_unit_count,
       COALESCE(quantity.total_units, 0) > 3 AS execution_unit_has_more,
       GREATEST(COALESCE(plan.plan_count,0),COALESCE(segment.plan_count,0))::integer AS plan_count,
       COALESCE(segment.segment_count, 0)::integer AS segment_count,
       COALESCE(segment.waiting_count, 0)::integer AS waiting_count,
       COALESCE(segment.ready_count, 0)::integer AS ready_count,
       COALESCE(segment.dispatched_count, 0)::integer AS dispatched_count,
       COALESCE(segment.in_progress_count, 0)::integer AS in_progress_count,
       COALESCE(segment.completed_count, 0)::integer AS completed_count,
       COALESCE(segment.material_ready_count, 0)::integer AS material_ready_count,
       COALESCE(segment.warehouse_ready_count, 0)::integer AS warehouse_ready_count,
       COALESCE(segment.issued_count, 0)::integer AS issued_count,
       COALESCE(segment.reportable_count, 0)::integer AS reportable_count,
       COALESCE(segment.fqc_pending_count, 0)::integer AS fqc_pending_count,
       COALESCE(segment.finished_pending_count, 0)::integer
           AS finished_inbound_pending_count,
       COALESCE(segment.earliest_begin_date, plan.earliest_begin_date)
           AS earliest_begin_date,
       COALESCE(segment.latest_end_date, plan.latest_end_date)
           AS latest_end_date,
       root.source_status,
       COALESCE(demand.remaining_qty, 0)::numeric AS remaining_demand_qty,
       COALESCE(action.open_count, 0)::integer AS open_action_count,
       COALESCE(plan.open_count, 0)::integer AS open_plan_count,
       COALESCE(segment.open_segment_count, 0)::integer AS open_segment_count,
       root.owner_employee_name,
       root.analyzed_at,
       COALESCE(progress.root_planned_qty, 0)::numeric AS root_planned_qty,
       COALESCE(progress.root_inbound_qty, 0)::numeric AS root_inbound_qty,
       CASE WHEN COALESCE(progress.root_planned_qty, 0) > 0
            THEN LEAST(COALESCE(progress.root_inbound_qty, 0)
                       / progress.root_planned_qty, 1)
            ELSE NULL END AS root_progress_ratio
FROM roots root
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(GREATEST(item.requested_qty-item.approved_qty,0)),0)
               AS remaining_qty
    FROM production_material_analysis_items item
    WHERE root.root_type = 'ANALYSIS' AND item.analysis_id = root.root_id
      AND item.is_deleted = FALSE
) demand ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*) FILTER (
               WHERE action.status IN ('OPEN','CREATED','IN_PROGRESS'))::integer
               AS open_count
    FROM preplan_supply_actions action
    WHERE root.root_type = 'ANALYSIS' AND action.analysis_id = root.root_id
) action ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS plan_count,
           COUNT(*) FILTER (
               WHERE plan.status = 0 OR (plan.status = 1
                 AND plan.is_closed = FALSE AND plan.is_stopped = FALSE
                 AND plan.is_canceled = FALSE))::integer AS open_count,
           MIN(plan.bill_date) AS earliest_begin_date,
           MAX(plan.delivery_date) AS latest_end_date
    FROM production_plans plan
    WHERE (root.root_type = 'ANALYSIS'
           AND plan.material_analysis_id = root.root_id
           AND plan.is_deleted = FALSE)
       OR (root.root_type = 'PLAN' AND plan.id = root.root_id
           AND plan.is_deleted = FALSE)
) plan ON TRUE
LEFT JOIN segment_rollup segment
  ON segment.root_type = root.root_type AND segment.root_id = root.root_id
LEFT JOIN sales_order_rollup sales
  ON sales.root_type = root.root_type AND sales.root_id = root.root_id
LEFT JOIN workshop_count_rollup workshop_count
  ON workshop_count.root_type = root.root_type
 AND workshop_count.root_id = root.root_id
LEFT JOIN workshop_preview_rollup workshop_preview
  ON workshop_preview.root_type = root.root_type
 AND workshop_preview.root_id = root.root_id
LEFT JOIN product_rollup product
  ON product.root_type = root.root_type AND product.root_id = root.root_id
LEFT JOIN color_rollup color
  ON color.root_type = root.root_type AND color.root_id = root.root_id
LEFT JOIN quantity_rollup quantity
  ON quantity.root_type = root.root_type AND quantity.root_id = root.root_id
LEFT JOIN root_progress_rollup progress
  ON progress.root_type = root.root_type AND progress.root_id = root.root_id
WHERE (root.root_type='ANALYSIS' AND
       (COALESCE(demand.remaining_qty,0)>0 OR COALESCE(action.open_count,0)>0
        OR COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0))
   OR (root.root_type='PLAN' AND
       (COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0));

COMMENT ON VIEW v_production_execution_workbench_roots IS
    'One bounded row per outer analysis; legacy plans use the outermost plan UUID. V485: single-pass rollups (V470 scanned the segment view once per root per fact). V487: +maker/analyzed_at and top-level root-only completion progress; zero-material flag on the segment view. V719: analysis root_label prefers the WL analysis_no, falling back to the id-8 hex label only when absent.';
