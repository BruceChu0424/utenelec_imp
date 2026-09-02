package com.uten.imp.features.subcontract.plan;

import com.uten.imp.application.port.SubcontractPreparationInventoryPort;
import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItem;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItemRepository;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueRepository;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundDraftRef;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundPlanLine;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskDetail;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskListItem;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 委外目标件出仓与前置自制服务（V436；兼容 V304 历史行）。
 *
 * <p>V436 新流永远出仓订货目标件本身。无活动直接 BOM 的目标件走
 * {@code DIRECT_OUTBOUND}；有子层走 {@code MAKE_THEN_OUTBOUND}，必须经过物料分析、
 * DRAW 实发、生产、FQC 与仓库整批实收，形成订单专属 reservation 后才进入仓库任务。
 * 草稿按冻结仓分组；未选仓 DIRECT 行独立成单，由仓库选择仓后原子占用库存。
 *
 * <p>新流 {@code planned/prepared/issued} 全部使用货品基本单位；订货单位换算率冻结在
 * {@code bom_unit_qty}，回仓仍由 V221 supplier-held 守恒消费。V304 已存在的
 * {@code LEGACY_BOM_COMPONENT} 行保留原“发 BOM 子件”语义，不回填、不改写历史。
 */
@Service
@RequiredArgsConstructor
public class SubcontractMaterialPlanService
        implements SubcontractPreparationInventoryPort {

    private static final short ISSUE_DRAFT = 0;

    private final EntityManager em;
    private final JdbcTemplate jdbc;
    private final DocNumberService docNumberService;
    private final SubcontractMaterialIssueRepository issueRepo;
    private final SubcontractMaterialIssueItemRepository issueItemRepo;
    private final SecurityContextCurrentUser currentUser;
    private final SubcontractChainNoticePort chainNotice;
    private final InventoryMutationLock inventoryLock;

    // ==================== 链路钩子（订货 Service 同事务调用） ====================

    /**
     * 财务批准同事务：每条订货明细建立一个“目标件出仓”计划行。
     * 无活动子 BOM 的目标件可直接进入仓库出仓；有活动子 BOM 的目标件必须先由计划员
     * 启动正常 MAKE 分析，并在 DRAW 实发、报工、FQC、仓库整批实收后才能生成出仓草稿。
     * V304 历史 BOM 子件计划不改写，继续由 flow_mode=LEGACY_BOM_COMPONENT 兼容。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    @SuppressWarnings("unchecked")
    public void createPlanOnApproval(UUID orderId) {
        List<Object[]> orderRows = em.createNativeQuery("""
                SELECT id, bill_no, supplier_id, deliver_date
                FROM subcontract_orders WHERE id = :id
                """).setParameter("id", orderId).getResultList();
        if (orderRows.isEmpty()) {
            return;
        }
        Object[] order = orderRows.getFirst();
        String orderBillNo = Objects.toString(order[1]);
        UUID supplierId = (UUID) order[2];
        LocalDate deliverDate = toLocalDate(order[3]);

        List<Object[]> items = em.createNativeQuery("""
                SELECT item.id, item.goods_id, item.color_id, item.qty, item.line_no,
                       COALESCE(item.unit_rate, 1), item.unit_id,
                       COALESCE(application.warehouse_id, order_header.warehouse_id)
                FROM subcontract_order_items item
                JOIN subcontract_orders order_header ON order_header.id = item.order_id
                LEFT JOIN subcontract_application_items application_item
                  ON application_item.id = item.application_item_id
                LEFT JOIN subcontract_applications application
                  ON application.id = application_item.application_id
                WHERE item.order_id = :orderId
                  AND COALESCE(item.is_deleted, false) = false
                ORDER BY item.line_no ASC NULLS LAST, item.id
                """).setParameter("orderId", orderId).getResultList();
        if (items.isEmpty()) {
            return;
        }
        List<UUID> parentGoodsIds = items.stream()
                .map(row -> (UUID) row[1]).filter(Objects::nonNull).distinct().toList();
        Map<UUID, Object[]> goodsMaster = loadGoodsMaster(parentGoodsIds);

        // 先算后插：全部计划行量 ≤ 0 时不建计划（视为无需发料）。
        record PendingLine(UUID id, UUID orderItemId, UUID goodsId, UUID colorId,
                           UUID unitId, BigDecimal orderUnitRate,
                           BigDecimal plannedBaseQty, String flowMode,
                           String preparationStatus, BigDecimal preparedBaseQty,
                           UUID suggestedWarehouseId,
                           boolean bomHasChildren, String bomFingerprint,
                           UUID preparationAnalysisId, UUID preparationAnalysisItemId,
                           UUID prepareTaskId) {
        }
        List<PendingLine> pendingLines = new ArrayList<>();
        // 直下单销售式供货：同单同货多行共享一个递减的可用量池，防止重复占用
        // （与销售 reserveOnApprove 同款口径）。
        Map<String, BigDecimal> stockPool = new HashMap<>();
        for (Object[] item : items) {
            UUID orderItemId = (UUID) item[0];
            UUID goodsId = (UUID) item[1];
            UUID colorId = (UUID) item[2];
            BigDecimal orderQty = decimal(item[3]);
            BigDecimal orderUnitRate = decimal(item[5]);
            BigDecimal planned = orderQty.multiply(orderUnitRate)
                    .setScale(4, RoundingMode.HALF_UP);
            if (planned.signum() <= 0) {
                continue;
            }
            Object[] master = goodsMaster.get(goodsId);
            UUID baseUnitId = master == null ? (UUID) item[6] : (UUID) master[3];
            BomSnapshot bom = currentBomSnapshot(goodsId);
            // V458：订货行能追溯到委外前置自制账本批次时，说明自制在下单前
            // 已完成（produced ≥ notified ≥ planned），批准即待出仓。
            PreparedLineage prepared = preparedLineage(orderItemId);
            boolean makeFirst = bom.hasChildren() && prepared == null;
            boolean preparedOutbound = prepared != null;
            if (makeFirst) {
                // 直下单销售式供货：先按全局可用量（账面−安全库存−生效预留）拆出
                // 现货直发行（DIRECT 行走既有「无仓草稿→仓库选仓原子占用→实发」链，
                // 建议仓来自订单/申请，仓库可换仓），仅缺口部分保留前置自制行；
                // 建分析的量取计划行量，拆行后即缺口量。仓库现货充足时不再生产。
                String poolKey = goodsId + "|" + Objects.toString(colorId, "");
                BigDecimal avail = stockPool.computeIfAbsent(poolKey,
                        k -> globalAvailableBase(goodsId, colorId));
                BigDecimal stockTake = planned.min(avail.max(BigDecimal.ZERO));
                if (stockTake.signum() > 0) {
                    stockPool.put(poolKey, avail.subtract(stockTake));
                }
                BigDecimal makeQty = planned.subtract(stockTake);
                if (stockTake.signum() > 0) {
                    pendingLines.add(new PendingLine(
                            UUID.randomUUID(), orderItemId, goodsId, colorId,
                            baseUnitId, orderUnitRate, stockTake,
                            "DIRECT_OUTBOUND", "READY_OUTBOUND", stockTake,
                            (UUID) item[7], false, bom.fingerprint(),
                            null, null, null));
                }
                if (makeQty.signum() > 0) {
                    pendingLines.add(new PendingLine(
                            UUID.randomUUID(), orderItemId, goodsId, colorId,
                            baseUnitId, orderUnitRate, makeQty,
                            "MAKE_THEN_OUTBOUND", "ACTION_REQUIRED",
                            BigDecimal.ZERO, (UUID) item[7],
                            true, bom.fingerprint(),
                            null, null, null));
                }
                continue;
            }
            pendingLines.add(new PendingLine(
                    UUID.randomUUID(), orderItemId, goodsId, colorId,
                    baseUnitId, orderUnitRate, planned,
                    preparedOutbound ? "PREPARED_OUTBOUND" : "DIRECT_OUTBOUND",
                    "READY_OUTBOUND", planned,
                    preparedOutbound ? prepared.warehouseId() : (UUID) item[7],
                    preparedOutbound, bom.fingerprint(),
                    preparedOutbound ? prepared.analysisId() : null,
                    preparedOutbound ? prepared.analysisItemId() : null,
                    preparedOutbound ? prepared.taskId() : null));
        }
        if (pendingLines.isEmpty()) {
            return;
        }

        UUID planId = UUID.randomUUID();
        UUID actorUser = currentUser.requireId();
        jdbc.update("""
                INSERT INTO subcontract_material_plans(
                    id, order_id, order_bill_no, supplier_id, status, created_by, updated_by)
                VALUES (?, ?, ?, ?, 'OPEN', ?, ?)
                """, planId, orderId, orderBillNo, supplierId, actorUser, actorUser);
        int lineNo = 1;
        for (PendingLine line : pendingLines) {
            jdbc.update("""
                    INSERT INTO subcontract_material_plan_items(
                        id, plan_id, order_item_id, line_no,
                        parent_goods_id, parent_color_id,
                        goods_id, color_id, unit_id, unit_rate,
                        bom_unit_qty, planned_qty, issued_qty,
                        flow_mode, preparation_status, prepared_qty,
                        preparation_warehouse_id, preparation_version,
                        bom_has_children_snapshot, preparation_bom_fingerprint,
                        preparation_analysis_id, preparation_analysis_item_id,
                        created_by, updated_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 0,
                            ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
                    """,
                    line.id(), planId, line.orderItemId(), lineNo++,
                    line.goodsId(), line.colorId(),
                    line.goodsId(), line.colorId(), line.unitId(),
                    line.orderUnitRate(), line.plannedBaseQty(),
                    line.flowMode(), line.preparationStatus(),
                    line.preparedBaseQty(), line.suggestedWarehouseId(),
                    line.bomHasChildren(), line.bomFingerprint(),
                    line.preparationAnalysisId(), line.preparationAnalysisItemId(),
                    actorUser, actorUser);
        }
        // V458：PREPARED_OUTBOUND 行把任务持有的前置自制预留转换为本行专属
        // SUBCONTRACT_OUTBOUND 预留（释放旧的、等量新建，保持事实可回放），
        // 之后再生成出仓草稿。
        for (PendingLine line : pendingLines) {
            if ("PREPARED_OUTBOUND".equals(line.flowMode())) {
                convertPrepareTaskReservations(
                        line.id(), line.prepareTaskId(),
                        line.plannedBaseQty(), actorUser);
            }
        }
        createDraftForPlan(planId, orderBillNo, supplierId, deliverDate, actorUser);
        for (PendingLine line : pendingLines) {
            if ("MAKE_THEN_OUTBOUND".equals(line.flowMode())) {
                // 直下单销售式供货：MAKE 行量=缺口，通知计划部补产；
                // 现货直发行走下方 OUTBOUND_READY 通知仓库发货。
                chainNotice.notifySubcontractPrepareShortage(line.id());
            } else {
                chainNotice.notifySubcontractOutboundReady(line.id());
            }
        }
    }

    /**
     * 全局可用量（基本单位，销售 reserveOnApprove 同款口径）：
     * 全仓账面−安全库存−全部生效预留，GREATEST(…,0) 兜底；带货色锁防并发超占。
     * colorId 可能为 NULL，比较与 CAST 对齐 StockReservationRepository 的写法。
     */
    private BigDecimal globalAvailableBase(UUID goodsId, UUID colorId) {
        inventoryLock.lock(new InventoryKey(goodsId, colorId));
        BigDecimal value = jdbc.queryForObject("""
                SELECT GREATEST(
                  (SELECT COALESCE(SUM(GREATEST(
                              COALESCE(b.qty, 0)
                              - GREATEST(
                                  COALESCE(CAST(g.min_qty AS NUMERIC), 0), 0),
                              0)), 0)
                     FROM stock_balances b
                     JOIN goods g ON g.id = b.goods_id
                     WHERE b.goods_id = ?
                       AND (b.color_id IS NOT DISTINCT FROM CAST(? AS uuid)))
                  - (SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
                       FROM stock_reservations r
                       WHERE r.is_deleted = FALSE AND r.status = 0
                         AND r.goods_id = ?
                         AND (r.color_id IS NOT DISTINCT FROM CAST(? AS uuid)))
                , 0)
                """, BigDecimal.class, goodsId, colorId, goodsId, colorId);
        return value == null ? BigDecimal.ZERO : value;
    }

    /** V458 订货红冲：PREPARED 行未消费的计划专属预留对称转回任务持有。 */
    private void restorePrepareTaskReservations(UUID planId, UUID actorUser) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT plan_item.id, batch.task_id
                FROM subcontract_material_plan_items plan_item
                JOIN subcontract_order_items order_item
                  ON order_item.id = plan_item.order_item_id
                 AND order_item.is_deleted = FALSE
                JOIN subcontract_application_items application_item
                  ON application_item.id = order_item.application_item_id
                 AND application_item.is_deleted = FALSE
                JOIN preplan_subcontract_make_task_batches batch
                  ON batch.application_item_id = application_item.id
                WHERE plan_item.plan_id = :planId
                  AND plan_item.flow_mode = 'PREPARED_OUTBOUND'
                  AND plan_item.is_deleted = FALSE
                """).setParameter("planId", planId));
        for (Object[] row : rows) {
            UUID planItemId = (UUID) row[0];
            UUID taskId = (UUID) row[1];
            @SuppressWarnings("unchecked")
            List<Object[]> reservations = em.createNativeQuery("""
                    SELECT id, qty - consumed_qty - released_qty,
                           goods_id, color_id, warehouse_id,
                           supply_id, source_doc_id
                    FROM stock_reservations
                    WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND owner_id = :planItemId
                      AND status = 0 AND consumed_qty = 0 AND is_deleted = FALSE
                    ORDER BY created_at, id
                    FOR UPDATE
                    """).setParameter("planItemId", planItemId).getResultList();
            for (Object[] reservation : reservations) {
                BigDecimal slice = decimal(reservation[1]);
                if (slice.signum() <= 0) continue;
                em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET released_qty = qty, status = 1,
                            release_reason = 'SUBCONTRACT_PREPARED_ORDER_REVERSED',
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND consumed_qty = 0
                        """).setParameter("actorId", actorUser)
                        .setParameter("id", reservation[0]).executeUpdate();
                em.createNativeQuery("""
                        INSERT INTO stock_reservations(
                            id, order_item_id, goods_id, color_id, warehouse_id,
                            qty, consumed_qty, released_qty, status, source,
                            source_doc_type, source_doc_id,
                            owner_type, owner_id, purpose, demand_id,
                            supply_type, supply_id, idempotency_key,
                            created_by, updated_by)
                        VALUES (
                            :id, NULL, :goodsId, :colorId, :warehouseId,
                            :qty, 0, 0, 0, 1,
                            'PRODUCTION_INBOUND', :sourceDocId,
                            'SUBCONTRACT_PREPARE_TASK', :taskId,
                            'SUBCONTRACT_PREPARE_TASK', NULL,
                            'PRODUCTION_FINISHED_IN', :supplyId, :key,
                            :actorId, :actorId)
                        """)
                        .setParameter("id", UUID.randomUUID())
                        .setParameter("goodsId", reservation[2])
                        .setParameter("colorId", reservation[3])
                        .setParameter("warehouseId", reservation[4])
                        .setParameter("qty", slice)
                        .setParameter("sourceDocId", reservation[6])
                        .setParameter("taskId", taskId)
                        .setParameter("supplyId", reservation[5])
                        .setParameter("key", "SC-PREPARED-BACK:" + taskId + ':'
                                + reservation[0])
                        .setParameter("actorId", actorUser)
                        .executeUpdate();
            }
        }
    }

    /** V458 订货行 → 前置自制账本批次 → 任务的谱系（无批次返回 null）。 */
    private PreparedLineage preparedLineage(UUID orderItemId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT task.id, task.warehouse_id,
                       task.analysis_id, task.preparation_item_id
                FROM subcontract_order_items order_item
                JOIN subcontract_application_items application_item
                  ON application_item.id = order_item.application_item_id
                 AND application_item.is_deleted = FALSE
                JOIN preplan_subcontract_make_task_batches batch
                  ON batch.application_item_id = application_item.id
                JOIN preplan_subcontract_make_tasks task
                  ON task.id = batch.task_id
                 AND task.status = 'ACTIVE'
                WHERE order_item.id = :orderItemId
                  AND order_item.is_deleted = FALSE
                ORDER BY task.id
                """).setParameter("orderItemId", orderItemId));
        if (rows.isEmpty()) return null;
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外订货行对应多个前置自制任务，数据谱系异常，禁止自动出仓");
        }
        Object[] row = rows.getFirst();
        return new PreparedLineage((UUID) row[0], (UUID) row[1],
                (UUID) row[2], (UUID) row[3]);
    }

    private record PreparedLineage(
            UUID taskId, UUID warehouseId,
            UUID analysisId, UUID analysisItemId) {
    }

    /**
     * 释放任务持有的 SUBCONTRACT_PREPARE_TASK 预留切片（FIFO，至多 planned），
     * 并为计划行建立等量 SUBCONTRACT_OUTBOUND / PRODUCTION_FINISHED_IN 预留。
     */
    private void convertPrepareTaskReservations(
            UUID planItemId, UUID taskId, BigDecimal plannedQty, UUID actorUser) {
        List<Object[]> held = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reservation.id, reservation.qty
                    - reservation.consumed_qty - reservation.released_qty,
                       reservation.goods_id, reservation.color_id,
                       reservation.warehouse_id, reservation.supply_id,
                       reservation.source_doc_id
                FROM stock_reservations reservation
                WHERE reservation.owner_type = 'SUBCONTRACT_PREPARE_TASK'
                  AND reservation.owner_id = :taskId
                  AND reservation.status = 0 AND reservation.is_deleted = FALSE
                  AND reservation.consumed_qty = 0
                ORDER BY reservation.created_at, reservation.id
                FOR UPDATE
                """).setParameter("taskId", taskId));
        BigDecimal remaining = plannedQty;
        for (Object[] row : held) {
            if (remaining.signum() <= 0) break;
            UUID reservationId = (UUID) row[0];
            BigDecimal slice = decimal(row[1]).min(remaining);
            if (slice.signum() <= 0) continue;
            em.createNativeQuery("""
                    UPDATE stock_reservations
                    SET released_qty = released_qty + :slice, status = 1,
                        release_reason = 'SUBCONTRACT_PREPARED_ORDER_CONVERTED',
                        lock_version = lock_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id AND consumed_qty = 0
                      AND released_qty + :slice <= qty
                    """).setParameter("slice", slice)
                    .setParameter("actorId", actorUser)
                    .setParameter("id", reservationId).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (
                        :id, NULL, :goodsId, :colorId, :warehouseId,
                        :qty, 0, 0, 0, 1,
                        'PRODUCTION_INBOUND', :sourceDocId,
                        'SUBCONTRACT_OUTBOUND', :planItemId,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'PRODUCTION_FINISHED_IN', :supplyId, :key,
                        :actorId, :actorId)
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("goodsId", row[2])
                    .setParameter("colorId", row[3])
                    .setParameter("warehouseId", row[4])
                    .setParameter("qty", slice)
                    .setParameter("sourceDocId", row[6])
                    .setParameter("planItemId", planItemId)
                    .setParameter("supplyId", row[5])
                    .setParameter("key", "SC-PREPARED-OUT:" + planItemId + ':' + reservationId)
                    .setParameter("actorId", actorUser)
                    .executeUpdate();
            remaining = remaining.subtract(slice);
        }
        if (remaining.signum() != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外前置自制专属库存不足以覆盖订货量，请核对账本后重试");
        }
    }

    /**
     * 出仓审核同事务末段：按计划行回写 issued_qty（CAS 防超计划）；计划 OPEN 且仍有
     * 剩余量且无未审草稿时自动续生下一批草稿（分批出仓闭环）。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterIssueApproved(UUID issueId) {
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT id, plan_item_id, qty FROM subcontract_material_issue_items
                WHERE issue_id = :issueId AND plan_item_id IS NOT NULL
                """).setParameter("issueId", issueId).getResultList();
        if (lines.isEmpty()) {
            return;
        }
        UUID planId = null;
        for (Object[] line : lines) {
            UUID planItemId = (UUID) line[1];
            BigDecimal qty = decimal(line[2]);
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET issued_qty = issued_qty + ?, updated_at = now()
                    WHERE id = ? AND is_deleted = FALSE
                      AND issued_qty + ? <= planned_qty
                    """, qty, planItemId, qty);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "出仓量超过发料计划余量，请刷新出仓任务后重试");
            }
            if (planId == null) {
                planId = jdbc.queryForObject("""
                        SELECT plan_id FROM subcontract_material_plan_items WHERE id = ?
                        """, UUID.class, planItemId);
            }
        }
        if (planId == null) {
            return;
        }
        jdbc.update("""
                UPDATE subcontract_material_plan_items
                SET preparation_status = 'OUTBOUND_COMPLETE',
                    preparation_version = preparation_version + 1,
                    updated_at = now()
                WHERE id IN (
                    SELECT DISTINCT plan_item_id
                    FROM subcontract_material_issue_items
                    WHERE issue_id = ? AND plan_item_id IS NOT NULL)
                  AND flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                  AND issued_qty = planned_qty
                  AND preparation_status = 'READY_OUTBOUND'
                """, issueId);
        String status = jdbc.queryForObject("""
                SELECT status FROM subcontract_material_plans WHERE id = ?
                """, String.class, planId);
        if (!"OPEN".equals(status)) {
            throw new ApiException(ErrorCode.CONFLICT, "发料计划已关闭或取消，禁止继续出仓");
        }
        Long issuedNewFlowLines = jdbc.queryForObject("""
                SELECT COUNT(DISTINCT issue_item.plan_item_id)
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                 AND plan_item.flow_mode IN (
                     'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                 AND plan_item.is_deleted = FALSE
                WHERE issue_item.issue_id = ?
                  AND issue_item.plan_item_id IS NOT NULL
                  AND issue_item.is_deleted = FALSE
                """, Long.class, issueId);
        if (issuedNewFlowLines != null && issuedNewFlowLines > 0) {
            chainNotice.notifySubcontractOutboundCompleted(issueId);
        }
        // 分批闭环：审核后仍有剩余且已无未审草稿 → 自动续生下一批。
        if (remainingLines(planId).stream().anyMatch(row -> decimal(row[8]).signum() > 0)) {
            @SuppressWarnings("unchecked")
            List<Object[]> plan = em.createNativeQuery("""
                    SELECT p.order_bill_no, p.supplier_id, o.deliver_date
                    FROM subcontract_material_plans p
                    JOIN subcontract_orders o ON o.id = p.order_id
                    WHERE p.id = :id
                    """).setParameter("id", planId).getResultList();
            if (!plan.isEmpty()) {
                Object[] head = plan.getFirst();
                createDraftForPlan(planId, Objects.toString(head[0]), (UUID) head[1],
                        toLocalDate(head[2]),
                        currentUser.requireId());
            }
        }
    }

    /** 出仓红冲同事务：issued_qty 对称回减（不自动补草稿，由工作台手工补齐，避免抖动）。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterIssueReversed(UUID issueId) {
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT issue_item.plan_item_id, issue_item.qty, plan_item.flow_mode
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                WHERE issue_item.issue_id = :issueId
                  AND issue_item.plan_item_id IS NOT NULL
                """).setParameter("issueId", issueId).getResultList();
        boolean reversedNewFlow = false;
        for (Object[] line : lines) {
            BigDecimal qty = decimal(line[1]);
            reversedNewFlow = reversedNewFlow
                    || List.of("DIRECT_OUTBOUND", "MAKE_THEN_OUTBOUND",
                            "PREPARED_OUTBOUND")
                    .contains(Objects.toString(line[2], ""));
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET preparation_status = CASE
                            WHEN flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                             AND preparation_status = 'OUTBOUND_COMPLETE'
                             AND GREATEST(issued_qty - ?, 0) < planned_qty
                            THEN 'READY_OUTBOUND' ELSE preparation_status END,
                        preparation_version = CASE
                            WHEN flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                            THEN preparation_version + 1 ELSE preparation_version END,
                        issued_qty = GREATEST(issued_qty - ?, 0), updated_at = now()
                    WHERE id = ? AND is_deleted = FALSE
                    """, qty, qty, (UUID) line[0]);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "发料计划行已变化，请刷新后重试");
            }
        }
        if (reversedNewFlow) {
            chainNotice.notifySubcontractOutboundReversed(issueId);
        }
    }

    /** 订货红冲同事务：软删未审自动草稿 + 计划置 CANCELED（已审出仓由既有守卫先行拦截）。 */
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public void requireOrderReversalAllowed(UUID orderId) {
        Long blocked = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM subcontract_material_plan_items plan_item
                JOIN subcontract_material_plans plan ON plan.id = plan_item.plan_id
                LEFT JOIN production_material_analyses analysis
                  ON analysis.id = plan_item.preparation_analysis_id
                WHERE plan.order_id = ?
                  AND plan.is_deleted = FALSE AND plan_item.is_deleted = FALSE
                  AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND plan_item.preparation_status IN (
                      'IN_PREPARATION','WAITING_FQC','WAITING_INBOUND')
                  AND (analysis.id IS NULL OR analysis.status <> 'CANCELLED')
                """, Long.class, orderId);
        if (blocked != null && blocked > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外订货仍有进行中的前置自制链；请先按成品入库/FQC/报工/DRAW/生产计划顺序反向并取消物料分析");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void cancelForOrderReversal(UUID orderId) {
        UUID actorUser = currentUser.requireId();
        List<UUID> planIds = jdbc.queryForList("""
                SELECT id FROM subcontract_material_plans
                WHERE order_id = ? AND is_deleted = FALSE AND status = 'OPEN'
                """, UUID.class, orderId);
        for (UUID planId : planIds) {
            // V458：PREPARED_OUTBOUND 行的未消费预留先转回任务持有（申请仍有效，
            // 可再次分解订货），避免释放回公共池后被其它需求抢走。
            restorePrepareTaskReservations(planId, actorUser);
            releasePlanReservations(planId, "SUBCONTRACT_ORDER_REVERSED");
            jdbc.update("""
                    UPDATE subcontract_material_issues SET is_deleted = TRUE, deleted_at = now()
                    WHERE status = 0 AND is_deleted = FALSE AND id IN (
                        SELECT DISTINCT ii.issue_id FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_plan_items pi ON pi.id = ii.plan_item_id
                        WHERE pi.plan_id = ?)
                    """, planId);
            jdbc.update("""
                    UPDATE subcontract_material_plans
                    SET status = 'CANCELED', updated_at = now() WHERE id = ?
                    """, planId);
            jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET preparation_status = 'CANCELLED',
                        preparation_version = preparation_version + 1,
                        updated_at = now()
                    WHERE plan_id = ? AND flow_mode IN (
                        'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                    """, planId);
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(
            UUID stockDocumentId, UUID warehouseId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT plan_item.id, plan_item.plan_id, stock_item.id,
                       stock_item.goods_id, stock_item.color_id,
                       stock_item.qty * COALESCE(stock_item.unit_rate, 1),
                       plan_item.preparation_warehouse_id,
                       plan_item.planned_qty, plan_item.prepared_qty,
                       plan.order_bill_no, plan.supplier_id, order_header.deliver_date,
                       production_plan.material_analysis_id,
                       production_plan.material_analysis_item_id,
                       analysis_link.analysis_id, analysis_link.analysis_item_id,
                       analysis_link.allocation_status,
                       production_item.goods_id, production_item.color_id,
                       production_item.unit_id, production_item.unit_rate,
                       stock_item.unit_id, stock_item.unit_rate,
                       plan_item.goods_id, plan_item.color_id, plan_item.unit_id,
                       plan_item.preparation_analysis_id,
                       plan_item.preparation_analysis_item_id,
                       production_plan.status
                FROM stock_document_items stock_item
                JOIN stock_documents stock_doc
                  ON stock_doc.id = stock_item.doc_id
                 AND stock_doc.status = 1 AND stock_doc.is_deleted = FALSE
                JOIN production_plan_items production_item
                  ON production_item.id = stock_item.upstream_item_id
                 AND production_item.is_deleted = FALSE
                JOIN production_plans production_plan
                  ON production_plan.id = production_item.plan_id
                 AND production_plan.is_deleted = FALSE
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.preparation_analysis_id =
                     production_plan.material_analysis_id
                 AND plan_item.preparation_analysis_item_id =
                     production_plan.material_analysis_item_id
                 AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
                 AND plan_item.is_deleted = FALSE
                LEFT JOIN production_material_analysis_plan_links analysis_link
                  ON analysis_link.plan_id = production_plan.id
                 AND analysis_link.analysis_id = plan_item.preparation_analysis_id
                 AND analysis_link.analysis_item_id =
                     plan_item.preparation_analysis_item_id
                JOIN subcontract_material_plans plan
                  ON plan.id = plan_item.plan_id AND plan.status = 'OPEN'
                 AND plan.is_deleted = FALSE
                JOIN subcontract_orders order_header ON order_header.id = plan.order_id
                WHERE stock_item.doc_id = :documentId
                  AND stock_item.bill_type = 'FINISHED_IN'
                  AND stock_item.is_deleted = FALSE
                ORDER BY plan_item.id, stock_item.id
                FOR UPDATE OF plan_item
                """).setParameter("documentId", stockDocumentId).getResultList();
        if (rows.isEmpty()) return;
        UUID actorId = currentUser.requireId();
        java.util.Set<UUID> readyPlans = new java.util.LinkedHashSet<>();
        java.util.Map<UUID, Object[]> planHeads = new LinkedHashMap<>();
        java.util.Map<UUID, BigDecimal> preparedByPlanItem = new HashMap<>();
        for (Object[] row : rows) {
            UUID planItemId = (UUID) row[0];
            UUID planId = (UUID) row[1];
            UUID stockItemId = (UUID) row[2];
            UUID frozenWarehouse = (UUID) row[6];
            BigDecimal baseQty = decimal(row[5]);
            UUID preparationAnalysisId = (UUID) row[26];
            UUID preparationAnalysisItemId = (UUID) row[27];
            BigDecimal productionRate = row[20] == null
                    ? BigDecimal.ONE : decimal(row[20]);
            BigDecimal stockRate = row[22] == null
                    ? BigDecimal.ONE : decimal(row[22]);
            boolean exactLineage = Objects.equals(row[12], preparationAnalysisId)
                    && Objects.equals(row[13], preparationAnalysisItemId)
                    && Objects.equals(row[14], preparationAnalysisId)
                    && Objects.equals(row[15], preparationAnalysisItemId)
                    && "APPROVED".equals(row[16]);
            boolean exactDimension = Objects.equals(row[17], row[23])
                    && Objects.equals(row[18], row[24])
                    && Objects.equals(row[19], row[25])
                    && Objects.equals(row[3], row[23])
                    && Objects.equals(row[4], row[24])
                    && Objects.equals(row[21], row[25])
                    && productionRate.compareTo(BigDecimal.ONE) == 0
                    && stockRate.compareTo(BigDecimal.ONE) == 0;
            if (!exactLineage || !exactDimension
                    || row[28] == null || ((Number) row[28]).shortValue() != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "成品实收入库与委外前置分析目标计划行的 UUID、货色、单位或换算率不一致");
            }
            if (!Objects.equals(frozenWarehouse, warehouseId)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外前置自制实收仓与任务冻结仓不一致，禁止静默跨仓释放出仓");
            }
            if (baseQty.signum() <= 0) continue;
            String idempotencyKey = "SC-OUT-MAKE-IN:" + stockItemId;
            Number existing = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM stock_reservations
                    WHERE idempotency_key = :key
                    """).setParameter("key", idempotencyKey).getSingleResult();
            if (existing.longValue() > 0) continue;
            UUID reservationId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (
                        :id, NULL, :goodsId, :colorId, :warehouseId,
                        :qty, 0, 0, 0, 1,
                        'PRODUCTION_INBOUND', :documentId,
                        'SUBCONTRACT_OUTBOUND', :planItemId,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'PRODUCTION_FINISHED_IN', :stockItemId, :key,
                        :actorId, :actorId)
                    """)
                    .setParameter("id", reservationId)
                    .setParameter("goodsId", row[3])
                    .setParameter("colorId", row[4])
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("qty", baseQty)
                    .setParameter("documentId", stockDocumentId)
                    .setParameter("planItemId", planItemId)
                    .setParameter("stockItemId", stockItemId)
                    .setParameter("key", idempotencyKey)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            int updated = em.createNativeQuery("""
                    UPDATE subcontract_material_plan_items
                    SET prepared_qty = prepared_qty + :qty,
                        preparation_status = CASE
                            WHEN prepared_qty + :qty > 0
                            THEN 'READY_OUTBOUND' ELSE 'WAITING_INBOUND' END,
                        preparation_version = preparation_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                      AND flow_mode = 'MAKE_THEN_OUTBOUND'
                      AND preparation_status IN (
                          'IN_PREPARATION','WAITING_FQC','WAITING_INBOUND')
                      AND prepared_qty + :qty <= planned_qty
                    """)
                    .setParameter("qty", baseQty)
                    .setParameter("actorId", actorId)
                    .setParameter("id", planItemId)
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外前置自制实收量超过订货目标量或任务状态已变化");
            }
            BigDecimal preparedAfter = preparedByPlanItem
                    .getOrDefault(planItemId, decimal(row[8]))
                    .add(baseQty);
            preparedByPlanItem.put(planItemId, preparedAfter);
            // V458 分批出仓：首片实收即释放可出仓（可出仓量=LEAST(planned,prepared)-issued）。
            // 通知只在「首次可得」与「整批完成」两个节点发出，避免每片打扰仓库；
            // 中途追加的可出仓量由任务投影与续生草稿体现。
            boolean firstAvailability = decimal(row[8]).signum() == 0
                    && preparedAfter.signum() > 0;
            boolean completed = preparedAfter.compareTo(decimal(row[7])) >= 0;
            if (firstAvailability || completed) {
                readyPlans.add(planId);
                planHeads.put(planId, new Object[]{row[9], row[10], row[11], planItemId});
            }
        }
        for (UUID planId : readyPlans) {
            Object[] head = planHeads.get(planId);
            if (hasPendingDraft(planId)) {
                continue;
            }
            createDraftForPlan(planId, Objects.toString(head[0]), (UUID) head[1],
                    toLocalDate(head[2]), actorId);
            chainNotice.notifySubcontractOutboundReady((UUID) head[3]);
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeFinishedInboundReversed(UUID stockDocumentId) {
        @SuppressWarnings("unchecked")
        List<Object[]> reservations = em.createNativeQuery("""
                SELECT reservation.id, reservation.owner_id, reservation.qty,
                       reservation.consumed_qty, reservation.released_qty
                FROM stock_reservations reservation
                WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND reservation.supply_type = 'PRODUCTION_FINISHED_IN'
                  AND reservation.source_doc_type = 'PRODUCTION_INBOUND'
                  AND reservation.source_doc_id = :documentId
                  AND reservation.is_deleted = FALSE
                ORDER BY reservation.owner_id, reservation.id
                FOR UPDATE
                """).setParameter("documentId", stockDocumentId).getResultList();
        UUID actorId = currentUser.requireId();
        for (Object[] row : reservations) {
            UUID reservationId = (UUID) row[0];
            UUID planItemId = (UUID) row[1];
            BigDecimal qty = decimal(row[2]);
            if (decimal(row[3]).signum() > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "前置自制目标件已经委外出仓，必须先红冲委外出仓再红冲成品入库");
            }
            Number drafts = (Number) em.createNativeQuery("""
                    SELECT COUNT(*)
                    FROM subcontract_material_issue_items issue_item
                    JOIN subcontract_material_issues issue
                      ON issue.id = issue_item.issue_id
                    WHERE issue_item.plan_item_id = :planItemId
                      AND issue.status = 0 AND issue.is_deleted = FALSE
                    """).setParameter("planItemId", planItemId).getSingleResult();
            if (drafts.longValue() > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "前置自制目标件已有委外出仓草稿，请先删除草稿再红冲成品入库");
            }
            if (decimal(row[4]).compareTo(qty) < 0) {
                em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET released_qty = qty, status = 1,
                            release_reason = 'PRODUCTION_FINISHED_IN_REVERSED',
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND consumed_qty = 0
                        """).setParameter("actorId", actorId)
                        .setParameter("id", reservationId).executeUpdate();
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_material_plan_items
                        SET prepared_qty = prepared_qty - :qty,
                            preparation_status = 'WAITING_INBOUND',
                            preparation_version = preparation_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND prepared_qty >= :qty
                          AND issued_qty <= prepared_qty - :qty
                        """).setParameter("qty", qty)
                        .setParameter("actorId", actorId)
                        .setParameter("id", planItemId).executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外前置自制专属数量已被使用，禁止红冲成品入库");
                }
            }
        }
    }

    /** System draft save: atomically replace its direct-stock reservation. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void reserveDraft(UUID issueId, UUID warehouseId) {
        if (warehouseId == null) return;
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT issue_item.id, issue_item.plan_item_id, issue_item.qty,
                       plan_item.goods_id, plan_item.color_id,
                       plan_item.flow_mode, plan_item.preparation_status,
                       plan_item.preparation_warehouse_id,
                       plan_item.bom_has_children_snapshot,
                       plan_item.preparation_bom_fingerprint
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue
                  ON issue.id = issue_item.issue_id
                 AND issue.status = 0 AND issue.is_deleted = FALSE
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                 AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                 AND plan_item.is_deleted = FALSE
                WHERE issue_item.issue_id = :issueId
                ORDER BY plan_item.id, issue_item.id
                FOR UPDATE OF plan_item
                """).setParameter("issueId", issueId).getResultList();
        if (lines.isEmpty()) return;
        inventoryLock.lockAll(lines.stream().map(row ->
                new InventoryKey((UUID) row[3], (UUID) row[4])).toList());
        releaseDraftReservations(issueId);
        UUID actorId = currentUser.requireId();
        for (Object[] row : lines) {
            UUID issueItemId = (UUID) row[0];
            UUID planItemId = (UUID) row[1];
            BigDecimal qty = decimal(row[2]);
            UUID goodsId = (UUID) row[3];
            UUID colorId = (UUID) row[4];
            String flowMode = Objects.toString(row[5]);
            if (Set.of("DIRECT_OUTBOUND", "MAKE_THEN_OUTBOUND").contains(flowMode)) {
                BomSnapshot currentBom = currentBomSnapshot(goodsId);
                if (!Objects.equals(row[8], currentBom.hasChildren())
                        || !Objects.equals(row[9], currentBom.fingerprint())) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外目标件 BOM 已在审批后变化，必须受控重评准备路线，禁止按旧结构出仓");
                }
            }
            if (qty.signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "委外目标件出仓数量必须大于零");
            }
            if ("MAKE_THEN_OUTBOUND".equals(flowMode)
                    || "PREPARED_OUTBOUND".equals(flowMode)) {
                if (!"READY_OUTBOUND".equals(row[6])
                        || !Objects.equals(row[7], warehouseId)) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "前置自制尚未实收入冻结仓，禁止保存委外出仓草稿");
                }
                Number reserved = (Number) em.createNativeQuery("""
                        SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0)
                        FROM stock_reservations
                        WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                          AND owner_id = :planItemId AND warehouse_id = :warehouseId
                          AND goods_id = :goodsId
                          AND color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                          AND status = 0 AND is_deleted = FALSE
                        """).setParameter("planItemId", planItemId)
                        .setParameter("warehouseId", warehouseId)
                        .setParameter("goodsId", goodsId)
                        .setParameter("colorId", colorId).getSingleResult();
                if (decimal(reserved).compareTo(qty) < 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外前置自制专属库存不足，请刷新任务");
                }
                continue;
            }
            // DIRECT reservations are replaceable only while unconsumed. This
            // also handles approve -> reverse -> regenerate: the restored old
            // reservation is released under the same inventory lock before a
            // new draft reservation is created, so it is never double-counted.
            em.createNativeQuery("""
                    UPDATE stock_reservations
                    SET released_qty = qty, status = 1,
                        release_reason = 'SUBCONTRACT_OUTBOUND_DRAFT_REPLACED',
                        lock_version = lock_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND owner_id = :planItemId
                      AND supply_type = 'STOCK_BALANCE'
                      AND status = 0 AND consumed_qty = 0
                      AND is_deleted = FALSE
                    """).setParameter("actorId", actorId)
                    .setParameter("planItemId", planItemId).executeUpdate();
            List<Object[]> balances = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                            SELECT balance.id, available.available_qty
                            FROM stock_balances balance
                            JOIN v_stock_available available
                              ON available.warehouse_id = balance.warehouse_id
                             AND available.goods_id = balance.goods_id
                             AND available.color_id IS NOT DISTINCT FROM balance.color_id
                            WHERE balance.warehouse_id = :warehouseId
                              AND balance.goods_id = :goodsId
                              AND balance.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                            """).setParameter("warehouseId", warehouseId)
                    .setParameter("goodsId", goodsId).setParameter("colorId", colorId));
            if (balances.isEmpty() || decimal(balances.getFirst()[1]).compareTo(qty) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "目标仓合格可动用库存不足，不能占用本次委外目标件");
            }
            int warehouseUpdated = em.createNativeQuery("""
                    UPDATE subcontract_material_plan_items
                    SET preparation_warehouse_id = :warehouseId,
                        preparation_version = preparation_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id AND flow_mode = 'DIRECT_OUTBOUND'
                      AND preparation_status = 'READY_OUTBOUND'
                    """).setParameter("warehouseId", warehouseId)
                    .setParameter("actorId", actorId).setParameter("id", planItemId)
                    .executeUpdate();
            if (warehouseUpdated != 1) throw new ApiException(ErrorCode.CONFLICT,
                    "委外目标件出仓任务已变化，请刷新后重试");
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (:id, NULL, :goodsId, :colorId, :warehouseId,
                        :qty, 0, 0, 0, 0,
                        'SUBCONTRACT_OUTBOUND_DRAFT', :issueId,
                        'SUBCONTRACT_OUTBOUND', :planItemId,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'STOCK_BALANCE', :balanceId, :key,
                        :actorId, :actorId)
                    """).setParameter("id", UUID.randomUUID())
                    .setParameter("goodsId", goodsId).setParameter("colorId", colorId)
                    .setParameter("warehouseId", warehouseId).setParameter("qty", qty)
                    .setParameter("issueId", issueId).setParameter("planItemId", planItemId)
                    .setParameter("balanceId", balances.getFirst()[0])
                    .setParameter("key", "SC-OUT-DRAFT:" + issueItemId)
                    .setParameter("actorId", actorId).executeUpdate();
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseDraftReservations(UUID issueId) {
        em.createNativeQuery("""
                UPDATE stock_reservations
                SET released_qty = qty, status = 1,
                    release_reason = 'SUBCONTRACT_OUTBOUND_DRAFT_REPLACED',
                    lock_version = lock_version + 1, updated_at = now()
                WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND supply_type = 'STOCK_BALANCE'
                  AND source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                  AND source_doc_id = :issueId
                  AND status = 0 AND consumed_qty = 0 AND is_deleted = FALSE
                """).setParameter("issueId", issueId).executeUpdate();
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void consumeOutboundReservations(UUID issueId, UUID warehouseId) {
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT issue_item.id, issue_item.plan_item_id, issue_item.qty
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                 AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                WHERE issue_item.issue_id = :issueId
                ORDER BY plan_item.id, issue_item.id
                """).setParameter("issueId", issueId).getResultList();
        UUID actorId = currentUser.requireId();
        for (Object[] line : lines) {
            UUID issueItemId = (UUID) line[0];
            UUID planItemId = (UUID) line[1];
            BigDecimal remaining = decimal(line[2]);
            @SuppressWarnings("unchecked")
            List<Object[]> reservations = em.createNativeQuery("""
                    SELECT id, qty-consumed_qty-released_qty
                    FROM stock_reservations
                    WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND owner_id = :planItemId AND warehouse_id = :warehouseId
                      AND status = 0 AND is_deleted = FALSE
                    ORDER BY CASE WHEN supply_type = 'PRODUCTION_FINISHED_IN' THEN 0 ELSE 1 END,
                             created_at, id
                    FOR UPDATE
                    """).setParameter("planItemId", planItemId)
                    .setParameter("warehouseId", warehouseId).getResultList();
            for (Object[] reservation : reservations) {
                if (remaining.signum() <= 0) break;
                BigDecimal take = remaining.min(decimal(reservation[1]));
                if (take.signum() <= 0) continue;
                UUID reservationId = (UUID) reservation[0];
                int updated = em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET consumed_qty = consumed_qty + :qty,
                            status = CASE WHEN consumed_qty + released_qty + :qty = qty
                                          THEN 1 ELSE 0 END,
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND status = 0
                          AND consumed_qty + released_qty + :qty <= qty
                        """).setParameter("qty", take).setParameter("actorId", actorId)
                        .setParameter("id", reservationId).executeUpdate();
                if (updated != 1) throw new ApiException(ErrorCode.CONFLICT,
                        "委外目标件专属预留已被并发修改");
                em.createNativeQuery("""
                        INSERT INTO subcontract_outbound_issue_reservation_allocations(
                            id, issue_id, issue_item_id, plan_item_id,
                            reservation_id, allocated_qty, status,
                            idempotency_key, created_by)
                        VALUES (:id, :issueId, :issueItemId, :planItemId,
                            :reservationId, :qty, 'EFFECTIVE', :key, :actorId)
                        """).setParameter("id", UUID.randomUUID())
                        .setParameter("issueId", issueId).setParameter("issueItemId", issueItemId)
                        .setParameter("planItemId", planItemId)
                        .setParameter("reservationId", reservationId).setParameter("qty", take)
                        .setParameter("key", "SC-OUT-ISSUE:" + issueItemId + ':' + reservationId)
                        .setParameter("actorId", actorId).executeUpdate();
                remaining = remaining.subtract(take);
            }
            if (remaining.signum() > 0) throw new ApiException(ErrorCode.CONFLICT,
                    "本次委外出仓没有足额订单专属库存预留");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseOutboundReservations(UUID issueId) {
        @SuppressWarnings("unchecked")
        List<Object[]> allocations = em.createNativeQuery("""
                SELECT allocation.id, allocation.reservation_id, allocation.allocated_qty
                FROM subcontract_outbound_issue_reservation_allocations allocation
                WHERE allocation.issue_id = :issueId AND allocation.status = 'EFFECTIVE'
                ORDER BY allocation.reservation_id, allocation.id FOR UPDATE
                """).setParameter("issueId", issueId).getResultList();
        UUID actorId = currentUser.requireId();
        for (Object[] allocation : allocations) {
            BigDecimal qty = decimal(allocation[2]);
            int restored = em.createNativeQuery("""
                    UPDATE stock_reservations
                    SET consumed_qty = consumed_qty - :qty, status = 0,
                        lock_version = lock_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id AND consumed_qty >= :qty
                    """).setParameter("qty", qty).setParameter("actorId", actorId)
                    .setParameter("id", allocation[1]).executeUpdate();
            if (restored != 1) throw new ApiException(ErrorCode.CONFLICT,
                    "委外出仓专属预留消费记录不一致，禁止红冲");
            em.createNativeQuery("""
                    UPDATE subcontract_outbound_issue_reservation_allocations
                    SET status = 'REVERSED', reversed_at = now(), reversed_by = :actorId
                    WHERE id = :id AND status = 'EFFECTIVE'
                    """).setParameter("actorId", actorId).setParameter("id", allocation[0])
                    .executeUpdate();
        }
    }

    // ==================== 仓库出仓工作台 ====================

    /** 待出仓任务：OPEN 计划且有待仓库执行的出仓量（计划 − 已出仓 > 0；草稿占用不影响任务可见性）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public PageResponse<OutboundTaskListItem> tasks(int page, int size, String keyword) {
        String kw = keyword == null || keyword.isBlank() ? null : "%" + keyword.trim() + "%";
        String kwClause = kw == null ? "" : """
                AND (p.order_bill_no ILIKE ? OR s.name ILIKE ?)
                """;
        String base = """
                FROM subcontract_material_plans p
                JOIN subcontract_orders o ON o.id = p.order_id
                LEFT JOIN suppliers s ON s.id = p.supplier_id
                JOIN (
                    SELECT pi.plan_id,
                           COUNT(*) AS line_count,
                           SUM(pi.planned_qty) AS planned_total,
                           SUM(pi.issued_qty) AS issued_total,
                           SUM(GREATEST(pi.planned_qty - pi.issued_qty, 0))
                               AS remaining_total,
                           SUM(CASE
                                 WHEN pi.preparation_status IN
                                      ('LEGACY_READY','READY_OUTBOUND')
                                 THEN GREATEST(
                                      LEAST(pi.planned_qty, pi.prepared_qty)
                                      - pi.issued_qty
                                      - COALESCE(draft_qty.qty, 0), 0)
                                 ELSE 0
                               END) AS ready_outbound_total,
                           COUNT(*) FILTER (
                               WHERE pi.preparation_status IN
                                     ('LEGACY_READY','READY_OUTBOUND')
                                 AND pi.planned_qty - pi.issued_qty > 0
                           ) AS ready_line_count,
                           COUNT(*) FILTER (
                               WHERE pi.flow_mode = 'MAKE_THEN_OUTBOUND'
                                 AND pi.preparation_status IN (
                                     'ACTION_REQUIRED','IN_PREPARATION',
                                     'WAITING_FQC','WAITING_INBOUND')
                           ) AS waiting_preparation_count,
                           COUNT(*) FILTER (
                               WHERE pi.preparation_status = 'CANCELLED'
                                  OR pi.flow_mode NOT IN (
                                      'LEGACY_BOM_COMPONENT','DIRECT_OUTBOUND',
                                      'MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                                  OR pi.preparation_status NOT IN (
                                      'LEGACY_READY','ACTION_REQUIRED',
                                      'IN_PREPARATION','WAITING_FQC',
                                      'WAITING_INBOUND','READY_OUTBOUND',
                                      'OUTBOUND_COMPLETE','CANCELLED')
                           ) AS blocked_line_count
                    FROM subcontract_material_plan_items pi
                    LEFT JOIN (
                        SELECT ii.plan_item_id, SUM(ii.qty) AS qty
                        FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_issues issue
                          ON issue.id = ii.issue_id
                         AND issue.status = 0
                         AND issue.is_deleted = FALSE
                        GROUP BY ii.plan_item_id
                    ) draft_qty ON draft_qty.plan_item_id = pi.id
                    WHERE pi.is_deleted = FALSE
                    GROUP BY pi.plan_id
                ) agg ON agg.plan_id = p.id
                LEFT JOIN LATERAL (
                    SELECT i.id AS issue_id, i.bill_no
                    FROM subcontract_material_issues i
                    WHERE i.status = 0 AND i.is_deleted = FALSE AND EXISTS (
                        SELECT 1 FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_plan_items pi2 ON pi2.id = ii.plan_item_id
                        WHERE ii.issue_id = i.id AND pi2.plan_id = p.id)
                    ORDER BY i.created_at DESC
                    LIMIT 1
                ) draft ON TRUE
                WHERE p.is_deleted = FALSE AND p.status = 'OPEN'
                  AND agg.ready_line_count > 0
                  AND (agg.ready_outbound_total > 0 OR draft.issue_id IS NOT NULL)
                """ + kwClause;
        Object[] params = kw == null ? new Object[0] : new Object[]{kw, kw};
        Long total = jdbc.queryForObject("SELECT COUNT(*) " + base, Long.class, params);
        List<OutboundTaskListItem> content = jdbc.query("""
                SELECT p.id, p.order_id, p.order_bill_no, s.name, o.deliver_date,
                       agg.line_count, agg.planned_total, agg.issued_total,
                       agg.remaining_total, draft.issue_id, draft.bill_no,
                       agg.ready_outbound_total, agg.ready_line_count,
                       agg.waiting_preparation_count, agg.blocked_line_count
                """ + base + """
                ORDER BY o.deliver_date ASC NULLS LAST, p.created_at ASC
                LIMIT ? OFFSET ?
                """,
                (rs, rowNum) -> new OutboundTaskListItem(
                        rs.getObject(1, UUID.class),
                        rs.getObject(2, UUID.class),
                        rs.getString(3),
                        rs.getString(4),
                        rs.getObject(5, LocalDate.class),
                        rs.getInt(6),
                        rs.getBigDecimal(7),
                        rs.getBigDecimal(8),
                        rs.getBigDecimal(9),
                        rs.getObject(10, UUID.class),
                        rs.getString(11),
                        rs.getBigDecimal(12),
                        rs.getInt(13),
                        rs.getInt(14),
                        rs.getInt(15)),
                append(params, size, (long) (Math.max(page, 1) - 1) * size));
        long totalElements = total == null ? 0 : total;
        int totalPages = size <= 0 ? 0 : (int) Math.ceil((double) totalElements / size);
        return new PageResponse<>(content, page, size, totalElements, totalPages);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public long countTasks() {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_plans p
                WHERE p.is_deleted = FALSE AND p.status = 'OPEN' AND EXISTS (
                    SELECT 1 FROM subcontract_material_plan_items pi
                    WHERE pi.plan_id = p.id AND pi.is_deleted = FALSE
                      AND pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                      AND LEAST(pi.planned_qty, pi.prepared_qty) - pi.issued_qty > 0)
                """, Long.class);
        return count == null ? 0 : count;
    }

    /** 计划详情：计划行（含库位/草稿占用/剩余）+ 该计划全部出仓单。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public OutboundTaskDetail taskDetail(UUID planId) {
        boolean canHandleOutbound = hasCurrentAuthority("subcontract_outbound:execute");
        List<OutboundPlanLine> lines = jdbc.query("""
                SELECT pi.id, pi.order_item_id,
                       pi.parent_goods_id, pi.parent_color_id, pg.code, pg.name,
                       pi.goods_id, g.code, g.name, g.stock_place,
                       pi.color_id, c.name, pi.unit_id, u.name, pi.unit_rate, pi.bom_unit_qty,
                       pi.planned_qty, pi.issued_qty,
                       COALESCE((SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                                 JOIN subcontract_material_issues i ON i.id = ii.issue_id
                                 WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0)
                       , pi.flow_mode, pi.preparation_status, pi.prepared_qty,
                       GREATEST(LEAST(pi.planned_qty, pi.prepared_qty)
                           - pi.issued_qty - COALESCE((
                               SELECT SUM(ii.qty)
                               FROM subcontract_material_issue_items ii
                               JOIN subcontract_material_issues i ON i.id = ii.issue_id
                               WHERE ii.plan_item_id = pi.id
                                 AND i.status = 0 AND i.is_deleted = FALSE), 0), 0),
                       GREATEST(pi.planned_qty - pi.issued_qty, 0),
                       pi.preparation_analysis_id, pi.preparation_analysis_item_id
                FROM subcontract_material_plan_items pi
                JOIN goods pg ON pg.id = pi.parent_goods_id
                JOIN goods g ON g.id = pi.goods_id
                LEFT JOIN colors c ON c.id = pi.color_id
                LEFT JOIN units u ON u.id = pi.unit_id
                WHERE pi.plan_id = ? AND pi.is_deleted = FALSE
                  AND pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                  AND pi.planned_qty - pi.issued_qty > 0
                ORDER BY pi.line_no ASC NULLS LAST, pi.id
                """,
                (rs, rowNum) -> new OutboundPlanLine(
                        rs.getObject(1, UUID.class),
                        rs.getObject(2, UUID.class),
                        rs.getObject(3, UUID.class),
                        rs.getObject(4, UUID.class),
                        rs.getString(5), rs.getString(6),
                        rs.getObject(7, UUID.class),
                        rs.getString(8), rs.getString(9), rs.getString(10),
                        rs.getObject(11, UUID.class), rs.getString(12),
                        rs.getObject(13, UUID.class), rs.getString(14),
                        rs.getBigDecimal(15), rs.getBigDecimal(16),
                        rs.getBigDecimal(17), rs.getBigDecimal(18),
                        rs.getBigDecimal(19), rs.getString(20), rs.getString(21),
                        rs.getBigDecimal(22), rs.getBigDecimal(23),
                        rs.getBigDecimal(24), rs.getObject(25, UUID.class),
                        rs.getObject(26, UUID.class), null,
                        outboundActions(canHandleOutbound, rs.getBigDecimal(23),
                                rs.getBigDecimal(19))),
                planId);
        if (lines.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外发料计划不存在");
        }
        List<Object[]> head = jdbc.query("""
                SELECT p.order_id, p.order_bill_no, p.status, s.name, o.deliver_date, p.close_reason,
                       p.supplier_id
                FROM subcontract_material_plans p
                LEFT JOIN suppliers s ON s.id = p.supplier_id
                JOIN subcontract_orders o ON o.id = p.order_id
                WHERE p.id = ? AND p.is_deleted = FALSE
                """,
                (rs, rowNum) -> new Object[]{
                        rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3),
                        rs.getString(4), rs.getObject(5, LocalDate.class), rs.getString(6),
                        rs.getObject(7, UUID.class)},
                planId);
        if (head.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外发料计划不存在");
        }
        List<OutboundDraftRef> drafts = jdbc.query("""
                SELECT i.id, i.bill_no, i.status, i.bill_date, w.name, i.approver_name,
                       (SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii WHERE ii.issue_id = i.id)
                FROM subcontract_material_issues i
                LEFT JOIN warehouses w ON w.id = i.warehouse_id
                WHERE i.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    JOIN subcontract_material_plan_items pi ON pi.id = ii.plan_item_id
                    WHERE ii.issue_id = i.id AND pi.plan_id = ?)
                ORDER BY i.created_at
                """,
                (rs, rowNum) -> new OutboundDraftRef(
                        rs.getObject(1, UUID.class),
                        rs.getString(2),
                        rs.getShort(3),
                        rs.getObject(4, LocalDate.class),
                        rs.getString(5),
                        rs.getString(6),
                        rs.getBigDecimal(7)),
                planId);
        Object[] h = head.getFirst();
        return new OutboundTaskDetail(
                planId,
                (UUID) h[0],
                (String) h[1],
                (String) h[2],
                (UUID) h[6],
                (String) h[3],
                (LocalDate) h[4],
                (String) h[5],
                lines,
                drafts);
    }

    /** 工作台「补齐出仓单」：有剩余且无未审草稿时手工重建草稿（红冲后补发等场景）。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_outbound:execute')")
    public UUID regenerateDraft(UUID planId) {
        lockPlan(planId, "OPEN");
        if (remainingLines(planId).stream().noneMatch(row -> decimal(row[8]).signum() > 0)) {
            throw new ApiException(ErrorCode.CONFLICT, "计划已无待出仓余量");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> plan = em.createNativeQuery("""
                SELECT p.order_bill_no, p.supplier_id, o.deliver_date
                FROM subcontract_material_plans p
                JOIN subcontract_orders o ON o.id = p.order_id
                WHERE p.id = :id
                """).setParameter("id", planId).getResultList();
        Object[] head = plan.getFirst();
        UUID created = createDraftForPlan(planId, Objects.toString(head[0]), (UUID) head[1],
                toLocalDate(head[2]),
                currentUser.requireId());
        if (created == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "各待出仓仓组均已有未审核草稿，无需补齐");
        }
        return created;
    }

    /** 工作台「不再出仓」：关闭剩余量（委外商料已够/订单变更等），必填原因。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_outbound:close')")
    public void closePlan(UUID planId, String reason) {
        if (reason == null || reason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "关闭发料计划必须填写原因");
        }
        lockPlan(planId, "OPEN");
        if (hasPendingDraft(planId)) {
            throw new ApiException(ErrorCode.CONFLICT, "存在未审核的出仓草稿，请先处理或删除草稿");
        }
        Long dependentLines = jdbc.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_plan_items
                WHERE plan_id = ? AND is_deleted = FALSE
                  AND flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND preparation_status IN (
                      'ACTION_REQUIRED','IN_PREPARATION','WAITING_FQC','WAITING_INBOUND')
                """, Long.class, planId);
        if (dependentLines != null && dependentLines > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "同一委外订货仍有待启动或进行中的前置自制行，禁止从仓库关闭整张出仓计划；请拆单或先完成/取消依赖");
        }
        releasePlanReservations(planId, "SUBCONTRACT_OUTBOUND_PLAN_CLOSED");
        jdbc.update("""
                UPDATE subcontract_material_plans
                SET status = 'CLOSED', close_reason = ?, updated_at = now(), updated_by = ?
                WHERE id = ?
                """, reason.trim(), currentUser.requireId(), planId);
        jdbc.update("""
                UPDATE subcontract_material_plan_items
                SET preparation_status = 'CANCELLED',
                    preparation_version = preparation_version + 1,
                    updated_at = now(), updated_by = ?
                WHERE plan_id = ? AND flow_mode IN (
                    'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                  AND preparation_status <> 'OUTBOUND_COMPLETE'
                """, currentUser.requireId(), planId);
    }

    // ==================== 内部 ====================

    private void lockPlan(UUID planId, String requiredStatus) {
        List<String> rows = jdbc.query("""
                SELECT status FROM subcontract_material_plans
                WHERE id = ? AND is_deleted = FALSE FOR UPDATE
                """, (rs, rowNum) -> rs.getString(1), planId);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外发料计划不存在");
        }
        if (!rows.getFirst().equals(requiredStatus)) {
            throw new ApiException(ErrorCode.CONFLICT, "发料计划已关闭或取消，请刷新后重试");
        }
    }

    private void releasePlanReservations(UUID planId, String reason) {
        jdbc.update("""
                UPDATE stock_reservations reservation
                SET released_qty = reservation.qty - reservation.consumed_qty,
                    status = 1, release_reason = ?,
                    lock_version = reservation.lock_version + 1,
                    updated_at = now(), updated_by = ?
                WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND reservation.status = 0
                  AND reservation.is_deleted = FALSE
                  AND reservation.owner_id IN (
                      SELECT id FROM subcontract_material_plan_items
                      WHERE plan_id = ? AND is_deleted = FALSE)
                """, reason, currentUser.requireId(), planId);
    }

    private boolean hasPendingDraft(UUID planId) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(DISTINCT i.id) FROM subcontract_material_issues i
                WHERE i.status = 0 AND i.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    JOIN subcontract_material_plan_items pi ON pi.id = ii.plan_item_id
                    WHERE ii.issue_id = i.id AND pi.plan_id = ?)
                """, Long.class, planId);
        return count != null && count > 0;
    }

    private boolean hasCurrentAuthority(String authority) {
        return currentUser.get()
                .map(user -> user.isSuperAdmin() || user.getAuthorities().stream()
                        .anyMatch(granted -> authority.equals(granted.getAuthority())))
                .orElse(false);
    }

    private static List<String> outboundActions(
            boolean canHandleOutbound, BigDecimal readyQty, BigDecimal draftReservedQty) {
        if (!canHandleOutbound) return List.of();
        BigDecimal ready = readyQty == null ? BigDecimal.ZERO : readyQty;
        BigDecimal draft = draftReservedQty == null ? BigDecimal.ZERO : draftReservedQty;
        return ready.add(draft).signum() > 0
                ? List.of("HANDLE_OUTBOUND")
                : List.of();
    }

    /** 计划行剩余视图：列 8 = 剩余量（planned − issued − 未审草稿占用）。 */
    private List<Object[]> remainingLines(UUID planId) {
        return jdbc.query("""
                SELECT pi.id, pi.order_item_id, pi.parent_goods_id, pi.parent_color_id,
                       pi.goods_id, pi.unit_id, pi.bom_unit_qty, pi.planned_qty,
                       CASE
                         WHEN pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                         THEN LEAST(pi.planned_qty, pi.prepared_qty)
                              - pi.issued_qty - COALESCE((
                           SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                           JOIN subcontract_material_issues i ON i.id = ii.issue_id
                           WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0)
                         ELSE 0
                       END,
                       pi.color_id, pi.preparation_warehouse_id, pi.flow_mode
                FROM subcontract_material_plan_items pi
                WHERE pi.plan_id = ? AND pi.is_deleted = FALSE
                ORDER BY pi.line_no ASC NULLS LAST, pi.id
                """,
                (rs, rowNum) -> new Object[]{
                        rs.getObject(1, UUID.class), rs.getObject(2, UUID.class),
                        rs.getObject(3, UUID.class), rs.getObject(4, UUID.class),
                        rs.getObject(5, UUID.class), rs.getObject(6, UUID.class),
                        rs.getBigDecimal(7), rs.getBigDecimal(8), rs.getBigDecimal(9),
                        rs.getObject(10, UUID.class), rs.getObject(11, UUID.class),
                        rs.getString(12)},
                planId);
    }

    /**
     * 按计划剩余量分仓生成出仓草稿（调用方须持计划锁/在批准事务内）。
     * 同冻结仓 MAKE 行合并；未选仓 DIRECT 行逐行独立，避免一张 issue 混仓。
     * 草稿 maker 置空（系统生成）：仓库凭 subcontract_material_issue:edit 权限拣货审核，
     * 不再受归属人隔离；返回草稿 id。
     */
    private UUID createDraftForPlan(UUID planId, String orderBillNo, UUID supplierId,
                                    LocalDate deliverDate, UUID actorUser) {
        List<Object[]> remaining = remainingLines(planId).stream()
                .filter(row -> decimal(row[8]).signum() > 0).toList();
        if (remaining.isEmpty()) {
            return null;
        }
        Map<String, List<Object[]>> groups = new LinkedHashMap<>();
        for (Object[] row : remaining) {
            UUID frozenWarehouseId = (UUID) row[10];
            // MAKE rows with the same frozen warehouse share one issue header.
            // DIRECT rows have no warehouse until warehouse staff choose one,
            // so each remains its own draft and can later choose independently.
            String key = frozenWarehouseId == null
                    ? ("LEGACY_BOM_COMPONENT".equals(row[11])
                        ? "LEGACY_UNASSIGNED"
                        : "UNASSIGNED:" + row[0])
                    : "WAREHOUSE:" + frozenWarehouseId;
            if (frozenWarehouseId == null
                    ? hasPendingDraftForPlanItem((UUID) row[0])
                    : hasPendingDraftForWarehouse(planId, frozenWarehouseId)) {
                continue;
            }
            groups.computeIfAbsent(key, ignored -> new ArrayList<>()).add(row);
        }
        UUID firstDraftId = null;
        for (List<Object[]> group : groups.values()) {
            UUID draftId = createDraftForLines(
                    group, orderBillNo, supplierId, deliverDate, actorUser);
            if (firstDraftId == null) firstDraftId = draftId;
        }
        return firstDraftId;
    }

    private boolean hasPendingDraftForPlanItem(UUID planItemId) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                WHERE issue_item.plan_item_id = ?
                  AND issue.status = 0 AND issue.is_deleted = FALSE
                """, Long.class, planItemId);
        return count != null && count > 0;
    }

    private boolean hasPendingDraftForWarehouse(UUID planId, UUID warehouseId) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(DISTINCT issue.id)
                FROM subcontract_material_issues issue
                WHERE issue.status = 0 AND issue.is_deleted = FALSE
                  AND issue.warehouse_id = ?
                  AND EXISTS (
                      SELECT 1
                      FROM subcontract_material_issue_items issue_item
                      JOIN subcontract_material_plan_items plan_item
                        ON plan_item.id = issue_item.plan_item_id
                      WHERE issue_item.issue_id = issue.id
                        AND plan_item.plan_id = ?)
                """, Long.class, warehouseId, planId);
        return count != null && count > 0;
    }

    private UUID createDraftForLines(
            List<Object[]> remaining,
            String orderBillNo,
            UUID supplierId,
            LocalDate deliverDate,
            UUID actorUser) {
        List<UUID> goodsIds = new ArrayList<>();
        remaining.forEach(row -> {
            goodsIds.add((UUID) row[4]);
            goodsIds.add((UUID) row[2]);
        });
        Map<UUID, Object[]> master = loadGoodsMaster(goodsIds);

        SubcontractMaterialIssue draft = new SubcontractMaterialIssue();
        draft.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE));
        draft.setBillDate(BusinessTime.today());
        draft.setSupplierId(supplierId);
        draft.setWarehouseId((UUID) remaining.getFirst()[10]);
        draft.setDeliverDate(deliverDate);
        draft.setStatus(ISSUE_DRAFT);
        draft.setMakerId(null); // 系统生成草稿：无归属人，仓库按权限执行出仓
        draft.setRemark("系统按委外订货单 " + orderBillNo + " 财务批准自动生成");
        draft.setSourceDocNo(orderBillNo);
        issueRepo.save(draft);
        jdbc.update("UPDATE subcontract_material_issues SET created_by = ? WHERE id = ?",
                actorUser, draft.getId());

        OffsetDateTime now = OffsetDateTime.now();
        int lineNo = 1;
        for (Object[] row : remaining) {
            SubcontractMaterialIssueItem it = new SubcontractMaterialIssueItem();
            it.setIssueId(draft.getId());
            it.setBillNo(draft.getBillNo());
            it.setBillDate(draft.getBillDate());
            it.setLineNo(lineNo++);
            it.setOrderItemId((UUID) row[1]);
            it.setPlanItemId((UUID) row[0]);
            it.setGoodsId((UUID) row[4]);
            Object[] childMaster = master.get((UUID) row[4]);
            applySnapshot(it, childMaster, false, now);
            it.setUnitId(row[5] != null ? (UUID) row[5]
                    : childMaster == null ? null : (UUID) childMaster[3]);
            it.setColorId((UUID) row[9]);
            it.setUnitRate(BigDecimal.ONE);
            it.setQty(decimal(row[8]));
            it.setParentGoodsId((UUID) row[2]);
            applySnapshot(it, master.get((UUID) row[2]), true, now);
            it.setParentColorId((UUID) row[3]);
            issueItemRepo.save(it);
        }
        return draft.getId();
    }

    private static void applySnapshot(SubcontractMaterialIssueItem item, Object[] master,
                                      boolean parent, OffsetDateTime now) {
        String code = master == null ? null : Objects.toString(master[1], null);
        String name = master == null ? null : Objects.toString(master[2], null);
        if (parent) {
            item.setParentGoodsCodeSnapshot(code);
            item.setParentGoodsNameSnapshot(name);
            item.setParentGoodsSnapshotSource(SubcontractGoodsSnapshot.MASTER_AT_SAVE);
            item.setParentGoodsSnapshotLockedAt(now);
        } else {
            item.setGoodsCodeSnapshot(code);
            item.setGoodsNameSnapshot(name);
            item.setGoodsSnapshotSource(SubcontractGoodsSnapshot.MASTER_AT_SAVE);
            item.setGoodsSnapshotLockedAt(now);
        }
    }

    private BomSnapshot currentBomSnapshot(UUID goodsId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT bom.id, bom.component_goods_id, bom.color_id, bom.qty
                FROM goods_bom_items bom
                JOIN goods child ON child.id = bom.component_goods_id
                 AND child.is_deleted = FALSE
                 AND COALESCE(child.auto_created, FALSE) = FALSE
                WHERE bom.goods_id = :goodsId AND bom.is_deleted = FALSE
                ORDER BY bom.id
                """).setParameter("goodsId", goodsId));
        StringBuilder canonical = new StringBuilder("GOODS|")
                .append(goodsId).append('\n');
        for (Object[] row : rows) {
            canonical.append(row[0]).append('|').append(row[1]).append('|')
                    .append(Objects.toString(row[2], "")).append('|')
                    .append(decimal(row[3]).stripTrailingZeros().toPlainString())
                    .append('\n');
        }
        try {
            byte[] digest = java.security.MessageDigest.getInstance("SHA-256")
                    .digest(canonical.toString().getBytes(
                            java.nio.charset.StandardCharsets.UTF_8));
            return new BomSnapshot(!rows.isEmpty(),
                    java.util.HexFormat.of().formatHex(digest));
        } catch (java.security.NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    /** goods 主档：id → [id, code, name, unit_id, stock_place]。 */
    private Map<UUID, Object[]> loadGoodsMaster(List<UUID> goodsIds) {
        List<UUID> ids = goodsIds.stream().filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, code, name, unit_id, stock_place FROM goods WHERE id IN (:ids)
                """).setParameter("ids", ids).getResultList();
        Map<UUID, Object[]> map = new HashMap<>();
        rows.forEach(row -> map.put((UUID) row[0], row));
        return map;
    }

    /** 原生查询 DATE 列安全转 LocalDate（驱动可能返回 java.sql.Date 或 LocalDate）。 */
    private static LocalDate toLocalDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate d) return d;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static Object[] append(Object[] params, Object... extra) {
        Object[] out = new Object[params.length + extra.length];
        System.arraycopy(params, 0, out, 0, params.length);
        System.arraycopy(extra, 0, out, params.length, extra.length);
        return out;
    }

    private record BomSnapshot(boolean hasChildren, String fingerprint) {
    }
}
