-- =====================================================================
-- V463：订货明细多来源锚定（同货品合并生成订货单）
-- =====================================================================
-- 业务背景（ADR-069）：采购/委外任务工作台多选多条申请（可跨申请单）生成
-- 订货单时，同「货品+颜色+单位」的申请明细合并为一条订货明细、数量加总，
-- 订货单/详情/财务审核/仓库各处只见一行。
--
-- 架构：ADR-065 在申请层拒绝合并行是为了保住「一明细一锚点」。本迁移把
-- 同样的思想下移一层——订货明细仍真合并为一行，但新增「订货行→申请明细」
-- 分配表逐条保留锚点与数量：
--   * purchase_order_item_sources(order_item_id, request_item_id, alloc_qty)
--   * subcontract_order_item_sources(order_item_id, application_item_id, alloc_qty)
-- 数量账（ordered_qty 回写、任务台剩余量、待财务占用）、exact-peg 溯源、
-- 供给进度、分析覆盖统计全部改从 sources 汇总；收货沿订货行入库后在
-- peg/统计侧按 alloc_qty FIFO 分摊到各申请行（末位来源吸收超额，单来源
-- 行为与历史完全一致）。
--
-- 兼容：purchase_order_items.request_item_id / subcontract_order_items.
-- application_item_id 保留为首来源（主锚点），历史行由本迁移回填为
-- 单来源（alloc_qty = 行数量）；单来源行的全部分摊语义与 V463 之前逐位
-- 相同（末位吸收超额 ⇒ 单来源分享 = 全量）。
-- =====================================================================

-- ① 采购订货行来源分配表 ----------------------------------------------

CREATE TABLE purchase_order_item_sources (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_item_id   UUID NOT NULL
        REFERENCES purchase_order_items(id) ON DELETE CASCADE,
    request_item_id UUID NOT NULL
        REFERENCES purchase_request_items(id) ON DELETE RESTRICT,
    alloc_qty       NUMERIC(18,4) NOT NULL,
    line_no         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT purchase_order_item_sources_alloc_chk
        CHECK (alloc_qty > 0),
    CONSTRAINT purchase_order_item_sources_unique
        UNIQUE (order_item_id, request_item_id),
    CONSTRAINT purchase_order_item_sources_line_no_chk
        CHECK (line_no >= 1)
);

CREATE INDEX idx_purchase_order_item_sources_request_item
    ON purchase_order_item_sources(request_item_id);

CREATE TRIGGER trg_audit_purchase_order_item_sources
    AFTER INSERT OR UPDATE OR DELETE ON purchase_order_item_sources
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE purchase_order_item_sources IS
    '采购订货明细的多申请明细来源分配（V463/ADR-069）：一条订货行可锚定多条采购申请明细，'
    'alloc_qty 为该行数量中归属此申请行的份额（FIFO 分配、末位吸收超额）；'
    'SUM(alloc_qty) = 订货行 qty；单来源行与历史 request_item_id 单锚语义一致';

-- ② 委外订货行来源分配表 ----------------------------------------------

CREATE TABLE subcontract_order_item_sources (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_item_id        UUID NOT NULL
        REFERENCES subcontract_order_items(id) ON DELETE CASCADE,
    application_item_id  UUID NOT NULL
        REFERENCES subcontract_application_items(id) ON DELETE RESTRICT,
    alloc_qty            NUMERIC(18,4) NOT NULL,
    line_no              INT NOT NULL DEFAULT 1,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT subcontract_order_item_sources_alloc_chk
        CHECK (alloc_qty > 0),
    CONSTRAINT subcontract_order_item_sources_unique
        UNIQUE (order_item_id, application_item_id),
    CONSTRAINT subcontract_order_item_sources_line_no_chk
        CHECK (line_no >= 1)
);

CREATE INDEX idx_subcontract_order_item_sources_application_item
    ON subcontract_order_item_sources(application_item_id);

CREATE TRIGGER trg_audit_subcontract_order_item_sources
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_order_item_sources
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE subcontract_order_item_sources IS
    '委外订货明细的多申请明细来源分配（V463/ADR-069）：与采购侧对称，'
    'SUM(alloc_qty) = 订货行 qty，单来源行为与历史 application_item_id 单锚一致';

-- ③ 历史行回填：单来源（alloc_qty = 行数量，line_no = 1） ----------------
-- 回填不区分 is_deleted（软删行的锚点记录一并保留，读取侧各视图自带
-- is_deleted 过滤）；ON CONFLICT 幂等，重复执行安全。

