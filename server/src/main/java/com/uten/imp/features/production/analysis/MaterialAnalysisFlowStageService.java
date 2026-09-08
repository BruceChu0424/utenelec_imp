package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 物料分析行级「流程阶段」批量推导（表格进度/待办列的唯一口径）。
 *
 * <p>每条分析物料行输出一个规范阶段键（如 {@code BUY_WAIT_IQC}），全站前端共用
 * 一份词表渲染；弹窗内的逐步时间线仍由
 * {@link MaterialAnalysisSupplyProgressService#supplyProgress} 提供，两者读同一批
 * 单据事实，本类只做“当前停在哪一步”的归并。判定链：
 * 采购 = 提交需求 → 下单 → 财务批准 → 仓库收货 → 品质验收 → 入库齐套；
 * 委外 = 提交申请 → 下单 → 财务批准 → 目标件准备/出仓 → 回厂 → IQC → 入库；
 * 自制 = 计划锚点的执行段状态（等待物料 → 等待领料 → 生产中 → 已完工）。
 * 入库齐套的权威口径（2026-09-06 修订）：需求仍在行内（required&gt;0）且缺口归零
 * = 现货/权益覆盖齐套；历史转出行的 required 与 shortage 可能一并归零，不能当作齐套。
 * 这些行必须逐订单明细核对真实收货、全部IQC及合格入库量，部分入库不等于整批完成。</p>
 */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisFlowStageService {

    // 采购链
    static final String BUY_PENDING_ISSUE = "BUY_PENDING_ISSUE";
    static final String BUY_REQUESTED = "BUY_REQUESTED";
    static final String BUY_PENDING_FINANCE = "BUY_PENDING_FINANCE";
    static final String BUY_WAIT_RECEIPT = "BUY_WAIT_RECEIPT";
    static final String BUY_WAIT_IQC = "BUY_WAIT_IQC";
    static final String BUY_WAIT_STOCK_IN = "BUY_WAIT_STOCK_IN";
    static final String BUY_STOCKED = "BUY_STOCKED";

    // 委外链
    static final String SC_PENDING_ISSUE = "SC_PENDING_ISSUE";
    static final String SC_REQUESTED = "SC_REQUESTED";
    static final String SC_PENDING_FINANCE = "SC_PENDING_FINANCE";
    static final String SC_WAIT_OUTBOUND = "SC_WAIT_OUTBOUND";
    static final String SC_WAIT_RETURN = "SC_WAIT_RETURN";
    static final String SC_WAIT_IQC = "SC_WAIT_IQC";
    static final String SC_WAIT_STOCK_IN = "SC_WAIT_STOCK_IN";
    static final String SC_STOCKED = "SC_STOCKED";

    // 自制链（锚点子件执行段）
    static final String MAKE_PENDING_ISSUE = "MAKE_PENDING_ISSUE";
    static final String MAKE_PLAN_SUBMITTED = "MAKE_PLAN_SUBMITTED";
    static final String MAKE_WAITING_MATERIAL = "MAKE_WAITING_MATERIAL";
    static final String MAKE_WAITING_DRAW = "MAKE_WAITING_DRAW";
    static final String MAKE_ZERO_READY = "MAKE_ZERO_READY";
    static final String MAKE_IN_PROGRESS = "MAKE_IN_PROGRESS";
    static final String MAKE_COMPLETED = "MAKE_COMPLETED";

    private final EntityManager em;

    /**
     * 推导一批物料行的流程阶段。
     *
     * @param analysisId         分析 id（链路查询按分析收敛，一次批量）
     * @param routeByLine        行 → 展示路线（已确认优先，回退建议）
     * @param shortageByLine     行 → shortage_qty（入库齐套权威）
     * @param requiredByLine     行 → required_qty
     * @param childStatusByLine  行 → 计划锚点子件的执行状态（可空）
     * @param childZeroByLine    行 → 子件执行段是否全部零料直制
     */
    @Transactional(readOnly = true)
    public Map<UUID, String> lineFlowStages(
            UUID analysisId,
            Map<UUID, String> routeByLine,
            Map<UUID, BigDecimal> shortageByLine,
            Map<UUID, BigDecimal> requiredByLine,
            Map<UUID, String> childStatusByLine,
            Map<UUID, Boolean> childZeroByLine) {
        ChainFacts facts = loadChainFacts(analysisId);
        Map<UUID, String> result = new LinkedHashMap<>();
        for (Map.Entry<UUID, String> routeEntry : routeByLine.entrySet()) {
            UUID lineId = routeEntry.getKey();
            String route = normalizeRoute(routeEntry.getValue());
            // 2026-09-06 锚点模型：需求转出后行 required=0 是常态——不能因此
            // 跳过（否则已下达行退化成「已转入生产计划」通用文案）。零需求且
            // 无行动的行会推导为 *_PENDING_ISSUE，客户端本就不把它当流程中。
            BigDecimal shortage = shortageByLine.getOrDefault(
                    lineId, BigDecimal.ZERO);
            BigDecimal required = requiredByLine.getOrDefault(
                    lineId, BigDecimal.ZERO);
            switch (route) {
                case "MAKE" -> result.put(lineId, makeStage(
                        childStatusByLine.get(lineId),
                        childZeroByLine.getOrDefault(lineId, Boolean.FALSE)));
                case "SUBCONTRACT" -> result.put(lineId, subcontractStage(
                        lineId, required, shortage, facts,
                        childStatusByLine.get(lineId),
                        childZeroByLine.getOrDefault(lineId, Boolean.FALSE)));
                default -> result.put(lineId,
                        purchaseStage(lineId, required, shortage, facts));
            }
        }
        return result;
    }

    private static String makeStage(String childStatus, boolean childZero) {
        if (childStatus == null || childStatus.isBlank()) {
            return MAKE_PENDING_ISSUE;
        }
        return switch (childStatus) {
            case "SUBMITTED" -> MAKE_PLAN_SUBMITTED;
            case "APPROVED", "WAITING" -> MAKE_WAITING_MATERIAL;
            case "READY" -> childZero ? MAKE_ZERO_READY : MAKE_WAITING_DRAW;
            case "DISPATCHED" -> MAKE_WAITING_DRAW;
            case "IN_PROGRESS" -> MAKE_IN_PROGRESS;
            case "COMPLETED" -> MAKE_COMPLETED;
            default -> MAKE_PENDING_ISSUE;
        };
    }

    private static String purchaseStage(
            UUID lineId, BigDecimal required, BigDecimal shortage, ChainFacts facts) {
        LineChain chain = facts.lines.get(lineId);
        if (chain == null || chain.purchaseExternalItems.isEmpty()) {
            return BUY_PENDING_ISSUE;
        }
        // 2026-09-06 修复「未下单却显示已入库」：整批下达会同时归零 required 与
        // shortage——那是需求转出，不是齐套。只有需求仍在行内（required>0）时
        // 缺口归零才是现货/权益覆盖的已入库；转出行必须沿链路逐步判定。
        if (required.signum() > 0 && shortage.signum() <= 0) {
            return BUY_STOCKED;
        }
        OrderView orders = facts.purchaseOrders(chain.purchaseExternalItems);
        if (orders.itemIds.isEmpty() || !orders.allOrdered) {
            return BUY_REQUESTED;
        }
        if (!orders.allApproved || facts.financePending(orders.orderIds, "PURCHASE")) {
            return BUY_PENDING_FINANCE;
        }
        List<UUID> approvedReceiptItems =
                facts.approvedPurchaseReceiptItems(orders.itemIds);
        if (approvedReceiptItems.isEmpty()) {
            return BUY_WAIT_RECEIPT;
        }
        IqcView iqc = facts.iqc("PURCHASE", approvedReceiptItems);
        if (iqc.total < approvedReceiptItems.size() || iqc.open > 0) {
            return BUY_WAIT_IQC;
        }
        // 全部不合格：原订单是唯一补货通道（V466，在途计入已退回不合格量），
        // 阶段回到等待补货到货，不能误报已入库。
        if (iqc.passed.signum() <= 0) {
            return BUY_WAIT_RECEIPT;
        }
        // 合格切片仍有未入库量时继续等待仓库，不因已有部分入库而完成整批。
        if (iqc.stocked.compareTo(iqc.passed) < 0) {
            return BUY_WAIT_STOCK_IN;
        }
        // Live shortage is authoritative; legacy zero-demand rows require complete order evidence.
        return shortage.signum() > 0 || !facts.fullyStocked(orders, "PURCHASE")
                ? BUY_WAIT_RECEIPT : BUY_STOCKED;
    }

    private static String subcontractStage(
            UUID lineId, BigDecimal required, BigDecimal shortage, ChainFacts facts,
            String childStatus, boolean childZero) {
        LineChain chain = facts.lines.get(lineId);
        boolean hasApplication = chain != null
                && !chain.subcontractExternalItems.isEmpty();
        if (!hasApplication) {
            // 无申请 = 尚未通知委外：有前置自制则先走车间，否则未下达。
            return childStatus == null || childStatus.isBlank()
                    ? SC_PENDING_ISSUE
                    : makeStage(childStatus, childZero);
        }
        // 与采购同口径（2026-09-06）：整批下达归零是转出不是齐套，转出行沿
        // 链路逐步判定；只有需求仍在行内时缺口归零才是覆盖齐套。
        if (required.signum() > 0 && shortage.signum() <= 0) {
            return SC_STOCKED;
        }
        OrderView orders = facts.subcontractOrders(chain.subcontractExternalItems);
        if (orders.itemIds.isEmpty() || !orders.allOrdered) {
            return SC_REQUESTED;
        }
        if (!orders.allApproved || facts.financePending(orders.orderIds, "SUBCONTRACT")) {
            return SC_PENDING_FINANCE;
        }
        if (!facts.subcontractOutboundComplete(orders.itemIds)) {
            return SC_WAIT_OUTBOUND;
        }
        List<UUID> approvedReceiptItems =
                facts.approvedSubcontractReceiptItems(orders.itemIds);
        if (approvedReceiptItems.isEmpty()) {
            return SC_WAIT_RETURN;
        }
        IqcView iqc = facts.iqc("SUBCONTRACT", approvedReceiptItems);
        if (iqc.total < approvedReceiptItems.size() || iqc.open > 0) {
            return SC_WAIT_IQC;
        }
        // 全部不合格：回厂补货通道，等待补货回厂（V466 同口径）。
        if (iqc.passed.signum() <= 0) {
            return SC_WAIT_RETURN;
        }
        if (iqc.stocked.compareTo(iqc.passed) < 0) {
            return SC_WAIT_STOCK_IN;
        }
        return shortage.signum() > 0 || !facts.fullyStocked(orders, "SUBCONTRACT")
                ? SC_WAIT_RETURN : SC_STOCKED;
    }

    private static String normalizeRoute(String raw) {
        String route = raw == null ? "" : raw.strip().toUpperCase(java.util.Locale.ROOT);
        return route.isEmpty() ? "BUY" : route;
    }

    // ============================ 批量事实装载 ============================

    private ChainFacts loadChainFacts(UUID analysisId) {
        // 行 → 供给行动（未取消），并按外部单据类型分采购/委外外部明细。
        Map<UUID, LineChain> lines = new LinkedHashMap<>();
        Map<UUID, String> actionType = new HashMap<>();
        Map<UUID, Set<UUID>> actionExternalItems = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT allocation.analysis_material_id, action.id,
                               action.external_document_type
                        FROM preplan_supply_action_allocations allocation
                        JOIN preplan_supply_actions action
                          ON action.id = allocation.action_id
                        WHERE action.analysis_id = :analysisId
                          AND action.status <> 'CANCELLED'
                        ORDER BY allocation.analysis_material_id, action.id
                        """).setParameter("analysisId", analysisId))) {
            UUID lineId = (UUID) row[0];
            UUID actionId = (UUID) row[1];
            String externalType = (String) row[2];
            LineChain chain = lines.computeIfAbsent(lineId, ignored -> new LineChain());
            actionType.put(actionId, externalType);
            chain.actions.add(actionId);
        }
        Set<UUID> actionIds = new LinkedHashSet<>(actionType.keySet());
        if (!actionIds.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                            SELECT action_id, external_item_id
                            FROM preplan_supply_action_allocations
                            WHERE action_id IN (:actionIds)
                              AND external_item_id IS NOT NULL
                            UNION
                            SELECT id, safety_external_item_id
                            FROM preplan_supply_actions
                            WHERE id IN (:actionIds)
                              AND safety_external_item_id IS NOT NULL
                            """).setParameter("actionIds", List.copyOf(actionIds)))) {
                actionExternalItems
                        .computeIfAbsent((UUID) row[0], ignored -> new LinkedHashSet<>())
                        .add((UUID) row[1]);
            }
        }
        for (Map.Entry<UUID, LineChain> entry : lines.entrySet()) {
            for (UUID actionId : entry.getValue().actions) {
                Set<UUID> items = actionExternalItems.getOrDefault(actionId, Set.of());
                String type = actionType.get(actionId);
                if ("SUBCONTRACT_APPLICATION".equals(type)) {
                    entry.getValue().subcontractExternalItems.addAll(items);
                } else if (type != null && type.startsWith("PURCHASE")) {
                    entry.getValue().purchaseExternalItems.addAll(items);
                }
            }
        }

        // 采购链：订货单 + 明细；财务审批案件；已审收货明细；IQC。
        Map<UUID, List<OrderRow>> purchaseOrderRows = new LinkedHashMap<>();
        Map<UUID, List<OrderRow>> subcontractOrderRows = new LinkedHashMap<>();
        Set<UUID> allPurchaseItems = new LinkedHashSet<>();
        Set<UUID> allSubcontractItems = new LinkedHashSet<>();
        for (Map.Entry<UUID, LineChain> entry : lines.entrySet()) {
            allPurchaseItems.addAll(entry.getValue().purchaseExternalItems);
            allSubcontractItems.addAll(entry.getValue().subcontractExternalItems);
        }
        collectOrders("purchase", allPurchaseItems, purchaseOrderRows);
        collectOrders("subcontract", allSubcontractItems, subcontractOrderRows);
        Set<UUID> allOrderIds = new LinkedHashSet<>();
        purchaseOrderRows.values().stream().flatMap(List::stream)
                .forEach(order -> allOrderIds.add(order.orderId));
        subcontractOrderRows.values().stream().flatMap(List::stream)
                .forEach(order -> allOrderIds.add(order.orderId));

        Map<UUID, List<String>> approvalStatusByOrder = new LinkedHashMap<>();
        if (!allOrderIds.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                            SELECT approval.order_id, approval.status
                            FROM procurement_order_approval_cases approval
                            WHERE approval.order_id IN (:orderIds)
                            """).setParameter("orderIds", List.copyOf(allOrderIds)))) {
                approvalStatusByOrder
                        .computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>())
                        .add((String) row[1]);
            }
        }

        Set<UUID> purchaseOrderItemIds = purchaseOrderRows.values().stream().flatMap(List::stream)
                .map(order -> order.orderItemId).collect(Collectors.toSet());
        Set<UUID> subcontractOrderItemIds = subcontractOrderRows.values().stream().flatMap(List::stream)
                .map(order -> order.orderItemId).collect(Collectors.toSet());
        Map<UUID, Set<UUID>> approvedPurchaseReceiptItems =
                approvedReceiptItems("purchase", purchaseOrderItemIds);
        Map<UUID, Set<UUID>> approvedSubcontractReceiptItems =
                approvedReceiptItems("subcontract", subcontractOrderItemIds);

        Map<UUID, IqcRow> iqcRows = new LinkedHashMap<>();
        Set<UUID> allReceiptItems = new LinkedHashSet<>();
        approvedPurchaseReceiptItems.values().forEach(allReceiptItems::addAll);
        approvedSubcontractReceiptItems.values().forEach(allReceiptItems::addAll);
        if (!allReceiptItems.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                            SELECT inspection.receipt_type, inspection.receipt_item_id,
                                   inspection.status, inspection.passed_base_qty,
                                   COALESCE(inspection.warehouse_stocked_base_qty, 0)
                            FROM procurement_inspection_items inspection
                            WHERE inspection.receipt_item_id IN (:receiptItemIds)
                            """).setParameter("receiptItemIds", List.copyOf(allReceiptItems)))) {
                iqcRows.put((UUID) row[1], new IqcRow(
                        (String) row[0], (String) row[2], decimal(row[3]), decimal(row[4])));
            }
        }

        // 委外准备/出仓：出仓完成 = 已出仓量覆盖计划量。
        Map<UUID, BigDecimal> outboundPlanned = new LinkedHashMap<>();
        Map<UUID, BigDecimal> outboundIssued = new LinkedHashMap<>();
        if (!subcontractOrderItemIds.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                            SELECT pi.order_item_id, pi.planned_qty, pi.issued_qty
                            FROM subcontract_material_plan_items pi
                            JOIN subcontract_material_plans p
                              ON p.id = pi.plan_id AND p.is_deleted = FALSE
                            WHERE pi.order_item_id IN (:orderItemIds)
                              AND pi.is_deleted = FALSE
                              AND pi.preparation_status <> 'CANCELLED'
                            """).setParameter("orderItemIds",
                    List.copyOf(subcontractOrderItemIds)))) {
                outboundPlanned.merge((UUID) row[0], decimal(row[1]), BigDecimal::add);
                outboundIssued.merge((UUID) row[0], decimal(row[2]), BigDecimal::add);
            }
        }
        return new ChainFacts(
                lines, purchaseOrderRows, subcontractOrderRows,
                approvalStatusByOrder,
                approvedPurchaseReceiptItems, approvedSubcontractReceiptItems,
                iqcRows, outboundPlanned, outboundIssued);
    }

    private void collectOrders(
            String kind, Set<UUID> externalItemIds, Map<UUID, List<OrderRow>> into) {
        if (externalItemIds.isEmpty()) {
            return;
        }
        boolean purchase = "purchase".equals(kind);
        // sources 表只有 order_item_id（无 order_id）——经订货明细联到订单头，
        // 与 MaterialAnalysisSupplyProgressService 单行版同一连接关系。
        String sql = """
                SELECT src.%s, ord.id, ord.status, src.order_item_id,
                       ROUND(COALESCE(item.qty, 0) * COALESCE(item.unit_rate, 1), 4)
                FROM %s src
                JOIN %s item
                  ON item.id = src.order_item_id
                 AND item.is_deleted = FALSE
                JOIN %s ord
                  ON ord.id = item.order_id
                WHERE src.%s IN (:externalItemIds)
                  AND ord.is_deleted = FALSE
                  AND ord.status <> -1
                """.formatted(
                purchase ? "request_item_id" : "application_item_id",
                purchase ? "purchase_order_item_sources" : "subcontract_order_item_sources",
                purchase ? "purchase_order_items" : "subcontract_order_items",
                purchase ? "purchase_orders" : "subcontract_orders",
                purchase ? "request_item_id" : "application_item_id");
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery(sql)
                .setParameter("externalItemIds", List.copyOf(externalItemIds)))) {
            UUID externalItemId = (UUID) row[0];
            into.computeIfAbsent(externalItemId, ignored -> new ArrayList<>()).add(new OrderRow(
                    (UUID) row[1], ((Number) row[2]).intValue(), (UUID) row[3], decimal(row[4])));
        }
    }

    private Map<UUID, Set<UUID>> approvedReceiptItems(String kind, Set<UUID> orderItemIds) {
        if (orderItemIds.isEmpty()) {
            return Map.of();
        }
        boolean purchase = "purchase".equals(kind);
        String sql = """
                SELECT receipt_item.order_item_id, receipt_item.id
                FROM %s receipt_item
                JOIN %s receipt ON receipt.id = receipt_item.receipt_id
                WHERE receipt_item.order_item_id IN (:orderItemIds)
                  AND receipt_item.is_deleted = FALSE
                  AND receipt.is_deleted = FALSE
                  AND receipt.status = 1
                """.formatted(
                purchase ? "purchase_receipt_items" : "subcontract_receipt_items",
                purchase ? "purchase_receipts" : "subcontract_receipts");
        Map<UUID, Set<UUID>> byOrderItem = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(
                em.createNativeQuery(sql)
                        .setParameter("orderItemIds", List.copyOf(orderItemIds)))) {
            byOrderItem.computeIfAbsent((UUID) row[0], ignored -> new LinkedHashSet<>()).add((UUID) row[1]);
        }
        return byOrderItem;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    // ============================ 事实结构 ============================

    private static final class LineChain {
        final List<UUID> actions = new ArrayList<>();
        final Set<UUID> purchaseExternalItems = new LinkedHashSet<>();
        final Set<UUID> subcontractExternalItems = new LinkedHashSet<>();
    }

    private record OrderRow(UUID orderId, int status, UUID orderItemId, BigDecimal requiredBaseQty) {
    }

    private record IqcRow(
            String receiptType, String status, BigDecimal passedBaseQty,
            BigDecimal stockedBaseQty) {
    }

    private record OrderView(Set<UUID> orderIds, Set<UUID> itemIds, boolean allApproved,
                             boolean allOrdered, Map<UUID, BigDecimal> requiredByOrderItem) {
    }

    private record IqcView(long total, long open, BigDecimal passed, BigDecimal stocked) {
    }

    private static final class ChainFacts {
        final Map<UUID, LineChain> lines;
        final Map<UUID, List<OrderRow>> purchaseOrderRows;
        final Map<UUID, List<OrderRow>> subcontractOrderRows;
        final Map<UUID, List<String>> approvalStatusByOrder;
        final Map<UUID, Set<UUID>> approvedPurchaseReceiptItems;
        final Map<UUID, Set<UUID>> approvedSubcontractReceiptItems;
        final Map<UUID, IqcRow> iqcRows;
        final Map<UUID, BigDecimal> outboundPlanned;
        final Map<UUID, BigDecimal> outboundIssued;

        private ChainFacts(
                Map<UUID, LineChain> lines,
                Map<UUID, List<OrderRow>> purchaseOrderRows,
                Map<UUID, List<OrderRow>> subcontractOrderRows,
                Map<UUID, List<String>> approvalStatusByOrder,
                Map<UUID, Set<UUID>> approvedPurchaseReceiptItems,
                Map<UUID, Set<UUID>> approvedSubcontractReceiptItems,
                Map<UUID, IqcRow> iqcRows,
                Map<UUID, BigDecimal> outboundPlanned,
                Map<UUID, BigDecimal> outboundIssued) {
            this.lines = lines;
            this.purchaseOrderRows = purchaseOrderRows;
            this.subcontractOrderRows = subcontractOrderRows;
            this.approvalStatusByOrder = approvalStatusByOrder;
            this.approvedPurchaseReceiptItems = approvedPurchaseReceiptItems;
            this.approvedSubcontractReceiptItems = approvedSubcontractReceiptItems;
            this.iqcRows = iqcRows;
            this.outboundPlanned = outboundPlanned;
            this.outboundIssued = outboundIssued;
        }

        OrderView purchaseOrders(Set<UUID> externalItems) {
            return orders(purchaseOrderRows, externalItems);
        }

        OrderView subcontractOrders(Set<UUID> externalItems) {
            return orders(subcontractOrderRows, externalItems);
        }

        private static OrderView orders(
                Map<UUID, List<OrderRow>> rows, Set<UUID> externalItems) {
            Set<UUID> orderIds = new LinkedHashSet<>();
            Set<UUID> itemIds = new LinkedHashSet<>();
            boolean allApproved = true;
            boolean allOrdered = true;
            Map<UUID, BigDecimal> requiredByOrderItem = new LinkedHashMap<>();
            for (UUID externalItem : externalItems) {
                List<OrderRow> sourceOrders = rows.getOrDefault(externalItem, List.of());
                if (sourceOrders.isEmpty()) allOrdered = false;
                for (OrderRow row : sourceOrders) {
                    orderIds.add(row.orderId());
                    itemIds.add(row.orderItemId());
                    requiredByOrderItem.put(row.orderItemId(), row.requiredBaseQty());
                    if (row.status() != 1) allApproved = false;
                }
            }
            return new OrderView(orderIds, itemIds, allApproved, allOrdered, requiredByOrderItem);
        }

        boolean financePending(Set<UUID> orderIds, String orderType) {
            for (UUID orderId : orderIds) {
                for (String status : approvalStatusByOrder.getOrDefault(
                        orderId, List.of())) {
                    if ("PENDING".equals(status)) {
                        return true;
                    }
                }
            }
            return false;
        }

        List<UUID> approvedPurchaseReceiptItems(Set<UUID> orderItemIds) {
            return orderItemIds.stream()
                    .flatMap(id -> approvedPurchaseReceiptItems.getOrDefault(id, Set.of()).stream())
                    .distinct()
                    .collect(Collectors.toList());
        }

        List<UUID> approvedSubcontractReceiptItems(Set<UUID> orderItemIds) {
            return orderItemIds.stream()
                    .flatMap(id -> approvedSubcontractReceiptItems.getOrDefault(id, Set.of()).stream())
                    .distinct()
                    .collect(Collectors.toList());
        }

        /** Transferred legacy demand needs receipt evidence for every order item. */
        boolean fullyStocked(OrderView orders, String receiptType) {
            Map<UUID, Set<UUID>> receipts = "PURCHASE".equals(receiptType)
                    ? approvedPurchaseReceiptItems : approvedSubcontractReceiptItems;
            for (UUID orderItem : orders.itemIds) {
                List<UUID> items = List.copyOf(receipts.getOrDefault(orderItem, Set.of()));
                IqcView evidence = iqc(receiptType, items);
                if (items.isEmpty() || evidence.total < items.size() || evidence.open > 0
                        || evidence.passed.signum() <= 0
                        || evidence.stocked.compareTo(evidence.passed) < 0
                        || evidence.stocked.compareTo(orders.requiredByOrderItem.get(orderItem)) < 0) {
                    return false;
                }
            }
            return !orders.itemIds.isEmpty();
        }

        IqcView iqc(String receiptType, List<UUID> receiptItems) {
            long total = 0;
            long open = 0;
            BigDecimal passed = BigDecimal.ZERO;
            BigDecimal stocked = BigDecimal.ZERO;
            for (UUID receiptItem : receiptItems) {
                IqcRow row = iqcRows.get(receiptItem);
                if (row == null || !receiptType.equals(row.receiptType())) {
                    continue;
                }
                total++;
                if ("PENDING".equals(row.status()) || "PARTIAL".equals(row.status())) {
                    open++;
                }
                passed = passed.add(row.passedBaseQty());
                stocked = stocked.add(row.stockedBaseQty());
            }
            return new IqcView(total, open, passed, stocked);
        }

        boolean subcontractOutboundComplete(Set<UUID> orderItemIds) {
            BigDecimal planned = BigDecimal.ZERO;
            BigDecimal issued = BigDecimal.ZERO;
            boolean anyPlan = false;
            for (UUID orderItem : orderItemIds) {
                BigDecimal itemPlanned = outboundPlanned.getOrDefault(
                        orderItem, BigDecimal.ZERO);
                if (itemPlanned.signum() > 0) {
                    anyPlan = true;
                }
                planned = planned.add(itemPlanned);
                issued = issued.add(outboundIssued.getOrDefault(
                        orderItem, BigDecimal.ZERO));
            }
            return anyPlan && planned.signum() > 0
                    && issued.compareTo(planned) >= 0;
        }
    }
}
