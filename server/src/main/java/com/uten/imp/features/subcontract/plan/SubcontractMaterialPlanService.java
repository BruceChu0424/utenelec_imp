package com.uten.imp.features.subcontract.plan;

import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.application.port.SubcontractShortDeliveryPort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.finance.ProcurementOrderQuantityBounds;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskDetail;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskLine;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskListItem;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 委外领料计划(ADR-143): 委外任务按工序只领 P 的直属物料, 分批领、分批回厂。
 *
 * <p>财务批准时按 {@code fn_subcontract_draw_edges(P)} 为每条可发外直属边冻结一条计划行:
 * 物料、解析后颜色、冻结单耗 {@code b = ROUND(订货换算率 × 边用量, 6)}、计划量
 * {@code planned = f(Q) = CEIL(Q × b, 4)}。之后一切按冻结计划行读取, 不再读现时 BOM;
 * 没有可发外直属边的委外件(缺 BOM)不能批准(ADR-143 §二.3), 批准后每条明细都有计划行。
 *
 * <p>计划行 {@code issued_qty} 是<b>已发净量</b>: 出仓审核 +、出仓红冲 −、材料退货审核 −、
 * 退料红冲 +, 全部 CAS, 始终 {@code 0 ≤ issued ≤ planned}。领料草稿只由委外人员在
 * 「领料」提交时新建(见 {@code features/subcontract/draw}); 本服务负责草稿的预留占用/消费/
 * 红冲恢复/撤回释放、按明细结束领料、改量与订货红冲, 以及仓库委外出仓工作台的读模型。
 * 系统不自动建出仓草稿; 委外件只按冻结计划行领直属物料发外(ADR-143)。
 *
 * <p>预留释放、出仓、退料、批准、改量之后, 只在事务里追加一条「领料重算」outbox 事件
 * ({@link SubcontractOutboundWakePort}), 可领量在提交后才计算。
 */
@Service
@RequiredArgsConstructor
public class SubcontractMaterialPlanService {

    private static final int SCALE = 4;

    private final EntityManager em;
    private final JdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;
    private final SubcontractChainNoticePort chainNotice;
    private final InventoryMutationLock inventoryLock;
    private final SubcontractOutboundWakePort drawRecheck;
    /**
     * 结束领料后重评短交(ADR-101 §2.5)。ObjectProvider 断 bean 环: 短交服务本身依赖本服务
     * (minimumOrderQtyFromIssued 体检), 构造注入会成环。
     */
    private final ObjectProvider<SubcontractShortDeliveryPort> shortDelivery;
    /** ADR-143 §二.3 委外件缺 BOM 转研发(研发任务模块实现)；单测手工构造时为空，只跳过登记。 */
    @org.springframework.beans.factory.annotation.Autowired
    private ObjectProvider<com.uten.imp.application.port.RdBomGapPort> rdBomGaps;

    /** 撤回结果: 受影响的领料草稿(按 id 排序)与撤掉的草稿行数。 */
    public record WithdrawResult(List<UUID> issueIds, int removedLineCount) {
        public WithdrawResult {
            issueIds = List.copyOf(issueIds);
        }
    }

    // ==================== 财务批准: 冻结领料计划 ====================

    /**
     * 财务批准同事务: 每条订货明细按 {@code fn_subcontract_draw_edges(P)} 的每条可发外直属边冻结一条
     * 计划行。有明细的委外件没有任何可发外直属边(缺 BOM)时先转研发完善再 409 拒绝(ADR-143 §二.3,
     * 订货侧批准前已检查, 这里是兜底), 绝不留下没有计划行的已批准明细。冻结单耗为 0 或同一物料颜色
     * 出现多条边时可读拒绝。只建计划, 不建草稿、不占库存; 提交后由 outbox 重算可领并提醒委外人员。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void createPlanOnApproval(UUID orderId) {
        List<Object[]> head = rows("""
                SELECT bill_no, supplier_id, maker_id FROM subcontract_orders WHERE id = :orderId
                """, Map.of("orderId", orderId));
        if (head.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在");
        }
        requireDrawableBom(orderId, Objects.toString(head.getFirst()[0], null), (UUID) head.getFirst()[2]);
        List<Object[]> edges = rows("""
                SELECT oi.id, oi.line_no, oi.goods_id, oi.color_id,
                       COALESCE(oi.goods_code_snapshot, parent.code), COALESCE(oi.goods_name_snapshot, parent.name),
                       edge.component_goods_id, edge.color_id, component.unit_id, component.code, component.name,
                       ROUND(COALESCE(oi.unit_rate, 1) * edge.edge_qty, 6) AS bom_unit_qty,
                       fn_subcontract_draw_f(oi.qty, ROUND(COALESCE(oi.unit_rate, 1) * edge.edge_qty, 6))
                FROM subcontract_order_items oi
                CROSS JOIN LATERAL fn_subcontract_draw_edges(oi.goods_id) edge
                JOIN goods component ON component.id = edge.component_goods_id
                LEFT JOIN goods parent ON parent.id = oi.goods_id
                WHERE oi.order_id = :orderId AND NOT oi.is_deleted
                ORDER BY oi.line_no ASC NULLS LAST, oi.id, edge.sort_order, edge.edge_id
                """, Map.of("orderId", orderId));
        if (edges.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "委外订货单没有明细，不能冻结领料计划");
        }
        List<String> problems = new ArrayList<>();
        Set<String> seen = new LinkedHashSet<>();
        for (Object[] edge : edges) {
            String parentLabel = label(edge[4], edge[5]);
            String materialLabel = label(edge[9], edge[10]);
            if (decimal(edge[11]).signum() <= 0) {
                problems.add("第 " + edge[1] + " 行委外件 " + parentLabel + " 的直属物料 " + materialLabel
                        + " 折算到订货单位的单耗不足 0.000001");
            }
            if (!seen.add(edge[0] + "|" + edge[6] + "|" + Objects.toString(edge[7], ""))) {
                problems.add("第 " + edge[1] + " 行委外件 " + parentLabel + " 的 BOM 里直属物料 " + materialLabel
                        + " (同一颜色)出现了多行");
            }
        }
        if (!problems.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, String.join("；", problems)
                    + "；不能冻结委外领料计划，请先在 BOM 核对用量或合并物料行后再批准");
        }
        UUID planId = UUID.randomUUID();
        UUID actor = currentUser.requireId();
        jdbc.update("""
                INSERT INTO subcontract_material_plans(
                    id, order_id, order_bill_no, supplier_id, status, created_by, updated_by)
                VALUES (?, ?, ?, ?, 'OPEN', ?, ?)
                """, planId, orderId, head.getFirst()[0], head.getFirst()[1], actor, actor);
        int lineNo = 1;
        List<SubcontractOutboundWakePort.StockedDimension> dimensions = new ArrayList<>();
        for (Object[] edge : edges) {
            jdbc.update("""
                    INSERT INTO subcontract_material_plan_items(
                        id, plan_id, order_item_id, line_no,
                        parent_goods_id, parent_color_id,
                        goods_id, color_id, unit_id, unit_rate,
                        bom_unit_qty, planned_qty, issued_qty,
                        created_by, updated_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 0, ?, ?)
                    """,
                    UUID.randomUUID(), planId, edge[0], lineNo++,
                    edge[2], edge[3],
                    edge[6], edge[7], edge[8],
                    decimal(edge[11]), decimal(edge[12]),
                    actor, actor);
            dimensions.add(new SubcontractOutboundWakePort.StockedDimension((UUID) edge[6], (UUID) edge[7], null));
        }
        drawRecheck.enqueueDrawRecheck(dimensions);
    }

    /**
     * 每条明细的委外件都必须有可发外直属物料(ADR-143 §二.3)。缺的逐个转研发完善(独立事务立即提交,
     * 随后的 409 不撤销; 订货单制单人进等待名单), 再以与订货送审同一措辞拒绝批准。
     */
    private void requireDrawableBom(UUID orderId, String billNo, UUID makerEmployeeId) {
        List<Object[]> missing = rows("""
                SELECT DISTINCT ON (oi.goods_id) oi.goods_id,
                       COALESCE(oi.goods_code_snapshot, goods.code), COALESCE(oi.goods_name_snapshot, goods.name)
                FROM subcontract_order_items oi
                LEFT JOIN goods ON goods.id = oi.goods_id
                WHERE oi.order_id = :orderId AND NOT oi.is_deleted
                  AND NOT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(oi.goods_id))
                ORDER BY oi.goods_id, oi.line_no ASC NULLS LAST, oi.id
                """, Map.of("orderId", orderId));
        if (missing.isEmpty()) {
            return;
        }
        List<String> labels = new ArrayList<>();
        var port = rdBomGaps == null ? null : rdBomGaps.getIfAvailable();
        for (Object[] row : missing) {
            String goodsLabel = label(row[1], row[2]);
            labels.add(goodsLabel);
            if (port != null && row[0] != null) {
                port.forwardBomGap((UUID) row[0], com.uten.imp.application.port.RdBomGapPort.SOURCE_SUBCONTRACT_ORDER,
                        orderId, billNo,
                        "委外订货单 " + Objects.toString(billNo, "") + " 里的委外件 " + goodsLabel
                                + " 还没有维护 BOM(直属物料)，不能批准",
                        makerEmployeeId);
            }
        }
        throw new ApiException(ErrorCode.CONFLICT,
                com.uten.imp.application.port.RdBomGapPort.subcontractBomMissingMessage(labels, false));
    }