INSERT INTO purchase_order_item_sources (
    order_item_id, request_item_id, alloc_qty, line_no)
SELECT oi.id, oi.request_item_id, COALESCE(oi.qty, 0), 1
FROM purchase_order_items oi
WHERE oi.request_item_id IS NOT NULL
  AND COALESCE(oi.qty, 0) > 0
ON CONFLICT (order_item_id, request_item_id) DO NOTHING;

INSERT INTO subcontract_order_item_sources (
    order_item_id, application_item_id, alloc_qty, line_no)
SELECT oi.id, oi.application_item_id, COALESCE(oi.qty, 0), 1
FROM subcontract_order_items oi
WHERE oi.application_item_id IS NOT NULL
  AND COALESCE(oi.qty, 0) > 0
ON CONFLICT (order_item_id, application_item_id) DO NOTHING;

-- ④ 来源 FIFO 分摊函数（供 Java 侧覆盖统计复用） -----------------------
-- 语义：订货行的某个总量 T（BASE 单位，即行单位 × unit_rate）按 sources
-- 顺序（line_no, id）FIFO 分摊；末位来源吸收超额；单来源行 ⇒ 份额 = T
-- 全量（与历史单锚行为逐位一致）。alloc_qty ≤ 0 的来源份额为 0。

CREATE OR REPLACE FUNCTION fn_purchase_order_source_share(
    p_order_item_id UUID,
    p_request_item_id UUID,
    p_total_base NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    WITH bounds AS (
        SELECT src.request_item_id,
               src.alloc_qty * COALESCE(item.unit_rate, 1) AS alloc_base,
               COALESCE(SUM(src.alloc_qty) OVER w, 0)
                   * COALESCE(item.unit_rate, 1)
                   - src.alloc_qty * COALESCE(item.unit_rate, 1) AS prefix_base,
               ROW_NUMBER() OVER w AS rn,
               COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
        FROM purchase_order_item_sources src
        JOIN purchase_order_items item ON item.id = src.order_item_id
        WHERE src.order_item_id = p_order_item_id
        WINDOW w AS (
            PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
    )
    SELECT COALESCE((
        SELECT CASE
            WHEN b.rn = b.source_count
                THEN GREATEST(COALESCE(p_total_base, 0) - b.prefix_base, 0)
            ELSE GREATEST(
                LEAST(b.alloc_base, COALESCE(p_total_base, 0) - b.prefix_base),
                0)
        END
        FROM bounds b
        WHERE b.request_item_id = p_request_item_id
    ), 0);
$$;

CREATE OR REPLACE FUNCTION fn_subcontract_order_source_share(
    p_order_item_id UUID,
    p_application_item_id UUID,
    p_total_base NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    WITH bounds AS (
        SELECT src.application_item_id,
               src.alloc_qty * COALESCE(item.unit_rate, 1) AS alloc_base,
               COALESCE(SUM(src.alloc_qty) OVER w, 0)
                   * COALESCE(item.unit_rate, 1)
                   - src.alloc_qty * COALESCE(item.unit_rate, 1) AS prefix_base,
               ROW_NUMBER() OVER w AS rn,
               COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
        FROM subcontract_order_item_sources src
        JOIN subcontract_order_items item ON item.id = src.order_item_id
        WHERE src.order_item_id = p_order_item_id
        WINDOW w AS (
            PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
    )
    SELECT COALESCE((
        SELECT CASE
            WHEN b.rn = b.source_count
                THEN GREATEST(COALESCE(p_total_base, 0) - b.prefix_base, 0)
            ELSE GREATEST(
                LEAST(b.alloc_base, COALESCE(p_total_base, 0) - b.prefix_base),
                0)
        END
        FROM bounds b
        WHERE b.application_item_id = p_application_item_id
    ), 0);
$$;

-- ⑤ 任务台投影：待财务占用改按 sources 汇总 ---------------------------
-- 列名/类型/顺序与 V301 完全一致（mapRow 按固定列位读 31 列）；
-- 仅 purchase_pending / subcontract_pending 的分组键从
-- oi.request_item_id（行全量）改为 src.request_item_id + src.alloc_qty
-- （来源份额），合并行的占用不再串到首来源一张申请上。

CREATE OR REPLACE VIEW v_procurement_decomposition_tasks AS
WITH purchase_pending AS (
    SELECT src.request_item_id AS source_item_id,
           SUM(COALESCE(src.alloc_qty, 0)) AS pending_qty
    FROM procurement_order_approval_cases approval
    JOIN purchase_orders po
      ON approval.order_type = 'PURCHASE'
     AND approval.order_id = po.id
     AND approval.status = 'PENDING'
    JOIN purchase_order_items oi ON oi.order_id = po.id
    JOIN purchase_order_item_sources src ON src.order_item_id = oi.id
    WHERE po.status = 0
      AND po.is_deleted = FALSE
      AND oi.is_deleted = FALSE
    GROUP BY src.request_item_id
),
subcontract_pending AS (
    SELECT src.application_item_id AS source_item_id,
           SUM(COALESCE(src.alloc_qty, 0)) AS pending_qty
    FROM procurement_order_approval_cases approval
    JOIN subcontract_orders so
      ON approval.order_type = 'SUBCONTRACT'
     AND approval.order_id = so.id
     AND approval.status = 'PENDING'
    JOIN subcontract_order_items oi ON oi.order_id = so.id
    JOIN subcontract_order_item_sources src ON src.order_item_id = oi.id
    WHERE so.status = 0
      AND so.is_deleted = FALSE
      AND oi.is_deleted = FALSE
    GROUP BY src.application_item_id
),
purchase_rows AS (
    SELECT
        'PURCHASE'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.production_plan_no, ''), NULLIF(item.source_doc_no, ''),
                 NULLIF(request.source_doc_no, ''), request.bill_no) AS plan_no,
        request.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'BUY'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS allocated_qty,
        COALESCE(item.ordered_qty, 0) AS fulfilled_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0)
                 - COALESCE(pending.pending_qty, 0), 0) AS open_qty,
        'WAITING_ORDER'::TEXT AS task_status,
        COALESCE(item.deliver_date, request.need_date) AS need_date,
        COALESCE(item.deliver_date, request.need_date) AS expected_date,
        CASE
            WHEN COALESCE(item.deliver_date, request.need_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, request.updated_at) AS updated_at,
        'PURCHASE_REQUEST'::TEXT AS action_doc_type,
        request.id AS action_doc_id,
        request.bill_no AS action_doc_no,
        item.id AS action_item_id,
        request.status::TEXT AS action_doc_status
    FROM purchase_request_items item
    JOIN purchase_requests request ON request.id = item.request_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = request.warehouse_id
    LEFT JOIN purchase_pending pending ON pending.source_item_id = item.id
    WHERE request.status = 1
      AND request.is_deleted = FALSE
      AND request.is_closed = FALSE
      AND item.is_deleted = FALSE
),
purchase_order_pending_rows AS (
    -- 等待财务审核：订货单仍是草稿(status=0)且当前有 PENDING 审批案件。
    -- 任务行让采购员能在任务台找到「已提交、财务未决」的单据；
    -- open_qty = 行全量（申请行侧已等额扣减，待完成总口径不重复）。
    SELECT
        'PURCHASE'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), NULLIF(item.production_plan_no, ''),
                 po.bill_no) AS plan_no,
        po.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'BUY'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        COALESCE(item.qty, 0) AS open_qty,
        'ORDER_PENDING_APPROVAL'::TEXT AS task_status,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
        CASE
            WHEN COALESCE(item.deliver_date, po.deliver_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, po.updated_at) AS updated_at,
        'PURCHASE_ORDER'::TEXT AS action_doc_type,
        po.id AS action_doc_id,
        po.bill_no AS action_doc_no,
        item.id AS action_item_id,
        po.status::TEXT AS action_doc_status
    FROM purchase_order_items item
    JOIN purchase_orders po ON po.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
    WHERE po.status = 0
      AND po.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND EXISTS (
          SELECT 1 FROM procurement_order_approval_cases pend
          WHERE pend.order_type = 'PURCHASE' AND pend.order_id = po.id
            AND pend.status = 'PENDING'
      )
),
purchase_order_rows AS (
    SELECT
        'PURCHASE'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), NULLIF(item.production_plan_no, ''),
                 po.bill_no) AS plan_no,
        po.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'BUY'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.received_qty, 0)
                 + COALESCE(item.returned_qty, 0), 0) AS open_qty,
        CASE WHEN po.is_closed THEN 'COMPLETED' ELSE 'FINANCE_APPROVED' END::TEXT AS task_status,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
        CASE
            WHEN NOT po.is_closed
                 AND COALESCE(item.deliver_date, po.deliver_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, po.updated_at) AS updated_at,
        'PURCHASE_ORDER'::TEXT AS action_doc_type,
        po.id AS action_doc_id,
        po.bill_no AS action_doc_no,
        item.id AS action_item_id,
        po.status::TEXT AS action_doc_status
    FROM purchase_order_items item
    JOIN purchase_orders po ON po.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
    WHERE po.status = 1
      AND po.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND (NOT po.is_closed OR po.updated_at >= CURRENT_DATE - INTERVAL '30 days')
),
purchase_rejected_rows AS (
    -- 财务驳回：订货单提交财务审核后被驳回（status 仍为 0 草稿），且当前无新的待审核
    -- 案件（已驳回未重新提交）。EXISTS/NOT EXISTS 避免多次审核历史导致的行重复。
    SELECT
        'PURCHASE'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), NULLIF(item.production_plan_no, ''),
                 po.bill_no) AS plan_no,
        po.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'BUY'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        COALESCE(item.qty, 0) AS open_qty,
        'FINANCE_REJECTED'::TEXT AS task_status,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
        NULL::TEXT AS exception_code,
        GREATEST(item.updated_at, po.updated_at) AS updated_at,
        'PURCHASE_ORDER'::TEXT AS action_doc_type,
        po.id AS action_doc_id,
        po.bill_no AS action_doc_no,
        item.id AS action_item_id,
        po.status::TEXT AS action_doc_status
    FROM purchase_order_items item
    JOIN purchase_orders po ON po.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
    WHERE po.status = 0
      AND po.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND EXISTS (
          SELECT 1 FROM procurement_order_approval_cases rej
          WHERE rej.order_type = 'PURCHASE' AND rej.order_id = po.id
            AND rej.status = 'REJECTED'
      )
      AND NOT EXISTS (
          SELECT 1 FROM procurement_order_approval_cases pend
          WHERE pend.order_type = 'PURCHASE' AND pend.order_id = po.id
            AND pend.status = 'PENDING'
      )
),
subcontract_rows AS (
    SELECT
        'SUBCONTRACT'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), NULLIF(application.source_doc_no, ''),
                 application.bill_no) AS plan_no,
        application.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'SUBCONTRACT'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS allocated_qty,
        COALESCE(item.ordered_qty, 0) AS fulfilled_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0)
                 - COALESCE(pending.pending_qty, 0), 0) AS open_qty,
        'WAITING_ORDER'::TEXT AS task_status,
        application.need_date AS need_date,
        application.need_date AS expected_date,
        CASE
            WHEN application.need_date < CURRENT_DATE THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, application.updated_at) AS updated_at,
        'SUBCONTRACT_APPLICATION'::TEXT AS action_doc_type,
        application.id AS action_doc_id,
        application.bill_no AS action_doc_no,
        item.id AS action_item_id,
        application.status::TEXT AS action_doc_status
    FROM subcontract_application_items item
    JOIN subcontract_applications application ON application.id = item.application_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = application.warehouse_id
    LEFT JOIN subcontract_pending pending ON pending.source_item_id = item.id
    WHERE application.status = 1
      AND application.is_deleted = FALSE
      AND application.is_closed = FALSE
      AND item.is_deleted = FALSE
),
subcontract_order_pending_rows AS (
    -- 委外等待财务审核：与采购同口径（status=0 + 当前 PENDING 审批案件）。
    SELECT
        'SUBCONTRACT'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), so.bill_no) AS plan_no,
        so.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'SUBCONTRACT'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        COALESCE(item.qty, 0) AS open_qty,
        'ORDER_PENDING_APPROVAL'::TEXT AS task_status,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
        CASE
            WHEN COALESCE(item.deliver_date, so.deliver_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, so.updated_at) AS updated_at,
        'SUBCONTRACT_ORDER'::TEXT AS action_doc_type,
        so.id AS action_doc_id,
        so.bill_no AS action_doc_no,
        item.id AS action_item_id,
        so.status::TEXT AS action_doc_status
    FROM subcontract_order_items item
    JOIN subcontract_orders so ON so.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
    WHERE so.status = 0
      AND so.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND EXISTS (
          SELECT 1 FROM procurement_order_approval_cases pend
          WHERE pend.order_type = 'SUBCONTRACT' AND pend.order_id = so.id
            AND pend.status = 'PENDING'
      )
),
subcontract_order_rows AS (
    -- 委外对齐采购：已生效委外订货单(status=1)的明细行，按 is_closed 分到
    -- FINANCE_APPROVED(待采购完成) / COMPLETED(已完成，近30天)。
    SELECT
        'SUBCONTRACT'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), so.bill_no) AS plan_no,
        so.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'SUBCONTRACT'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.received_qty, 0)
                 + COALESCE(item.returned_qty, 0), 0) AS open_qty,
        CASE WHEN so.is_closed THEN 'COMPLETED' ELSE 'FINANCE_APPROVED' END::TEXT AS task_status,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
        CASE
            WHEN NOT so.is_closed
                 AND COALESCE(item.deliver_date, so.deliver_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, so.updated_at) AS updated_at,
        'SUBCONTRACT_ORDER'::TEXT AS action_doc_type,
        so.id AS action_doc_id,
        so.bill_no AS action_doc_no,
        item.id AS action_item_id,
        so.status::TEXT AS action_doc_status
    FROM subcontract_order_items item
    JOIN subcontract_orders so ON so.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
    WHERE so.status = 1
      AND so.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND (NOT so.is_closed OR so.updated_at >= CURRENT_DATE - INTERVAL '30 days')
),
subcontract_rejected_rows AS (
    -- 委外财务驳回：订货单提交财务审核后被驳回(status 仍 0)，且当前无新的待审核案件。
    SELECT
        'SUBCONTRACT'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), so.bill_no) AS plan_no,
        so.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'SUBCONTRACT'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        COALESCE(item.qty, 0) AS open_qty,
        'FINANCE_REJECTED'::TEXT AS task_status,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
        NULL::TEXT AS exception_code,
        GREATEST(item.updated_at, so.updated_at) AS updated_at,
        'SUBCONTRACT_ORDER'::TEXT AS action_doc_type,
        so.id AS action_doc_id,
        so.bill_no AS action_doc_no,
        item.id AS action_item_id,
        so.status::TEXT AS action_doc_status
    FROM subcontract_order_items item
    JOIN subcontract_orders so ON so.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
    WHERE so.status = 0
      AND so.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND EXISTS (
          SELECT 1 FROM procurement_order_approval_cases rej
          WHERE rej.order_type = 'SUBCONTRACT' AND rej.order_id = so.id
            AND rej.status = 'REJECTED'
      )
      AND NOT EXISTS (
          SELECT 1 FROM procurement_order_approval_cases pend
          WHERE pend.order_type = 'SUBCONTRACT' AND pend.order_id = so.id
            AND pend.status = 'PENDING'
      )
)
SELECT * FROM purchase_rows WHERE open_qty > 0
UNION ALL
SELECT * FROM purchase_order_pending_rows
UNION ALL
SELECT * FROM purchase_order_rows
UNION ALL
SELECT * FROM purchase_rejected_rows
UNION ALL
SELECT * FROM subcontract_rows WHERE open_qty > 0
UNION ALL
SELECT * FROM subcontract_order_pending_rows
UNION ALL
SELECT * FROM subcontract_order_rows
UNION ALL
SELECT * FROM subcontract_rejected_rows;

