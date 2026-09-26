-- V720 汇总下单通道的来源标签并入 V719 编号口径（2026-09-25 用户实机反馈：
-- 「采购员/委外的计划号那里没有修改」——同料合并走汇总通道的单据写的是
-- 「物料分析汇总 <日期>」，V719 只回写了经典通道的「计划前物料分析 <日期>」）。
-- 汇总批次锚定单一分析（preplan_aggregate_batches.analysis_id），文档级映射无歧义：
-- 按 preplan_supply_actions / 订货行来源表（V463）把能精确回溯的
-- 「物料分析汇总 <日期>」展示字符串回写成 WL 分析编号；多来源合并且指向不同
-- 分析的行、无法回溯的行保留原日期标签。不加表、不动任何数量与关联。

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
        '^物料分析汇总 [0-9]{4}-[0-9]{2}-[0-9]{2}', request_owner.analysis_no)
FROM request_owner
WHERE request.id = request_owner.request_id
  AND (request.source_doc_no LIKE '物料分析汇总 %'
       OR request.remark LIKE '物料分析汇总 %');

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
  AND (item.source_doc_no LIKE '物料分析汇总 %'
       OR item.production_plan_no LIKE '物料分析汇总 %');

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
  AND (item.source_doc_no LIKE '物料分析汇总 %'
       OR item.production_plan_no LIKE '物料分析汇总 %');

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
  AND "order".source_doc_no LIKE '物料分析汇总 %';

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
  AND (item.source_doc_no LIKE '物料分析汇总 %'
       OR item.production_plan_no LIKE '物料分析汇总 %');

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
        '^物料分析汇总 [0-9]{4}-[0-9]{2}-[0-9]{2}', application_owner.analysis_no)
FROM application_owner
WHERE application.id = application_owner.application_id
  AND (application.source_doc_no LIKE '物料分析汇总 %'
       OR application.remark LIKE '物料分析汇总 %');

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
  AND item.source_doc_no LIKE '物料分析汇总 %';

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
  AND item.source_doc_no LIKE '物料分析汇总 %';

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
  AND "order".source_doc_no LIKE '物料分析汇总 %';

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
  AND item.source_doc_no LIKE '物料分析汇总 %';
