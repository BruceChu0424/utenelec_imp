-- V292: 计划前物料分析生成的采购申请/委外申请，来源单据与备注去 UUID 化。
--
-- 历史数据把「物料分析-<analysis uuid>」整串写进了 source_doc_no / production_plan_no /
-- remark，单据页对业务人员不可读。新代码（MaterialAnalysisCommandService + 两个生产侧
-- facade）已改为可读标签「计划前物料分析 <分析日期>」，销售谱系回溯改按 analysis id
-- 精确关联，不再做字符串匹配。本迁移把存量行一次性改写成同样的口径：
--   来源单据 = 计划前物料分析 <analyzed_at 上海日期>
--   备注     = 计划前物料分析 <日期> 备料任务自动生成（采购）/ …委外备料任务自动生成（委外）
-- 采购订货及下游单据的来源列继承申请行（source_doc_no / production_plan_no），一并改写，
-- 保持全链路口径一致。改写仅匹配生成器写入的精确前缀，不触碰人工编辑过的备注。

-- 1) 采购申请（表头）
UPDATE purchase_requests r
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'),
    remark = CASE
        WHEN r.remark = '生产计划 物料分析-' || a.id::text || ' 未覆盖物料自动生成'
            THEN '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD') || ' 备料任务自动生成'
        ELSE replace(
            r.remark,
            '生产计划 物料分析-' || a.id::text,
            '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'))
    END
FROM production_material_analyses a
WHERE r.source_doc_no = '物料分析-' || a.id::text;

-- 2) 采购申请明细
UPDATE purchase_request_items i
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'),
    production_plan_no = CASE
        WHEN i.production_plan_no = '物料分析-' || a.id::text
            THEN '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD')
        ELSE i.production_plan_no
    END
FROM production_material_analyses a
WHERE i.source_doc_no = '物料分析-' || a.id::text;

-- 3) 委外申请（表头）
UPDATE subcontract_applications s
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'),
    remark = CASE
        WHEN s.remark = '生产计划 物料分析-' || a.id::text || ' 委外来源物料缺口自动生成；供应商待委外部门确认'
            THEN '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD') || ' 委外备料任务自动生成；供应商待委外部门确认'
        ELSE replace(
            s.remark,
            '生产计划 物料分析-' || a.id::text,
            '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'))
    END
FROM production_material_analyses a
WHERE s.source_doc_no = '物料分析-' || a.id::text;

-- 4) 委外申请明细
UPDATE subcontract_application_items i
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD')
FROM production_material_analyses a
WHERE i.source_doc_no = '物料分析-' || a.id::text;

-- 5) 下游继承行（订货/收货明细按同前缀一并改写；当前无存量，防御未来补跑）
UPDATE purchase_order_items i
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'),
    production_plan_no = CASE
        WHEN i.production_plan_no = '物料分析-' || a.id::text
            THEN '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD')
        ELSE i.production_plan_no
    END
FROM production_material_analyses a
WHERE i.source_doc_no = '物料分析-' || a.id::text
   OR i.production_plan_no = '物料分析-' || a.id::text;

UPDATE subcontract_order_items i
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD')
FROM production_material_analyses a
WHERE i.source_doc_no = '物料分析-' || a.id::text;

UPDATE purchase_receipt_items i
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD')
FROM production_material_analyses a
WHERE i.source_doc_no = '物料分析-' || a.id::text;

UPDATE subcontract_receipt_items i
SET source_doc_no = '计划前物料分析 ' || to_char(a.analyzed_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD')
FROM production_material_analyses a
WHERE i.source_doc_no = '物料分析-' || a.id::text;

-- 6) 自制备料需求行：来源编号去 UUID 化。
--    历史值「MAKE-<uuid>」改为「自制备料 <行创建日> <id前4位>」，
--    与新代码（MaterialAnalysisCommandService#nextMakeSourceRef）的生成口径一致；
--    尾码取自条目 id，满足 (source_type, source_ref) 全局唯一索引。
--    注：preplan_supply_actions.external_document_no 受 append-only 触发器保护不可改写；
--    其 MAKE 短码不进任何用户界面（界面只展示采购/委外路线单号），保留原值。
UPDATE production_material_analysis_items i
SET source_ref = '自制备料 '
    || to_char(i.created_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD')
    || ' ' || left(i.id::text, 4)
WHERE i.source_type = 'MAKE_COMPONENT'
  AND i.source_ref LIKE 'MAKE-%';
