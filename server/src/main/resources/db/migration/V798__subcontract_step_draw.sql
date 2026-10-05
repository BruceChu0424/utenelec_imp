-- =====================================================================
-- V798 (ADR-143) 委外按工序领直属物料、齐套通知、分批回厂
-- =====================================================================
-- 委外订货明细 P 只把 P 的直属物料发给委外商, 与车间工序领料同构:
--   * 财务批准时按 fn_subcontract_draw_edges(P) 为每条可发外直属边冻结一条领料计划行
--     (物料、解析后颜色、单耗 b = ROUND(订货单位换算率 x 边用量, 6)、计划量 = CEIL(Q x b, 4));
--     没有可发外直属边 = 缺 BOM: 订货单不能提交财务/批准(已通知研发完善), 所以已批准明细一定有计划行;
--     万一没有计划行, 可回厂套数为 0、回厂物料口径不放行、成本不完整(一律 fail-closed);
--   * 计划行 issued_qty = 已发外净量(发料审核 +、发料红冲 -、材料退货审核 -、退料红冲 +);
--   * 委外人员按套数提交领料, 每次提交新建领料草稿并写 requested_qty, 仓库只能改少;
--   * 可领 / 已领 / 可回厂套数只在服务端由本迁移的读函数算一次(fn_subcontract_draw_*);
--   * 财务批准的委外商自带料 E(V642 / ADR-101 二.8)不用我方物料: 我方供料套数
--     Qm = LEAST(Q, GREATEST(Q - E, 已领完整套数)), 可领封顶、还缺、「料已发完」都按 Qm(fn_subcontract_material_qty);
--   * 回厂按目标量逐种核销(R = 有效回厂行的 material_basis_qty 之和), 守卫逐种物料校验;
--     老系统导入的回厂行没有冻结口径, 不算缺口径(不拦导入, 也不拦之后对它的退货);
--   * 仓库拣货时整行不发 = 软删该行并写 warehouse_dropped_at(提交量保留, 发料回执据此列「少发」)。
-- 同时删除「先在厂内做出 P 再整件发外」的前置自制全家(V436/V447/V458/V494/V496/V529/V535
-- 的表、视图、函数、触发器、列与取值), 以及「唯一子件」判据。
--
-- V797 是上一轮被回退的方案(多直属子件整体外发、保留前置自制), 已在测试服务器执行过,
-- 文件原样保留; 它建立或改写的对象在这里全部删除或整体重写:
--   fn_subcontract_component_outbound_goods / _edges / _kit_capacity 删除,
--   fn_subcontract_component_available_stock 删除(由 fn_subcontract_draw_line_stock 取代),
--   fn_subcontract_component_entitled_lots 改为按订货明细 + 冻结计划行计算(签名变更),
--   fn_subcontract_take_component_entitlements / fn_guard_subcontract_target_quantity_basis_insert /
--   fn_assert_subcontract_target_outbound_receipt 整体重写。
--
-- 顺序(单个 Flyway 事务, 不用 CONCURRENTLY):
--   1. 前置检查: 库里还有旧形态数据就拒绝, 先用 V798 之前的版本做显式测试清空;
--   2. 删除幸存表上读将删对象的触发器(含 _upd/_del 变体);
--   3. 新列、新表;
--   4. 新读函数与本特性自有函数整体重写(LANGUAGE sql 在建时校验, 先建被调用者);
--   5. 共享函数、视图、约束、索引、触发器按现时定义锚点补丁(去 CR 后核对命中次数, 不符即中止;
--      含车间直送 SUBCONTRACT_ROUTE 文案 fn_workshop_direct_reason_text 改为委外领料说法);
--   6. 删视图、删表、删索引、删列、删函数;
--   7. 新权限点 subcontract_order:draw, 退役 subcontract_outbound:close(仓库「不再出仓」随本轮删除);
--   8. 后置扫描: 任何幸存的函数体 / 视图 / 约束 / 索引 / 触发器条件仍引用被删对象或取值即中止。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 前置检查(只拒绝真正的旧形态数据; 空库直接通过)
-- ---------------------------------------------------------------------
DO $v798_preflight$
DECLARE
    old_shape TEXT;
BEGIN
    SELECT string_agg(evidence, '; ' ORDER BY evidence) INTO old_shape FROM (
        SELECT 'subcontract_material_plans=' || count(*) AS evidence
        FROM subcontract_material_plans HAVING count(*) > 0
        UNION ALL SELECT 'subcontract_material_plan_items=' || count(*)
        FROM subcontract_material_plan_items HAVING count(*) > 0
        UNION ALL SELECT 'subcontract_component_stock_handoffs=' || count(*)
        FROM subcontract_component_stock_handoffs HAVING count(*) > 0
        UNION ALL SELECT 'subcontract_outbound_issue_reservation_allocations=' || count(*)
        FROM subcontract_outbound_issue_reservation_allocations HAVING count(*) > 0
        UNION ALL SELECT 'subcontract_material_issue_items(bound to a plan line)=' || count(*)
        FROM subcontract_material_issue_items WHERE plan_item_id IS NOT NULL HAVING count(*) > 0
        UNION ALL SELECT 'subcontract_receipt_material_consumptions(DIRECT_TARGET)=' || count(*)
        FROM subcontract_receipt_material_consumptions WHERE consumption_basis = 'DIRECT_TARGET' HAVING count(*) > 0
        UNION ALL SELECT 'subcontract_outbound_preparation_commands=' || count(*)
        FROM subcontract_outbound_preparation_commands HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_make_tasks=' || count(*)
        FROM preplan_subcontract_make_tasks HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_make_task_batches=' || count(*)
        FROM preplan_subcontract_make_task_batches HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_make_batch_reversals=' || count(*)
        FROM preplan_subcontract_make_batch_reversals HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_requirement_handoffs=' || count(*)
        FROM preplan_subcontract_requirement_handoffs HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_requirement_handoff_items=' || count(*)
        FROM preplan_subcontract_requirement_handoff_items HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_requirement_handoff_events=' || count(*)
        FROM preplan_subcontract_requirement_handoff_events HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_requirement_supply_claims=' || count(*)
        FROM preplan_subcontract_requirement_supply_claims HAVING count(*) > 0
        UNION ALL SELECT 'preplan_subcontract_entitlement_handoff_slices=' || count(*)
        FROM preplan_subcontract_entitlement_handoff_slices HAVING count(*) > 0
        UNION ALL SELECT 'stock_reservations(subcontract outbound or preparation owner)=' || count(*)
        FROM stock_reservations
        WHERE owner_type IN ('SUBCONTRACT_OUTBOUND', 'SUBCONTRACT_PREPARE_TASK', 'SUBCONTRACT_ORDER_PREPARATION')
           OR purpose IN ('SUBCONTRACT_OUTBOUND', 'SUBCONTRACT_PREPARE_TASK', 'SUBCONTRACT_ORDER_PREPARATION')
        HAVING count(*) > 0
        UNION ALL SELECT 'production_material_analysis_items(make-first source)=' || count(*)
        FROM production_material_analysis_items
        WHERE source_type IN ('SUBCONTRACT_MAKE', 'SUBCONTRACT_PREPARATION')
           OR subcontract_order_item_id IS NOT NULL OR subcontract_order_qty_base IS NOT NULL
        HAVING count(*) > 0
        UNION ALL SELECT 'preplan_supply_actions(SUBCONTRACT_MAKE_TASK)=' || count(*)
        FROM preplan_supply_actions WHERE external_document_type = 'SUBCONTRACT_MAKE_TASK' HAVING count(*) > 0
        UNION ALL SELECT 'preplan_aggregate_batches(anchored SUBCONTRACT)=' || count(*)
        FROM preplan_aggregate_batches
        WHERE route = 'SUBCONTRACT' AND (anchor_analysis_item_id IS NOT NULL OR plan_id IS NOT NULL)
        HAVING count(*) > 0
        UNION ALL SELECT 'preplan_stock_entitlement_events(SUBCONTRACT_HANDOFF)=' || count(*)
        FROM preplan_stock_entitlement_events
        WHERE event_type IN ('SUBCONTRACT_HANDOFF_IN', 'SUBCONTRACT_HANDOFF_OUT') HAVING count(*) > 0
    ) found;
    IF old_shape IS NOT NULL THEN
        RAISE EXCEPTION 'V798 (ADR-143) 前置检查失败: 库里还有旧形态的委外领料/前置自制数据 [%]. 请先用当前已部署的 V798 之前版本执行显式测试清空, 再激活含 V798 的版本', old_shape
            USING ERRCODE = '55000';
    END IF;
END;
$v798_preflight$;

-- ---------------------------------------------------------------------
-- 2. 幸存表上读将删表/列/函数的触发器(含 _upd/_del 变体)
-- ---------------------------------------------------------------------
DROP TRIGGER trg_check_preplan_subcontract_entitlement_event ON preplan_stock_entitlement_events;
DROP TRIGGER trg_validate_preplan_subcontract_handoff_events ON preplan_stock_entitlement_events;
DROP TRIGGER trg_guard_preplan_subcontract_claimed_allocation ON preplan_supply_action_allocations;
DROP TRIGGER trg_validate_preplan_subcontract_supply_claim_allocation ON preplan_supply_action_allocations;
DROP TRIGGER trg_guard_preplan_subcontract_claimed_action ON preplan_supply_actions;
DROP TRIGGER trg_direct_subcontract_analysis_preparation ON production_material_analyses;
DROP TRIGGER trg_bind_direct_subcontract_preparation ON production_material_analysis_items;
DROP TRIGGER trg_bind_direct_subcontract_preparation_upd ON production_material_analysis_items;
DROP TRIGGER trg_guard_subcontract_qualified_child_identity ON production_material_analysis_items;
DROP TRIGGER trg_subcontract_preparation_analysis_source_guard ON production_material_analysis_items;
DROP TRIGGER trg_subcontract_preparation_analysis_source_guard_upd ON production_material_analysis_items;
DROP TRIGGER trg_guard_preplan_subcontract_handoff_material_identity ON production_material_analysis_materials;
DROP TRIGGER trg_subcontract_prep_finished_analysis_link_guard ON production_material_analysis_plan_links;
DROP TRIGGER trg_subcontract_prep_finished_production_item_guard ON production_plan_items;
DROP TRIGGER trg_subcontract_prep_finished_production_item_guard_upd ON production_plan_items;
DROP TRIGGER trg_subcontract_prep_finished_production_plan_guard ON production_plans;
DROP TRIGGER trg_subcontract_prep_finished_stock_item_guard ON stock_document_items;
DROP TRIGGER trg_subcontract_prep_finished_stock_item_guard_upd ON stock_document_items;
DROP TRIGGER trg_subcontract_finished_custody_activation ON stock_documents;
DROP TRIGGER trg_subcontract_finished_custody_activation_upd ON stock_documents;
DROP TRIGGER trg_subcontract_prep_finished_stock_doc_guard ON stock_documents;
DROP TRIGGER trg_subcontract_prep_finished_stock_doc_guard_upd ON stock_documents;
DROP TRIGGER trg_guard_subcontract_preparation_reservation_identity ON stock_reservations;
DROP TRIGGER trg_guard_subcontract_preparation_reservation_identity_upd ON stock_reservations;
DROP TRIGGER trg_subcontract_prepared_source_capacity ON stock_reservations;
DROP TRIGGER trg_subcontract_prepared_source_capacity_del ON stock_reservations;
DROP TRIGGER trg_subcontract_prepared_source_capacity_upd ON stock_reservations;
DROP TRIGGER trg_subcontract_qualified_preparation_origin ON stock_reservations;
DROP TRIGGER trg_subcontract_qualified_preparation_origin_upd ON stock_reservations;
DROP TRIGGER trg_subcontract_loss_allowance ON subcontract_material_plan_items;
DROP TRIGGER trg_subcontract_prep_finished_plan_item_guard ON subcontract_material_plan_items;
DROP TRIGGER trg_subcontract_preparation_handoff_required ON subcontract_material_plan_items;
DROP TRIGGER trg_subcontract_preparation_source_guard ON subcontract_material_plan_items;
DROP TRIGGER trg_direct_subcontract_item_preparation ON subcontract_order_items;
DROP TRIGGER trg_direct_subcontract_order_preparation ON subcontract_orders;

-- ---------------------------------------------------------------------
-- 3. 新列与新表
-- ---------------------------------------------------------------------
-- 3.1 计划行「结束领料」: 行开放 = 计划 OPEN 且未删且 draw_closed_at 为空。
ALTER TABLE subcontract_material_plan_items
    ADD COLUMN draw_closed_at TIMESTAMPTZ,
    ADD COLUMN draw_closed_by UUID REFERENCES users(id),
    ADD COLUMN draw_close_reason TEXT,
    ADD CONSTRAINT subcontract_material_plan_item_draw_close_chk CHECK (
        (draw_closed_at IS NULL AND draw_closed_by IS NULL AND draw_close_reason IS NULL)
        OR (draw_closed_at IS NOT NULL AND draw_close_reason IS NOT NULL
            AND char_length(btrim(draw_close_reason)) BETWEEN 1 AND 200));

COMMENT ON COLUMN subcontract_material_plan_items.goods_id IS
    'V798(ADR-143): 发给委外商的直属物料(财务批准时按 fn_subcontract_draw_edges 冻结); 委外商交回的是 parent_goods_id';
COMMENT ON COLUMN subcontract_material_plan_items.color_id IS
    'V798(ADR-143): 冻结的物料颜色 = COALESCE(BOM 边颜色, 物料默认颜色)';
COMMENT ON COLUMN subcontract_material_plan_items.bom_unit_qty IS
    'V798(ADR-143): 冻结单耗 b = ROUND(订货单位换算率 x 边用量, 6), 每个订货单位的物料量(计划行单位)';
COMMENT ON COLUMN subcontract_material_plan_items.planned_qty IS
    'V798(ADR-143): 计划量 = fn_subcontract_draw_f(订货量, b) = CEIL(Q x b, 4); 改量按新订货量整体重算';
COMMENT ON COLUMN subcontract_material_plan_items.issued_qty IS
    'V798(ADR-143): 已发外净量 = 发料审核 + / 发料红冲 - / 材料退货审核 - / 退料红冲 +; 0 <= issued_qty <= planned_qty';
COMMENT ON COLUMN subcontract_material_plan_items.draw_closed_at IS
    'V798(ADR-143): 结束领料(不再发外)的时间; 非空即本行不再接受领料, 未发领料已撤回、预留已释放';
COMMENT ON COLUMN subcontract_material_plan_items.draw_close_reason IS
    'V798(ADR-143): 结束领料原因(必填, 不超过 200 字)';

