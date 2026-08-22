package com.uten.imp.features.subcontract.plan;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
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
import java.util.UUID;

/**
 * 委外发料计划服务（V304 · 委外全链路重设计）。
 *
 * <p>委外是「先出（材料）后进（成品）」：财务批准委外订货的同事务，按当时 BOM 展开生成
 * 发料计划快照（{@code subcontract_material_plans/items}）并自动生一张出仓单草稿；
 * 仓库在出仓工作台拣货、改量、审核；审核/红冲对称回写计划行 {@code issued_qty}；
 * 分批出仓时余量自动续生下一批草稿，直至出完或仓库手工「不再出仓」。
 *
 * <p>数量口径：{@code planned_qty = 订货明细量（父件单据单位） × bom_unit_qty（子件/父件）}，
 * 与 V221 守恒消费（回厂父件量 × frozen_unit_qty）同口径；BOM 取每个 父件+子件+颜色 的第一条
 * 活动边（与发料审核 {@code lookupFrozenUnitQty} 同源排序），排除 stub（auto_created）货品。
 */
@Service
@RequiredArgsConstructor
public class SubcontractMaterialPlanService {

    private static final short ISSUE_DRAFT = 0;

    private final EntityManager em;
    private final JdbcTemplate jdbc;
    private final DocNumberService docNumberService;
    private final SubcontractMaterialIssueRepository issueRepo;
    private final SubcontractMaterialIssueItemRepository issueItemRepo;
    private final SecurityContextCurrentUser currentUser;

    // ==================== 链路钩子（订货 Service 同事务调用） ====================