    // ==================== 出仓 / 退料回写已发净量 ====================

    /** 出仓审核同事务: 计划行已发净量 += 本次出仓量(CAS 不超计划), 通知已发出; 不续建草稿。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterIssueApproved(UUID issueId) {
        List<Object[]> lines = issueLines(issueId);
        if (lines.isEmpty()) {
            return;
        }
        for (Object[] line : lines) {
            BigDecimal qty = decimal(line[1]);
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET issued_qty = issued_qty + ?, updated_at = now()
                    WHERE id = ? AND NOT is_deleted AND issued_qty + ? <= planned_qty
                    """, qty, line[0], qty);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "出仓量超过领料计划余量，请刷新出仓任务后重试");
            }
        }
        Long closedPlans = jdbc.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_issue_items item
                JOIN subcontract_material_plan_items line ON line.id = item.plan_item_id
                JOIN subcontract_material_plans plan ON plan.id = line.plan_id
                WHERE item.issue_id = ? AND NOT item.is_deleted
                  AND (plan.status <> 'OPEN' OR plan.is_deleted OR line.draw_closed_at IS NOT NULL)
                """, Long.class, issueId);
        if (closedPlans != null && closedPlans > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "该委外明细的领料已结束或订货已撤销，禁止继续出仓");
        }
        chainNotice.notifySubcontractOutboundCompleted(issueId);
        drawRecheck.enqueueDrawRecheck(dimensionsOf(lines));
    }

    /** 出仓红冲同事务: 已发净量对称回减(CAS 不为负), 通知已红冲; 不自动补草稿。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterIssueReversed(UUID issueId) {
        List<Object[]> lines = issueLines(issueId);
        if (lines.isEmpty()) {
            return;
        }
        for (Object[] line : lines) {
            BigDecimal qty = decimal(line[1]);
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET issued_qty = issued_qty - ?, updated_at = now()
                    WHERE id = ? AND NOT is_deleted AND issued_qty >= ?
                    """, qty, line[0], qty);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "领料计划的已发外数量不足以红冲本次出仓，请刷新后重试");
            }
        }
        chainNotice.notifySubcontractOutboundReversed(issueId);
        drawRecheck.enqueueDrawRecheck(dimensionsOf(lines));
    }

    /** 材料退货审核同事务: 退回的料从已发净量里扣掉(CAS 不为负), 退回入库后可再次领料。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterMaterialReturnApproved(UUID returnId) {
        List<Object[]> lines = returnLines(returnId);
        for (Object[] line : lines) {
            BigDecimal qty = decimal(line[1]);
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET issued_qty = issued_qty - ?, updated_at = now()
                    WHERE id = ? AND NOT is_deleted AND issued_qty >= ?
                    """, qty, line[0], qty);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "退料量超过领料计划的已发外数量，请刷新后重试");
            }
        }
        if (!lines.isEmpty()) {
            drawRecheck.enqueueDrawRecheck(dimensionsOf(lines));
        }
    }

    /**
     * 退料红冲同事务: 已发净量加回。若退回的料已被重新领出(已发 + 待仓库发 + 本次 &gt; 计划)则拒绝,
     * 守住「每种物料已覆盖 ≤ 计划」。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterMaterialReturnReversed(UUID returnId) {
        List<Object[]> lines = returnLines(returnId);
        for (Object[] line : lines) {
            BigDecimal qty = decimal(line[1]);
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items line
                    SET issued_qty = line.issued_qty + ?, updated_at = now()
                    WHERE line.id = ? AND NOT line.is_deleted
                      AND line.issued_qty + ? + COALESCE((
                          SELECT SUM(item.qty)
                          FROM subcontract_material_issue_items item
                          JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                           AND issue.status = 0 AND NOT issue.is_deleted
                          WHERE item.plan_item_id = line.id AND NOT item.is_deleted), 0) <= line.planned_qty
                    """, qty, line[0], qty);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "退回的料已重新领出，不能红冲退料");
            }
        }
        if (!lines.isEmpty()) {
            drawRecheck.enqueueDrawRecheck(dimensionsOf(lines));
        }
    }

    // ==================== 领料草稿的预留 ====================

    /**
     * 领料草稿占用库存(提交领料新建草稿后、仓库保存拣货修改后都调用): 先释放本草稿原有占用,
     * 再逐行按冻结计划行的物料货色, 优先接收本订货明细在该仓的专属批次
     * ({@code fn_subcontract_take_component_entitlements}), 余量占用该仓公共可用库存。
     * 仓库改少即同步少占; 物料不够即 409。调用方须已按 ADR-107 预锁本草稿涉及的订货单与物料维度。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void reserveDraft(UUID issueId, UUID warehouseId) {
        List<Object[]> lines = rows("""
                SELECT issue_item.id, issue_item.plan_item_id, issue_item.qty,
                       plan_item.goods_id, plan_item.color_id,
                       plan.status, plan_item.draw_closed_at IS NULL
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                 AND issue.status = 0 AND NOT issue.is_deleted
                JOIN subcontract_material_plan_items plan_item ON plan_item.id = issue_item.plan_item_id
                 AND NOT plan_item.is_deleted
                JOIN subcontract_material_plans plan ON plan.id = plan_item.plan_id AND NOT plan.is_deleted
                WHERE issue_item.issue_id = :issueId AND NOT issue_item.is_deleted
                ORDER BY plan_item.id, issue_item.id
                FOR UPDATE OF plan_item
                """, Map.of("issueId", issueId));
        if (lines.isEmpty()) {
            return;
        }
        if (warehouseId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "领料出仓单必须指定发出仓");
        }
        for (Object[] line : lines) {
            if (!"OPEN".equals(line[5]) || !Boolean.TRUE.equals(line[6])) {
                throw new ApiException(ErrorCode.CONFLICT, "该委外明细的领料已结束或订货已撤销，不能再保存出仓");
            }
        }
        // ADR-146 计入可用量的仓(fn_warehouse_counts_as_usable): 与领料候选仓(fn_subcontract_draw_line_stock 的
        // 专属批次与公共可用两部分)、领料提交的锁发现同一个谓词——系统分出来的仓这里一定放行。
        // 停用叶仓的既有库存仍可动用(V540); 「新选一个仓必须启用」只在有人换仓时判定,
        // 由 SubcontractMaterialIssueService.update 的 require(原仓, 新仓, GOOD_OUT) 负责。
        Boolean usable = jdbc.queryForObject("SELECT fn_warehouse_counts_as_usable(CAST(? AS uuid))",
                Boolean.class, warehouseId);
        if (!Boolean.TRUE.equals(usable)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "领料只能从计入可用量的良品子仓发出(不能是主仓、不良品仓、车间内料仓或不核算的仓)，请换一个仓库");
        }
        inventoryLock.lockAll(lines.stream()
                .map(line -> new InventoryKey((UUID) line[3], (UUID) line[4])).toList());
        releaseDraftReservations(issueId);
        UUID actorId = currentUser.requireId();
        // 早先草稿已作废、却还挂着的未消费占用一并释放, 不重复占库存。
        em.createNativeQuery("""
                UPDATE stock_reservations reservation
                SET released_qty = reservation.qty - reservation.consumed_qty, status = 1,
                    release_reason = 'SUBCONTRACT_DRAW_DRAFT_GONE',
                    lock_version = reservation.lock_version + 1,
                    updated_at = now(), updated_by = :actorId
                WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND reservation.owner_id IN (:planItemIds)
                  AND reservation.source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                  AND reservation.status = 0 AND reservation.consumed_qty = 0
                  AND NOT reservation.is_deleted
                  AND NOT EXISTS (
                      SELECT 1 FROM subcontract_material_issues live_draft
                      WHERE live_draft.id = reservation.source_doc_id
                        AND live_draft.status = 0 AND NOT live_draft.is_deleted)
                """).setParameter("actorId", actorId)
                .setParameter("planItemIds", lines.stream().map(line -> line[1]).distinct().toList())
                .executeUpdate();
        for (Object[] line : lines) {
            UUID issueItemId = (UUID) line[0];
            UUID planItemId = (UUID) line[1];
            BigDecimal qty = decimal(line[2]);
            UUID goodsId = (UUID) line[3];
            UUID colorId = (UUID) line[4];
            if (qty.signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "领料出仓数量必须大于零");
            }
            BigDecimal exact = decimal(jdbc.queryForObject("""
                    SELECT COALESCE(SUM(stock.exact_qty), 0)
                    FROM fn_subcontract_draw_line_stock(CAST(? AS uuid)) stock
                    WHERE stock.warehouse_id = CAST(? AS uuid)
                    """, BigDecimal.class, planItemId, warehouseId));
            BigDecimal taken = BigDecimal.ZERO;
            if (exact.signum() > 0) {
                taken = decimal(jdbc.queryForObject("""
                        SELECT fn_subcontract_take_component_entitlements(
                            CAST(? AS uuid), CAST(? AS uuid), CAST(? AS uuid), ?, CAST(? AS uuid))
                        """, BigDecimal.class, planItemId, issueId, warehouseId, qty, actorId));
            }
            BigDecimal publicQty = qty.subtract(taken);
            if (publicQty.signum() <= 0) {
                continue;
            }
            List<Object[]> balances = jdbc.query("""
                    SELECT balance.id, GREATEST(COALESCE(available.available_qty, 0), 0)
                    FROM stock_balances balance
                    LEFT JOIN v_stock_available available
                      ON available.warehouse_id = balance.warehouse_id
                     AND available.goods_id = balance.goods_id
                     AND available.color_id IS NOT DISTINCT FROM balance.color_id
                    WHERE balance.warehouse_id = CAST(? AS uuid)
                      AND balance.goods_id = CAST(? AS uuid)
                      AND balance.color_id IS NOT DISTINCT FROM CAST(? AS uuid)
                    """, (rs, rowNum) -> new Object[]{rs.getObject(1, UUID.class), rs.getBigDecimal(2)},
                    warehouseId, goodsId, colorId);
            if (balances.isEmpty() || decimal(balances.getFirst()[1]).compareTo(publicQty) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "领料物料在该仓的可用库存不足，请刷新后重新核对领料数量或换仓");
            }
            // 每次重新占用都有自己的事件身份: 明细 UUID 在多次保存间不变, 不能用它当唯一键。
            UUID reservationId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (:id, NULL, :goodsId, CAST(:colorId AS uuid), :warehouseId,
                        :qty, 0, 0, 0, 0,
                        'SUBCONTRACT_OUTBOUND_DRAFT', :issueId,
                        'SUBCONTRACT_OUTBOUND', :planItemId,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'STOCK_BALANCE', :balanceId, :key,
                        :actorId, :actorId)
                    """).setParameter("id", reservationId)
                    .setParameter("goodsId", goodsId).setParameter("colorId", colorId)
                    .setParameter("warehouseId", warehouseId).setParameter("qty", publicQty)
                    .setParameter("issueId", issueId).setParameter("planItemId", planItemId)
                    .setParameter("balanceId", balances.getFirst()[0])
                    .setParameter("key", "SC-OUT-DRAFT:" + issueItemId + ":" + reservationId)
                    .setParameter("actorId", actorId).executeUpdate();
        }
    }

    /** 释放本草稿全部未消费占用(专属批次的占用由数据库交接守卫原样退回原分析)。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseDraftReservations(UUID issueId) {
        List<Object[]> released = returning("""
                UPDATE stock_reservations
                SET released_qty = qty, status = 1,
                    release_reason = 'SUBCONTRACT_OUTBOUND_DRAFT_REPLACED',
                    lock_version = lock_version + 1, updated_at = now()
                WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND supply_type = 'STOCK_BALANCE'
                  AND source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                  AND source_doc_id = :issueId
                  AND status = 0 AND consumed_qty = 0 AND is_deleted = FALSE
                RETURNING goods_id, color_id
                """, Map.of("issueId", issueId));
        enqueueReleased(released);
    }

    /**
     * 出仓审核同事务: 每行按出仓量逐笔消费本草稿的占用(专属批次在前), 记消费分配; 仓库改少后
     * 仍挂着的剩余占用同时释放, 不让少发的量一直被占着。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void consumeOutboundReservations(UUID issueId, UUID warehouseId) {
        List<Object[]> lines = rows("""
                SELECT issue_item.id, issue_item.plan_item_id, issue_item.qty
                FROM subcontract_material_issue_items issue_item
                WHERE issue_item.issue_id = :issueId AND NOT issue_item.is_deleted
                  AND issue_item.plan_item_id IS NOT NULL
                ORDER BY issue_item.plan_item_id, issue_item.id
                """, Map.of("issueId", issueId));
        if (lines.isEmpty()) {
            return;
        }
        UUID actorId = currentUser.requireId();
        for (Object[] line : lines) {
            UUID issueItemId = (UUID) line[0];
            UUID planItemId = (UUID) line[1];
            BigDecimal remaining = decimal(line[2]);
            List<Object[]> reservations = rows("""
                    SELECT reservation.id, reservation.qty - reservation.consumed_qty - reservation.released_qty
                    FROM stock_reservations reservation
                    WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND reservation.owner_id = :planItemId AND reservation.warehouse_id = :warehouseId
                      AND reservation.source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                      AND reservation.source_doc_id = :issueId
                      AND reservation.status = 0 AND NOT reservation.is_deleted
                    ORDER BY CASE WHEN EXISTS (
                                 SELECT 1 FROM subcontract_component_stock_handoffs handoff
                                 WHERE handoff.target_reservation_id = reservation.id) THEN 0 ELSE 1 END,
                             reservation.created_at, reservation.id
                    FOR UPDATE OF reservation
                    """, Map.of("planItemId", planItemId, "warehouseId", warehouseId, "issueId", issueId));
            for (Object[] reservation : reservations) {
                if (remaining.signum() <= 0) {
                    break;
                }
                BigDecimal take = remaining.min(decimal(reservation[1]));
                if (take.signum() <= 0) {
                    continue;
                }
                UUID reservationId = (UUID) reservation[0];
                int updated = em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET consumed_qty = consumed_qty + :qty,
                            status = CASE WHEN consumed_qty + released_qty + :qty = qty THEN 1 ELSE 0 END,
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND status = 0
                          AND consumed_qty + released_qty + :qty <= qty
                        """).setParameter("qty", take).setParameter("actorId", actorId)
                        .setParameter("id", reservationId).executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT, "领料占用已被并发修改，请刷新后重试");
                }
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
            if (remaining.signum() > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "本次出仓没有足额的领料占用，请先保存拣货数量后再审核");
            }
        }
        List<Object[]> residual = returning("""
                UPDATE stock_reservations
                SET released_qty = qty - consumed_qty, status = 1,
                    release_reason = 'SUBCONTRACT_OUTBOUND_ISSUE_RESIDUAL',
                    lock_version = lock_version + 1, updated_at = now(), updated_by = :actorId
                WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                  AND source_doc_id = :issueId
                  AND status = 0 AND is_deleted = FALSE
                RETURNING goods_id, color_id
                """, Map.of("issueId", issueId, "actorId", actorId));
        enqueueReleased(residual);
    }

    /** 出仓红冲同事务: 按消费分配原样恢复占用后再整体释放, 专属批次由交接守卫退回原分析。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseOutboundReservations(UUID issueId) {
        List<Object[]> allocations = rows("""
                SELECT allocation.id, allocation.reservation_id, allocation.allocated_qty
                FROM subcontract_outbound_issue_reservation_allocations allocation
                WHERE allocation.issue_id = :issueId AND allocation.status = 'EFFECTIVE'
                ORDER BY allocation.reservation_id, allocation.id FOR UPDATE
                """, Map.of("issueId", issueId));
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
            if (restored != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "委外出仓的占用消费记录不一致，禁止红冲");
            }
            em.createNativeQuery("""
                    UPDATE subcontract_outbound_issue_reservation_allocations
                    SET status = 'REVERSED', reversed_at = now(), reversed_by = :actorId
                    WHERE id = :id AND status = 'EFFECTIVE'
                    """).setParameter("actorId", actorId).setParameter("id", allocation[0])
                    .executeUpdate();
        }
        releaseDraftReservations(issueId);
    }

    // ==================== 撤回 / 结束领料 / 改量 / 订货红冲 ====================

    /**
     * 撤回这些订货明细还没发出的领料草稿行: 释放占用(专属批次退回原分析)、删掉这些行,
     * 草稿空了就整张作废, 并通知草稿所在仓库。{@code force=false} 时仓库已保存过拣货修改
     * (改了数量、删掉了物料行或改过草稿, 判定同 {@link #DRAFT_EDITED_BY_WAREHOUSE})的草稿拒绝撤回,
     * 这种草稿由仓库在拣货页整张退回({@link #withdrawDraft})。撤回不写 warehouse_dropped_at。
     * 调用方须已预锁订货单并锁住草稿头与计划行。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public WithdrawResult withdrawPendingDraws(Collection<UUID> orderItemIds, boolean force) {
        List<UUID> items = orderItemIds == null ? List.of()
                : orderItemIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (items.isEmpty()) {
            return new WithdrawResult(List.of(), 0);
        }
        List<Object[]> drafts = rows("""
                SELECT issue.id, issue.bill_no, issue.created_by, issue.updated_by,
                       EXISTS (SELECT 1 FROM subcontract_material_issue_items dropped
                               WHERE dropped.issue_id = issue.id AND dropped.warehouse_dropped_at IS NOT NULL
                                 AND dropped.order_item_id IN (:items))
                FROM subcontract_material_issues issue
                WHERE issue.status = 0 AND NOT issue.is_deleted
                  AND EXISTS (
                      SELECT 1 FROM subcontract_material_issue_items item
                      WHERE item.issue_id = issue.id AND NOT item.is_deleted
                        AND item.plan_item_id IS NOT NULL AND item.order_item_id IN (:items))
                ORDER BY issue.id
                FOR UPDATE
                """, Map.of("items", items));
        if (drafts.isEmpty()) {
            return new WithdrawResult(List.of(), 0);
        }
        UUID actorId = currentUser.requireId();
        Set<UUID> selected = Set.copyOf(items);
        List<UUID> affected = new ArrayList<>();
        int removed = 0;
        List<SubcontractOutboundWakePort.StockedDimension> dimensions = new ArrayList<>();
        for (Object[] draft : drafts) {
            UUID issueId = (UUID) draft[0];
            List<Object[]> lines = rows("""
                    SELECT item.id, item.plan_item_id, item.order_item_id, item.qty, item.requested_qty,
                           item.goods_id, item.color_id
                    FROM subcontract_material_issue_items item
                    WHERE item.issue_id = :issueId AND NOT item.is_deleted
                    ORDER BY item.id
                    """, Map.of("issueId", issueId));
            List<Object[]> withdrawn = lines.stream()
                    .filter(line -> line[1] != null && selected.contains((UUID) line[2])).toList();
            if (withdrawn.isEmpty()) {
                continue;
            }
            if (!force) {
                boolean edited = !Objects.equals(draft[2], draft[3]) || Boolean.TRUE.equals(draft[4])
                        || withdrawn.stream().anyMatch(line ->
                                line[4] == null || decimal(line[3]).compareTo(decimal(line[4])) != 0);
                if (edited) {
                    throw new ApiException(ErrorCode.CONFLICT, "领料出仓单 " + draft[1]
                            + " 仓库已开始拣货并修改过，这边不能撤回；请联系仓库在拣货页把这张领料退回");
                }
            }
            List<UUID> planItemIds = withdrawn.stream().map(line -> (UUID) line[1]).distinct().toList();
            List<Object[]> released = returning("""
                    UPDATE stock_reservations
                    SET released_qty = qty - consumed_qty, status = 1,
                        release_reason = 'SUBCONTRACT_DRAW_WITHDRAWN',
                        lock_version = lock_version + 1, updated_at = now(), updated_by = :actorId
                    WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                      AND source_doc_id = :issueId
                      AND owner_id IN (:planItemIds)
                      AND status = 0 AND consumed_qty = 0 AND is_deleted = FALSE
                    RETURNING goods_id, color_id
                    """, Map.of("actorId", actorId, "issueId", issueId, "planItemIds", planItemIds));
            released.forEach(row -> dimensions.add(
                    new SubcontractOutboundWakePort.StockedDimension((UUID) row[0], (UUID) row[1], null)));
            em.createNativeQuery("""
                    UPDATE subcontract_material_issue_items
                    SET is_deleted = TRUE, updated_at = now(), updated_by = :actorId
                    WHERE id IN (:itemIds)
                    """).setParameter("actorId", actorId)
                    .setParameter("itemIds", withdrawn.stream().map(line -> line[0]).toList())
                    .executeUpdate();
            if (withdrawn.size() == lines.size()) {
                em.createNativeQuery("""
                        UPDATE subcontract_material_issues
                        SET is_deleted = TRUE, deleted_at = now(), updated_at = now(), updated_by = :actorId
                        WHERE id = :issueId
                        """).setParameter("actorId", actorId).setParameter("issueId", issueId).executeUpdate();
            }
            affected.add(issueId);
            removed += withdrawn.size();
        }
        affected.forEach(chainNotice::notifySubcontractDrawWithdrawn);
        drawRecheck.enqueueDrawRecheck(dimensions);
        return new WithdrawResult(affected, removed);
    }

    /**
     * 「仓库已改过这张领料草稿」的判定(SQL 片段, 与 {@link #withdrawPendingDraws} 的 force=false 拒绝条件
     * 同一口径): 草稿头被别人(仓库)保存过, 或本任务的领料行改了数量、被仓库删掉。别名 {@code issue}
     * 为草稿头, 参数 {@code :draftItemId} 为订货明细。任务详情据此决定给不给「撤回」。
     */
    public static final String DRAFT_EDITED_BY_WAREHOUSE = """
            (issue.updated_by IS DISTINCT FROM issue.created_by
             OR EXISTS (SELECT 1 FROM subcontract_material_issue_items edited_item
                        WHERE edited_item.issue_id = issue.id AND edited_item.order_item_id = :draftItemId
                          AND edited_item.plan_item_id IS NOT NULL
                          AND ((NOT edited_item.is_deleted
                                AND (edited_item.requested_qty IS NULL
                                     OR edited_item.qty <> edited_item.requested_qty))
                               OR edited_item.warehouse_dropped_at IS NOT NULL)))
            """;