-- 3.2 领料草稿行的提交量: 只能由委外领料提交写入, 写入后不可改, 仓库实发 qty <= requested_qty。
ALTER TABLE subcontract_material_issue_items
    ADD COLUMN requested_qty NUMERIC(18,4),
    ADD CONSTRAINT subcontract_material_issue_item_requested_qty_chk
        CHECK (requested_qty IS NULL OR (requested_qty > 0 AND qty <= requested_qty));
COMMENT ON COLUMN subcontract_material_issue_items.requested_qty IS
    'V798(ADR-143): 委外人员提交领料时的本行数量(计划行单位); 绑定计划行的发料行必须有, 写入后不可改, 仓库只能把 qty 改少';

-- 3.2b 仓库拣货时整行不发: 该行软删并记下时间, qty 与 requested_qty 原样保留, 发料回执据此列出「少发」。
--      只有仓库保存拣货时删行会写; 委外人员撤回领料的软删不写。软删行不进任何库存、预留、计划行与守卫口径(都只看未删行)。
ALTER TABLE subcontract_material_issue_items
    ADD COLUMN warehouse_dropped_at TIMESTAMPTZ,
    ADD CONSTRAINT subcontract_material_issue_item_warehouse_dropped_chk
        CHECK (warehouse_dropped_at IS NULL OR is_deleted);
COMMENT ON COLUMN subcontract_material_issue_items.warehouse_dropped_at IS
    'V798(ADR-143): 仓库拣货时整行不发的时间(只在仓库保存拣货删行时写入, 必须同时软删); 撤回领料不写. 发料回执的少发 = 未删行与仓库删行的 requested_qty 之和 - 未删行实发 qty';

-- 3.3 回厂行的物料口径数量: 审核时写入 = 回厂量 - 本单质检补回分配 - 财务批准自带料(订货单位), 之后不随实时状态重算。
ALTER TABLE subcontract_receipt_items
    ADD COLUMN material_basis_qty NUMERIC(18,4),
    ADD CONSTRAINT subcontract_receipt_item_material_basis_chk
        CHECK (material_basis_qty IS NULL OR (material_basis_qty >= 0 AND material_basis_qty <= qty));
COMMENT ON COLUMN subcontract_receipt_items.material_basis_qty IS
    'V798(ADR-143): 回厂审核时冻结的物料核销口径数量(订货单位) = 回厂量 - 本单质检补回分配 - 财务批准自带料; R = 有效回厂行之和';

-- 3.4 「可领」通知的高水位: 只由投递后的重算写入, 可领量比上次提醒时高才再提醒。
CREATE TABLE subcontract_draw_notice_marks (
    order_item_id UUID PRIMARY KEY REFERENCES subcontract_order_items(id) ON DELETE CASCADE,
    notified_drawable NUMERIC(18,4) NOT NULL DEFAULT 0,
    epoch INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT subcontract_draw_notice_mark_values_chk CHECK (notified_drawable >= 0 AND epoch >= 0)
);
COMMENT ON TABLE subcontract_draw_notice_marks IS
    'V798(ADR-143): 委外可领料通知的高水位(每个订货明细一行). 可领 > 水位才提醒并抬高水位; 可领 < 水位时降水位并 epoch+1, 不提醒. 系统协调状态, 不挂行级审计, 清空业务数据时清空';