COMMENT ON VIEW v_procurement_decomposition_tasks IS
    '采购/委外任务中心权威投影（设计对齐）：采购与委外均含 申请待分解(WAITING_ORDER,申请行剩余量,黄) / 等待财务审核(ORDER_PENDING_APPROVAL,V301,蓝) / 财务已通过·待采购完成(FINANCE_APPROVED,已生效订单未收完,青) / 财务驳回(FINANCE_REJECTED,审核未过未重提,红) / 已完成(COMPLETED,近30天收完,绿) 五档；申请行仍扣除已生效和待财务订单占用（V463 起待财务占用按 sources 来源份额汇总，合并订货行不再串占首来源），待完成(open_qty>0)=所有未完成任务';

-- ⑥ BUY 行动切片进度视图：订货行改经 sources 关联并按 FIFO 分摊 -------
-- 列契约与 V446 完全一致；仅把「订货行 ↔ 申请行」的等值连接换成
-- sources 连接，订货行级别的到货/待检/未交数量按 fn_*_source_share 同款
-- FIFO（末位吸收超额）拆到各申请行切片。

CREATE OR REPLACE VIEW v_preplan_buy_action_slice_progress AS
WITH slice_items AS (
    SELECT DISTINCT action.id AS action_id,
           'DEMAND'::TEXT AS slice_type,
           allocation.external_item_id AS request_item_id
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id = action.id
     AND allocation.external_item_id IS NOT NULL
    WHERE action.route = 'BUY'
    UNION ALL
    SELECT action.id, 'SAFETY', action.safety_external_item_id
    FROM preplan_supply_actions action
    WHERE action.route = 'BUY'
      AND action.safety_external_item_id IS NOT NULL
), request_progress AS (
    SELECT slice.action_id, slice.slice_type,
           COUNT(*)::BIGINT AS item_count,
           BOOL_AND(
               item.is_deleted = FALSE
               AND request.id IS NOT NULL
               AND request.is_deleted = FALSE
               AND request.status IN (0,1)
               AND COALESCE(request.is_stopped,FALSE) = FALSE
               AND request.id = action.external_document_id
           ) AS source_valid,
           SUM(GREATEST(
               COALESCE(item.qty,0) - COALESCE(item.ordered_qty,0), 0
           ) * COALESCE(item.unit_rate,1))::numeric AS unordered_qty
    FROM slice_items slice
    JOIN preplan_supply_actions action ON action.id = slice.action_id
    LEFT JOIN purchase_request_items item
      ON item.id = slice.request_item_id
    LEFT JOIN purchase_requests request
      ON request.id = item.request_id
    GROUP BY slice.action_id, slice.slice_type
), item_receipts AS (
    -- 每条已生效订货行的到货事实（与 V446 receipt_by_order_item 同一 CASE
    -- 口径，先按订货行汇总，供来源 FIFO 分摊）。
    SELECT order_item.id AS order_item_id,
           COALESCE(SUM(CASE
               WHEN receipt.id IS NULL THEN 0
               WHEN inspection.id IS NULL
               THEN receipt_item.qty * COALESCE(receipt_item.unit_rate,1)
               WHEN inspection.status = 'REVERSED' THEN 0
               ELSE inspection.warehouse_stocked_base_qty
           END),0)::numeric AS passed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0 ELSE inspection.failed_base_qty
           END),0)::numeric AS failed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0
               ELSE GREATEST(
                   inspection.received_base_qty
                       - inspection.failed_base_qty
                       - inspection.warehouse_stocked_base_qty,
                   0
               )
           END),0)::numeric AS pending_qty
    FROM purchase_order_items order_item
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN purchase_receipt_items receipt_item
      ON receipt_item.order_item_id = order_item.id
     AND receipt_item.is_deleted = FALSE
    LEFT JOIN purchase_receipts receipt
      ON receipt.id = receipt_item.receipt_id
     AND receipt.status = 1
     AND receipt.is_deleted = FALSE
    LEFT JOIN procurement_inspection_items inspection
      ON receipt.id IS NOT NULL
     AND inspection.receipt_type = 'PURCHASE'
     AND inspection.receipt_item_id = receipt_item.id
    WHERE order_item.is_deleted = FALSE
    GROUP BY order_item.id
), source_slices AS (
    -- 订货行 × 来源申请行：alloc/prefix（BASE 单位）与末位标记。
    SELECT src.order_item_id,
           src.request_item_id,
           src.alloc_qty * COALESCE(order_item.unit_rate, 1) AS alloc_base,
           COALESCE(SUM(src.alloc_qty) OVER w, 0)
               * COALESCE(order_item.unit_rate, 1)
               - src.alloc_qty * COALESCE(order_item.unit_rate, 1) AS prefix_base,
           ROW_NUMBER() OVER w AS rn,
           COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
    FROM purchase_order_item_sources src
    JOIN purchase_order_items order_item
      ON order_item.id = src.order_item_id
     AND order_item.is_deleted = FALSE
    WINDOW w AS (
        PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
), source_progress AS (
    SELECT slice.action_id, slice.slice_type,
           slice.request_item_id,
           sl.order_item_id,
           purchase_order.id IS NOT NULL AS order_exists,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(
                   GREATEST(
                       COALESCE(order_item.qty,0) - COALESCE(order_item.received_qty,0)
                       + COALESCE(order_item.returned_qty,0), 0)
                       * COALESCE(order_item.unit_rate,1)
                   - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   GREATEST(
                       COALESCE(order_item.qty,0) - COALESCE(order_item.received_qty,0)
                       + COALESCE(order_item.returned_qty,0), 0)
                       * COALESCE(order_item.unit_rate,1)
                   - sl.prefix_base), 0)
           END AS open_order_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(
                   GREATEST(COALESCE(receipt.passed_qty,0)
                       - COALESCE(order_item.returned_qty,0)
                           * COALESCE(order_item.unit_rate,1), 0)
                   - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   GREATEST(COALESCE(receipt.passed_qty,0)
                       - COALESCE(order_item.returned_qty,0)
                           * COALESCE(order_item.unit_rate,1), 0)
                   - sl.prefix_base), 0)
           END AS qualified_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(COALESCE(receipt.failed_qty,0) - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   COALESCE(receipt.failed_qty,0) - sl.prefix_base), 0)
           END AS failed_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(COALESCE(receipt.pending_qty,0) - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   COALESCE(receipt.pending_qty,0) - sl.prefix_base), 0)
           END AS pending_qty
    FROM slice_items slice
    JOIN source_slices sl
      ON sl.request_item_id = slice.request_item_id
    JOIN purchase_order_items order_item
      ON order_item.id = sl.order_item_id
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN item_receipts receipt ON receipt.order_item_id = order_item.id
), order_progress AS (
    SELECT slice.action_id, slice.slice_type,
           BOOL_OR(sp.order_exists) AS order_exists,
           COALESCE(SUM(sp.open_order_qty),0)::numeric AS open_order_qty,
           COALESCE(SUM(sp.qualified_qty),0)::numeric AS qualified_qty,
           COALESCE(SUM(sp.failed_qty),0)::numeric AS failed_qty,
           COALESCE(SUM(sp.pending_qty),0)::numeric AS pending_qty
    FROM slice_items slice
    LEFT JOIN source_progress sp
      ON sp.action_id = slice.action_id
     AND sp.slice_type = slice.slice_type
     AND sp.request_item_id = slice.request_item_id
    GROUP BY slice.action_id, slice.slice_type
), kind_progress AS (
    SELECT request.action_id, request.slice_type,
           request.item_count, request.source_valid,
           COALESCE(request.unordered_qty,0) AS unordered_qty,
           COALESCE(orders.order_exists,FALSE) AS order_exists,
           COALESCE(orders.open_order_qty,0) AS open_order_qty,
           COALESCE(orders.qualified_qty,0) AS qualified_qty,
           COALESCE(orders.failed_qty,0) AS failed_qty,
           COALESCE(orders.pending_qty,0) AS pending_qty
    FROM request_progress request
    LEFT JOIN order_progress orders
      ON orders.action_id = request.action_id
     AND orders.slice_type = request.slice_type
)
SELECT action.id AS action_id,
       action.requested_qty AS demand_requested_qty,
       action.safety_replenishment_qty AS safety_requested_qty,
       (action.requested_qty = 0 OR COALESCE(demand.item_count,0) > 0
          AND COALESCE(demand.source_valid,FALSE)) AS demand_source_valid,
       (action.safety_replenishment_qty = 0 OR COALESCE(safety.item_count,0) > 0
          AND COALESCE(safety.source_valid,FALSE)) AS safety_source_valid,
       COALESCE(demand.qualified_qty,0) AS demand_qualified_qty,
       COALESCE(safety.qualified_qty,0) AS safety_qualified_qty,
       COALESCE(demand.failed_qty,0) AS demand_failed_qty,
       COALESCE(safety.failed_qty,0) AS safety_failed_qty,
       COALESCE(demand.unordered_qty,0)
          + COALESCE(demand.open_order_qty,0)
          + COALESCE(demand.pending_qty,0) AS demand_future_qty,
       COALESCE(safety.unordered_qty,0)
          + COALESCE(safety.open_order_qty,0)
          + COALESCE(safety.pending_qty,0) AS safety_future_qty,
       COALESCE(demand.pending_qty,0) AS demand_pending_qty,
       COALESCE(safety.pending_qty,0) AS safety_pending_qty,
       COALESCE(demand.order_exists,FALSE) AS demand_order_exists,
       COALESCE(safety.order_exists,FALSE) AS safety_order_exists
FROM preplan_supply_actions action
LEFT JOIN kind_progress demand
  ON demand.action_id = action.id AND demand.slice_type = 'DEMAND'
LEFT JOIN kind_progress safety
  ON safety.action_id = action.id AND safety.slice_type = 'SAFETY'
WHERE action.route = 'BUY';