    /**
     * 财务批准同事务：按订货明细 BOM 一级子件展开建发料计划 + 自动生全量出仓草稿。
     * 订货货品无 BOM 子件时不建计划（委外商自备料，进度区显示「无需发料」）。
     * 调用方必须已持有订货单写锁（applyFinanceApproval 内 requireOrderForUpdate）。
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
                SELECT id, goods_id, color_id, qty, line_no
                FROM subcontract_order_items
                WHERE order_id = :orderId AND COALESCE(is_deleted, false) = false
                ORDER BY line_no ASC NULLS LAST, id
                """).setParameter("orderId", orderId).getResultList();
        if (items.isEmpty()) {
            return;
        }
        List<UUID> parentGoodsIds = items.stream()
                .map(row -> (UUID) row[1]).filter(Objects::nonNull).distinct().toList();
        // BOM 一级子件：每个 父件+子件+颜色 取第一条活动边（与发料审核冻结单耗同源排序）。
        List<Object[]> bomRows = parentGoodsIds.isEmpty() ? List.of() : em.createNativeQuery("""
                SELECT DISTINCT ON (bom.goods_id, bom.component_goods_id, bom.color_id)
                       bom.goods_id, bom.component_goods_id, bom.qty, bom.color_id
                FROM goods_bom_items bom
                JOIN goods child ON child.id = bom.component_goods_id
                 AND COALESCE(child.is_deleted, false) = false
                 AND COALESCE(child.auto_created, false) = false
                WHERE bom.goods_id IN (:parentIds)
                  AND COALESCE(bom.is_deleted, false) = false
                ORDER BY bom.goods_id, bom.component_goods_id, bom.color_id,
                         bom.sort_order ASC NULLS LAST, bom.id
                """).setParameter("parentIds", parentGoodsIds).getResultList();
        if (bomRows.isEmpty()) {
            return; // 无 BOM：委外商自备料
        }
        Map<UUID, List<Object[]>> bomByParent = new LinkedHashMap<>();
        for (Object[] row : bomRows) {
            bomByParent.computeIfAbsent((UUID) row[0], k -> new ArrayList<>()).add(row);
        }

        // 子件主档（单位/编码/名称/库位），供计划行单位与自动草稿快照。
        List<UUID> childGoodsIds = bomRows.stream()
                .map(row -> (UUID) row[1]).distinct().toList();
        Map<UUID, Object[]> goodsMaster = loadGoodsMaster(childGoodsIds);

        // 先算后插：全部计划行量 ≤ 0 时不建计划（视为无需发料）。
        record PendingLine(UUID orderItemId, UUID parentGoodsId, UUID parentColorId,
                           UUID childGoodsId, UUID childColorId, UUID unitId,
                           BigDecimal bomUnitQty, BigDecimal plannedQty) {
        }
        List<PendingLine> pendingLines = new ArrayList<>();
        for (Object[] item : items) {
            UUID orderItemId = (UUID) item[0];
            UUID parentGoodsId = (UUID) item[1];
            UUID parentColorId = (UUID) item[2];
            BigDecimal orderQty = decimal(item[3]);
            for (Object[] child : bomByParent.getOrDefault(parentGoodsId, List.of())) {
                UUID childGoodsId = (UUID) child[1];
                BigDecimal bomUnitQty = decimal(child[2]);
                BigDecimal planned = orderQty == null ? BigDecimal.ZERO
                        : orderQty.multiply(bomUnitQty).setScale(4, RoundingMode.HALF_UP);
                if (planned.signum() <= 0) {
                    continue;
                }
                Object[] master = goodsMaster.get(childGoodsId);
                pendingLines.add(new PendingLine(orderItemId, parentGoodsId, parentColorId,
                        childGoodsId, (UUID) child[3], master == null ? null : (UUID) master[3],
                        bomUnitQty, planned));
            }
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
                        created_by, updated_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 0, ?, ?)
                    """,
                    UUID.randomUUID(), planId, line.orderItemId(), lineNo++,
                    line.parentGoodsId(), line.parentColorId(),
                    line.childGoodsId(), line.childColorId(), line.unitId(),
                    line.bomUnitQty(), line.plannedQty(),
                    actorUser, actorUser);
        }
        createDraftForPlan(planId, orderBillNo, supplierId, deliverDate, actorUser);
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
        String status = jdbc.queryForObject("""
                SELECT status FROM subcontract_material_plans WHERE id = ?
                """, String.class, planId);
        if (!"OPEN".equals(status)) {
            throw new ApiException(ErrorCode.CONFLICT, "发料计划已关闭或取消，禁止继续出仓");
        }
        // 分批闭环：审核后仍有剩余且已无未审草稿 → 自动续生下一批。
        if (remainingLines(planId).stream().anyMatch(row -> decimal(row[8]).signum() > 0)
                && !hasPendingDraft(planId)) {
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
                SELECT plan_item_id, qty FROM subcontract_material_issue_items
                WHERE issue_id = :issueId AND plan_item_id IS NOT NULL
                """).setParameter("issueId", issueId).getResultList();
        for (Object[] line : lines) {
            BigDecimal qty = decimal(line[1]);
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET issued_qty = GREATEST(issued_qty - ?, 0), updated_at = now()
                    WHERE id = ? AND is_deleted = FALSE
                    """, qty, (UUID) line[0]);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "发料计划行已变化，请刷新后重试");
            }
        }
    }

    /** 订货红冲同事务：软删未审自动草稿 + 计划置 CANCELED（已审出仓由既有守卫先行拦截）。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void cancelForOrderReversal(UUID orderId) {
        List<UUID> planIds = jdbc.queryForList("""
                SELECT id FROM subcontract_material_plans
                WHERE order_id = ? AND is_deleted = FALSE AND status = 'OPEN'
                """, UUID.class, orderId);
        for (UUID planId : planIds) {
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
                           SUM(GREATEST(pi.planned_qty - pi.issued_qty, 0)) AS pending_total
                    FROM subcontract_material_plan_items pi
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
                WHERE p.is_deleted = FALSE AND p.status = 'OPEN' AND agg.pending_total > 0
                """ + kwClause;
        Object[] params = kw == null ? new Object[0] : new Object[]{kw, kw};
        Long total = jdbc.queryForObject("SELECT COUNT(*) " + base, Long.class, params);
        List<OutboundTaskListItem> content = jdbc.query("""
                SELECT p.id, p.order_id, p.order_bill_no, s.name, o.deliver_date,
                       agg.line_count, agg.planned_total, agg.issued_total, agg.pending_total,
                       draft.issue_id, draft.bill_no
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
                        rs.getString(11)),
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
                      AND pi.planned_qty - pi.issued_qty > 0)
                """, Long.class);
        return count == null ? 0 : count;
    }

    /** 计划详情：计划行（含库位/草稿占用/剩余）+ 该计划全部出仓单。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public OutboundTaskDetail taskDetail(UUID planId) {
        List<OutboundPlanLine> lines = jdbc.query("""
                SELECT pi.id, pi.order_item_id,
                       pi.parent_goods_id, pi.parent_color_id, pg.code, pg.name,
                       pi.goods_id, g.code, g.name, g.stock_place,
                       pi.color_id, c.name, pi.unit_id, u.name, pi.unit_rate, pi.bom_unit_qty,
                       pi.planned_qty, pi.issued_qty,
                       COALESCE((SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                                 JOIN subcontract_material_issues i ON i.id = ii.issue_id
                                 WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0)
                FROM subcontract_material_plan_items pi
                JOIN goods pg ON pg.id = pi.parent_goods_id
                JOIN goods g ON g.id = pi.goods_id
                LEFT JOIN colors c ON c.id = pi.color_id
                LEFT JOIN units u ON u.id = pi.unit_id
                WHERE pi.plan_id = ? AND pi.is_deleted = FALSE
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
                        rs.getBigDecimal(19)),
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
        if (hasPendingDraft(planId)) {
            throw new ApiException(ErrorCode.CONFLICT, "已存在未审核的出仓草稿，无需补齐");
        }
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
        return createDraftForPlan(planId, Objects.toString(head[0]), (UUID) head[1],
                toLocalDate(head[2]),
                currentUser.requireId());
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
        jdbc.update("""
                UPDATE subcontract_material_plans
                SET status = 'CLOSED', close_reason = ?, updated_at = now(), updated_by = ?
                WHERE id = ?
                """, reason.trim(), currentUser.requireId(), planId);
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

    /** 计划行剩余视图：列 8 = 剩余量（planned − issued − 未审草稿占用）。 */
    private List<Object[]> remainingLines(UUID planId) {
        return jdbc.query("""
                SELECT pi.id, pi.order_item_id, pi.parent_goods_id, pi.parent_color_id,
                       pi.goods_id, pi.unit_id, pi.bom_unit_qty, pi.planned_qty,
                       pi.planned_qty - pi.issued_qty - COALESCE((
                           SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                           JOIN subcontract_material_issues i ON i.id = ii.issue_id
                           WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0),
                       pi.color_id
                FROM subcontract_material_plan_items pi
                WHERE pi.plan_id = ? AND pi.is_deleted = FALSE
                ORDER BY pi.line_no ASC NULLS LAST, pi.id
                """,
                (rs, rowNum) -> new Object[]{
                        rs.getObject(1, UUID.class), rs.getObject(2, UUID.class),
                        rs.getObject(3, UUID.class), rs.getObject(4, UUID.class),
                        rs.getObject(5, UUID.class), rs.getObject(6, UUID.class),
                        rs.getBigDecimal(7), rs.getBigDecimal(8), rs.getBigDecimal(9),
                        rs.getObject(10, UUID.class)},
                planId);
    }

    /**
     * 按计划剩余量生成一张出仓草稿（调用方须持计划锁/在批准事务内）。
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
}
