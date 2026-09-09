package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanInboundAllocationReadPort;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Database-backed, amount-free warehouse projection of preplan material purpose. */
@Service
@RequiredArgsConstructor
public class PreplanInboundAllocationProjectionService
        implements PreplanInboundAllocationReadPort {

    private final EntityManager em;
    private final com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScope;

    @Override
    @Transactional(readOnly = true)
    public Map<UUID, List<AllocationView>> expectedForPassEvents(
            String rawReceiptType,
            UUID receiptId,
            Collection<UUID> rawPassEventIds) {
        String receiptType = normalizeReceiptType(rawReceiptType);
        List<UUID> passEventIds = ids(rawPassEventIds);
        if (receiptId == null || passEventIds.isEmpty()) return Map.of();

        List<Slice> slices = expectedSlices(receiptType, receiptId, passEventIds);
        if (slices.isEmpty()) return Map.of();
        List<SourceAnchor> anchors = sourceAnchors(
                receiptType,
                slices.stream().map(Slice::receiptItemId).distinct().toList());
        Set<UUID> externalItemIds = anchors.stream()
                .map(SourceAnchor::externalItemId).filter(Objects::nonNull)
                .collect(LinkedHashSet::new, Set::add, Set::addAll);
        Set<UUID> orderItemIds = anchors.stream()
                .map(SourceAnchor::orderItemId).filter(Objects::nonNull)
                .collect(LinkedHashSet::new, Set::add, Set::addAll);
        Map<UUID, List<PreplanCandidate>> preplan = preplanCandidates(externalItemIds);
        Map<UUID, List<FormalCandidate>> formal = formalCandidates(
                receiptType, orderItemIds);

        Map<UUID, BigDecimal> preplanHeadroom = new HashMap<>();
        preplan.values().forEach(values -> values.forEach(value ->
                preplanHeadroom.put(value.allocationId(), value.headroom())));
        Map<UUID, BigDecimal> formalHeadroom = new HashMap<>();
        formal.values().forEach(values -> values.forEach(value ->
                formalHeadroom.put(value.pegId(), value.headroom())));
        Map<UUID, List<SourceAnchor>> anchorsByReceipt = new LinkedHashMap<>();
        anchors.forEach(anchor -> anchorsByReceipt.computeIfAbsent(
                anchor.receiptItemId(), ignored -> new ArrayList<>()).add(anchor));
        // Source capacity belongs to an order-item/source/mode, not a PASS event
        // or receipt row. Repeated anchors must reuse it rather than add capacity.
        Map<SourceBudgetKey, BigDecimal> sourceBudgets = new HashMap<>();
        for (SourceAnchor anchor : anchors) {
            sourceBudgets.merge(new SourceBudgetKey(anchor.orderItemId(), anchor.externalItemId(), false),
                    anchor.exactRemainingQty().max(BigDecimal.ZERO), BigDecimal::min);
            sourceBudgets.merge(new SourceBudgetKey(anchor.orderItemId(), anchor.externalItemId(), true),
                    anchor.sharedRemainingQty().max(BigDecimal.ZERO), BigDecimal::min);
        }

        Map<UUID, List<AllocationView>> result = new LinkedHashMap<>();
        for (Slice slice : slices) {
            BigDecimal remaining = slice.remainingQty();
            List<AllocationView> views = new ArrayList<>();
            boolean mismatchedReservationIntent = false;
            Set<String> mismatchedIntendedWarehouses = new LinkedHashSet<>();
            for (SourceAnchor anchor : anchorsByReceipt.getOrDefault(
                    slice.receiptItemId(), List.of())) {
                for (PreplanCandidate candidate : anchor.externalItemId() == null
                        ? List.<PreplanCandidate>of()
                        : preplan.getOrDefault(anchor.externalItemId(), List.of())) {
                    // The exact request/allocation identity determines the beneficiary.
                    // The eventual stock-in warehouse is its physical location, not a new owner.
                    if (!slice.matches(candidate.goodsId(), candidate.colorId())) continue;
                    BigDecimal headroom = preplanHeadroom.getOrDefault(
                            candidate.allocationId(), BigDecimal.ZERO);
                    boolean shared = "SHARED_FUTURE_CLAIM".equals(
                            candidate.operationType());
                    SourceBudgetKey budgetKey = new SourceBudgetKey(
                            anchor.orderItemId(), anchor.externalItemId(), shared);
                    BigDecimal budget = sourceBudgets.getOrDefault(budgetKey, BigDecimal.ZERO);
                    BigDecimal take = remaining.min(headroom).min(budget)
                            .max(BigDecimal.ZERO);
                    if (take.signum() <= 0) continue;
                    views.add(candidate.toView(
                            slice.passEventId(), take,
                            slice.warehouseId(), slice.warehouseName(), true));
                    preplanHeadroom.put(candidate.allocationId(), headroom.subtract(take));
                    sourceBudgets.put(budgetKey, budget.subtract(take));
                    remaining = remaining.subtract(take);
                    if (remaining.signum() <= 0) break;
                }
                if (remaining.signum() <= 0) break;
            }
            // 无订单锚点的 PASS 切片（如直接送检）orderItemId 为 null，
            // 不可变分组 Map 不接受 null 键查询。
            if (remaining.signum() > 0 && slice.orderItemId() != null) {
                for (FormalCandidate candidate : formal.getOrDefault(
                        slice.orderItemId(), List.of())) {
                    boolean warehouseMatches = slice.warehouseId().equals(
                            candidate.targetWarehouseId());
                    if (!warehouseMatches) {
                        mismatchedReservationIntent |= candidate.headroom().signum() > 0;
                        if (candidate.headroom().signum() > 0
                                && candidate.targetWarehouseName() != null) {
                            mismatchedIntendedWarehouses.add(
                                    candidate.targetWarehouseName());
                        }
                        continue;
                    }
                    if (!slice.matches(candidate.goodsId(), candidate.colorId())) continue;
                    BigDecimal headroom = formalHeadroom.getOrDefault(
                            candidate.pegId(), BigDecimal.ZERO);
                    BigDecimal take = remaining.min(headroom).max(BigDecimal.ZERO);
                    if (take.signum() <= 0) continue;
                    views.add(candidate.toView(
                            slice.passEventId(), take,
                            slice.warehouseId(), slice.warehouseName()));
                    formalHeadroom.put(candidate.pegId(), headroom.subtract(take));
                    remaining = remaining.subtract(take);
                    if (remaining.signum() <= 0) break;
                }
            }
            if (remaining.signum() > 0) {
                views.add(publicView(
                        slice.passEventId(), null, remaining,
                        slice.warehouseId(), slice.warehouseName(),
                        List.copyOf(mismatchedIntendedWarehouses),
                        !mismatchedReservationIntent,
                        mismatchedReservationIntent
                                ? "来源预定主仓与本次入库仓不一致；本数量不会跨仓绑定，按实际仓公共入库"
                                : "未被生产需求预定，按实际仓公共入库"));
            }
            result.put(slice.passEventId(), List.copyOf(views));
        }
        return Map.copyOf(result);
    }

    @Override
    @Transactional(readOnly = true)
    public Map<UUID, List<AllocationView>> expectedForOrderItems(
            String rawOrderType,
            Collection<OrderItemQuantity> rawOrderItems) {
        String orderType = normalizeReceiptType(rawOrderType);
        List<OrderItemQuantity> orderItems = rawOrderItems == null
                ? List.of()
                : rawOrderItems.stream()
                        .filter(Objects::nonNull)
                        .filter(value -> value.orderItemId() != null
                                && value.receivableBaseQty() != null
                                && value.receivableBaseQty().signum() > 0)
                        .sorted(Comparator.comparing(OrderItemQuantity::orderItemId))
                        .toList();
        if (orderItems.isEmpty()) return Map.of();
        List<SourceAnchor> anchors = orderSourceAnchors(
                orderType,
                orderItems.stream().map(OrderItemQuantity::orderItemId).toList());
        Set<UUID> externalItemIds = anchors.stream()
                .map(SourceAnchor::externalItemId).filter(Objects::nonNull)
                .collect(LinkedHashSet::new, Set::add, Set::addAll);
        Set<UUID> orderItemIds = orderItems.stream()
                .map(OrderItemQuantity::orderItemId)
                .collect(LinkedHashSet::new, Set::add, Set::addAll);
        Map<UUID, List<PreplanCandidate>> preplan = preplanCandidates(externalItemIds);
        Map<UUID, List<FormalCandidate>> formal = formalCandidates(
                orderType, orderItemIds);
        Map<UUID, BigDecimal> preplanHeadroom = new HashMap<>();
        preplan.values().forEach(values -> values.forEach(value ->
                preplanHeadroom.put(value.allocationId(), value.headroom())));
        Map<UUID, BigDecimal> formalHeadroom = new HashMap<>();
        formal.values().forEach(values -> values.forEach(value ->
                formalHeadroom.put(value.pegId(), value.headroom())));
        Map<UUID, List<SourceAnchor>> anchorsByOrder = new LinkedHashMap<>();
        anchors.forEach(anchor -> anchorsByOrder.computeIfAbsent(
                anchor.orderItemId(), ignored -> new ArrayList<>()).add(anchor));

        Map<UUID, List<AllocationView>> result = new LinkedHashMap<>();
        for (OrderItemQuantity orderItem : orderItems) {
            BigDecimal remaining = orderItem.receivableBaseQty();
            List<AllocationView> views = new ArrayList<>();
            Set<String> intendedWarehouses = new LinkedHashSet<>();
            for (SourceAnchor anchor : anchorsByOrder.getOrDefault(
                    orderItem.orderItemId(), List.of())) {
                BigDecimal exactBudget = anchor.exactRemainingQty();
                BigDecimal sharedBudget = anchor.sharedRemainingQty();
                for (PreplanCandidate candidate : anchor.externalItemId() == null
                        ? List.<PreplanCandidate>of()
                        : preplan.getOrDefault(anchor.externalItemId(), List.of())) {
                    BigDecimal headroom = preplanHeadroom.getOrDefault(
                            candidate.allocationId(), BigDecimal.ZERO);
                    boolean shared = "SHARED_FUTURE_CLAIM".equals(
                            candidate.operationType());
                    BigDecimal budget = shared ? sharedBudget : exactBudget;
                    BigDecimal take = remaining.min(headroom).min(budget)
                            .max(BigDecimal.ZERO);
                    if (take.signum() <= 0) continue;
                    if (candidate.targetWarehouseName() != null) {
                        intendedWarehouses.add(candidate.targetWarehouseName());
                    }
                    views.add(candidate.toView(null, take, null, null, false));
                    preplanHeadroom.put(candidate.allocationId(), headroom.subtract(take));
                    if (shared) {
                        sharedBudget = sharedBudget.subtract(take);
                    } else {
                        exactBudget = exactBudget.subtract(take);
                    }
                    remaining = remaining.subtract(take);
                    if (remaining.signum() <= 0) break;
                }
                if (remaining.signum() <= 0) break;
            }
            if (remaining.signum() > 0) {
                for (FormalCandidate candidate : formal.getOrDefault(
                        orderItem.orderItemId(), List.of())) {
                    BigDecimal headroom = formalHeadroom.getOrDefault(
                            candidate.pegId(), BigDecimal.ZERO);
                    BigDecimal take = remaining.min(headroom).max(BigDecimal.ZERO);
                    if (take.signum() <= 0) continue;
                    if (candidate.targetWarehouseName() != null) {
                        intendedWarehouses.add(candidate.targetWarehouseName());
                    }
                    views.add(candidate.toView(null, take, null, null));
                    formalHeadroom.put(candidate.pegId(), headroom.subtract(take));
                    remaining = remaining.subtract(take);
                    if (remaining.signum() <= 0) break;
                }
            }
            if (remaining.signum() > 0) {
                views.add(publicView(
                        null,null,remaining,null,null,
                        List.copyOf(intendedWarehouses),false,
                        intendedWarehouses.isEmpty()
                                ? "未被生产需求预定；登记时选择任一有效仓后按公共库存处理"
                                : "选择实际入库仓后校验；与预定主仓不一致的数量将按实际仓公共入库"));
            }
            result.put(orderItem.orderItemId(), List.copyOf(views));
        }
        return Map.copyOf(result);
    }

    @Override
    @Transactional(readOnly = true)
    public List<AllocationView> actualForBatches(
            Collection<UUID> rawStockInBatchIds) {
        List<UUID> stockInBatchIds = ids(rawStockInBatchIds);
        if (stockInBatchIds.isEmpty()) return List.of();
        List<ActualSlice> slices = actualSlices(stockInBatchIds);
        if (slices.isEmpty()) return List.of();
        List<UUID> itemIds = slices.stream().map(ActualSlice::batchItemId).toList();
        List<AllocationView> result = new ArrayList<>();
        result.addAll(actualBeneficiaryBalances(itemIds));
        result.addAll(actualFormalizedEntitlements(itemIds));
        Map<UUID, BigDecimal> attributed = new HashMap<>();
        result.forEach(value -> attributed.merge(
                value.stockInBatchItemId(), value.qty(), BigDecimal::add));
        List<AllocationView> directFormal = actualDirectFormal(
                stockInBatchIds, slices, attributed);
        result.addAll(directFormal);
        Map<UUID, List<String>> intendedByItem = intendedWarehouses(slices);
        Map<UUID, BigDecimal> directAttributed = new HashMap<>();
        directFormal.forEach(value -> directAttributed.merge(
                value.stockInBatchItemId(), value.qty(), BigDecimal::add));
        for (ActualSlice slice : slices) {
            BigDecimal publicQty = slice.baseQty().subtract(
                    attributed.getOrDefault(slice.batchItemId(), BigDecimal.ZERO))
                    .subtract(directAttributed.getOrDefault(
                            slice.batchItemId(), BigDecimal.ZERO))
                    .max(BigDecimal.ZERO);
            if (publicQty.signum() > 0) {
                List<String> intended = intendedByItem.getOrDefault(
                        slice.batchItemId(), List.of());
                result.add(publicView(
                        slice.passEventId(), slice.batchItemId(), publicQty,
                        slice.warehouseId(), slice.warehouseName(), intended,
                        intended.isEmpty(),
                        intended.isEmpty()
                                ? "当前未形成生产预留，已进入公共库存"
                                : "实际入库仓与预定主仓不一致，未跨仓绑定，已进入实际仓公共库存"));
            }
        }
        Map<UUID, BigDecimal> projectedByItem = new HashMap<>();
        result.forEach(value -> projectedByItem.merge(
                value.stockInBatchItemId(), value.qty(), BigDecimal::add));
        for (ActualSlice slice : slices) {
            if (projectedByItem.getOrDefault(
                    slice.batchItemId(), BigDecimal.ZERO)
                    .compareTo(slice.baseQty()) != 0) {
                throw new IllegalStateException(
                        "warehouse stock-in allocation projection is not conserved");
            }
        }
        result.sort(Comparator
                .comparing((AllocationView value) ->
                        value.stockInBatchItemId().toString())
                .thenComparing(AllocationView::kind)
                .thenComparing(value -> Objects.toString(value.analysisId(), "")));
        return List.copyOf(result);
    }

    private List<Slice> expectedSlices(
            String receiptType, UUID receiptId, List<UUID> passEventIds) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT event.id,inspection.receipt_item_id,
                       inspection.warehouse_id,warehouse.name,
                       inspection.goods_id,inspection.color_id,
                       event.base_qty-COALESCE(stocked.qty,0),
                       CASE WHEN inspection.receipt_type='PURCHASE'
                            THEN purchase_item.order_item_id
                            ELSE subcontract_item.order_item_id END
                FROM procurement_inspection_events event
                JOIN procurement_inspection_items inspection
                  ON inspection.id=event.inspection_item_id
                LEFT JOIN warehouses warehouse ON warehouse.id=inspection.warehouse_id
                LEFT JOIN purchase_receipt_items purchase_item
                  ON inspection.receipt_type='PURCHASE'
                 AND purchase_item.id=inspection.receipt_item_id
                LEFT JOIN subcontract_receipt_items subcontract_item
                  ON inspection.receipt_type='SUBCONTRACT'
                 AND subcontract_item.id=inspection.receipt_item_id
                LEFT JOIN LATERAL (
                    SELECT SUM(item.base_qty) AS qty
                    FROM procurement_iqc_stock_in_batch_items item
                    WHERE item.pass_event_id=event.id
                ) stocked ON TRUE
                WHERE event.id IN (:eventIds)
                  AND event.action='PASS'
                  AND event.requires_warehouse_stock_in=TRUE
                  AND inspection.receipt_type=:receiptType
                  AND inspection.receipt_id=:receiptId
                  AND inspection.status <> 'REVERSED'
                  AND event.base_qty-COALESCE(stocked.qty,0) > 0
                ORDER BY event.occurred_at,event.id
                """).setParameter("eventIds", passEventIds)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)).stream()
                .map(row -> new Slice(
                        uuid(row[0]),uuid(row[1]),uuid(row[2]),string(row[3]),
                        uuid(row[4]),uuid(row[5]),decimal(row[6]),uuid(row[7])))
                .toList();
    }

    private List<SourceAnchor> sourceAnchors(
            String receiptType, List<UUID> receiptItemIds) {
        if (receiptItemIds.isEmpty()) return List.of();
        boolean purchase = "PURCHASE".equals(receiptType);
        String receiptItems = purchase
                ? "purchase_receipt_items" : "subcontract_receipt_items";
        String orderItems = purchase
                ? "purchase_order_items" : "subcontract_order_items";
        String sources = purchase
                ? "purchase_order_item_sources" : "subcontract_order_item_sources";
        String external = purchase ? "request_item_id" : "application_item_id";
        String share = purchase
                ? "fn_purchase_order_source_share"
                : "fn_subcontract_order_source_share";
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT receipt_item.id,order_item.id,source.%1$s,source.line_no,
                       GREATEST(source_qty.base_qty
                           -COALESCE(public_qty.base_qty,0)
                           -fn_preplan_order_exact_attributed_qty(
                               :orderType,order_item.order_id,source.%1$s,'SUPPLY'),0)
                           AS exact_remaining_qty,
                       GREATEST(COALESCE(public_qty.base_qty,0)
                           -fn_preplan_order_exact_attributed_qty(
                               :orderType,order_item.order_id,source.%1$s,
                               'SHARED_FUTURE_CLAIM'),0)
                           AS shared_remaining_qty
                FROM %2$s receipt_item
                JOIN %3$s order_item ON order_item.id=receipt_item.order_item_id
                JOIN %4$s source ON source.order_item_id=order_item.id
                CROSS JOIN LATERAL (
                    SELECT %5$s(order_item.id,source.%1$s,
                        order_item.qty*COALESCE(order_item.unit_rate,1)) AS base_qty
                ) source_qty
                LEFT JOIN LATERAL (
                    SELECT public.source_action_id
                    FROM v_preplan_public_supply_sources_v474 public
                    WHERE public.external_item_id=source.%1$s
                    ORDER BY public.source_action_id LIMIT 1
                ) public_source ON TRUE
                LEFT JOIN LATERAL (
                    SELECT fn_preplan_order_public_source_qty(
                        public_source.source_action_id,source.%1$s,
                        :orderType,order_item.order_id) AS base_qty
                ) public_qty ON TRUE
                WHERE receipt_item.id IN (:receiptItemIds)
                  AND receipt_item.is_deleted=FALSE AND order_item.is_deleted=FALSE
                UNION ALL
                SELECT receipt_item.id,order_item.id,order_item.%1$s,0,
                       order_item.qty*COALESCE(order_item.unit_rate,1),0
                FROM %2$s receipt_item
                JOIN %3$s order_item ON order_item.id=receipt_item.order_item_id
                WHERE receipt_item.id IN (:receiptItemIds)
                  AND receipt_item.is_deleted=FALSE AND order_item.is_deleted=FALSE
                  AND order_item.%1$s IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM %4$s source
                                  WHERE source.order_item_id=order_item.id)
                ORDER BY 1,4
                """.formatted(external, receiptItems, orderItems, sources, share))
                .setParameter("receiptItemIds", receiptItemIds)
                .setParameter("orderType", receiptType)).stream()
                .map(row -> new SourceAnchor(
                        uuid(row[0]),uuid(row[1]),uuid(row[2]),integer(row[3]),
                        decimal(row[4]),decimal(row[5])))
                .toList();
    }

    private List<SourceAnchor> orderSourceAnchors(
            String orderType, List<UUID> orderItemIds) {
        if (orderItemIds.isEmpty()) return List.of();
        boolean purchase = "PURCHASE".equals(orderType);
        String orderItems = purchase
                ? "purchase_order_items" : "subcontract_order_items";
        String sources = purchase
                ? "purchase_order_item_sources" : "subcontract_order_item_sources";
        String external = purchase ? "request_item_id" : "application_item_id";
        String share = purchase
                ? "fn_purchase_order_source_share"
                : "fn_subcontract_order_source_share";
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT NULL,item.id,source.%1$s,source.line_no,
                       GREATEST(source_qty.base_qty
                           -COALESCE(public_qty.base_qty,0)
                           -fn_preplan_order_exact_attributed_qty(
                               :orderType,item.order_id,source.%1$s,'SUPPLY'),0),
                       GREATEST(COALESCE(public_qty.base_qty,0)
                           -fn_preplan_order_exact_attributed_qty(
                               :orderType,item.order_id,source.%1$s,
                               'SHARED_FUTURE_CLAIM'),0)
                FROM %2$s item
                JOIN %3$s source ON source.order_item_id=item.id
                CROSS JOIN LATERAL (
                    SELECT %4$s(item.id,source.%1$s,
                        item.qty*COALESCE(item.unit_rate,1)) AS base_qty
                ) source_qty
                LEFT JOIN LATERAL (
                    SELECT public.source_action_id
                    FROM v_preplan_public_supply_sources_v474 public
                    WHERE public.external_item_id=source.%1$s
                    ORDER BY public.source_action_id LIMIT 1
                ) public_source ON TRUE
                LEFT JOIN LATERAL (
                    SELECT fn_preplan_order_public_source_qty(
                        public_source.source_action_id,source.%1$s,
                        :orderType,item.order_id) AS base_qty
                ) public_qty ON TRUE
                WHERE item.id IN (:orderItemIds) AND item.is_deleted=FALSE
                UNION ALL
                SELECT NULL,item.id,item.%1$s,0,
                       item.qty*COALESCE(item.unit_rate,1),0
                FROM %2$s item
                WHERE item.id IN (:orderItemIds) AND item.is_deleted=FALSE
                  AND item.%1$s IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM %3$s source
                                  WHERE source.order_item_id=item.id)
                ORDER BY 2,4
                """.formatted(external, orderItems, sources, share))
                .setParameter("orderItemIds", orderItemIds)
                .setParameter("orderType", orderType)).stream()
                .map(row -> new SourceAnchor(
                        null,uuid(row[1]),uuid(row[2]),integer(row[3]),
                        decimal(row[4]),decimal(row[5])))
                .toList();
    }

    private Map<UUID, List<PreplanCandidate>> preplanCandidates(
            Set<UUID> externalItemIds) {
        if (externalItemIds.isEmpty()) return Map.of();
        Map<UUID, List<PreplanCandidate>> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT allocation.external_item_id,allocation.id,
                       action.id,action.operation_type,
                       action.warehouse_id,warehouse.name,
                       analysis.warehouse_id,
                       allocation.analysis_id,allocation.analysis_material_id,
                       material.goods_id,material.color_id,
                       GREATEST(allocation.allocated_qty-COALESCE(exact.qty,0),0),
                       product_goods.code,product_goods.name,
                       COALESCE(NULLIF(BTRIM(source.source_ref),''),'生产物料分析'),
                       work.plan_id,work.plan_no,work.segment_id,work.segment_code,
                       work.workshop_id,work.workshop_name,
                       work.responsible_id,work.responsible_name
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id=allocation.action_id
                 AND action.status <> 'CANCELLED'
                JOIN production_material_analyses analysis
                  ON analysis.id=allocation.analysis_id
                 AND analysis.is_deleted=FALSE
                 AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED','COMPLETED')
                JOIN production_material_analysis_materials material
                  ON material.id=allocation.analysis_material_id
                 AND material.analysis_id=allocation.analysis_id
                 AND material.active=TRUE
                JOIN production_material_analysis_items source
                  ON source.id=material.analysis_item_id
                 AND source.analysis_id=analysis.id
                 AND source.is_deleted=FALSE
                LEFT JOIN goods product_goods ON product_goods.id=source.goods_id
                LEFT JOIN warehouses warehouse ON warehouse.id=action.warehouse_id
                LEFT JOIN LATERAL (
                    SELECT plan.id AS plan_id,plan.bill_no AS plan_no,
                           segment.id AS segment_id,segment.segment_code,
                           segment.workshop_department_id AS workshop_id,
                           workshop.name AS workshop_name,
                           segment.responsible_employee_id AS responsible_id,
                           responsible.full_name AS responsible_name
                    FROM production_material_analysis_plan_links link
                    JOIN production_plans plan ON plan.id=link.plan_id
                     AND plan.status=1 AND plan.is_deleted=FALSE
                     AND plan.is_canceled=FALSE
                    JOIN production_planning_packages package
                      ON package.plan_id=plan.id
                     AND package.status='CONFIRMED' AND package.is_deleted=FALSE
                    JOIN production_execution_segments segment
                      ON segment.package_id=package.id AND segment.plan_id=plan.id
                     AND segment.is_deleted=FALSE
                     AND segment.status IN ('WAITING','READY','DISPATCHED','IN_PROGRESS')
                    JOIN production_material_demands demand
                      ON demand.execution_segment_id=segment.id
                     AND demand.goods_id=material.goods_id
                     AND demand.color_id IS NOT DISTINCT FROM material.color_id
                     AND demand.is_deleted=FALSE
                    LEFT JOIN departments workshop
                      ON workshop.id=segment.workshop_department_id
                    LEFT JOIN employees responsible
                      ON responsible.id=segment.responsible_employee_id
                    WHERE link.analysis_id=analysis.id
                      AND link.analysis_item_id=material.analysis_item_id
                      AND link.allocation_status='APPROVED'
                    ORDER BY CASE segment.status WHEN 'WAITING' THEN 0 ELSE 1 END,
                             segment.plan_begin_date NULLS LAST,segment.id
                    LIMIT 1
                ) work ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(CASE
                        WHEN reservation.release_reason='TRANSFERRED_TO_PLAN'
                        THEN exact_peg.qty
                        ELSE GREATEST(reservation.qty-reservation.consumed_qty
                            -reservation.released_qty,0) END) AS qty
                    FROM preplan_analysis_stock_exact_pegs exact_peg
                    JOIN stock_reservations reservation
                      ON reservation.id=exact_peg.stock_reservation_id
                     AND reservation.is_deleted=FALSE
                    WHERE exact_peg.supply_action_allocation_id=allocation.id
                      AND (reservation.status=0
                           OR reservation.release_reason='TRANSFERRED_TO_PLAN')
                ) exact ON TRUE
                WHERE allocation.external_item_id IN (:externalItemIds)
                ORDER BY allocation.external_item_id,
                         CASE action.operation_type
                           WHEN 'SHARED_FUTURE_CLAIM' THEN 1 ELSE 0 END,
                         action.created_at,action.id,
                         allocation.created_at,allocation.id
                """).setParameter("externalItemIds", externalItemIds))) {
            PreplanCandidate value = PreplanCandidate.from(row);
            result.computeIfAbsent(value.externalItemId(), ignored -> new ArrayList<>())
                    .add(value);
        }
        return result;
    }

    private Map<UUID, List<FormalCandidate>> formalCandidates(
            String receiptType, Set<UUID> orderItemIds) {
        if (orderItemIds.isEmpty()) return Map.of();
        String supplyType = "PURCHASE".equals(receiptType)
                ? "PURCHASE_ORDER_ITEM" : "SUBCONTRACT_ORDER_ITEM";
        Map<UUID, List<FormalCandidate>> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT peg.supply_item_id,peg.id,
                       demand.warehouse_id,warehouse.name,
                       demand.goods_id,demand.color_id,
                       GREATEST(peg.allocated_qty-peg.consumed_qty-peg.released_qty,0),
                       demand.plan_id,plan.bill_no,segment.id,segment.segment_code,
                       segment.workshop_department_id,workshop.name,
                       segment.responsible_employee_id,responsible.full_name,
                       product.code,product.name
                FROM production_material_supply_pegs peg
                JOIN production_material_demands demand ON demand.id=peg.demand_id
                 AND demand.is_deleted=FALSE
                JOIN production_planning_packages package ON package.id=demand.package_id
                 AND package.status='CONFIRMED' AND package.is_deleted=FALSE
                JOIN production_plans plan ON plan.id=demand.plan_id
                LEFT JOIN production_execution_segments segment
                  ON segment.id=demand.execution_segment_id
                 AND segment.is_deleted=FALSE
                LEFT JOIN departments workshop
                  ON workshop.id=segment.workshop_department_id
                LEFT JOIN employees responsible
                  ON responsible.id=segment.responsible_employee_id
                LEFT JOIN goods product ON product.id=segment.product_goods_id
                LEFT JOIN warehouses warehouse ON warehouse.id=demand.warehouse_id
                WHERE peg.supply_type=:supplyType
                  AND peg.supply_item_id IN (:orderItemIds)
                  AND peg.status <> 'REVERSED'
                  AND peg.allocated_qty-peg.consumed_qty-peg.released_qty > 0
                ORDER BY peg.supply_item_id,demand.need_date NULLS LAST,
                         demand.id,peg.id
                """).setParameter("supplyType", supplyType)
                .setParameter("orderItemIds", orderItemIds))) {
            FormalCandidate value = FormalCandidate.from(row);
            result.computeIfAbsent(value.orderItemId(), ignored -> new ArrayList<>())
                    .add(value);
        }
        return result;
    }

    private List<ActualSlice> actualSlices(List<UUID> batchIds) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,item.batch_id,item.pass_event_id,
                       item.warehouse_id,warehouse.name,
                       item.goods_id,item.color_id,item.base_qty,
                       item.inspection_item_id,inspection.receipt_item_id,
                       inspection.receipt_type,
                       CASE WHEN inspection.receipt_type='PURCHASE'
                            THEN purchase_item.order_item_id
                            ELSE subcontract_item.order_item_id END,
                       batch.confirmed_at
                FROM procurement_iqc_stock_in_batch_items item
                JOIN procurement_iqc_stock_in_batches batch
                  ON batch.id=item.batch_id
                JOIN procurement_inspection_items inspection
                  ON inspection.id=item.inspection_item_id
                LEFT JOIN purchase_receipt_items purchase_item
                  ON inspection.receipt_type='PURCHASE'
                 AND purchase_item.id=inspection.receipt_item_id
                LEFT JOIN subcontract_receipt_items subcontract_item
                  ON inspection.receipt_type='SUBCONTRACT'
                 AND subcontract_item.id=inspection.receipt_item_id
                LEFT JOIN warehouses warehouse ON warehouse.id=item.warehouse_id
                WHERE item.batch_id IN (:batchIds)
                ORDER BY item.position,item.id
                """).setParameter("batchIds", batchIds)).stream()
                .map(row -> new ActualSlice(
                        uuid(row[0]),uuid(row[1]),uuid(row[2]),uuid(row[3]),string(row[4]),
                        uuid(row[5]),uuid(row[6]),decimal(row[7]),uuid(row[8]),uuid(row[9]),
                        string(row[10]),uuid(row[11]),offsetDateTime(row[12])))
                .toList();
    }

    private List<ActualSlice> actualSlicesForReceiptItems(
            Collection<UUID> receiptItemIds) {
        if (receiptItemIds == null || receiptItemIds.isEmpty()) return List.of();
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,item.batch_id,item.pass_event_id,
                       item.warehouse_id,warehouse.name,
                       item.goods_id,item.color_id,item.base_qty,
                       item.inspection_item_id,inspection.receipt_item_id,
                       inspection.receipt_type,
                       CASE WHEN inspection.receipt_type='PURCHASE'
                            THEN purchase_item.order_item_id
                            ELSE subcontract_item.order_item_id END,
                       batch.confirmed_at
                FROM procurement_iqc_stock_in_batch_items item
                JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id
                JOIN procurement_inspection_items inspection
                  ON inspection.id=item.inspection_item_id
                LEFT JOIN purchase_receipt_items purchase_item
                  ON inspection.receipt_type='PURCHASE'
                 AND purchase_item.id=inspection.receipt_item_id
                LEFT JOIN subcontract_receipt_items subcontract_item
                  ON inspection.receipt_type='SUBCONTRACT'
                 AND subcontract_item.id=inspection.receipt_item_id
                LEFT JOIN warehouses warehouse ON warehouse.id=item.warehouse_id
                WHERE inspection.receipt_item_id IN (:receiptItemIds)
                ORDER BY batch.confirmed_at,item.id
                """).setParameter("receiptItemIds", receiptItemIds)).stream()
                .map(row -> new ActualSlice(
                        uuid(row[0]),uuid(row[1]),uuid(row[2]),uuid(row[3]),string(row[4]),
                        uuid(row[5]),uuid(row[6]),decimal(row[7]),uuid(row[8]),uuid(row[9]),
                        string(row[10]),uuid(row[11]),offsetDateTime(row[12])))
                .toList();
    }

    private Map<UUID, List<String>> intendedWarehouses(List<ActualSlice> slices) {
        Map<UUID, LinkedHashSet<String>> result = new LinkedHashMap<>();
        for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
            List<ActualSlice> typed = slices.stream()
                    .filter(slice -> type.equals(slice.orderType()))
                    .filter(slice -> slice.orderItemId() != null).toList();
            if (typed.isEmpty()) continue;
            List<UUID> orderItemIds = typed.stream().map(ActualSlice::orderItemId)
                    .distinct().toList();
            Map<UUID, List<FormalCandidate>> formal = formalCandidates(
                    type, new LinkedHashSet<>(orderItemIds));
            for (ActualSlice slice : typed) {
                LinkedHashSet<String> names = result.computeIfAbsent(
                        slice.batchItemId(), ignored -> new LinkedHashSet<>());
                // Preplan-owned receipts follow their actual warehouse. Only the
                // separate legacy direct-formal route still has an intended-warehouse warning.
                formal.getOrDefault(slice.orderItemId(), List.of()).stream()
                        .filter(candidate -> !Objects.equals(
                                candidate.targetWarehouseId(), slice.warehouseId()))
                        .map(FormalCandidate::targetWarehouseName)
                        .filter(Objects::nonNull).forEach(names::add);
            }
        }
        Map<UUID, List<String>> immutable = new LinkedHashMap<>();
        result.forEach((key, value) -> immutable.put(key, List.copyOf(value)));
        return Map.copyOf(immutable);
    }

    private List<AllocationView> actualDirectFormal(
            List<UUID> batchIds,
            List<ActualSlice> slices,
            Map<UUID, BigDecimal> preplanAttributed) {
        Set<UUID> selectedBatchIds = Set.copyOf(batchIds);
        Set<UUID> receiptItemIds = slices.stream().map(ActualSlice::receiptItemId)
                .filter(Objects::nonNull)
                .collect(LinkedHashSet::new, Set::add, Set::addAll);
        List<ActualSlice> allSlices = actualSlicesForReceiptItems(receiptItemIds);
        List<UUID> allItemIds = allSlices.stream().map(ActualSlice::batchItemId).toList();
        Map<UUID, BigDecimal> allPreplanAttributed = new HashMap<>();
        List<AllocationView> allPreplan = new ArrayList<>();
        allPreplan.addAll(actualBeneficiaryBalances(allItemIds));
        allPreplan.addAll(actualFormalizedEntitlements(allItemIds));
        allPreplan.forEach(value -> allPreplanAttributed.merge(
                value.stockInBatchItemId(), value.qty(), BigDecimal::add));
        preplanAttributed.forEach(allPreplanAttributed::putIfAbsent);
        Map<UUID, BigDecimal> remainingByItem = new HashMap<>();
        allSlices.forEach(slice -> remainingByItem.put(
                slice.batchItemId(),
                slice.baseQty().subtract(allPreplanAttributed.getOrDefault(
                        slice.batchItemId(), BigDecimal.ZERO)).max(BigDecimal.ZERO)));
        List<DirectFormalCandidate> candidates = new ArrayList<>();
        candidates.addAll(directFormalCandidates(
                "production_material_receipt_allocations", receiptItemIds));
        candidates.addAll(directFormalCandidates(
                "production_material_subcontract_receipt_allocations", receiptItemIds));
        candidates.sort(Comparator
                .comparing(DirectFormalCandidate::receiptItemId)
                .thenComparing(DirectFormalCandidate::createdAt)
                .thenComparing(DirectFormalCandidate::allocationId));
        Map<UUID, List<ActualSlice>> slicesByReceipt = new LinkedHashMap<>();
        allSlices.stream().sorted(Comparator
                        .comparing(ActualSlice::confirmedAt)
                        .thenComparing(ActualSlice::batchItemId))
                .forEach(slice -> slicesByReceipt.computeIfAbsent(
                        slice.receiptItemId(), ignored -> new ArrayList<>()).add(slice));
        List<AllocationView> result = new ArrayList<>();
        for (DirectFormalCandidate candidate : candidates) {
            BigDecimal allocationRemaining = candidate.qty();
            for (ActualSlice slice : slicesByReceipt.getOrDefault(
                    candidate.receiptItemId(), List.of())) {
                if (allocationRemaining.signum() <= 0) break;
                BigDecimal itemRemaining = remainingByItem.getOrDefault(
                        slice.batchItemId(), BigDecimal.ZERO);
                BigDecimal take = allocationRemaining.min(itemRemaining)
                        .max(BigDecimal.ZERO);
                if (take.signum() <= 0) continue;
                if (selectedBatchIds.contains(slice.batchId())) {
                    result.add(candidate.toView(slice, take));
                }
                allocationRemaining = allocationRemaining.subtract(take);
                remainingByItem.put(
                        slice.batchItemId(), itemRemaining.subtract(take));
            }
            if (allocationRemaining.signum() > 0) {
                throw new IllegalStateException(
                        "formal receipt allocation exceeds warehouse stock-in slices");
            }
        }
        return result;
    }

    private List<DirectFormalCandidate> directFormalCandidates(
            String table, Collection<UUID> receiptItemIds) {
        if (receiptItemIds.isEmpty()) return List.of();
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT allocation.id,allocation.receipt_item_id,
                       allocation.allocated_qty,allocation.created_at,
                       demand.warehouse_id,warehouse.name,
                       plan.id,plan.bill_no,segment.id,segment.segment_code,
                       segment.workshop_department_id,workshop.name,
                       segment.responsible_employee_id,responsible.full_name,
                       product.code,product.name
                FROM %s allocation
                JOIN production_material_demands demand
                  ON demand.id=allocation.demand_id
                JOIN production_plans plan ON plan.id=demand.plan_id
                LEFT JOIN production_execution_segments segment
                  ON segment.id=demand.execution_segment_id
                LEFT JOIN warehouses warehouse ON warehouse.id=demand.warehouse_id
                LEFT JOIN departments workshop
                  ON workshop.id=segment.workshop_department_id
                LEFT JOIN employees responsible
                  ON responsible.id=segment.responsible_employee_id
                LEFT JOIN goods product ON product.id=segment.product_goods_id
                WHERE allocation.receipt_item_id IN (:receiptItemIds)
                  AND allocation.status='EFFECTIVE'
                ORDER BY allocation.receipt_item_id,
                         allocation.created_at,allocation.id
                """.formatted(table))
                .setParameter("receiptItemIds", receiptItemIds)).stream()
                .map(DirectFormalCandidate::from).toList();
    }

    private List<AllocationView> actualBeneficiaryBalances(List<UUID> itemIds) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT origin.event_group_id,exact.source_disposition_event_id,
                       balance.effective_qty,
                       reservation.warehouse_id,warehouse.name,
                       balance.beneficiary_analysis_id,
                       balance.beneficiary_analysis_material_id,
                       product.code,product.name,
                       COALESCE(NULLIF(BTRIM(source.source_ref),''),'生产物料分析'),
                       action.operation_type
                FROM preplan_stock_entitlement_events origin
                JOIN preplan_analysis_stock_exact_pegs exact
                  ON exact.id=origin.source_exact_peg_id
                JOIN preplan_supply_action_allocations allocation
                  ON allocation.id=exact.supply_action_allocation_id
                JOIN preplan_supply_actions action ON action.id=allocation.action_id
                JOIN stock_reservations reservation
                  ON reservation.id=origin.stock_reservation_id
                JOIN v_preplan_stock_entitlement_beneficiary_balance balance
                  ON balance.stock_reservation_id=reservation.id
                JOIN production_material_analysis_materials material
                  ON material.analysis_id=balance.beneficiary_analysis_id
                 AND material.id=balance.beneficiary_analysis_material_id
                JOIN production_material_analysis_items source
                  ON source.analysis_id=material.analysis_id
                 AND source.id=material.analysis_item_id
                LEFT JOIN goods product ON product.id=source.goods_id
                LEFT JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id
                WHERE origin.event_type='ORIGIN_IQC'
                  AND origin.event_group_id IN (:itemIds)
                  AND balance.effective_qty > 0
                ORDER BY origin.event_group_id,balance.beneficiary_analysis_id,
                         balance.beneficiary_analysis_material_id
                """).setParameter("itemIds", itemIds)).stream()
                .map(row -> new AllocationView(
                        uuid(row[1]),uuid(row[0]),
                        "SHARED_FUTURE_CLAIM".equals(string(row[10]))
                                ? SHARED_CLAIM : EXACT_ANALYSIS,
                        decimal(row[2]),uuid(row[3]),string(row[4]),
                        uuid(row[3]),string(row[4]),warehouseNames(string(row[4])),true,
                        uuid(row[5]),uuid(row[6]),string(row[7]),string(row[8]),
                        string(row[9]),null,null,null,null,null,null,null,null,
                        "已按实际入库形成分析物料权益"))
                .toList();
    }

    private List<AllocationView> actualFormalizedEntitlements(List<UUID> itemIds) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT origin.event_group_id,exact.source_disposition_event_id,
                       formal.qty,target_reservation.warehouse_id,warehouse.name,
                       source_event.beneficiary_analysis_id,
                       source_event.beneficiary_analysis_material_id,
                       product.code,product.name,
                       COALESCE(NULLIF(BTRIM(source.source_ref),''),'生产物料分析'),
                       plan.id,plan.bill_no,segment.id,segment.segment_code,
                       segment.workshop_department_id,workshop.name,
                       segment.responsible_employee_id,responsible.full_name
                FROM preplan_stock_entitlement_events origin
                JOIN preplan_analysis_stock_exact_pegs exact
                  ON exact.id=origin.source_exact_peg_id
                JOIN preplan_stock_entitlement_events source_event
                  ON source_event.stock_reservation_id=origin.stock_reservation_id
                 AND source_event.source_exact_peg_id=exact.id
                 AND source_event.event_type IN (
                     'ORIGIN_IQC','REALLOCATE_IN','PRIORITY_IN','RESTORE')
                JOIN preplan_stock_entitlement_events formal
                  ON formal.source_entitlement_event_id=source_event.id
                 AND formal.event_type='FORMALIZE'
                JOIN production_material_demands demand
                  ON demand.id=formal.target_demand_id
                JOIN stock_reservations target_reservation
                  ON target_reservation.id=formal.target_stock_reservation_id
                 AND target_reservation.demand_id=demand.id
                JOIN production_plans plan ON plan.id=demand.plan_id
                LEFT JOIN production_execution_segments segment
                  ON segment.id=demand.execution_segment_id
                JOIN production_material_analysis_materials material
                  ON material.analysis_id=source_event.beneficiary_analysis_id
                 AND material.id=source_event.beneficiary_analysis_material_id
                JOIN production_material_analysis_items source
                  ON source.analysis_id=material.analysis_id
                 AND source.id=material.analysis_item_id
                LEFT JOIN goods product ON product.id=source.goods_id
                LEFT JOIN warehouses warehouse ON warehouse.id=target_reservation.warehouse_id
                LEFT JOIN departments workshop
                  ON workshop.id=segment.workshop_department_id
                LEFT JOIN employees responsible
                  ON responsible.id=segment.responsible_employee_id
                WHERE origin.event_type='ORIGIN_IQC'
                  AND origin.event_group_id IN (:itemIds)
                  AND NOT EXISTS (
                      SELECT 1 FROM preplan_stock_entitlement_events restore
                      WHERE restore.event_type='RESTORE'
                        AND restore.counter_event_id=formal.id)
                ORDER BY origin.event_group_id,formal.created_at,formal.id
                """).setParameter("itemIds", itemIds)).stream()
                .map(row -> new AllocationView(
                        uuid(row[1]),uuid(row[0]),FORMAL_DEMAND,decimal(row[2]),
                        uuid(row[3]),string(row[4]),uuid(row[3]),string(row[4]),
                        warehouseNames(string(row[4])),true,
                        uuid(row[5]),uuid(row[6]),string(row[7]),string(row[8]),
                        string(row[9]),uuid(row[10]),string(row[11]),
                        uuid(row[12]),string(row[13]),uuid(row[14]),string(row[15]),
                        uuid(row[16]),string(row[17]),"已转入正式工单物料预留"))
                .toList();
    }

    private static AllocationView publicView(
            UUID passEventId, UUID batchItemId, BigDecimal qty,
            UUID warehouseId, String warehouseName,
            List<String> intendedWarehouseNames,
            boolean warehouseMatches, String status) {
        return new AllocationView(
                passEventId,batchItemId,PUBLIC,qty,
                warehouseId,warehouseName,null,null,
                intendedWarehouseNames,warehouseMatches,
                null,null,null,null,"公共库存",
                null,null,null,null,null,null,null,null,status);
    }

    private static String normalizeReceiptType(String value) {
        String normalized = Objects.toString(value, "").strip()
                .toUpperCase(Locale.ROOT);
        if (!Set.of("PURCHASE", "SUBCONTRACT").contains(normalized)) {
            throw new IllegalArgumentException("unsupported receipt type");
        }
        return normalized;
    }

    private static List<UUID> ids(Collection<UUID> values) {
        if (values == null) return List.of();
        return values.stream().filter(Objects::nonNull).distinct().sorted().toList();
    }

    private record Slice(
            UUID passEventId, UUID receiptItemId,
            UUID warehouseId, String warehouseName,
            UUID goodsId, UUID colorId,
            BigDecimal remainingQty, UUID orderItemId) {
        boolean matches(UUID goods, UUID color) {
            return goodsId.equals(goods) && Objects.equals(colorId, color);
        }
    }

    private record SourceAnchor(
            UUID receiptItemId, UUID orderItemId,
            UUID externalItemId, int lineNo,
            BigDecimal exactRemainingQty,
            BigDecimal sharedRemainingQty) {
    }

    private record SourceBudgetKey(UUID orderItemId, UUID externalItemId, boolean sharedClaim) {}

    private record PreplanCandidate(
            UUID externalItemId, UUID allocationId, UUID actionId,
            String operationType, UUID targetWarehouseId,
            String targetWarehouseName, UUID analysisWarehouseId,
            UUID analysisId, UUID analysisMaterialId,
            UUID goodsId, UUID colorId, BigDecimal headroom,
            String productCode, String productName, String sourceLabel,
            UUID planId, String planNo, UUID segmentId, String segmentCode,
            UUID workshopId, String workshopName,
            UUID responsibleId, String responsibleName) {
        static PreplanCandidate from(Object[] row) {
            return new PreplanCandidate(
                    uuid(row[0]),uuid(row[1]),uuid(row[2]),string(row[3]),
                    uuid(row[4]),string(row[5]),uuid(row[6]),uuid(row[7]),uuid(row[8]),
                    uuid(row[9]),uuid(row[10]),decimal(row[11]),string(row[12]),
                    string(row[13]),string(row[14]),uuid(row[15]),string(row[16]),
                    uuid(row[17]),string(row[18]),uuid(row[19]),string(row[20]),
                    uuid(row[21]),string(row[22]));
        }

        AllocationView toView(
                UUID passEventId, BigDecimal qty,
                UUID actualWarehouseId, String actualWarehouseName,
                boolean matches) {
            String formation = segmentId == null
                    ? "尚未形成生产计划或工单"
                    : workshopId == null
                            ? "工单已形成，尚未指定生产车间"
                            : "工单已形成，等待本批物料";
            return new AllocationView(
                    passEventId,null,
                    "SHARED_FUTURE_CLAIM".equals(operationType)
                            ? SHARED_CLAIM : EXACT_ANALYSIS,
                    qty,actualWarehouseId,actualWarehouseName,
                    targetWarehouseId,targetWarehouseName,
                    warehouseNames(targetWarehouseName),matches,
                    analysisId,analysisMaterialId,productCode,productName,sourceLabel,
                    planId,planNo,segmentId,segmentCode,workshopId,workshopName,
                    responsibleId,responsibleName,formation);
        }
    }

    private record FormalCandidate(
            UUID orderItemId, UUID pegId,
            UUID targetWarehouseId, String targetWarehouseName,
            UUID goodsId, UUID colorId, BigDecimal headroom,
            UUID planId, String planNo, UUID segmentId, String segmentCode,
            UUID workshopId, String workshopName,
            UUID responsibleId, String responsibleName,
            String productCode, String productName) {
        static FormalCandidate from(Object[] row) {
            return new FormalCandidate(
                    uuid(row[0]),uuid(row[1]),uuid(row[2]),string(row[3]),
                    uuid(row[4]),uuid(row[5]),decimal(row[6]),uuid(row[7]),string(row[8]),
                    uuid(row[9]),string(row[10]),uuid(row[11]),string(row[12]),
                    uuid(row[13]),string(row[14]),string(row[15]),string(row[16]));
        }

        AllocationView toView(
                UUID passEventId, BigDecimal qty,
                UUID actualWarehouseId, String actualWarehouseName) {
            boolean matches = actualWarehouseId != null
                    && actualWarehouseId.equals(targetWarehouseId);
            return new AllocationView(
                    passEventId,null,FORMAL_DEMAND,qty,
                    actualWarehouseId,actualWarehouseName,
                    targetWarehouseId,targetWarehouseName,
                    warehouseNames(targetWarehouseName),matches,
                    null,null,productCode,productName,"正式生产需求",
                    planId,planNo,segmentId,segmentCode,workshopId,workshopName,
                    responsibleId,responsibleName,
                    segmentId == null ? "正式需求尚未形成工单" : "已形成正式工单");
        }
    }

    private record ActualSlice(
            UUID batchItemId, UUID batchId, UUID passEventId,
            UUID warehouseId, String warehouseName,
            UUID goodsId, UUID colorId, BigDecimal baseQty,
            UUID inspectionItemId, UUID receiptItemId,
            String orderType, UUID orderItemId,
            OffsetDateTime confirmedAt) {
    }

    private record DirectFormalCandidate(
            UUID allocationId, UUID receiptItemId, BigDecimal qty,
            OffsetDateTime createdAt,
            UUID targetWarehouseId, String targetWarehouseName,
            UUID planId, String planNo, UUID segmentId, String segmentCode,
            UUID workshopId, String workshopName,
            UUID responsibleId, String responsibleName,
            String productCode, String productName) {
        static DirectFormalCandidate from(Object[] row) {
            return new DirectFormalCandidate(
                    uuid(row[0]),uuid(row[1]),decimal(row[2]),offsetDateTime(row[3]),
                    uuid(row[4]),string(row[5]),uuid(row[6]),string(row[7]),
                    uuid(row[8]),string(row[9]),uuid(row[10]),string(row[11]),
                    uuid(row[12]),string(row[13]),string(row[14]),string(row[15]));
        }

        AllocationView toView(ActualSlice slice, BigDecimal allocatedQty) {
            boolean matches = Objects.equals(
                    slice.warehouseId(), targetWarehouseId);
            return new AllocationView(
                    slice.passEventId(),slice.batchItemId(),FORMAL_DEMAND,
                    allocatedQty,slice.warehouseId(),slice.warehouseName(),
                    targetWarehouseId,targetWarehouseName,
                    warehouseNames(targetWarehouseName),matches,
                    null,null,productCode,productName,"正式生产需求",
                    planId,planNo,segmentId,segmentCode,workshopId,workshopName,
                    responsibleId,responsibleName,
                    matches ? "已按实际入库转入正式工单物料预留"
                            : "实际入库仓与正式需求仓不一致，请核对异常链路");
        }
    }

    private static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static String string(Object value) {
        return value == null ? null : value.toString();
    }

    private static int integer(Object value) {
        return value == null ? 0 : ((Number) value).intValue();
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        if (value instanceof java.time.Instant instant) {
            return instant.atOffset(ZoneOffset.UTC);
        }
        return OffsetDateTime.parse(value.toString());
    }

    private static List<String> warehouseNames(String value) {
        return value == null || value.isBlank() ? List.of() : List.of(value);
    }

    private static boolean sameMainWarehouse(Map<UUID, UUID> roots, UUID left, UUID right) {
        if (left == null || right == null) return false;
        if (left.equals(right)) return true;
        UUID main = roots.get(left);
        return main != null && main.equals(roots.get(right));
    }
}