-- ---------------------------------------------------------------------
-- 4. 领料数量口径与读函数(唯一一处计算; Java 只读不复算)
-- ---------------------------------------------------------------------
-- f(S) = CEIL(S x b, 4): 套数 -> 物料量。Java 以 setScale(4, RoundingMode.CEILING) 镜像。
CREATE FUNCTION fn_subcontract_draw_f(p_sets NUMERIC, p_bom_unit_qty NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT ROUND(CEIL(p_sets * p_bom_unit_qty * 10000) / 10000, 4)
$$;
COMMENT ON FUNCTION fn_subcontract_draw_f(NUMERIC, NUMERIC) IS
    'V798(ADR-143 三.2): f(S) = CEIL(S x b, 4), 套数换物料量; 计划量 = f(订货量)';

-- sets(x) = TRUNC(x / b, 4): 物料量 -> 套数, 用整数除法精确截断(与 Java divide(b, 4, RoundingMode.DOWN) 一致)。
CREATE FUNCTION fn_subcontract_draw_sets(p_qty NUMERIC, p_bom_unit_qty NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN p_bom_unit_qty IS NULL OR p_bom_unit_qty <= 0 THEN NULL
                ELSE ROUND(div(GREATEST(COALESCE(p_qty, 0), 0) * 10000, p_bom_unit_qty) / 10000, 4) END
$$;
COMMENT ON FUNCTION fn_subcontract_draw_sets(NUMERIC, NUMERIC) IS
    'V798(ADR-143 三.2): sets(x) = TRUNC(x / b, 4), 物料量换套数(精确截断); 在 0.0001 网格上 f(S) <= x 当且仅当 S <= sets(x)';

-- 可发外直属边的唯一判据(ADR-143 二.19): 计划冻结、分析展开、可用量与精确归属只用它。
CREATE FUNCTION fn_subcontract_draw_edges(p_goods UUID)
RETURNS TABLE(edge_id UUID, component_goods_id UUID, color_id UUID, edge_qty NUMERIC, sort_order INTEGER)
LANGUAGE sql STABLE AS $$
    SELECT edge.id, edge.component_goods_id, COALESCE(edge.color_id, component.color_id), edge.qty, edge.sort_order
    FROM goods_bom_items edge
    JOIN goods component ON component.id = edge.component_goods_id
     AND NOT component.is_deleted
     AND NOT COALESCE(component.auto_created, FALSE)
     AND component.issue_method <> 'PERIODIC'
    WHERE edge.goods_id = p_goods
      AND NOT edge.is_deleted
      AND edge.consumption_basis = 'PER_UNIT'
      AND edge.control_stage IN ('START', 'ASSEMBLY', 'FINISH')
      AND edge.qty > 0
    ORDER BY edge.sort_order, edge.id
$$;
COMMENT ON FUNCTION fn_subcontract_draw_edges(UUID) IS
    'V798(ADR-143 二.19): 委外件的可发外直属边(按件用量、生产投入阶段、按单领料、用量 > 0、非系统占位), 颜色 = COALESCE(边颜色, 物料默认颜色)';

-- 精确归属的分摊权重只认 SUPPLY 行动(共享未来认领 / 未来调拨不稀释所有者)。
CREATE OR REPLACE FUNCTION fn_subcontract_component_parent_capacity(p_application_item UUID, p_allocation UUID, p_total NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH weights AS (
        SELECT allocation.id, allocation.allocated_qty
        FROM preplan_supply_action_allocations allocation
        JOIN preplan_supply_actions action ON action.id = allocation.action_id
         AND action.route = 'SUBCONTRACT' AND action.operation_type = 'SUPPLY' AND action.status <> 'CANCELLED'
         AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
        WHERE allocation.allocated_qty > 0
          AND (allocation.external_item_id = p_application_item
               OR action.public_surplus_external_item_id = p_application_item)
    ), portions AS (
        SELECT id,
               round(p_total * SUM(allocated_qty) OVER (ORDER BY id) / NULLIF(SUM(allocated_qty) OVER (), 0), 4)
               - round(p_total * COALESCE(SUM(allocated_qty) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
                       / NULLIF(SUM(allocated_qty) OVER (), 0), 4) AS qty
        FROM weights
    )
    SELECT COALESCE((SELECT qty FROM portions WHERE id = p_allocation), 0)
$$;

-- 订货明细可接管的精确专属批次(ADR-113 交接, 按冻结计划行):
--   * 物料节点 = 来源申请分摊行所在 P 节点的直属子节点; P 是顶层供给行(ROOT_SUPPLY)时是同一来源行 depth=1 的节点;
--   * 每个认领方 = (订货明细, 申请明细, P 节点), 容量 = 来源分摊量 x 冻结单耗按 SUPPLY 分摊行权重切分, 扣掉已接管未退回的量;
--   * 认领区间在该物料节点的全部在途订货明细之间切分, 批次区间按事件顺序, 两者求交, 同一批次不会被两个明细同时认领;
--   * 只看作业叶仓(未删、非不良、非线边); 计划行已关闭或计划不 OPEN 的明细不再认领。
DROP FUNCTION fn_subcontract_component_available_stock(UUID, UUID);
DROP FUNCTION fn_subcontract_component_entitled_lots(UUID, UUID);
CREATE FUNCTION fn_subcontract_component_entitled_lots(p_order_item_id UUID)
RETURNS TABLE(plan_item_id UUID, application_item_id UUID, entitlement_event_id UUID, stock_reservation_id UUID,
    beneficiary_analysis_id UUID, beneficiary_analysis_material_id UUID, source_exact_peg_id UUID,
    reallocation_id UUID, warehouse_id UUID, goods_id UUID, color_id UUID, remaining_qty NUMERIC,
    parent_material_id UUID)
LANGUAGE sql STABLE AS $$
    WITH own_parents AS (
        SELECT DISTINCT allocation.analysis_material_id AS parent_material_id
        FROM subcontract_order_item_sources source
        JOIN subcontract_application_items application ON application.id = source.application_item_id
         AND NOT application.is_deleted
        JOIN preplan_supply_actions action ON action.external_document_type = 'SUBCONTRACT_APPLICATION'
         AND action.external_document_id = application.application_id
         AND action.route = 'SUBCONTRACT' AND action.operation_type = 'SUPPLY' AND action.status <> 'CANCELLED'
        JOIN preplan_supply_action_allocations allocation ON allocation.action_id = action.id
         AND allocation.analysis_id = action.analysis_id AND allocation.allocated_qty > 0
         AND (allocation.external_item_id = application.id OR action.public_surplus_external_item_id = application.id)
        WHERE source.order_item_id = p_order_item_id AND source.alloc_qty > 0
    ), claims AS (
        SELECT item.id AS order_item_id, application.id AS application_item_id, parent.id AS parent_material_id,
               child.id AS material_id, child.analysis_id, line.id AS plan_item_id,
               SUM(fn_subcontract_component_parent_capacity(application.id, allocation.id,
                   source.alloc_qty * line.bom_unit_qty)) AS capacity_qty
        FROM own_parents own
        JOIN preplan_supply_action_allocations allocation ON allocation.analysis_material_id = own.parent_material_id
         AND allocation.allocated_qty > 0
        JOIN preplan_supply_actions action ON action.id = allocation.action_id
         AND action.analysis_id = allocation.analysis_id
         AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
         AND action.route = 'SUBCONTRACT' AND action.operation_type = 'SUPPLY' AND action.status <> 'CANCELLED'
        JOIN subcontract_application_items application ON application.application_id = action.external_document_id
         AND NOT application.is_deleted
         AND (allocation.external_item_id = application.id OR action.public_surplus_external_item_id = application.id)
        JOIN subcontract_order_item_sources source ON source.application_item_id = application.id AND source.alloc_qty > 0
        JOIN subcontract_order_items item ON item.id = source.order_item_id AND NOT item.is_deleted
         AND item.goods_id = application.goods_id AND item.color_id IS NOT DISTINCT FROM application.color_id
        JOIN production_material_analysis_materials parent ON parent.id = allocation.analysis_material_id
         AND parent.analysis_id = allocation.analysis_id AND parent.active
         AND parent.goods_id = application.goods_id AND parent.color_id IS NOT DISTINCT FROM application.color_id
        JOIN production_material_analysis_materials child ON child.analysis_id = parent.analysis_id
         AND child.analysis_item_id = parent.analysis_item_id AND child.active
         AND ((parent.node_role = 'ROOT_SUPPLY' AND child.depth = 1 AND child.parent_node_key IS NULL)
              OR (parent.node_role <> 'ROOT_SUPPLY' AND child.parent_node_key = parent.node_key))
        JOIN LATERAL (
            SELECT candidate.id, candidate.bom_unit_qty
            FROM subcontract_material_plan_items candidate
            JOIN subcontract_material_plans plan ON plan.id = candidate.plan_id
             AND plan.status = 'OPEN' AND NOT plan.is_deleted
            WHERE candidate.order_item_id = item.id AND NOT candidate.is_deleted
              AND candidate.draw_closed_at IS NULL
              AND candidate.goods_id = child.goods_id
              AND candidate.color_id IS NOT DISTINCT FROM child.color_id
            ORDER BY candidate.line_no NULLS LAST, candidate.id
            LIMIT 1
        ) line ON TRUE
        GROUP BY item.id, application.id, parent.id, child.id, child.analysis_id, line.id
    ), remaining AS (
        SELECT claim.*,
               GREATEST(claim.capacity_qty - COALESCE((
                   SELECT SUM(handoff.qty - target.released_qty)
                   FROM subcontract_component_stock_handoffs handoff
                   JOIN subcontract_material_plan_items taken ON taken.id = handoff.plan_item_id
                   JOIN stock_reservations target ON target.id = handoff.target_reservation_id
                   WHERE taken.order_item_id = claim.order_item_id
                     AND handoff.application_item_id = claim.application_item_id
                     AND handoff.parent_material_id = claim.parent_material_id
                     AND handoff.child_material_id = claim.material_id), 0), 0) AS remaining_capacity
        FROM claims claim
    ), claim_ranges AS (
        SELECT remaining.*,
               SUM(remaining_capacity) OVER (PARTITION BY material_id
                   ORDER BY order_item_id, application_item_id, parent_material_id) - remaining_capacity AS range_start,
               SUM(remaining_capacity) OVER (PARTITION BY material_id
                   ORDER BY order_item_id, application_item_id, parent_material_id) AS range_end
        FROM remaining
        WHERE remaining_capacity > 0
    ), wanted AS (
        SELECT DISTINCT claim.material_id, claim.analysis_id
        FROM claim_ranges claim
        WHERE claim.order_item_id = p_order_item_id
    ), source_lots AS (
        SELECT DISTINCT ON (lot.entitlement_event_id)
               lot.entitlement_event_id, lot.stock_reservation_id, lot.beneficiary_analysis_id,
               lot.beneficiary_analysis_material_id, lot.source_exact_peg_id, lot.reallocation_id,
               reservation.warehouse_id, reservation.goods_id, reservation.color_id,
               LEAST(lot.remaining_qty, reservation.qty - reservation.consumed_qty - reservation.released_qty) AS lot_qty
        FROM wanted
        JOIN production_material_analysis_materials child ON child.id = wanted.material_id
        JOIN v_preplan_stock_entitlement_lot_balance lot ON lot.beneficiary_analysis_id = wanted.analysis_id
         AND lot.beneficiary_analysis_material_id = wanted.material_id AND lot.remaining_qty > 0
        JOIN stock_reservations reservation ON reservation.id = lot.stock_reservation_id
         AND reservation.owner_type = 'PREPLAN_ANALYSIS' AND reservation.status = 0 AND NOT reservation.is_deleted
         AND reservation.goods_id = child.goods_id AND reservation.color_id IS NOT DISTINCT FROM child.color_id
         AND reservation.qty - reservation.consumed_qty - reservation.released_qty > 0
        JOIN warehouses warehouse ON warehouse.id = reservation.warehouse_id
         AND NOT warehouse.is_deleted AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
         AND fn_warehouse_is_operational_leaf(warehouse.id)
        ORDER BY lot.entitlement_event_id
    ), lot_ranges AS (
        SELECT lot.*,
               SUM(lot_qty) OVER (PARTITION BY beneficiary_analysis_material_id ORDER BY entitlement_event_id) - lot_qty AS range_start,
               SUM(lot_qty) OVER (PARTITION BY beneficiary_analysis_material_id ORDER BY entitlement_event_id) AS range_end
        FROM source_lots lot
    )
    SELECT claim.plan_item_id, claim.application_item_id, lot.entitlement_event_id, lot.stock_reservation_id,
           lot.beneficiary_analysis_id, lot.beneficiary_analysis_material_id, lot.source_exact_peg_id,
           lot.reallocation_id, lot.warehouse_id, lot.goods_id, lot.color_id,
           LEAST(claim.range_end, lot.range_end) - GREATEST(claim.range_start, lot.range_start),
           claim.parent_material_id
    FROM claim_ranges claim
    JOIN lot_ranges lot ON lot.beneficiary_analysis_material_id = claim.material_id
     AND GREATEST(claim.range_start, lot.range_start) < LEAST(claim.range_end, lot.range_end)
    WHERE claim.order_item_id = p_order_item_id
    ORDER BY claim.plan_item_id, claim.application_item_id, lot.entitlement_event_id
$$;
COMMENT ON FUNCTION fn_subcontract_component_entitled_lots(UUID) IS
    'V798(ADR-143 三.5): 订货明细按冻结计划行可接管的精确专属批次切片(顶层委外件取来源行 depth=1 节点; 认领区间按该物料节点全部在途订货明细切分)';

-- 计划行的可动用量(每个作业叶仓一行): 精确专属批次 + 公共可用量(v_stock_available 已扣他人预留)。
CREATE FUNCTION fn_subcontract_draw_line_stock(p_plan_item UUID)
RETURNS TABLE(warehouse_id UUID, exact_qty NUMERIC, public_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH line AS (
        SELECT plan_item.id, plan_item.order_item_id, plan_item.goods_id, plan_item.color_id
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = p_plan_item AND NOT plan_item.is_deleted
    ), exact_stock AS (
        SELECT lot.warehouse_id, SUM(lot.remaining_qty) AS qty
        FROM line
        CROSS JOIN LATERAL fn_subcontract_component_entitled_lots(line.order_item_id) lot
        WHERE lot.plan_item_id = line.id
        GROUP BY lot.warehouse_id
    ), public_stock AS (
        SELECT stock.warehouse_id, GREATEST(stock.available_qty, 0) AS qty
        FROM line
        JOIN v_stock_available stock ON stock.goods_id = line.goods_id
         AND stock.color_id IS NOT DISTINCT FROM line.color_id
        JOIN warehouses warehouse ON warehouse.id = stock.warehouse_id
         AND NOT warehouse.is_deleted AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
         AND fn_warehouse_is_operational_leaf(warehouse.id)
    )
    SELECT COALESCE(exact_stock.warehouse_id, public_stock.warehouse_id),
           COALESCE(exact_stock.qty, 0), COALESCE(public_stock.qty, 0)
    FROM exact_stock
    FULL JOIN public_stock ON public_stock.warehouse_id = exact_stock.warehouse_id
    WHERE COALESCE(exact_stock.qty, 0) > 0 OR COALESCE(public_stock.qty, 0) > 0
    ORDER BY 1
$$;
COMMENT ON FUNCTION fn_subcontract_draw_line_stock(UUID) IS
    'V798(ADR-143 三.5): 计划行在各作业叶仓的可动用量 = 精确专属批次 exact_qty + 公共可用 public_qty; 两者都为 0 的仓不返回';

-- 财务批准的委外商自带料 E(订货单位, ADR-143 三.4a): 回厂超过我方物料可做套数、经财务按约定接收的部分
-- (V642 / ADR-101 二.8)。只认已定案接收且未撤销的到货异常; 收货单红冲后异常转 RETURN_REQUIRED / CANCELED, 不再计入。
-- 回厂核销守卫的净额上限(fn_assert_subcontract_target_outbound_receipt)用同一个函数。
CREATE FUNCTION fn_subcontract_supplier_own_qty(p_order_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(finance_excess.approved_excess_qty), 0)
    FROM procurement_arrival_exceptions finance_excess
    WHERE finance_excess.order_type = 'SUBCONTRACT'
      AND finance_excess.order_item_id = p_order_item
      AND finance_excess.status IN ('RECEIPT_ADJUSTED', 'RECEIPT_POSTED', 'CLOSED')
      AND finance_excess.decision IN ('APPROVE_ALL', 'APPROVE_CUSTOM')
      AND finance_excess.approved_excess_qty > 0
$$;
COMMENT ON FUNCTION fn_subcontract_supplier_own_qty(UUID) IS
    'V798(ADR-143 三.4a): 财务批准的委外商自带料 E(订货单位) = 已定案接收(RECEIPT_ADJUSTED / RECEIPT_POSTED / CLOSED, APPROVE_ALL / APPROVE_CUSTOM)的到货异常 approved_excess_qty 之和';

-- 我方供料套数 Qm(订货单位, ADR-143 三.4a): 自带料那部分不需要我方物料。
-- Qm = LEAST(Q, GREATEST(Q - E, 已领完整套数, 0)); E = 0 时 Qm = Q。已经发出去的完整套数不会因为后来批准的自带料被「收回」。
CREATE FUNCTION fn_subcontract_material_qty(p_order_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN item.own_qty <= 0 THEN item.q
                ELSE LEAST(item.q, GREATEST(item.q - item.own_qty,
                     COALESCE((SELECT MIN(fn_subcontract_draw_sets(line.issued_qty, line.bom_unit_qty))
                               FROM subcontract_material_plan_items line
                               WHERE line.order_item_id = p_order_item AND NOT line.is_deleted), 0), 0)) END
    FROM (SELECT COALESCE(order_item.qty, 0) AS q, fn_subcontract_supplier_own_qty(order_item.id) AS own_qty
          FROM subcontract_order_items order_item
          WHERE order_item.id = p_order_item) item
$$;
COMMENT ON FUNCTION fn_subcontract_material_qty(UUID) IS
    'V798(ADR-143 三.4a): 我方供料套数 Qm = LEAST(Q, GREATEST(Q - E, MIN_i sets_i(sent_i), 0)), E = fn_subcontract_supplier_own_qty; 订货明细不存在时为空';

-- 计划行我方还要发到的量(计划行单位): needed_i = LEAST(planned_i, f_i(Qm))。「料已发完」「领满」「还缺」都按它。
CREATE FUNCTION fn_subcontract_draw_needed_qty(p_order_item UUID, p_planned_qty NUMERIC, p_bom_unit_qty NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT LEAST(p_planned_qty, fn_subcontract_draw_f(fn_subcontract_material_qty(p_order_item), p_bom_unit_qty))
$$;
COMMENT ON FUNCTION fn_subcontract_draw_needed_qty(UUID, NUMERIC, NUMERIC) IS
    'V798(ADR-143 三.4a): 计划行我方需发量 needed = LEAST(planned, f(Qm, b)); 没有自带料时 = planned';

-- 每条计划行的领料事实(计划行单位)。
CREATE FUNCTION fn_subcontract_draw_facts(p_order_item UUID)
RETURNS TABLE(plan_item_id UUID, line_no INTEGER, goods_id UUID, color_id UUID, unit_id UUID,
    bom_unit_qty NUMERIC, planned_qty NUMERIC, sent_qty NUMERIC, pending_qty NUMERIC,
    available_qty NUMERIC, usable_qty NUMERIC, line_open BOOLEAN, needed_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT line.id, line.line_no, line.goods_id, line.color_id, line.unit_id, line.bom_unit_qty,
           line.planned_qty, line.issued_qty,
           COALESCE((SELECT SUM(item.qty)
                     FROM subcontract_material_issue_items item
                     JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                      AND issue.status = 0 AND NOT issue.is_deleted
                     WHERE item.plan_item_id = line.id AND NOT item.is_deleted), 0),
           COALESCE((SELECT SUM(stock.exact_qty + stock.public_qty)
                     FROM fn_subcontract_draw_line_stock(line.id) stock), 0),
           COALESCE((SELECT SUM(item.at_supplier_qty + item.compensated_qty
                                - COALESCE(item.returned_qty, 0) - COALESCE(item.wasted_qty, 0))
                     FROM subcontract_material_issue_items item
                     JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                      AND issue.status = 1 AND NOT issue.is_deleted
                     WHERE item.plan_item_id = line.id AND NOT item.is_deleted), 0),
           plan.status = 'OPEN' AND NOT plan.is_deleted AND line.draw_closed_at IS NULL,
           LEAST(line.planned_qty, fn_subcontract_draw_f(material.qm, line.bom_unit_qty))
    FROM subcontract_material_plan_items line
    JOIN subcontract_material_plans plan ON plan.id = line.plan_id
    CROSS JOIN (SELECT fn_subcontract_material_qty(p_order_item) AS qm) material
    WHERE line.order_item_id = p_order_item AND NOT line.is_deleted
    ORDER BY line.line_no NULLS LAST, line.id
$$;
COMMENT ON FUNCTION fn_subcontract_draw_facts(UUID) IS
    'V798(ADR-143 三.3/三.4a): 每条未删计划行: 已发外净量 sent、已提交未发 pending、可动用 available、委外商处可做成 P 的 usable(已核销 + 结存)、行是否开放、我方需发量 needed = LEAST(planned, f(Qm))';

-- 订货明细的行级显示量(订货单位, ADR-143 三.4/三.4a): 已领 + 待仓库发 + 可领 + 还缺 = 我方供料套数 Qm
-- (没有委外商自带料时 Qm = 订货量)。order_qty 仍是订货量, material_qty = Qm。
CREATE FUNCTION fn_subcontract_draw_summary(p_order_item UUID)
RETURNS TABLE(order_qty NUMERIC, material_kind_count INTEGER, ready_kind_count INTEGER, drawn_qty NUMERIC,
    pending_qty NUMERIC, drawable_qty NUMERIC, short_qty NUMERIC, complete_qty NUMERIC, reachable_qty NUMERIC,
    all_covered BOOLEAN, all_sent BOOLEAN, any_open BOOLEAN, material_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH item AS (
        SELECT COALESCE(order_item.qty, 0) AS q,
               COALESCE(fn_subcontract_material_qty(order_item.id), COALESCE(order_item.qty, 0)) AS qm
        FROM subcontract_order_items order_item
        WHERE order_item.id = p_order_item
    ), facts AS (
        SELECT fact.*, CASE WHEN fact.line_open THEN fact.available_qty ELSE 0 END AS open_available
        FROM fn_subcontract_draw_facts(p_order_item) fact
    ), totals AS (
        SELECT COUNT(*)::INTEGER AS kinds,
               (COUNT(*) FILTER (WHERE fact.needed_qty - fact.sent_qty - fact.pending_qty - fact.open_available <= 0))::INTEGER AS ready,
               MIN(fn_subcontract_draw_sets(fact.sent_qty, fact.bom_unit_qty)) AS sent_sets,
               MIN(fn_subcontract_draw_sets(fact.sent_qty + fact.pending_qty, fact.bom_unit_qty)) AS covered_sets,
               MIN(fn_subcontract_draw_sets(fact.sent_qty + fact.pending_qty + fact.open_available, fact.bom_unit_qty)) AS reachable_sets,
               COALESCE(bool_and(NOT fact.line_open OR fact.sent_qty + fact.pending_qty >= fact.needed_qty), FALSE) AS covered_all,
               COALESCE(bool_and(NOT fact.line_open OR fact.sent_qty >= fact.needed_qty), FALSE) AS sent_all,
               COALESCE(bool_or(fact.line_open), FALSE) AS open_any
        FROM facts fact
    ), sets AS (
        SELECT item.q, item.qm, totals.*,
               CASE WHEN totals.kinds = 0 THEN 0 ELSE LEAST(item.qm, totals.sent_sets) END AS drawn,
               CASE WHEN totals.kinds = 0 THEN 0 ELSE LEAST(item.qm, totals.covered_sets) END AS complete,
               CASE WHEN totals.kinds = 0 THEN 0 ELSE LEAST(item.qm, totals.reachable_sets) END AS reachable
        FROM item CROSS JOIN totals
    )
    SELECT sets.q, sets.kinds, sets.ready, sets.drawn,
           sets.complete - sets.drawn,
           GREATEST(sets.reachable - sets.complete, 0),
           CASE WHEN sets.kinds = 0 THEN 0
                ELSE sets.qm - sets.drawn - (sets.complete - sets.drawn) - GREATEST(sets.reachable - sets.complete, 0) END,
           sets.complete, sets.reachable, sets.covered_all, sets.sent_all, sets.open_any, sets.qm
    FROM sets
$$;
COMMENT ON FUNCTION fn_subcontract_draw_summary(UUID) IS
    'V798(ADR-143 三.4/三.4a): Qm = fn_subcontract_material_qty(没有委外商自带料时 = Q); drawn = LEAST(Qm, MIN sets(sent)); pending = LEAST(Qm, MIN sets(sent+pending)) - drawn; drawable = MAX(0, LEAST(Qm, MIN sets(covered+available)) - complete); short = Qm - drawn - pending - drawable; ready / all_covered / all_sent 按 needed = LEAST(planned, f(Qm)); order_qty = Q, material_qty = Qm. 没有计划行(缺 BOM 的委外件不能批准, 不应出现)时 material_kind_count 与各数为 0、all_* 为假(不放行)';

-- 可回厂套数(订货单位, ADR-143 三.6): 委外商处能做成 P 的完整套数; 没有计划行时为 0(不放行回厂)。
CREATE FUNCTION fn_subcontract_returnable_qty(p_order_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN COUNT(line.id) = 0 THEN 0
                ELSE LEAST(MAX(order_item.qty),
                           MIN(fn_subcontract_draw_sets(COALESCE(supplier.usable_qty, 0), line.bom_unit_qty))) END
    FROM subcontract_order_items order_item
    JOIN subcontract_material_plan_items line ON line.order_item_id = order_item.id AND NOT line.is_deleted
    LEFT JOIN LATERAL (
        SELECT SUM(item.at_supplier_qty + item.compensated_qty
                   - COALESCE(item.returned_qty, 0) - COALESCE(item.wasted_qty, 0)) AS usable_qty
        FROM subcontract_material_issue_items item
        JOIN subcontract_material_issues issue ON issue.id = item.issue_id
         AND issue.status = 1 AND NOT issue.is_deleted
        WHERE item.plan_item_id = line.id AND NOT item.is_deleted
    ) supplier ON TRUE
    WHERE order_item.id = p_order_item
$$;
COMMENT ON FUNCTION fn_subcontract_returnable_qty(UUID) IS
    'V798(ADR-143 三.6): LEAST(Q, MIN_i sets_i(usable_i)), usable = 已审核发料的 at_supplier + compensated - returned - wasted; 无计划行返回 0(缺 BOM 的委外件不能批准, 已批准明细一定有计划行; 万一没有则不放行)';

-- 回厂物料口径(订货单位): R = 有效(已审核未红冲)回厂行的 material_basis_qty 之和, 及已红冲回厂行数(核销尾差容差)。
CREATE FUNCTION fn_subcontract_receipt_basis(p_order_item UUID)
RETURNS TABLE(basis_qty NUMERIC, reversed_line_count INTEGER)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(item.material_basis_qty) FILTER (WHERE receipt.status = 1 AND NOT receipt.is_deleted), 0),
           (COUNT(*) FILTER (WHERE receipt.status = -1
               OR EXISTS (SELECT 1 FROM subcontract_receipt_material_consumptions reversal
                          WHERE reversal.receipt_item_id = item.id AND reversal.reversal_of IS NOT NULL)))::INTEGER
    FROM subcontract_receipt_items item
    JOIN subcontract_receipts receipt ON receipt.id = item.receipt_id
    WHERE item.order_item_id = p_order_item AND NOT item.is_deleted
$$;
COMMENT ON FUNCTION fn_subcontract_receipt_basis(UUID) IS
    'V798(ADR-143 三.7): basis_qty = R(订货单位, 回厂审核时冻结的 material_basis_qty 之和); reversed_line_count = 已红冲的回厂行数';

-- 成本完整性(ADR-143 三.8): 领料制回厂行在每种冻结物料核销都达到目标量时完整;
-- 无计划行(缺 BOM 的委外件不能批准, 不应出现)一律不完整(fail-closed)。
CREATE FUNCTION fn_subcontract_receipt_material_complete(p_receipt_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    WITH receipt_line AS (
        SELECT item.id, item.order_item_id, item.material_basis_qty
        FROM subcontract_receipt_items item
        WHERE item.id = p_receipt_item AND NOT item.is_deleted
    ), live AS (
        SELECT consumption.issue_item_id, consumption.consumption_basis
        FROM subcontract_receipt_material_consumptions consumption
        JOIN receipt_line ON receipt_line.id = consumption.receipt_item_id
        WHERE consumption.reversal_of IS NULL
          AND NOT EXISTS (SELECT 1 FROM subcontract_receipt_material_consumptions reversed
                          WHERE reversed.reversal_of = consumption.id)
    ), lines AS (
        SELECT plan_item.id, plan_item.bom_unit_qty
        FROM subcontract_material_plan_items plan_item
        JOIN receipt_line ON receipt_line.order_item_id = plan_item.order_item_id
        WHERE NOT plan_item.is_deleted
    ), basis AS (
        SELECT receipt_basis.basis_qty, receipt_basis.reversed_line_count
        FROM receipt_line CROSS JOIN LATERAL fn_subcontract_receipt_basis(receipt_line.order_item_id) receipt_basis
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM receipt_line) THEN FALSE
        WHEN NOT EXISTS (SELECT 1 FROM lines) THEN FALSE
        ELSE (SELECT material_basis_qty FROM receipt_line) IS NOT NULL
             AND NOT EXISTS (
                 SELECT 1 FROM live
                 JOIN subcontract_material_issue_items issue_item ON issue_item.id = live.issue_item_id
                 LEFT JOIN lines ON lines.id = issue_item.plan_item_id
                 WHERE lines.id IS NULL OR live.consumption_basis <> 'FROZEN_BOM_ESTIMATE')
             AND NOT EXISTS (
                 SELECT 1
                 FROM lines CROSS JOIN basis
                 WHERE abs(COALESCE((SELECT SUM(issue_item.consumed_qty)
                                     FROM subcontract_material_issue_items issue_item
                                     JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                                      AND issue.status = 1 AND NOT issue.is_deleted
                                     WHERE issue_item.plan_item_id = lines.id AND NOT issue_item.is_deleted), 0)
                           - fn_subcontract_draw_f(basis.basis_qty, lines.bom_unit_qty))
                       > basis.reversed_line_count * 0.0001)
        END
$$;
COMMENT ON FUNCTION fn_subcontract_receipt_material_complete(UUID) IS
    'V798(ADR-143 三.8): 回厂行的物料成本是否完整(可计价 FINAL). 有计划行: 已冻结物料口径, 切片全是冻结计划物料, 每种物料累计核销达到 f(R); 无计划行(不应出现): 不完整';

-- ---------------------------------------------------------------------
-- 4b. 本特性自有守卫整体重写(不重建触发器, 保留 ENABLE ALWAYS 与延迟属性)
-- ---------------------------------------------------------------------
-- 冻结计划行插入守卫: 必须对应 fn_subcontract_draw_edges(订货货品) 的一条边。
CREATE OR REPLACE FUNCTION fn_guard_subcontract_target_quantity_basis_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM subcontract_order_items order_item
        CROSS JOIN LATERAL fn_subcontract_draw_edges(order_item.goods_id) edge
        JOIN goods component ON component.id = edge.component_goods_id
        WHERE order_item.id = NEW.order_item_id AND NOT order_item.is_deleted
          AND NEW.parent_goods_id = order_item.goods_id
          AND NEW.parent_color_id IS NOT DISTINCT FROM order_item.color_id
          AND NEW.goods_id = edge.component_goods_id
          AND NEW.color_id IS NOT DISTINCT FROM edge.color_id
          AND NEW.unit_id IS NOT DISTINCT FROM component.unit_id
          AND NEW.unit_rate = 1
          AND NEW.bom_unit_qty = ROUND(COALESCE(order_item.unit_rate, 1) * edge.edge_qty, 6)
          AND NEW.planned_qty = fn_subcontract_draw_f(order_item.qty, NEW.bom_unit_qty)
          AND NEW.issued_qty = 0
          AND NEW.draw_closed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'subcontract draw plan line must freeze one drawable direct BOM edge of the ordered goods'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_plan_basis_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- 发料分配守卫: 已审核的绑定计划行发料必须由同一计划行的委外出仓预留切片精确覆盖。
CREATE OR REPLACE FUNCTION fn_assert_subcontract_outbound_issue_allocation(p_issue_item_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_expected NUMERIC;
    v_allocated NUMERIC;
BEGIN
    SELECT CASE WHEN issue.status = 1 AND NOT issue.is_deleted AND NOT issue_item.is_deleted
                THEN issue_item.qty ELSE 0 END
      INTO v_expected
    FROM subcontract_material_issue_items issue_item
    JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
    JOIN subcontract_material_plan_items plan_item ON plan_item.id = issue_item.plan_item_id
    WHERE issue_item.id = p_issue_item_id;
    IF NOT FOUND THEN RETURN; END IF;

    IF EXISTS (
        SELECT 1
        FROM subcontract_outbound_issue_reservation_allocations allocation
        JOIN subcontract_material_issue_items issue_item ON issue_item.id = allocation.issue_item_id
        JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
        JOIN subcontract_material_plan_items plan_item ON plan_item.id = issue_item.plan_item_id
        JOIN stock_reservations reservation ON reservation.id = allocation.reservation_id
        WHERE allocation.issue_item_id = p_issue_item_id
          AND allocation.status = 'EFFECTIVE'
          AND (allocation.issue_id <> issue_item.issue_id
            OR allocation.plan_item_id <> issue_item.plan_item_id
            OR reservation.owner_type <> 'SUBCONTRACT_OUTBOUND'
            OR reservation.purpose <> 'SUBCONTRACT_OUTBOUND'
            OR reservation.owner_id <> allocation.plan_item_id
            OR reservation.warehouse_id IS DISTINCT FROM issue.warehouse_id
            OR reservation.goods_id IS DISTINCT FROM issue_item.goods_id
            OR reservation.color_id IS DISTINCT FROM issue_item.color_id
            OR plan_item.goods_id IS DISTINCT FROM issue_item.goods_id
            OR plan_item.color_id IS DISTINCT FROM issue_item.color_id)
    ) THEN
        RAISE EXCEPTION 'subcontract outbound allocation provenance is inconsistent'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(allocated_qty), 0) INTO v_allocated
    FROM subcontract_outbound_issue_reservation_allocations
    WHERE issue_item_id = p_issue_item_id AND status = 'EFFECTIVE';
    IF v_allocated <> v_expected THEN
        RAISE EXCEPTION 'approved subcontract draw issue lacks exact reservation coverage'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- 委外出仓预留守卫: 只核对预留消费与发料分配相等(前置自制成品来源判定随本轮删除)。
CREATE OR REPLACE FUNCTION fn_check_subcontract_outbound_reservation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' AND OLD.owner_type = 'SUBCONTRACT_OUTBOUND' THEN
        PERFORM fn_assert_subcontract_outbound_reservation_allocation(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' AND NEW.owner_type = 'SUBCONTRACT_OUTBOUND' THEN
        PERFORM fn_assert_subcontract_outbound_reservation_allocation(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

-- 接管精确批次: 只吃本计划行那种物料、该冻结颜色、该仓的批次; 草稿行数量必须等于本次接管请求量。
CREATE OR REPLACE FUNCTION fn_subcontract_take_component_entitlements(
    p_plan_item UUID, p_issue UUID, p_warehouse UUID, p_qty NUMERIC, p_actor UUID)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
    plan_item subcontract_material_plan_items%ROWTYPE;
    lot RECORD;
    source stock_reservations%ROWTYPE;
    take_qty NUMERIC;
    remaining NUMERIC := p_qty;
    target_id UUID;
    release_id UUID;
    handoff_id UUID;
    balance_id UUID;
BEGIN
    SELECT * INTO plan_item FROM subcontract_material_plan_items
    WHERE id = p_plan_item AND NOT is_deleted AND draw_closed_at IS NULL
    FOR UPDATE;
    IF plan_item.id IS NULL OR p_qty IS NULL OR p_qty <= 0 OR p_actor IS NULL OR NOT EXISTS (
        SELECT 1
        FROM subcontract_material_issues issue
        JOIN subcontract_material_issue_items item ON item.issue_id = issue.id
        WHERE issue.id = p_issue AND issue.status = 0 AND NOT issue.is_deleted
          AND issue.warehouse_id = p_warehouse
          AND item.plan_item_id = p_plan_item AND NOT item.is_deleted AND item.qty = p_qty
    ) THEN
        RAISE EXCEPTION 'invalid component custody handoff' USING ERRCODE = '23514';
    END IF;
    FOR lot IN
        SELECT * FROM fn_subcontract_component_entitled_lots(plan_item.order_item_id) candidate
        WHERE candidate.plan_item_id = p_plan_item
          AND candidate.warehouse_id = p_warehouse
          AND candidate.goods_id = plan_item.goods_id
          AND candidate.color_id IS NOT DISTINCT FROM plan_item.color_id
        ORDER BY candidate.entitlement_event_id
    LOOP
        EXIT WHEN remaining <= 0;
        PERFORM 1 FROM preplan_stock_entitlement_events WHERE id = lot.entitlement_event_id FOR UPDATE;
        SELECT * INTO STRICT source FROM stock_reservations WHERE id = lot.stock_reservation_id FOR UPDATE;
        take_qty := LEAST(remaining, lot.remaining_qty, source.qty - source.consumed_qty - source.released_qty);
        IF take_qty <= 0 OR source.status <> 0 THEN CONTINUE; END IF;
        IF balance_id IS NULL THEN
            SELECT id INTO STRICT balance_id FROM stock_balances
            WHERE warehouse_id = p_warehouse AND goods_id = plan_item.goods_id
              AND color_id IS NOT DISTINCT FROM plan_item.color_id;
        END IF;
        handoff_id := gen_random_uuid();
        target_id := gen_random_uuid();
        release_id := gen_random_uuid();
        INSERT INTO preplan_stock_entitlement_events(id, event_group_id, stock_reservation_id,
            beneficiary_analysis_id, beneficiary_analysis_material_id, event_type, qty,
            source_entitlement_event_id, reallocation_id, idempotency_key, created_by)
        VALUES (release_id, handoff_id, source.id, lot.beneficiary_analysis_id, lot.beneficiary_analysis_material_id,
            'RELEASE', take_qty, lot.entitlement_event_id, lot.reallocation_id, 'SC-COMPONENT-OUT:' || handoff_id, p_actor);
        UPDATE stock_reservations
        SET released_qty = released_qty + take_qty,
            status = CASE WHEN consumed_qty + released_qty + take_qty = qty THEN 1 ELSE 0 END,
            release_reason = 'TRANSFERRED_TO_SUBCONTRACT',
            lock_version = lock_version + 1, updated_at = now(), updated_by = p_actor
        WHERE id = source.id;
        INSERT INTO stock_reservations(id, goods_id, color_id, warehouse_id, qty, consumed_qty, released_qty, status, source,
            source_doc_type, source_doc_id, owner_type, owner_id, purpose, supply_type, supply_id, idempotency_key,
            created_by, updated_by)
        VALUES (target_id, source.goods_id, source.color_id, p_warehouse, take_qty, 0, 0, 0, 0,
            'SUBCONTRACT_OUTBOUND_DRAFT', p_issue, 'SUBCONTRACT_OUTBOUND', p_plan_item, 'SUBCONTRACT_OUTBOUND',
            'STOCK_BALANCE', balance_id, 'SC-COMPONENT-STOCK:' || handoff_id, p_actor, p_actor);
        INSERT INTO subcontract_component_stock_handoffs(id, plan_item_id, application_item_id, parent_material_id,
            child_material_id, source_entitlement_event_id, source_reservation_id, target_reservation_id,
            release_event_id, qty, created_by)
        VALUES (handoff_id, p_plan_item, lot.application_item_id, lot.parent_material_id,
            lot.beneficiary_analysis_material_id, lot.entitlement_event_id, source.id, target_id, release_id,
            take_qty, p_actor);
        remaining := remaining - take_qty;
    END LOOP;
    RETURN p_qty - remaining;
END;
$$;

-- 交接血缘守卫: 认冻结计划行(物料 + 冻结颜色), 不认现时 BOM; 顶层委外件的物料节点是来源行 depth=1 节点。
CREATE OR REPLACE FUNCTION fn_guard_subcontract_component_handoff_lineage()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        JOIN subcontract_material_plans plan ON plan.id = plan_item.plan_id
         AND plan.status = 'OPEN' AND NOT plan.is_deleted
        JOIN subcontract_order_items order_item ON order_item.id = plan_item.order_item_id
         AND NOT order_item.is_deleted
        JOIN subcontract_order_item_sources order_source ON order_source.order_item_id = order_item.id
         AND order_source.application_item_id = NEW.application_item_id AND order_source.alloc_qty > 0
        JOIN subcontract_application_items application ON application.id = order_source.application_item_id
         AND NOT application.is_deleted AND application.goods_id = order_item.goods_id
         AND application.color_id IS NOT DISTINCT FROM order_item.color_id
        JOIN production_material_analysis_materials parent ON parent.id = NEW.parent_material_id
         AND parent.active AND parent.goods_id = application.goods_id
         AND parent.color_id IS NOT DISTINCT FROM application.color_id
        JOIN production_material_analysis_materials child ON child.id = NEW.child_material_id
         AND child.active AND child.analysis_id = parent.analysis_id
         AND child.analysis_item_id = parent.analysis_item_id
         AND ((parent.node_role = 'ROOT_SUPPLY' AND child.depth = 1 AND child.parent_node_key IS NULL)
              OR (parent.node_role <> 'ROOT_SUPPLY' AND child.parent_node_key = parent.node_key))
        JOIN preplan_supply_action_allocations allocation ON allocation.analysis_id = parent.analysis_id
         AND allocation.analysis_material_id = parent.id AND allocation.allocated_qty > 0
        JOIN preplan_supply_actions action ON action.id = allocation.action_id
         AND action.analysis_id = parent.analysis_id AND action.route = 'SUBCONTRACT'
         AND action.operation_type = 'SUPPLY' AND action.status <> 'CANCELLED'
         AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
         AND action.external_document_id = application.application_id
         AND (allocation.external_item_id = application.id OR action.public_surplus_external_item_id = application.id)
        JOIN preplan_stock_entitlement_events origin ON origin.id = NEW.source_entitlement_event_id
         AND origin.stock_reservation_id = NEW.source_reservation_id
         AND origin.beneficiary_analysis_id = child.analysis_id
         AND origin.beneficiary_analysis_material_id = child.id
        JOIN stock_reservations source ON source.id = origin.stock_reservation_id
         AND source.owner_type = 'PREPLAN_ANALYSIS' AND NOT source.is_deleted
         AND source.goods_id = child.goods_id AND source.color_id IS NOT DISTINCT FROM child.color_id
        JOIN stock_reservations target ON target.id = NEW.target_reservation_id
         AND target.owner_type = 'SUBCONTRACT_OUTBOUND' AND target.owner_id = plan_item.id
         AND target.source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
         AND target.goods_id = source.goods_id AND target.color_id IS NOT DISTINCT FROM source.color_id
         AND target.warehouse_id = source.warehouse_id
        JOIN subcontract_material_issues issue ON issue.id = target.source_doc_id
         AND issue.status = 0 AND NOT issue.is_deleted AND issue.warehouse_id = target.warehouse_id
        JOIN subcontract_material_issue_items issue_item ON issue_item.issue_id = issue.id
         AND issue_item.plan_item_id = plan_item.id AND NOT issue_item.is_deleted
         AND issue_item.qty >= NEW.qty
        WHERE plan_item.id = NEW.plan_item_id
          AND NOT plan_item.is_deleted AND plan_item.draw_closed_at IS NULL
          AND plan_item.parent_goods_id = parent.goods_id
          AND plan_item.goods_id = child.goods_id
          AND plan_item.color_id IS NOT DISTINCT FROM child.color_id
    ) THEN
        RAISE EXCEPTION 'subcontract component custody must retain the exact application parent and entitled child'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_component_handoff_lineage';
    END IF;
    RETURN NEW;
END;
$$;

-- 回厂守恒(目标跟踪, ADR-143 三.7): 逐计划行核对 核销量 <= usable 与 |核销量 - f(R)| <= 已红冲回厂行数 x 0.0001。
-- R 用回厂审核时冻结的 material_basis_qty; 冻结口径相对回厂量的净额只能来自 V507 质检补回分配与
-- V642 财务批准的委外商自带料。无计划行(缺 BOM 的委外件不能批准, 不应出现)时可回厂套数按 0:
-- 物料口径回厂量 R 必须为 0(整行只能是质检补回或财务批准的委外商自带料), 否则拒绝(fail-closed)。
-- 老系统导入的回厂行(行或单头带 legacy_id / legacy_import_run_id)从来没有冻结口径, 不算「缺口径」;
-- 它们的 material_basis_qty 为空, 本来就不进净额、R 与无计划行检查, 所以只需在缺口径计数里豁免。
CREATE OR REPLACE FUNCTION fn_assert_subcontract_target_outbound_receipt(p_order_item_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_rate NUMERIC;
    v_basis NUMERIC;
    v_reversed_lines INTEGER;
    v_missing_basis INTEGER;
    v_netted NUMERIC;
    v_netted_lines INTEGER;
    v_replacement NUMERIC;
    v_supplier_own NUMERIC;
    v_target NUMERIC;
    line RECORD;
BEGIN
    IF p_order_item_id IS NULL THEN
        RETURN;
    END IF;

    SELECT COALESCE(unit_rate, 1) INTO v_rate
    FROM subcontract_order_items WHERE id = p_order_item_id FOR NO KEY UPDATE;

    SELECT COUNT(*) FILTER (WHERE item.material_basis_qty IS NULL
                              AND item.legacy_id IS NULL AND item.legacy_import_run_id IS NULL
                              AND receipt.legacy_id IS NULL AND receipt.legacy_import_run_id IS NULL),
           COALESCE(SUM(item.qty - item.material_basis_qty) FILTER (WHERE item.material_basis_qty < item.qty), 0),
           COUNT(*) FILTER (WHERE item.material_basis_qty < item.qty)
      INTO v_missing_basis, v_netted, v_netted_lines
    FROM subcontract_receipt_items item
    JOIN subcontract_receipts receipt ON receipt.id = item.receipt_id
     AND receipt.status = 1 AND NOT receipt.is_deleted
    WHERE item.order_item_id = p_order_item_id AND NOT item.is_deleted;
    IF v_missing_basis > 0 THEN
        RAISE EXCEPTION 'approved subcontract receipt line lacks its frozen material basis'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_receipt_material_basis_guard';
    END IF;

    SELECT COALESCE(SUM(allocation.allocated_base_qty), 0) INTO v_replacement
    FROM procurement_iqc_replacement_allocations allocation
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id = allocation.case_id
     AND rejection.receipt_type = 'SUBCONTRACT' AND rejection.order_item_id = p_order_item_id
     AND rejection.is_deleted = FALSE AND rejection.status <> 'REVERSED'
     AND rejection.return_recorded_at IS NOT NULL
    JOIN subcontract_receipt_items original_item ON original_item.id = rejection.receipt_item_id
     AND original_item.receipt_id = rejection.receipt_id AND original_item.order_item_id = p_order_item_id
     AND original_item.is_deleted = FALSE
    JOIN subcontract_receipts original_receipt ON original_receipt.id = original_item.receipt_id
     AND original_receipt.status = 1 AND original_receipt.is_deleted = FALSE
    JOIN subcontract_receipt_items replacement_item ON replacement_item.id = allocation.replacement_receipt_item_id
     AND replacement_item.order_item_id = p_order_item_id AND replacement_item.is_deleted = FALSE
     AND replacement_item.goods_id = rejection.goods_id
     AND replacement_item.color_id IS NOT DISTINCT FROM rejection.color_id
    JOIN subcontract_receipts replacement_receipt ON replacement_receipt.id = replacement_item.receipt_id
     AND replacement_receipt.status = 1 AND replacement_receipt.is_deleted = FALSE
     AND replacement_receipt.supplier_id = rejection.supplier_id
    WHERE allocation.replacement_receipt_type = 'SUBCONTRACT' AND allocation.status = 'ACTIVE';

    v_supplier_own := fn_subcontract_supplier_own_qty(p_order_item_id);

    IF v_netted > v_replacement / NULLIF(v_rate, 0) + v_supplier_own + v_netted_lines * 0.0001 THEN
        RAISE EXCEPTION 'subcontract receipt material basis nets more than IQC replacements and finance-approved supplier material'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_first_guard';
    END IF;

    SELECT receipt_basis.basis_qty, receipt_basis.reversed_line_count
      INTO v_basis, v_reversed_lines
    FROM fn_subcontract_receipt_basis(p_order_item_id) receipt_basis;

    IF v_basis > 0 AND NOT EXISTS (
        SELECT 1 FROM subcontract_material_plan_items plan_item
        WHERE plan_item.order_item_id = p_order_item_id AND NOT plan_item.is_deleted
    ) THEN
        RAISE EXCEPTION 'subcontract receipt has no frozen draw plan lines, so its returnable quantity is 0'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_first_guard';
    END IF;

    FOR line IN
        SELECT plan_item.id, plan_item.bom_unit_qty,
               COALESCE(SUM(issue_item.consumed_qty), 0) AS consumed_qty,
               COALESCE(SUM(issue_item.at_supplier_qty + issue_item.compensated_qty
                            - COALESCE(issue_item.returned_qty, 0) - COALESCE(issue_item.wasted_qty, 0)), 0) AS usable_qty
        FROM subcontract_material_plan_items plan_item
        LEFT JOIN (subcontract_material_issue_items issue_item
                   JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                    AND issue.status = 1 AND NOT issue.is_deleted)
          ON issue_item.plan_item_id = plan_item.id AND NOT issue_item.is_deleted
        WHERE plan_item.order_item_id = p_order_item_id AND NOT plan_item.is_deleted
        GROUP BY plan_item.id, plan_item.bom_unit_qty
    LOOP
        IF line.consumed_qty > line.usable_qty THEN
            RAISE EXCEPTION 'subcontract receipt consumes more of a material than the supplier holds'
                USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_first_guard';
        END IF;
        v_target := fn_subcontract_draw_f(v_basis, line.bom_unit_qty);
        IF abs(line.consumed_qty - v_target) > v_reversed_lines * 0.0001 THEN
            RAISE EXCEPTION 'subcontract receipt material consumption % differs from target % beyond the reversal tolerance',
                line.consumed_qty, v_target
                USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_consumption_guard';
        END IF;
    END LOOP;
END;
$$;

-- 回厂核销切片守卫: 只能切同一订货明细冻结计划物料的已审核发料, 口径固定 FROZEN_BOM_ESTIMATE(冻结单耗)。
CREATE OR REPLACE FUNCTION fn_guard_subcontract_receipt_material_consumption()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    receipt subcontract_receipt_items%ROWTYPE;
    issue subcontract_material_issue_items%ROWTYPE;
    original subcontract_receipt_material_consumptions%ROWTYPE;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'subcontract material consumption sources are immutable' USING ERRCODE = '55000';
    END IF;
    SELECT * INTO receipt FROM subcontract_receipt_items WHERE id = NEW.receipt_item_id;
    SELECT * INTO issue FROM subcontract_material_issue_items WHERE id = NEW.issue_item_id FOR UPDATE;
    IF receipt.id IS NULL OR issue.id IS NULL OR receipt.order_item_id IS DISTINCT FROM issue.order_item_id
       OR NEW.qty_base <> NEW.qty_doc * COALESCE(issue.unit_rate, 1) THEN
        RAISE EXCEPTION 'subcontract consumption must use the exact order and issued material base quantity'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.consumption_basis <> 'FROZEN_BOM_ESTIMATE' OR NOT EXISTS (
        SELECT 1 FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = issue.plan_item_id AND plan_item.order_item_id = receipt.order_item_id
    ) THEN
        RAISE EXCEPTION 'subcontract consumption must slice a frozen draw-plan material of the same order item'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.reversal_of IS NOT NULL THEN
        SELECT * INTO original FROM subcontract_receipt_material_consumptions WHERE id = NEW.reversal_of;
        IF original.id IS NULL OR original.reversal_of IS NOT NULL
           OR original.receipt_item_id <> NEW.receipt_item_id
           OR original.issue_item_id <> NEW.issue_item_id OR original.qty_doc <> NEW.qty_doc
           OR original.qty_base <> NEW.qty_base OR original.consumption_basis <> NEW.consumption_basis THEN
            RAISE EXCEPTION 'subcontract receipt reversal must restore the same complete original consumption slice'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- 领料草稿行守卫: 绑定计划行的发料行只能由委外领料提交建出(必有 requested_qty), 物料身份与冻结计划行一致,
-- 提交量与所属计划行写入后不可改; qty <= requested_qty 由 CHECK 保证。
CREATE FUNCTION fn_guard_subcontract_draw_issue_item()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    plan_item subcontract_material_plan_items%ROWTYPE;
    plan_open BOOLEAN;
BEGIN
    IF TG_OP = 'UPDATE' AND (OLD.requested_qty IS DISTINCT FROM NEW.requested_qty
                             OR (OLD.plan_item_id IS NOT NULL AND OLD.plan_item_id IS DISTINCT FROM NEW.plan_item_id)) THEN
        RAISE EXCEPTION 'submitted draw quantity and its plan line are immutable'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_issue_requested_guard';
    END IF;
    IF NEW.plan_item_id IS NULL THEN
        IF NEW.requested_qty IS NOT NULL THEN
            RAISE EXCEPTION 'only draw-plan issue lines carry a submitted draw quantity'
                USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_issue_requested_guard';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.requested_qty IS NULL THEN
        RAISE EXCEPTION 'draw-plan issue lines are created only by a subcontract draw submission'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_issue_requested_guard';
    END IF;
    SELECT * INTO plan_item FROM subcontract_material_plan_items WHERE id = NEW.plan_item_id;
    IF plan_item.id IS NULL
       OR plan_item.order_item_id IS DISTINCT FROM NEW.order_item_id
       OR plan_item.goods_id IS DISTINCT FROM NEW.goods_id
       OR plan_item.color_id IS DISTINCT FROM NEW.color_id
       OR plan_item.unit_id IS DISTINCT FROM NEW.unit_id
       OR plan_item.unit_rate IS DISTINCT FROM COALESCE(NEW.unit_rate, 1) THEN
        RAISE EXCEPTION 'subcontract issue line must carry the exact frozen draw-plan material'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_issue_identity_guard';
    END IF;
    IF TG_OP = 'INSERT' THEN
        SELECT plan.status = 'OPEN' AND NOT plan.is_deleted INTO plan_open
        FROM subcontract_material_plans plan WHERE plan.id = plan_item.plan_id;
        IF plan_item.is_deleted OR plan_item.draw_closed_at IS NOT NULL OR plan_open IS NOT TRUE THEN
            RAISE EXCEPTION 'subcontract draw is only accepted on an open plan line'
                USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_issue_identity_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_subcontract_draw_issue_item
    BEFORE INSERT ON subcontract_material_issue_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_draw_issue_item();
CREATE TRIGGER trg_guard_subcontract_draw_issue_item_upd
    BEFORE UPDATE OF plan_item_id, requested_qty, order_item_id, goods_id, color_id, unit_id, unit_rate
    ON subcontract_material_issue_items
    FOR EACH ROW
    WHEN (OLD.plan_item_id IS DISTINCT FROM NEW.plan_item_id
          OR OLD.requested_qty IS DISTINCT FROM NEW.requested_qty
          OR OLD.order_item_id IS DISTINCT FROM NEW.order_item_id
          OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
          OR OLD.color_id IS DISTINCT FROM NEW.color_id
          OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
          OR OLD.unit_rate IS DISTINCT FROM NEW.unit_rate)
    EXECUTE FUNCTION fn_guard_subcontract_draw_issue_item();
ALTER TABLE subcontract_material_issue_items ENABLE ALWAYS TRIGGER trg_guard_subcontract_draw_issue_item;
ALTER TABLE subcontract_material_issue_items ENABLE ALWAYS TRIGGER trg_guard_subcontract_draw_issue_item_upd;

-- ---------------------------------------------------------------------
-- 5. 共享对象按现时定义锚点补丁: 去 CR 后逐条核对命中次数, 不符即中止(不从旧迁移文本重建)。
--    FUNCTION: pg_get_functiondef; VIEW: pg_get_viewdef(pretty); CONSTRAINT: pg_get_constraintdef;
--    INDEX: pg_get_indexdef; TRIGGER: pg_get_triggerdef(重建后恢复原启用模式)。
-- ---------------------------------------------------------------------
CREATE TEMP TABLE v798_anchor_patches (
    seq INTEGER PRIMARY KEY,
    object_kind TEXT NOT NULL CHECK (object_kind IN ('FUNCTION', 'VIEW', 'CONSTRAINT', 'INDEX', 'TRIGGER')),
    object_ref TEXT NOT NULL,
    anchor TEXT NOT NULL CHECK (anchor <> ''),
    replacement TEXT NOT NULL,
    expected_hits INTEGER NOT NULL CHECK (expected_hits > 0)
) ON COMMIT DROP;

INSERT INTO v798_anchor_patches(seq, object_kind, object_ref, anchor, replacement, expected_hits) VALUES
    (1, 'FUNCTION', 'fn_goods_quantity_reference_sources()', E'\n    (''preplan_subcontract_make_tasks'', ARRAY[''goods_id''], ''true''),',
     E'', 1),
    (2, 'FUNCTION', 'fn_goods_quantity_reference_sources()', E'\n    (''preplan_subcontract_requirement_handoff_items'', ARRAY[''goods_id''], ''true''),',
     E'', 1),
    (3, 'FUNCTION', 'fn_goods_quantity_reference_sources()', E'\n    (''preplan_subcontract_requirement_handoffs'', ARRAY[''target_goods_id''], ''true''),',
     E'', 1),
    (4, 'FUNCTION', 'fn_check_preplan_stock_entitlement_event()', E'''SUBCONTRACT_HANDOFF_OUT'', ',
     E'', 2),
    (5, 'FUNCTION', 'fn_check_preplan_stock_entitlement_event()', E'''SUBCONTRACT_HANDOFF_IN'', ',
     E'', 1),
    (6, 'FUNCTION', 'fn_prepare_workshop_preplan_return(uuid,uuid,numeric,uuid)', E'''SUBCONTRACT_HANDOFF_OUT'',',
     E'', 1),
    (7, 'FUNCTION', 'fn_prepare_workshop_preplan_return(uuid,uuid,numeric,uuid)', E'''SUBCONTRACT_HANDOFF_IN'',',
     E'', 1),
    (8, 'FUNCTION', 'fn_analysis_plan_material_matches(uuid,uuid)', E'item.source_type IN(''MAKE_COMPONENT'',''SUBCONTRACT_MAKE'')',
     E'item.source_type=''MAKE_COMPONENT''', 1),
    (9, 'FUNCTION', 'fn_validate_make_component_source_dimension()', E'NEW.source_type NOT IN (''MAKE_COMPONENT'', ''SUBCONTRACT_MAKE'')',
     E'NEW.source_type <> ''MAKE_COMPONENT''', 1),
    (10, 'FUNCTION', 'fn_guard_preplan_reallocation_make_supplement()', E'child.source_type NOT IN (''MAKE_COMPONENT'',''SUBCONTRACT_MAKE'')',
     E'child.source_type<>''MAKE_COMPONENT''', 1),
    (11, 'FUNCTION', 'fn_preplan_aggregate_allocation_pending_qty(uuid)', E'action.external_document_type IN(''PREPLAN_MAKE_TASK'',''SUBCONTRACT_MAKE_TASK'')',
     E'action.external_document_type=''PREPLAN_MAKE_TASK''', 1),
    (12, 'FUNCTION', 'fn_check_preplan_make_entitlement_delegation()', E'\n        WHEN ''SUBCONTRACT'' THEN ''SUBCONTRACT_MAKE_TASK''',
     E'', 1),
    (13, 'FUNCTION', 'fn_check_preplan_make_entitlement_delegation()', E'\n        WHEN ''SUBCONTRACT'' THEN ''SUBCONTRACT_MAKE''',
     E'', 1),
    (14, 'FUNCTION', 'fn_check_preplan_make_entitlement_delegation()', E'action.route NOT IN (''MAKE'', ''SUBCONTRACT'')',
     E'action.route <> ''MAKE''', 1),
    (15, 'FUNCTION', 'fn_guard_preplan_public_surplus_shape()', E'\n        -- V589：前置自制台账\uFF08SUBCONTRACT_MAKE_TASK\uFF09外部化时还没有申请明细，\n        -- 公共量随后续通知批的 action 落到真实申请明细上；其余外部化形态仍\n        -- 必须给出公共明细锚。\n        IF NEW.external_document_type IS DISTINCT FROM ''SUBCONTRACT_MAKE_TASK'' THEN\n            RAISE EXCEPTION ''externalized public surplus must reference its public item''\n                USING ERRCODE = ''23514'';\n        END IF;\n        RETURN NEW;',
     E'\n        RAISE EXCEPTION ''externalized public surplus must reference its public item''\n            USING ERRCODE = ''23514'';', 1),
    (16, 'FUNCTION', 'fn_guard_preplan_supply_action_history()', E'\n                   OR (NEW.route = ''SUBCONTRACT''\n                       AND NEW.external_document_type =\n                           ''SUBCONTRACT_MAKE_TASK'')',
     E'', 1),
    (17, 'FUNCTION', 'fn_guard_preplan_supply_allocation_history()', E'\n                        OR (v_action.external_document_type =\n                                ''SUBCONTRACT_MAKE_TASK''\n                            AND v_action.external_document_id =\n                                NEW.external_item_id\n                            AND EXISTS (\n                                SELECT 1\n                                FROM production_material_analysis_items item\n                                WHERE item.id = NEW.external_item_id\n                                  AND item.analysis_id = NEW.analysis_id\n                                  AND (item.source_type = ''SUBCONTRACT_MAKE'' OR (item.source_type=''AGGREGATE_MAKE''\n        AND EXISTS(SELECT 1 FROM preplan_aggregate_batches batch WHERE batch.anchor_analysis_item_id=item.id AND batch.action_id=NEW.action_id AND batch.route=''SUBCONTRACT'')))\n                                  AND item.is_deleted = FALSE\n                            ))',
     E'', 1),
    (18, 'FUNCTION', 'fn_iqc_replacement_node_capacity(uuid,uuid)', E'\n    -- The preparation ledger owns unnotified subcontract work, including\n    -- already produced targets still waiting for external processing. Once\n    -- notified, the resulting application allocation above owns that quantity.\n    SELECT future_qty+COALESCE(SUM(GREATEST(task.required_qty-task.notified_qty,0)),0)\n      INTO future_qty FROM preplan_subcontract_make_tasks task\n    WHERE task.analysis_material_id=m.id AND task.analysis_id=m.analysis_id AND task.status=''ACTIVE'';',
     E'', 1),
    (19, 'FUNCTION', 'fn_preplan_make_public_supply_sources(uuid,uuid)', E' AND (origin.source_type <> ALL (ARRAY[''SUBCONTRACT_MAKE''::text, ''SUBCONTRACT_PREPARATION''::text]))',
     E'', 1),
    (20, 'FUNCTION', 'fn_preplan_make_public_supply_sources(uuid,uuid)', E' AND NOT (EXISTS ( SELECT 1\n                   FROM preplan_aggregate_batches preparation\n                  WHERE preparation.plan_id = plan.id AND preparation.route = ''SUBCONTRACT''::text))',
     E'', 1),
    (21, 'FUNCTION', 'fn_workshop_direct_relation_code(uuid,uuid)', E'WHEN v_target.supply_route = ''SUBCONTRACT'' OR fn_workshop_direct_source_is_subcontract(p_producing)',
     E'WHEN v_target.supply_route = ''SUBCONTRACT''', 1),
    (22, 'FUNCTION', 'fn_workshop_direct_targets(uuid,uuid,numeric)', E'\n               WHEN fn_workshop_direct_source_is_subcontract(p_producing) THEN ''SUBCONTRACT_ROUTE''',
     E'', 1),
    (23, 'FUNCTION', 'fn_workshop_direct_targets(uuid,uuid,numeric)', E'item.source_type IN (''MAKE_COMPONENT'', ''SUBCONTRACT_MAKE'', ''AGGREGATE_MAKE'')',
     E'item.source_type IN (''MAKE_COMPONENT'', ''AGGREGATE_MAKE'')', 1),
    (24, 'FUNCTION', 'fn_preplan_allocation_effective_exact_qty(uuid)', E'reservation.release_reason = ''TRANSFERRED_TO_PLAN''',
     E'reservation.release_reason IN (''TRANSFERRED_TO_PLAN'', ''TRANSFERRED_TO_SUBCONTRACT'')', 2),
    (25, 'FUNCTION', 'fn_guard_aggregate_anchor()', E'batch.route IN(''MAKE'',''SUBCONTRACT'')',
     E'batch.route=''MAKE''', 1),
    (26, 'FUNCTION', 'fn_notice_warehouse_visible(uuid,text,text,uuid,text,text)', E'\n        WHEN ''SUBCONTRACT_OUTBOUND_READY'' THEN\n            SELECT array_agg(DISTINCT warehouse) INTO warehouses FROM (\n                SELECT item.preparation_warehouse_id AS warehouse FROM subcontract_material_plan_items item\n                WHERE item.plan_id=COALESCE((SELECT plan_id FROM subcontract_material_plan_items WHERE id=source_id),route_id)\n                  AND NOT item.is_deleted AND (item.preparation_warehouse_id IS NOT NULL OR NOT EXISTS (\n                      SELECT 1 FROM subcontract_material_issue_items detail JOIN subcontract_material_issues draft ON draft.id=detail.issue_id\n                      WHERE detail.plan_item_id=item.id AND NOT detail.is_deleted AND draft.status=0 AND NOT draft.is_deleted))\n                UNION SELECT issue.warehouse_id FROM subcontract_material_issue_items detail\n                JOIN subcontract_material_issues issue ON issue.id=detail.issue_id\n                JOIN subcontract_material_plan_items item ON item.id=detail.plan_item_id\n                WHERE item.plan_id=COALESCE((SELECT plan_id FROM subcontract_material_plan_items WHERE id=source_id),route_id)\n                  AND NOT item.is_deleted AND NOT detail.is_deleted AND issue.status=0 AND NOT issue.is_deleted\n            ) outbound_warehouses;',
     E'\n        WHEN ''SUBCONTRACT_OUTBOUND_READY'' THEN\n            -- V798(ADR-143): one card per submitted draw draft; its warehouse is the draft''s issue warehouse.\n            SELECT array_agg(DISTINCT issue.warehouse_id) INTO warehouses FROM subcontract_material_issues issue\n            WHERE issue.id=COALESCE(source_id,route_id) AND NOT issue.is_deleted;', 1),
    (27, 'FUNCTION', 'fn_preplan_aggregate_allocation_scope(uuid)', E'\n    RETURN EXISTS(\n        SELECT 1 FROM preplan_supply_actions action\n        JOIN preplan_subcontract_make_task_batches notified ON notified.application_id=action.external_document_id\n        JOIN preplan_subcontract_make_tasks task ON task.id=notified.task_id\n        JOIN preplan_aggregate_batches shared ON shared.action_id=task.supply_action_id\n          AND shared.anchor_analysis_item_id=task.preparation_item_id AND shared.analysis_id=task.analysis_id\n          AND shared.route=''SUBCONTRACT''\n        WHERE action.id=p_action AND action.analysis_id=shared.analysis_id\n          AND action.external_document_type=''SUBCONTRACT_APPLICATION''\n          AND (EXISTS(SELECT 1 FROM preplan_supply_action_allocations slice\n                  WHERE slice.id=notified.allocation_id AND slice.action_id=action.id\n                    AND slice.external_item_id=notified.application_item_id)\n            OR (notified.allocation_id IS NULL AND action.requested_qty=0\n                AND action.public_surplus_external_item_id=notified.application_item_id)));',
     E'\n    RETURN FALSE;', 1),
    (28, 'FUNCTION', 'fn_check_subcontract_cost_scope_facts()', E'\n            SELECT expected_qty>0 AND expected_qty=(SELECT COALESCE(SUM(qty_base),0) FROM subcontract_receipt_material_consumptions c\n                WHERE c.receipt_item_id=object.execution_segment_id AND c.reversal_of IS NULL\n                  AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversed WHERE reversed.reversal_of=c.id))\n                AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions c WHERE c.receipt_item_id=object.execution_segment_id\n                    AND c.reversal_of IS NULL AND c.consumption_basis<>''DIRECT_TARGET'') INTO complete;',
     E'\n            complete:=expected_qty>0 AND fn_subcontract_receipt_material_complete(object.execution_segment_id);', 1),
    (29, 'VIEW', 'v_preplan_stock_entitlement_lot_balance', E'''SUBCONTRACT_HANDOFF_OUT''::text, ',
     E'', 1),
    (30, 'VIEW', 'v_preplan_stock_entitlement_lot_balance', E'''SUBCONTRACT_HANDOFF_IN''::text, ',
     E'', 1),
    (31, 'VIEW', 'v_production_execution_workbench_roots', E'ARRAY[''MAKE_COMPONENT''::text, ''SUBCONTRACT_MAKE''::text]',
     E'ARRAY[''MAKE_COMPONENT''::text]', 1),
    (32, 'CONSTRAINT', 'stock_reservations.stock_reservations_owner_type_chk', E', ''SUBCONTRACT_PREPARE_TASK''::text',
     E'', 1),
    (33, 'CONSTRAINT', 'stock_reservations.stock_reservations_owner_type_chk', E' OR (owner_type = ''SUBCONTRACT_ORDER_PREPARATION''::text)',
     E'', 1),
    (34, 'CONSTRAINT', 'stock_reservations.stock_reservations_purpose_chk', E', ''SUBCONTRACT_PREPARE_TASK''::text',
     E'', 1),
    (35, 'CONSTRAINT', 'stock_reservations.stock_reservations_purpose_chk', E' OR (purpose = ''SUBCONTRACT_ORDER_PREPARATION''::text)',
     E'', 1),
    (36, 'CONSTRAINT', 'stock_reservations.stock_reservations_owner_shape_chk', E' OR ((owner_type = ''SUBCONTRACT_PREPARE_TASK''::text) AND (purpose = ''SUBCONTRACT_PREPARE_TASK''::text) AND (order_item_id IS NULL) AND (demand_id IS NULL) AND (owner_id IS NOT NULL) AND (warehouse_id IS NOT NULL) AND (supply_type = ''PRODUCTION_FINISHED_IN''::text) AND (supply_id IS NOT NULL) AND (idempotency_key IS NOT NULL))',
     E'', 1),
    (37, 'CONSTRAINT', 'stock_reservations.stock_reservations_owner_shape_chk', E' OR ((owner_type = ''SUBCONTRACT_ORDER_PREPARATION''::text) AND (purpose = ''SUBCONTRACT_ORDER_PREPARATION''::text) AND (owner_id IS NOT NULL) AND (order_item_id IS NULL) AND (demand_id IS NULL) AND (warehouse_id IS NOT NULL) AND (consumed_qty = (0)::numeric) AND ((status = 0) OR (released_qty = qty)) AND ((NOT is_deleted) OR (released_qty = qty)) AND (supply_type = ''PRODUCTION_FINISHED_IN''::text) AND (supply_id IS NOT NULL) AND (source_doc_type = ''PRODUCTION_INBOUND''::text) AND (source_doc_id IS NOT NULL) AND (idempotency_key IS NOT NULL))',
     E'', 1),
    (38, 'CONSTRAINT', 'stock_reservations.stock_reservations_owner_shape_chk', E'(supply_type = ANY (ARRAY[''STOCK_BALANCE''::text, ''PRODUCTION_FINISHED_IN''::text]))',
     E'(supply_type = ''STOCK_BALANCE''::text)', 1),
    (39, 'CONSTRAINT', 'production_material_analysis_items.production_material_analysis_item_source_type_chk', E', ''SUBCONTRACT_MAKE''::text, ''SUBCONTRACT_PREPARATION''::text',
     E'', 1),
    (40, 'CONSTRAINT', 'production_material_analysis_items.production_material_analysis_item_parent_shape_chk', E'ARRAY[''MAKE_COMPONENT''::text, ''SUBCONTRACT_MAKE''::text]',
     E'ARRAY[''MAKE_COMPONENT''::text]', 2),
    (41, 'CONSTRAINT', 'preplan_supply_actions.preplan_supply_action_external_chk', E', ''SUBCONTRACT_MAKE_TASK''::text',
     E'', 1),
    (42, 'CONSTRAINT', 'preplan_supply_actions.preplan_supply_action_route_external_v250_chk', E' OR ((route = ''SUBCONTRACT''::text) AND (external_document_type = ''SUBCONTRACT_MAKE_TASK''::text))',
     E'', 1),
    (43, 'CONSTRAINT', 'preplan_stock_entitlement_events.preplan_entitlement_event_type_chk', E'''SUBCONTRACT_HANDOFF_IN''::text, ''SUBCONTRACT_HANDOFF_OUT''::text, ',
     E'', 1),
    (44, 'CONSTRAINT', 'subcontract_receipt_material_consumptions.subcontract_receipt_material_consumptio_consumption_basis_check', E'ARRAY[''DIRECT_TARGET''::text, ''FROZEN_BOM_ESTIMATE''::text]',
     E'ARRAY[''FROZEN_BOM_ESTIMATE''::text]', 1),
    (45, 'INDEX', 'uq_production_material_analysis_make_component_parent', E'ARRAY[''MAKE_COMPONENT''::text, ''SUBCONTRACT_MAKE''::text]',
     E'ARRAY[''MAKE_COMPONENT''::text]', 1),
    (46, 'INDEX', 'uq_production_material_analysis_system_source_ref', E' AND (NOT ((source_type = ''SUBCONTRACT_PREPARATION''::text) AND (source_ref ~~ ''SC-ORDER:%''::text)))',
     E'', 1),
    (47, 'TRIGGER', 'preplan_stock_entitlement_events.trg_check_preplan_stock_entitlement_event', E' WHEN ((new.event_type <> ALL (ARRAY[''SUBCONTRACT_HANDOFF_OUT''::text, ''SUBCONTRACT_HANDOFF_IN''::text])))',
     E'', 1),
    (48, 'TRIGGER', 'production_material_analysis_items.trg_validate_make_component_source_dimension_upd', E'ARRAY[''MAKE_COMPONENT''::text, ''SUBCONTRACT_MAKE''::text]',
     E'ARRAY[''MAKE_COMPONENT''::text]', 1),
    (49, 'FUNCTION', 'fn_workshop_direct_reason_text(text,text,text,text,text,numeric,numeric)', E'WHEN ''SUBCONTRACT_ROUTE'' THEN format(''%s 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料'', goods)',
     E'WHEN ''SUBCONTRACT_ROUTE'' THEN format(''上层 %s 是委外件：本工单做的物料先送入仓库，由委外人员领料发给委外商'', goods)', 1);

DO $v798_anchor_patches$
DECLARE
    target RECORD;
    patch RECORD;
    definition TEXT;
    hits INTEGER;
    trigger_enabled "char";
    table_ref TEXT;
    object_name TEXT;
BEGIN
    FOR target IN
        SELECT object_kind, object_ref, MIN(seq) AS first_seq
        FROM v798_anchor_patches GROUP BY object_kind, object_ref ORDER BY MIN(seq)
    LOOP
        definition := NULL;
        trigger_enabled := NULL;
        table_ref := split_part(target.object_ref, '.', 1);
        object_name := split_part(target.object_ref, '.', 2);
        CASE target.object_kind
            WHEN 'FUNCTION' THEN
                definition := pg_get_functiondef(target.object_ref::regprocedure);
            WHEN 'VIEW' THEN
                definition := pg_get_viewdef(target.object_ref::regclass, true);
            WHEN 'CONSTRAINT' THEN
                SELECT pg_get_constraintdef(constraint_row.oid) INTO definition
                FROM pg_constraint constraint_row
                WHERE constraint_row.conrelid = table_ref::regclass AND constraint_row.conname = object_name;
            WHEN 'INDEX' THEN
                definition := pg_get_indexdef(target.object_ref::regclass);
            WHEN 'TRIGGER' THEN
                SELECT pg_get_triggerdef(trigger_row.oid), trigger_row.tgenabled INTO definition, trigger_enabled
                FROM pg_trigger trigger_row
                WHERE trigger_row.tgrelid = table_ref::regclass AND trigger_row.tgname = object_name;
        END CASE;
        IF definition IS NULL THEN
            RAISE EXCEPTION 'V798 anchor patch target % % does not exist', target.object_kind, target.object_ref;
        END IF;
        definition := replace(definition, chr(13), '');
        FOR patch IN
            SELECT * FROM v798_anchor_patches
            WHERE object_kind = target.object_kind AND object_ref = target.object_ref
            ORDER BY seq
        LOOP
            hits := (length(definition) - length(replace(definition, patch.anchor, ''))) / length(patch.anchor);
            IF hits <> patch.expected_hits THEN
                RAISE EXCEPTION 'V798 anchor patch % on % % matched % time(s), expected %',
                    patch.seq, target.object_kind, target.object_ref, hits, patch.expected_hits;
            END IF;
            definition := replace(definition, patch.anchor, patch.replacement);
        END LOOP;
        CASE target.object_kind
            WHEN 'FUNCTION' THEN
                EXECUTE definition;
            WHEN 'VIEW' THEN
                EXECUTE 'CREATE OR REPLACE VIEW ' || target.object_ref::regclass::text || ' AS ' || definition;
            WHEN 'CONSTRAINT' THEN
                EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I, ADD CONSTRAINT %I %s',
                               table_ref::regclass, object_name, object_name, definition);
            WHEN 'INDEX' THEN
                EXECUTE format('DROP INDEX %s', target.object_ref::regclass);
                EXECUTE definition;
            WHEN 'TRIGGER' THEN
                EXECUTE format('DROP TRIGGER %I ON %s', object_name, table_ref::regclass);
                EXECUTE definition;
                IF trigger_enabled = 'A' THEN
                    EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I', table_ref::regclass, object_name);
                ELSIF trigger_enabled = 'R' THEN
                    EXECUTE format('ALTER TABLE %s ENABLE REPLICA TRIGGER %I', table_ref::regclass, object_name);
                ELSIF trigger_enabled = 'D' THEN
                    EXECUTE format('ALTER TABLE %s DISABLE TRIGGER %I', table_ref::regclass, object_name);
                END IF;
        END CASE;
    END LOOP;
END;
$v798_anchor_patches$;

-- 清空业务数据孪生函数(已安装定义, V741/V743 同款单行 needle 删除 + 锚点插入): 九张退役表移出策略,
-- 领料通知水位随业务清空。needle 单行无换行, 不受迁移文件 CRLF/LF 差异影响。
DO $reset_policy$
DECLARE
    definition TEXT;
    needle TEXT;
    anchor TEXT := '(''subcontract_component_stock_handoffs'', ''CLEAR''),';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    FOREACH needle IN ARRAY ARRAY[
        '(''subcontract_outbound_preparation_commands'', ''CLEAR''),',
        '(''preplan_subcontract_entitlement_handoff_slices'', ''CLEAR''),',
        '(''preplan_subcontract_requirement_handoff_events'', ''CLEAR''),',
        '(''preplan_subcontract_requirement_handoff_items'', ''CLEAR''),',
        '(''preplan_subcontract_requirement_handoffs'', ''CLEAR''),',
        '(''preplan_subcontract_requirement_supply_claims'', ''CLEAR''),',
        '(''preplan_subcontract_make_task_batches'', ''CLEAR''),',
        '(''preplan_subcontract_make_batch_reversals'', ''CLEAR''),',
        '(''preplan_subcontract_make_tasks'', ''CLEAR''),'] LOOP
        IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
            RAISE EXCEPTION 'V798 cannot drop retired subcontract policy row % from business_data_reset', needle;
        END IF;
        definition := replace(definition, needle, '');
    END LOOP;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('subcontract_draw_notice_marks' IN definition) > 0 THEN
        RAISE EXCEPTION 'V798 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor,
        anchor || E'\n            (''subcontract_draw_notice_marks'', ''CLEAR''),');
END;
$reset_policy$;

-- 汇总下单的委外批次永远是外部批次(无锚点), 成员 P 节点各自展开直属物料(ADR-143 4.5)。
ALTER TABLE preplan_aggregate_batches
    ADD CONSTRAINT preplan_aggregate_subcontract_external_chk
        CHECK (route <> 'SUBCONTRACT' OR anchor_analysis_item_id IS NULL);

-- ---------------------------------------------------------------------
-- 6. 删除前置自制全家与唯一子件判据
-- ---------------------------------------------------------------------
DROP VIEW v_preplan_subcontract_target_future_supply;
DROP VIEW v_preplan_subcontract_requirement_supply_claim_state;
DROP VIEW v_preplan_subcontract_parent_output_claim_balance;
DROP VIEW v_preplan_subcontract_entitlement_handoff_slice_state;
DROP VIEW v_preplan_subcontract_requirement_handoff_state;
DROP VIEW v_subcontract_quantity_basis_issues;

DROP TABLE preplan_subcontract_entitlement_handoff_slices;
DROP TABLE preplan_subcontract_requirement_supply_claims;
DROP TABLE preplan_subcontract_requirement_handoff_events;
DROP TABLE preplan_subcontract_requirement_handoff_items;
DROP TABLE preplan_subcontract_requirement_handoffs;
DROP TABLE preplan_subcontract_make_batch_reversals;
DROP TABLE preplan_subcontract_make_task_batches;
DROP TABLE preplan_subcontract_make_tasks;
DROP TABLE subcontract_outbound_preparation_commands;

DROP INDEX idx_preplan_subcontract_make_action_item;
DROP INDEX idx_stock_reservation_subcontract_prepare_task_owner;
DROP INDEX idx_subcontract_order_preparation_reservation;
DROP INDEX idx_subcontract_prepared_receipt_capacity;
DROP INDEX idx_preplan_entitlement_subcontract_handoff;
DROP INDEX uq_preplan_subcontract_handoff_in_counter;
DROP INDEX uq_preplan_subcontract_handoff_in_group;
DROP INDEX uq_preplan_subcontract_handoff_out_group;
DROP INDEX idx_subcontract_material_plan_items_preparation_analysis;
DROP INDEX idx_subcontract_material_plan_items_preparation_tasks;

ALTER TABLE subcontract_material_plan_items
    DROP CONSTRAINT subcontract_component_outbound_no_loss_replacement_chk,
    DROP CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk,
    DROP CONSTRAINT subcontract_material_plan_item_flow_mode_chk,
    DROP CONSTRAINT subcontract_material_plan_item_preparation_shape_chk,
    DROP CONSTRAINT subcontract_material_plan_item_preparation_source_fk,
    DROP CONSTRAINT subcontract_material_plan_item_preparation_status_chk,
    DROP CONSTRAINT subcontract_material_plan_item_preparation_version_chk,
    DROP CONSTRAINT subcontract_material_plan_item_prepared_qty_chk,
    DROP CONSTRAINT subcontract_material_plan_items_loss_replacement_qty_base_check,
    DROP CONSTRAINT subcontract_material_plan_ite_preparation_analysis_item_id_fkey,
    DROP CONSTRAINT subcontract_material_plan_items_preparation_analysis_id_fkey,
    DROP CONSTRAINT subcontract_material_plan_items_preparation_started_by_fkey,
    DROP CONSTRAINT subcontract_material_plan_items_preparation_warehouse_id_fkey,
    DROP COLUMN flow_mode,
    DROP COLUMN preparation_status,
    DROP COLUMN prepared_qty,
    DROP COLUMN preparation_warehouse_id,
    DROP COLUMN preparation_bom_fingerprint,
    DROP COLUMN preparation_analysis_id,
    DROP COLUMN preparation_analysis_item_id,
    DROP COLUMN preparation_started_by,
    DROP COLUMN preparation_started_at,
    DROP COLUMN preparation_version,
    DROP COLUMN bom_has_children_snapshot,
    DROP COLUMN loss_replacement_qty_base;

ALTER TABLE production_material_analysis_items
    DROP CONSTRAINT direct_subcontract_preparation_identity,
    DROP CONSTRAINT production_material_analysis_ite_subcontract_order_item_id_fkey,
    DROP COLUMN subcontract_order_item_id,
    DROP COLUMN subcontract_order_qty_base;

DROP FUNCTION fn_assert_direct_subcontract_preparation(UUID);
DROP FUNCTION fn_assert_preplan_subcontract_requirement_handoff(UUID);
DROP FUNCTION fn_assert_subcontract_finished_item_custody(UUID);
DROP FUNCTION fn_assert_subcontract_make_task_batches();
DROP FUNCTION fn_assert_subcontract_make_task_batches(UUID);
DROP FUNCTION fn_assert_subcontract_preparation_finished_source(UUID);
DROP FUNCTION fn_assert_subcontract_preparation_has_handoff(UUID);
DROP FUNCTION fn_assert_subcontract_preparation_source(UUID);
DROP FUNCTION fn_assert_subcontract_preparation_source_before_v535(UUID);
DROP FUNCTION fn_assert_subcontract_prepared_source_capacity(UUID);
DROP FUNCTION fn_bind_direct_subcontract_preparation();
DROP FUNCTION fn_check_direct_subcontract_preparation_owner();
DROP FUNCTION fn_check_legacy_subcontract_preparation_analysis_source();
DROP FUNCTION fn_check_preplan_subcontract_entitlement_event();
DROP FUNCTION fn_check_preplan_subcontract_handoff_item();
DROP FUNCTION fn_check_preplan_subcontract_handoff_slice();
DROP FUNCTION fn_check_preplan_subcontract_handoff_snapshot();
DROP FUNCTION fn_check_preplan_subcontract_requirement_event();
DROP FUNCTION fn_check_preplan_subcontract_requirement_handoff();
DROP FUNCTION fn_check_preplan_subcontract_supply_claim();
DROP FUNCTION fn_check_subcontract_finished_custody_activation();
DROP FUNCTION fn_check_subcontract_loss_allowance();
DROP FUNCTION fn_check_subcontract_make_task_batches();
DROP FUNCTION fn_check_subcontract_preparation_analysis_source();
DROP FUNCTION fn_check_subcontract_preparation_finished_source();
DROP FUNCTION fn_check_subcontract_preparation_has_handoff();
DROP FUNCTION fn_check_subcontract_preparation_source();
DROP FUNCTION fn_check_subcontract_prepared_source_capacity();
DROP FUNCTION fn_check_subcontract_qualified_preparation_reservation();
DROP FUNCTION fn_guard_aggregate_subcontract_task();
DROP FUNCTION fn_guard_preplan_subcontract_claimed_supply_history();
DROP FUNCTION fn_guard_preplan_subcontract_handoff_material_identity();
DROP FUNCTION fn_guard_preplan_subcontract_handoff_mutation();
DROP FUNCTION fn_guard_subcontract_make_batch_history();
DROP FUNCTION fn_guard_subcontract_make_batch_reversal();
DROP FUNCTION fn_guard_subcontract_preparation_command_append_only();
DROP FUNCTION fn_guard_subcontract_preparation_reservation_identity();
DROP FUNCTION fn_guard_subcontract_qualified_source_identity();
DROP FUNCTION fn_preplan_aggregate_subcontract_task_source(UUID, UUID, UUID);
DROP FUNCTION fn_recheck_subcontract_preparation_finished_source(TEXT, UUID);
DROP FUNCTION fn_signal_aggregate_notification_allocation();
DROP FUNCTION fn_subcontract_component_edges(UUID);
DROP FUNCTION fn_subcontract_component_kit_capacity(UUID);
DROP FUNCTION fn_subcontract_component_outbound_goods(UUID);
DROP FUNCTION fn_subcontract_preparation_reservation_has_qualified_origin(UUID);
DROP FUNCTION fn_subcontract_sole_component_goods(UUID);
DROP FUNCTION fn_validate_preplan_subcontract_handoff_slice_totals();
DROP FUNCTION fn_validate_preplan_subcontract_requirement_totals();
DROP FUNCTION fn_validate_preplan_subcontract_supply_claim_totals();
DROP FUNCTION fn_workshop_direct_source_is_subcontract(UUID);

-- ---------------------------------------------------------------------
-- 7. 权限: 新增委外领料, 退役仓库「不再出仓」
-- ---------------------------------------------------------------------
INSERT INTO permissions(code, name, module, category, sort_order, action_type, description, grant_policy)
VALUES ('subcontract_order:draw', '委外领料(提交、撤回、结束领料)', '委外管理', '委外订货', 327, 'EXECUTE',
        '在委外任务中心按可领套数提交领料、撤回仓库还没发出的领料、结束某条委外明细的领料(不再发外)',
        ARRAY['NORMAL']::text[]);

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
CROSS JOIN permissions permission
WHERE surface.surface_key = 'operations.subcontract'
  AND permission.code = 'subcontract_order:draw';

-- 本节改的是系统种子权限配置(同 V775 之前的全部种子授权与 V741 的权限退役), 不是业务事实:
-- 部门授权的永久记录身份绑定与删除留档(V775 trg_bind_business_record_parent / trg_retain_business_record)
-- 在本节内暂停, 结束后按 V775 原样 ENABLE ALWAYS 恢复。否则空库(首导目标)迁移后
-- business_record_identities / business_record_history 就有行, 首导守卫会判成「目标已有业务事实」拒绝首导。
ALTER TABLE department_permissions DISABLE TRIGGER trg_bind_business_record_parent;
ALTER TABLE department_permissions DISABLE TRIGGER trg_retain_business_record;

-- 能把委外订货单送财务的部门与个人加授就能领料(同一批人跟单)。
INSERT INTO department_permissions(department_id, permission_id)
SELECT holder_grant.department_id, target.id
FROM department_permissions holder_grant
JOIN permissions holder ON holder.id = holder_grant.permission_id
 AND holder.code = 'subcontract_order:submit_finance'
CROSS JOIN permissions target
WHERE target.code = 'subcontract_order:draw'
ON CONFLICT DO NOTHING;

INSERT INTO user_permission_overrides
    (user_id, permission_id, effect, authority_source, source_actor_user_id, row_version, active)
SELECT override_row.user_id, target.id, 'grant', override_row.authority_source,
       override_row.source_actor_user_id, 1, TRUE
FROM user_permission_overrides override_row
JOIN permissions holder ON holder.id = override_row.permission_id
 AND holder.code = 'subcontract_order:submit_finance'
CROSS JOIN permissions target
WHERE target.code = 'subcontract_order:draw'
  AND override_row.effect = 'grant' AND override_row.active
ON CONFLICT DO NOTHING;

-- 仓库侧「不再出仓」随 ADR-143 删除: 先删页面权限面映射(外键 RESTRICT), 再删目录行;
-- 部门授权、个人覆盖与负责人委派随外键级联删除(V741 同款)。
DELETE FROM permission_surface_permissions mapping
USING permissions permission
WHERE mapping.permission_id = permission.id
  AND permission.code = 'subcontract_outbound:close';
DELETE FROM permissions WHERE code = 'subcontract_outbound:close';

ALTER TABLE department_permissions ENABLE ALWAYS TRIGGER trg_bind_business_record_parent;
ALTER TABLE department_permissions ENABLE ALWAYS TRIGGER trg_retain_business_record;

DO $v798_permission_check$
BEGIN
    IF (SELECT count(*) FROM permission_surface_permissions mapping
        JOIN permissions permission ON permission.id = mapping.permission_id
        JOIN permission_surfaces surface ON surface.id = mapping.surface_id
        WHERE permission.code = 'subcontract_order:draw' AND surface.surface_key = 'operations.subcontract') <> 1 THEN
        RAISE EXCEPTION 'V798 subcontract_order:draw must be bound to the subcontract task-center surface';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'subcontract_outbound:close') THEN
        RAISE EXCEPTION 'V798 subcontract_outbound:close must be retired';
    END IF;
END;
$v798_permission_check$;

-- ---------------------------------------------------------------------
-- 8. 后置扫描: 任何幸存对象仍引用被删的表、视图、函数、列或取值即中止
-- ---------------------------------------------------------------------
DO $v798_postcondition$
DECLARE
    retired_names TEXT := '\m(preplan_subcontract_\w+|subcontract_outbound_preparation_commands|v_subcontract_quantity_basis_issues'
        || '|fn_subcontract_sole_component_goods|fn_subcontract_component_outbound_goods|fn_subcontract_component_edges'
        || '|fn_subcontract_component_kit_capacity|fn_subcontract_component_available_stock'
        || '|fn_workshop_direct_source_is_subcontract|fn_assert_subcontract_preparation_\w+'
        || '|fn_subcontract_preparation_reservation_has_qualified_origin|fn_preplan_aggregate_subcontract_task_source)\M'
        || '|fn_subcontract_component_entitled_lots\s*\(\s*NULL';
    retired_values TEXT := '''(SUBCONTRACT_MAKE|SUBCONTRACT_MAKE_TASK|SUBCONTRACT_PREPARATION|SUBCONTRACT_PREPARE_TASK'
        || '|SUBCONTRACT_ORDER_PREPARATION|SUBCONTRACT_HANDOFF_IN|SUBCONTRACT_HANDOFF_OUT|MAKE_THEN_OUTBOUND'
        || '|PREPARED_OUTBOUND|DIRECT_OUTBOUND|COMPONENT_OUTBOUND|LEGACY_BOM_COMPONENT|DIRECT_TARGET'
        || '|subcontract_outbound:close)''';
    plan_columns TEXT := '\m(flow_mode|prepared_qty|preparation_status|preparation_warehouse_id|preparation_bom_fingerprint'
        || '|preparation_analysis_id|preparation_analysis_item_id|preparation_started_by|preparation_started_at'
        || '|preparation_version|bom_has_children_snapshot|loss_replacement_qty_base)\M';
    item_columns TEXT := '\msubcontract_order_(item_id|qty_base)\M';
    offending TEXT;
BEGIN
    SELECT string_agg(found.name, ', ' ORDER BY found.name) INTO offending FROM (
        SELECT 'function ' || p.oid::regprocedure::text AS name, p.prosrc AS body
        FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND NOT EXISTS (SELECT 1 FROM pg_depend extension_member
                          WHERE extension_member.classid = 'pg_proc'::regclass
                            AND extension_member.objid = p.oid AND extension_member.deptype = 'e')
        UNION ALL
        SELECT 'view ' || c.relname, pg_get_viewdef(c.oid)
        FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('v', 'm')
        UNION ALL
        SELECT 'constraint ' || con.conrelid::regclass::text || '.' || con.conname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con WHERE con.connamespace = 'public'::regnamespace
        UNION ALL
        SELECT 'index ' || i.indexname, i.indexdef FROM pg_indexes i WHERE i.schemaname = 'public'
        UNION ALL
        SELECT 'trigger ' || t.tgrelid::regclass::text || '.' || t.tgname, pg_get_triggerdef(t.oid)
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace
    ) found
    WHERE found.body ~ retired_names
       OR found.body ~ retired_values
       OR (found.body ~ '\msubcontract_material_plan_items\M' AND found.body ~ plan_columns)
       OR (found.body ~ '\mproduction_material_analysis_items\M' AND found.body ~ item_columns);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'V798 left live objects referencing retired subcontract make-first objects or values: %', offending;
    END IF;

    SELECT string_agg(missing.name, ', ' ORDER BY missing.name) INTO offending FROM (
        SELECT relname AS name FROM pg_class
        WHERE relnamespace = 'public'::regnamespace
          AND (relname LIKE 'preplan_subcontract%' OR relname LIKE 'v_preplan_subcontract%'
               OR relname IN ('subcontract_outbound_preparation_commands', 'v_subcontract_quantity_basis_issues'))
        UNION ALL
        SELECT table_name || '.' || column_name FROM information_schema.columns
        WHERE table_schema = 'public'
          AND ((table_name = 'subcontract_material_plan_items' AND column_name IN (
                    'flow_mode', 'prepared_qty', 'preparation_status', 'preparation_warehouse_id',
                    'preparation_bom_fingerprint', 'preparation_analysis_id', 'preparation_analysis_item_id',
                    'preparation_started_by', 'preparation_started_at', 'preparation_version',
                    'bom_has_children_snapshot', 'loss_replacement_qty_base'))
            OR (table_name = 'production_material_analysis_items'
                AND column_name IN ('subcontract_order_item_id', 'subcontract_order_qty_base')))
    ) missing;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'V798 did not remove retired subcontract objects: %', offending;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM fn_goods_quantity_reference_sources() WHERE relation_name = 'subcontract_material_plan_items')
       OR EXISTS (SELECT 1 FROM fn_goods_quantity_reference_sources() WHERE to_regclass('public.' || relation_name) IS NULL) THEN
        RAISE EXCEPTION 'V798 goods quantity reference sources must name only live tables';
    END IF;
    IF position('(''subcontract_draw_notice_marks'', ''CLEAR'')' IN pg_get_functiondef('business_data_reset()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'V798 business_data_reset must clear subcontract_draw_notice_marks';
    END IF;
END;
$v798_postcondition$;