    /**
     * 仓库整张退回一张领料草稿(本次不发): 不论仓库是否改过拣货数量, 释放这张草稿全部未消费占用
     * (专属批次由交接守卫退回原分析)、作废它的全部领料行与草稿头, 告诉提交领料的委外人员(含原因),
     * 再重算可领。只动这一张草稿; 撤回类操作都不写 warehouse_dropped_at。
     * 调用方须已按撤回领料的锁顺序预锁, 并锁住这张草稿头与相关计划行。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public WithdrawResult withdrawDraft(UUID issueId, String reason) {
        List<Object[]> lines = rows("""
                SELECT item.id, item.order_item_id, line.goods_id, line.color_id
                FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                 AND issue.status = 0 AND NOT issue.is_deleted
                JOIN subcontract_material_plan_items line ON line.id = item.plan_item_id
                WHERE item.issue_id = :issueId AND NOT item.is_deleted
                ORDER BY item.id
                """, Map.of("issueId", issueId));
        if (lines.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "这张领料已发出、已撤回或已退回，请刷新后查看");
        }
        UUID actorId = currentUser.requireId();
        List<Object[]> released = returning("""
                UPDATE stock_reservations
                SET released_qty = qty - consumed_qty, status = 1,
                    release_reason = 'SUBCONTRACT_DRAW_RETURNED_BY_WAREHOUSE',
                    lock_version = lock_version + 1, updated_at = now(), updated_by = :actorId
                WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                  AND source_doc_id = :issueId
                  AND status = 0 AND consumed_qty = 0 AND is_deleted = FALSE
                RETURNING goods_id, color_id
                """, Map.of("actorId", actorId, "issueId", issueId));
        em.createNativeQuery("""
                UPDATE subcontract_material_issue_items
                SET is_deleted = TRUE, updated_at = now(), updated_by = :actorId
                WHERE issue_id = :issueId AND NOT is_deleted
                """).setParameter("actorId", actorId).setParameter("issueId", issueId).executeUpdate();
        em.createNativeQuery("""
                UPDATE subcontract_material_issues
                SET is_deleted = TRUE, deleted_at = now(), updated_at = now(), updated_by = :actorId
                WHERE id = :issueId
                """).setParameter("actorId", actorId).setParameter("issueId", issueId).executeUpdate();
        chainNotice.notifySubcontractDrawReturned(issueId, reason);
        List<SubcontractOutboundWakePort.StockedDimension> dimensions = new ArrayList<>();
        released.forEach(row -> dimensions.add(
                new SubcontractOutboundWakePort.StockedDimension((UUID) row[0], (UUID) row[1], null)));
        lines.forEach(line -> dimensions.add(
                new SubcontractOutboundWakePort.StockedDimension((UUID) line[2], (UUID) line[3], null)));
        drawRecheck.enqueueDrawRecheck(dimensions);
        drawRecheck.enqueueDrawRecheckForOrderItems(lines.stream().map(line -> (UUID) line[1]).toList());
        return new WithdrawResult(List.of(issueId), lines.size());
    }

    /**
     * 结束领料(不再发外, ADR-143 §二.15): 撤回本明细未发领料并释放占用(仓库改过拣货数量的也一并撤回:
     * 结束领料就是不再发, 仓库的拣货修改已无意义, 仓库照常收到「已撤回」通知), 关闭本明细的领料计划行
     * (draw_closed_*), 按「料已发完」重评短交, 收回可领提醒。原因必填(&le; 200 字)。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void closeDrawForOrderItem(UUID orderItemId, String reason) {
        String normalized = reason == null ? "" : reason.strip();
        if (normalized.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "结束领料必须填写原因");
        }
        if (normalized.length() > 200) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "结束领料原因不能超过 200 个字");
        }
        withdrawPendingDraws(List.of(orderItemId), true);
        List<Object[]> lines = rows("""
                SELECT line.id, line.goods_id, line.color_id
                FROM subcontract_material_plan_items line
                JOIN subcontract_material_plans plan ON plan.id = line.plan_id
                 AND plan.status = 'OPEN' AND NOT plan.is_deleted
                WHERE line.order_item_id = :orderItemId AND NOT line.is_deleted
                  AND line.draw_closed_at IS NULL
                ORDER BY line.id
                FOR UPDATE OF line
                """, Map.of("orderItemId", orderItemId));
        if (lines.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "该委外明细的领料已结束或订货已撤销，请刷新后重试");
        }
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                UPDATE subcontract_material_plan_items
                SET draw_closed_at = now(), draw_closed_by = :actorId, draw_close_reason = :reason,
                    updated_at = now(), updated_by = :actorId
                WHERE id IN (:lineIds)
                """).setParameter("actorId", actorId).setParameter("reason", normalized)
                .setParameter("lineIds", lines.stream().map(line -> line[0]).toList())
                .executeUpdate();
        shortDelivery.ifAvailable(port -> port.settleAfterMaterialIssueClosed(List.of(orderItemId)));
        chainNotice.resolveSubcontractDrawAvailable(orderItemId);
        drawRecheck.enqueueDrawRecheck(lines.stream()
                .map(line -> new SubcontractOutboundWakePort.StockedDimension((UUID) line[1], (UUID) line[2], null))
                .toList());
    }

    /**
     * 回厂下限(订货单位): 委外商处还压着的料按每种物料折算套数取最大(不同物料并行, 不相加),
     * 再加已回厂下限。待发草稿与未消费占用是将来的安排, 不进这个下限(改量时另由计划量校验)。
     */
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public BigDecimal minimumOrderQtyFromIssued(UUID orderItemId, BigDecimal orderUnitRate) {
        List<Object[]> rows = jdbc.query("""
                SELECT item.goods_id, item.color_id,
                       SUM(GREATEST(item.at_supplier_qty + COALESCE(item.compensated_qty, 0)
                               - item.consumed_qty - COALESCE(item.returned_qty, 0)
                               - COALESCE(item.wasted_qty, 0), 0)
                           / NULLIF(item.frozen_unit_qty, 0)),
                       BOOL_OR(GREATEST(item.at_supplier_qty - COALESCE(item.returned_qty, 0), 0) > 0
                           AND COALESCE(item.frozen_unit_qty, 0) <= 0)
                FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                WHERE item.order_item_id = ? AND issue.status = 1 AND NOT issue.is_deleted
                  AND NOT item.is_deleted
                GROUP BY item.goods_id, item.color_id
                """, (rs, rowNum) -> new Object[]{rs.getObject(1), rs.getObject(2),
                        rs.getBigDecimal(3), rs.getBoolean(4)}, orderItemId);
        BigDecimal minimum = BigDecimal.ZERO;
        for (Object[] row : rows) {
            if (Boolean.TRUE.equals(row[3])) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外实发缺少冻结单耗，不能推算减量下限，请先核实原出仓来源");
            }
            minimum = minimum.max(decimal(row[2]));
        }
        return minimum.add(ProcurementOrderQuantityBounds.receipts(em, "SUBCONTRACT", orderItemId)
                .minimumOrderedQty(orderUnitRate)).setScale(SCALE, RoundingMode.CEILING);
    }

    /**
     * 批准后改量(与订货 changeQty 同事务, 订货明细已写成新数量): 每条冻结计划行按新订货量整体重算
     * {@code planned = f(新Q)}, 不做增量累加。已发外或「已发外 + 待仓库发」超过新计划量的拒绝并
     * 列出物料与待发领料单(先撤回); 不建、不删草稿。参数里的增量/换算率/货品仅用于确定改了哪些明细。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyOrderQtyChange(
            UUID orderId, Map<UUID, BigDecimal> baseDeltaByOrderItemId,
            Map<UUID, BigDecimal> unitRateByOrderItemId,
            Map<UUID, UUID> goodsColorByOrderItemId) {
        List<UUID> changed = baseDeltaByOrderItemId.entrySet().stream()
                .filter(entry -> entry.getValue() != null && entry.getValue().signum() != 0)
                .map(Map.Entry::getKey).filter(Objects::nonNull).distinct().sorted().toList();
        if (changed.isEmpty()) {
            return;
        }
        // 改量后调用方会重算订货结案, 这些明细可能因此结清或重新打开: 按明细重算可领(投递时才算)。
        drawRecheck.enqueueDrawRecheckForOrderItems(changed);
        List<Object[]> lines = rows("""
                SELECT line.id, line.order_item_id, oi.line_no, line.goods_id, line.color_id,
                       line.planned_qty, line.issued_qty,
                       fn_subcontract_draw_f(oi.qty, line.bom_unit_qty) AS new_planned,
                       COALESCE((
                           SELECT SUM(item.qty)
                           FROM subcontract_material_issue_items item
                           JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                            AND issue.status = 0 AND NOT issue.is_deleted
                           WHERE item.plan_item_id = line.id AND NOT item.is_deleted), 0) AS pending_qty,
                       material.code, material.name
                FROM subcontract_material_plan_items line
                JOIN subcontract_material_plans plan ON plan.id = line.plan_id
                 AND plan.order_id = :orderId AND plan.status = 'OPEN' AND NOT plan.is_deleted
                JOIN subcontract_order_items oi ON oi.id = line.order_item_id
                LEFT JOIN goods material ON material.id = line.goods_id
                WHERE line.order_item_id IN (:items) AND NOT line.is_deleted
                ORDER BY line.id
                FOR UPDATE OF line
                """, Map.of("orderId", orderId, "items", changed));
        if (lines.isEmpty()) {
            return;
        }
        List<String> problems = new ArrayList<>();
        for (Object[] line : lines) {
            BigDecimal issued = decimal(line[6]);
            BigDecimal newPlanned = decimal(line[7]);
            BigDecimal pending = decimal(line[8]);
            if (issued.add(pending).compareTo(newPlanned) > 0) {
                problems.add("第 " + line[2] + " 行物料 " + label(line[9], line[10]) + " 新需求 "
                        + plain(newPlanned) + "，已发外 " + plain(issued) + "，待仓库发 " + plain(pending));
            }
        }
        if (!problems.isEmpty()) {
            List<String> drafts = jdbc.queryForList("""
                    SELECT DISTINCT issue.bill_no
                    FROM subcontract_material_issues issue
                    JOIN subcontract_material_issue_items item ON item.issue_id = issue.id
                     AND NOT item.is_deleted AND item.plan_item_id IS NOT NULL
                    WHERE issue.status = 0 AND NOT issue.is_deleted
                      AND item.order_item_id = ANY(CAST(string_to_array(CAST(? AS text), ',') AS uuid[]))
                    ORDER BY issue.bill_no
                    """, String.class, String.join(",", changed.stream().map(UUID::toString).toList()));
            throw new ApiException(ErrorCode.CONFLICT, "新数量对应的物料需求低于已发外或待仓库发的量："
                    + String.join("；", problems)
                    + (drafts.isEmpty() ? "" : "；请先撤回待仓库发的领料(" + String.join("、", drafts) + ")")
                    + "后再改量");
        }
        UUID actorId = currentUser.requireId();
        List<SubcontractOutboundWakePort.StockedDimension> dimensions = new ArrayList<>();
        for (Object[] line : lines) {
            BigDecimal newPlanned = decimal(line[7]);
            if (newPlanned.compareTo(decimal(line[5])) == 0) {
                continue;
            }
            if (newPlanned.signum() == 0) {
                jdbc.update("""
                        UPDATE subcontract_material_plan_items
                        SET is_deleted = TRUE, deleted_at = now(), updated_at = now(), updated_by = ?
                        WHERE id = ?
                        """, actorId, line[0]);
            } else {
                jdbc.update("""
                        UPDATE subcontract_material_plan_items
                        SET planned_qty = ?, updated_at = now(), updated_by = ?
                        WHERE id = ?
                        """, newPlanned, actorId, line[0]);
            }
            dimensions.add(new SubcontractOutboundWakePort.StockedDimension((UUID) line[3], (UUID) line[4], null));
        }
        drawRecheck.enqueueDrawRecheck(dimensions);
    }

    /**
     * 订货红冲同事务(订货单已由调用方预锁): 撤回全部未发领料并释放占用, 领料计划置 CANCELED,
     * 收回可领提醒。已审出仓由订货侧守卫先行拦截。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void cancelForOrderReversal(UUID orderId) {
        List<UUID> items = jdbc.queryForList("""
                SELECT DISTINCT line.order_item_id
                FROM subcontract_material_plan_items line
                JOIN subcontract_material_plans plan ON plan.id = line.plan_id
                WHERE plan.order_id = ? AND plan.status = 'OPEN' AND NOT plan.is_deleted
                  AND NOT line.is_deleted
                ORDER BY line.order_item_id
                """, UUID.class, orderId);
        withdrawPendingDraws(items, true);
        List<UUID> planIds = jdbc.queryForList("""
                SELECT id FROM subcontract_material_plans
                WHERE order_id = ? AND status = 'OPEN' AND NOT is_deleted
                ORDER BY id FOR UPDATE
                """, UUID.class, orderId);
        if (planIds.isEmpty()) {
            return;
        }
        UUID actorId = currentUser.requireId();
        List<Object[]> released = returning("""
                UPDATE stock_reservations reservation
                SET released_qty = reservation.qty - reservation.consumed_qty,
                    status = 1, release_reason = 'SUBCONTRACT_ORDER_REVERSED',
                    lock_version = reservation.lock_version + 1,
                    updated_at = now(), updated_by = :actorId
                WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND reservation.status = 0 AND NOT reservation.is_deleted
                  AND reservation.owner_id IN (
                      SELECT line.id FROM subcontract_material_plan_items line
                      WHERE line.plan_id IN (:planIds))
                RETURNING reservation.goods_id, reservation.color_id
                """, Map.of("actorId", actorId, "planIds", planIds));
        em.createNativeQuery("""
                UPDATE subcontract_material_plans
                SET status = 'CANCELED', updated_at = now(), updated_by = :actorId
                WHERE id IN (:planIds)
                """).setParameter("actorId", actorId).setParameter("planIds", planIds).executeUpdate();
        items.forEach(chainNotice::resolveSubcontractDrawAvailable);
        List<SubcontractOutboundWakePort.StockedDimension> dimensions = new ArrayList<>();
        released.forEach(row -> dimensions.add(
                new SubcontractOutboundWakePort.StockedDimension((UUID) row[0], (UUID) row[1], null)));
        for (Object[] row : rows("""
                SELECT DISTINCT line.goods_id, line.color_id
                FROM subcontract_material_plan_items line
                WHERE line.plan_id IN (:planIds) AND NOT line.is_deleted
                """, Map.of("planIds", planIds))) {
            dimensions.add(new SubcontractOutboundWakePort.StockedDimension((UUID) row[0], (UUID) row[1], null));
        }
        drawRecheck.enqueueDrawRecheck(dimensions);
    }

    // ==================== 仓库委外出仓工作台(读) ====================

    /**
     * 待发料任务: 一行 = 一张委外人员已提交、仓库还没发出的领料草稿; 按调用者的仓库数据范围(ADR-149,
     * 由控制器 WarehouseTaskScopePort.current(scopeWarehouseId) 解析, 服务端强制)过滤草稿发出仓,
     * 关键字匹配出仓单号/订货单号/委外商。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public PageResponse<OutboundTaskListItem> tasks(int page, int size, String keyword,
                                                    WarehouseTaskScope warehouseScope) {
        int pageSize = Math.min(Math.max(size, 1), 200);
        int pageNo = Math.max(page, 1);
        boolean scoped = warehouseScope != null && warehouseScope.active();
        String pattern = keyword == null || keyword.isBlank() ? null : "%" + keyword.strip() + "%";
        String from = outboundTaskFrom(warehouseScope, pattern != null);
        Query count = em.createNativeQuery("SELECT COUNT(*) " + from);
        Query list = em.createNativeQuery("""
                SELECT issue.id, issue.bill_no, plan.id, plan.order_id, plan.order_bill_no, supplier.name,
                       issue.warehouse_id, warehouse.name, draft_lines.line_count, draft_lines.kind_count,
                       issue.created_at, creator_employee.full_name
                """ + from + "\n" + """
                ORDER BY issue.created_at ASC, issue.bill_no
                LIMIT :pageLimit OFFSET :pageOffset
                """);
        for (Query query : List.of(count, list)) {
            if (scoped) {
                query.setParameter("warehouseScope", warehouseScope.idsCsv());
            }
            if (pattern != null) {
                query.setParameter("keyword", pattern);
            }
        }
        list.setParameter("pageLimit", pageSize);
        list.setParameter("pageOffset", (pageNo - 1) * pageSize);
        long total = ((Number) count.getSingleResult()).longValue();
        List<OutboundTaskListItem> items = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(list)) {
            items.add(new OutboundTaskListItem((UUID) row[0], (String) row[1], (UUID) row[2], (UUID) row[3],
                    (String) row[4], (String) row[5], (UUID) row[6], (String) row[7],
                    ((Number) row[8]).intValue(), ((Number) row[9]).intValue(),
                    offsetDateTime(row[10]), (String) row[11]));
        }
        int totalPages = (int) Math.ceil((double) total / pageSize);
        return new PageResponse<>(items, pageNo, pageSize, total, totalPages);
    }

    /**
     * 委外出库红数: 待仓库发出的领料草稿张数。与待发料列表同一条 FROM / WHERE(同一仓库数据范围, 不带关键字),
     * 所以红数与列表总行数逐条相等; 工作台徽章汇总也按调用者本人的数据范围计数(ADR-149, 不选仓 = 本人全部
     * 可见范围), 与列表默认范围同一谓词。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public long countTasks(WarehouseTaskScope warehouseScope) {
        boolean scoped = warehouseScope != null && warehouseScope.active();
        Query count = em.createNativeQuery("SELECT COUNT(*) " + outboundTaskFrom(warehouseScope, false));
        if (scoped) {
            count.setParameter("warehouseScope", warehouseScope.idsCsv());
        }
        return ((Number) count.getSingleResult()).longValue();
    }

    /**
     * 待发料列表与红数共用的 FROM / WHERE: 只认绑定冻结计划行的领料草稿(status 0)。
     * 仓库范围占位 {@code :warehouseScope}, 关键字占位 {@code :keyword}(出仓单号/订货单号/委外商)。
     */
    private static String outboundTaskFrom(WarehouseTaskScope warehouseScope, boolean keyword) {
        StringBuilder where = new StringBuilder(" WHERE issue.status = 0 AND NOT issue.is_deleted ");
        if (warehouseScope != null && warehouseScope.active()) {
            where.append(" AND ").append(warehouseScope.predicate("issue.warehouse_id", ":warehouseScope"))
                    .append(' ');
        }
        if (keyword) {
            where.append(" AND (issue.bill_no ILIKE :keyword OR plan.order_bill_no ILIKE :keyword"
                    + " OR supplier.name ILIKE :keyword) ");
        }
        return """
                FROM subcontract_material_issues issue
                JOIN LATERAL (
                    SELECT COUNT(*) AS line_count,
                           COUNT(DISTINCT item.goods_id::text || ':' || COALESCE(item.color_id::text, '')) AS kind_count,
                           (array_agg(line.plan_id ORDER BY line.plan_id))[1] AS plan_id
                    FROM subcontract_material_issue_items item
                    JOIN subcontract_material_plan_items line ON line.id = item.plan_item_id
                    WHERE item.issue_id = issue.id AND NOT item.is_deleted
                ) draft_lines ON draft_lines.line_count > 0
                JOIN subcontract_material_plans plan ON plan.id = draft_lines.plan_id
                LEFT JOIN suppliers supplier ON supplier.id = issue.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id = issue.warehouse_id
                LEFT JOIN users creator ON creator.id = issue.created_by
                LEFT JOIN employees creator_employee ON creator_employee.id = creator.employee_id
                """ + where;
    }

    /** 拣货页: 草稿头 + 每行申请量/当前量/该仓可拣量/库位。只认待发的领料草稿。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public OutboundTaskDetail taskDetail(UUID issueId) {
        List<Object[]> head = rows("""
                SELECT issue.id, issue.bill_no, plan.id, plan.order_id, plan.order_bill_no, supplier.name,
                       issue.warehouse_id, warehouse.name, issue.xmin::text
                FROM subcontract_material_issues issue
                JOIN LATERAL (
                    SELECT (array_agg(line.plan_id ORDER BY line.plan_id))[1] AS plan_id
                    FROM subcontract_material_issue_items item
                    JOIN subcontract_material_plan_items line ON line.id = item.plan_item_id
                    WHERE item.issue_id = issue.id AND NOT item.is_deleted
                ) owner ON owner.plan_id IS NOT NULL
                JOIN subcontract_material_plans plan ON plan.id = owner.plan_id
                LEFT JOIN suppliers supplier ON supplier.id = issue.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id = issue.warehouse_id
                WHERE issue.id = :issueId AND issue.status = 0 AND NOT issue.is_deleted
                """, Map.of("issueId", issueId));
        if (head.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外领料出仓任务不存在或已处理");
        }
        Object[] h = head.getFirst();
        List<OutboundTaskLine> lines = new ArrayList<>();
        for (Object[] row : rows("""
                SELECT item.id, item.plan_item_id, item.line_no,
                       COALESCE(item.parent_goods_name_snapshot, parent.name),
                       COALESCE(item.parent_goods_code_snapshot, parent.code),
                       item.goods_id, COALESCE(item.goods_code_snapshot, material.code),
                       COALESCE(item.goods_name_snapshot, material.name),
                       color.name, unit.name, item.requested_qty, item.qty,
                       GREATEST(COALESCE(own.qty, 0) + GREATEST(COALESCE(available.available_qty, 0), 0), 0),
                       material.stock_place
                FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                LEFT JOIN goods material ON material.id = item.goods_id
                LEFT JOIN goods parent ON parent.id = item.parent_goods_id
                LEFT JOIN colors color ON color.id = item.color_id
                LEFT JOIN units unit ON unit.id = item.unit_id
                LEFT JOIN LATERAL (
                    SELECT SUM(reservation.qty - reservation.consumed_qty - reservation.released_qty) AS qty
                    FROM stock_reservations reservation
                    WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND reservation.owner_id = item.plan_item_id
                      AND reservation.source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                      AND reservation.source_doc_id = issue.id
                      AND reservation.status = 0 AND NOT reservation.is_deleted
                ) own ON TRUE
                LEFT JOIN v_stock_available available ON available.warehouse_id = issue.warehouse_id
                 AND available.goods_id = item.goods_id
                 AND available.color_id IS NOT DISTINCT FROM item.color_id
                WHERE item.issue_id = :issueId AND NOT item.is_deleted AND item.plan_item_id IS NOT NULL
                ORDER BY item.line_no ASC NULLS LAST, item.id
                """, Map.of("issueId", issueId))) {
            lines.add(new OutboundTaskLine((UUID) row[0], (UUID) row[1],
                    row[2] == null ? null : ((Number) row[2]).intValue(),
                    (String) row[3], (String) row[4], (UUID) row[5], (String) row[6], (String) row[7],
                    (String) row[8], (String) row[9], (BigDecimal) row[10], decimal(row[11]),
                    decimal(row[12]), (String) row[13]));
        }
        return new OutboundTaskDetail((UUID) h[0], (String) h[1], (UUID) h[2], (UUID) h[3], (String) h[4],
                (String) h[5], (UUID) h[6], (String) h[7], Long.parseLong(h[8].toString()), lines);
    }

    // ==================== 内部 ====================

    /** 本出仓单挂计划的行, 按计划行合计: [plan_item_id, qty, goods_id, color_id]。 */
    private List<Object[]> issueLines(UUID issueId) {
        return rows("""
                SELECT item.plan_item_id, SUM(item.qty), line.goods_id, line.color_id
                FROM subcontract_material_issue_items item
                JOIN subcontract_material_plan_items line ON line.id = item.plan_item_id
                WHERE item.issue_id = :issueId AND item.plan_item_id IS NOT NULL AND NOT item.is_deleted
                GROUP BY item.plan_item_id, line.goods_id, line.color_id
                ORDER BY item.plan_item_id
                """, Map.of("issueId", issueId));
    }

    /** 本退料单退回的、挂计划的出仓行, 按计划行合计: [plan_item_id, qty, goods_id, color_id]。 */
    private List<Object[]> returnLines(UUID returnId) {
        return rows("""
                SELECT issue_item.plan_item_id, SUM(return_item.qty), line.goods_id, line.color_id
                FROM subcontract_material_return_items return_item
                JOIN subcontract_material_issue_items issue_item ON issue_item.id = return_item.material_issue_item_id
                JOIN subcontract_material_plan_items line ON line.id = issue_item.plan_item_id
                WHERE return_item.material_return_id = :returnId AND NOT return_item.is_deleted
                GROUP BY issue_item.plan_item_id, line.goods_id, line.color_id
                ORDER BY issue_item.plan_item_id
                """, Map.of("returnId", returnId));
    }

    private static List<SubcontractOutboundWakePort.StockedDimension> dimensionsOf(List<Object[]> lines) {
        return lines.stream()
                .map(line -> new SubcontractOutboundWakePort.StockedDimension((UUID) line[2], (UUID) line[3], null))
                .toList();
    }

    private void enqueueReleased(List<Object[]> released) {
        if (released.isEmpty()) {
            return;
        }
        drawRecheck.enqueueDrawRecheck(released.stream()
                .map(row -> new SubcontractOutboundWakePort.StockedDimension((UUID) row[0], (UUID) row[1], null))
                .toList());
    }

    /** UPDATE ... RETURNING goods_id, color_id: 释放了哪些物料货色(给领料重算用)。 */
    private List<Object[]> returning(String sql, Map<String, ?> parameters) {
        return new NamedParameterJdbcTemplate(jdbc).query(sql, parameters,
                (rs, rowNum) -> new Object[]{rs.getObject(1, UUID.class), rs.getObject(2, UUID.class)});
    }

    private List<Object[]> rows(String sql, Map<String, ?> parameters) {
        Query query = em.createNativeQuery(sql);
        parameters.forEach(query::setParameter);
        return NativeQueryResults.objectArrayRows(query);
    }

    /** 「名称(编码)」, 缺失时退回空串, 不让文案里出现 null。 */
    private static String label(Object code, Object name) {
        String text = Objects.toString(name, "");
        String number = Objects.toString(code, "");
        return number.isEmpty() ? text : text + "(" + number + ")";
    }

    private static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        return value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime time) return time;
        if (value instanceof Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof java.sql.Timestamp timestamp) return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        if (value instanceof java.time.ZonedDateTime zoned) return zoned.toOffsetDateTime();
        if (value instanceof java.time.LocalDateTime local) return local.atOffset(ZoneOffset.UTC);
        return OffsetDateTime.parse(value.toString());
    }
}
