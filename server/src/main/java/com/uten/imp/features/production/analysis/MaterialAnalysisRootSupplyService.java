package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.StockReservation;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Root products use the existing supply ledger and hand qualified output to sales or stock. */
@Service
@org.springframework.core.annotation.Order(-100)
@RequiredArgsConstructor
public class MaterialAnalysisRootSupplyService implements PreplanOriginEntitlementHook {
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyPriorityForOriginEvent(UUID originEventId) { fulfillOrigin(originEventId); }
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final InventoryMutationLock inventoryLock;
    private final PreplanStockEntitlementService entitlement;
    private final StockReservationService salesReservations;

    @Transactional(propagation = Propagation.MANDATORY)
    public void ensureRootNodes(UUID analysisId) {
        List<Object[]> invalid = rows("""
                SELECT item.id,goods.code
                FROM production_material_analysis_items item
                JOIN goods ON goods.id=item.goods_id
                LEFT JOIN sales_order_items sales ON sales.id=item.sales_order_item_id
                LEFT JOIN production_material_analysis_materials root ON root.id=item.root_material_id
                WHERE item.analysis_id=:id AND item.is_deleted=FALSE
                  AND item.source_type IN ('SALES_ORDER_ITEM','REWORK','TRIAL','SAMPLE','STOCK','OTHER')
                  AND (goods.unit_id IS NULL
                    OR (item.sales_order_item_id IS NULL AND item.unit_id IS DISTINCT FROM goods.unit_id)
                    OR (item.sales_order_item_id IS NOT NULL AND (
                      sales.unit_id IS NULL OR sales.unit_rate<=0
                      OR (sales.unit_id IS DISTINCT FROM goods.unit_id AND sales.unit_rate IS NULL)
                      OR (root.id IS NOT NULL AND root.per_product_qty<>COALESCE(sales.unit_rate,1)))))
                LIMIT 1
                ""","id",analysisId);
        if (!invalid.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "根产品缺少基本单位或销售单位换算无效，请先修复历史单位与换算率");
        }

        em.createNativeQuery("""
                UPDATE production_material_analysis_items
                SET root_material_id=gen_random_uuid()
                WHERE analysis_id=:analysisId AND is_deleted=FALSE
                  AND root_material_id IS NULL
                  AND source_type IN ('SALES_ORDER_ITEM','REWORK','TRIAL','SAMPLE','STOCK','OTHER')
                """).setParameter("analysisId", analysisId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_materials (
                  id,analysis_id,analysis_item_id,node_key,parent_node_key,bom_item_id,
                  goods_id,color_id,unit_id,depth,path,per_product_qty,
                  required_qty,available_qty,allocated_available_qty,reserved_qty,
                  safety_stock_qty,inbound_qty,shortage_qty,source_suggestion,active,
                  control_stage,consumption_basis,basis_output_qty,allow_partial_package,
                  hard_gate,bom_qty,parent_per_product_qty,calculation_mode,node_role,
                  allocated_start_qty,allocated_finish_qty,allocated_ship_qty,created_by,updated_by)
                SELECT item.root_material_id,item.analysis_id,item.id,'ROOT_SUPPLY',NULL,NULL,
                  item.goods_id,item.color_id,goods.unit_id,0,'[]',
                  COALESCE(sales.unit_rate,1),
                  CEIL(GREATEST(item.requested_qty,0)
                    *COALESCE(sales.unit_rate,1)*10000)/10000,
                  0,0,0,GREATEST(COALESCE(goods.min_qty,0),0),0,
                  CEIL(GREATEST(item.requested_qty,0)
                    *COALESCE(sales.unit_rate,1)*10000)/10000,
                  'MAKE',TRUE,'START','PER_UNIT',1,TRUE,TRUE,
                  COALESCE(sales.unit_rate,1),1,'EDGE_RULE','ROOT_SUPPLY',0,0,0,:actorId,:actorId
                FROM production_material_analysis_items item
                JOIN goods ON goods.id=item.goods_id
                LEFT JOIN sales_order_items sales ON sales.id=item.sales_order_item_id
                WHERE item.analysis_id=:analysisId AND item.root_material_id IS NOT NULL
                  AND item.is_deleted=FALSE
                ON CONFLICT (id) DO NOTHING
                """).setParameter("analysisId", analysisId)
                .setParameter("actorId", currentUser.requireId()).executeUpdate();
    }

    public Set<UUID> rootProductsWithBom(UUID analysisId) {
        return Set.copyOf(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT item.id FROM production_material_analysis_items item
                WHERE item.analysis_id=:id AND item.root_material_id IS NOT NULL AND item.is_deleted=FALSE
                  AND EXISTS (SELECT 1 FROM goods_bom_items bom JOIN goods child
                    ON child.id=bom.component_goods_id AND child.is_deleted=FALSE
                      AND COALESCE(child.auto_created,FALSE)=FALSE
                    WHERE bom.goods_id=item.goods_id AND bom.is_deleted=FALSE)
                """, UUID.class).setParameter("id",analysisId),UUID.class));
    }
    /** Runs after the ordinary BOM allocation: already protected component stock is not spent twice. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void refreshRootNodes(UUID analysisId, Map<UUID,BigDecimal> futureCoverage) {
        Map<InventoryKey, BigDecimal> publicPools = new HashMap<>();
        for (Object[] row : rows("""
                SELECT item.id,item.root_material_id,item.goods_id,item.color_id,
                  root.per_product_qty,COALESCE(root.confirmed_route,'MAKE'),
                  GREATEST(item.requested_qty,0),
                  analysis.warehouse_id,GREATEST(COALESCE(goods.min_qty,0),0),
                  COALESCE(balance.qty,0),
                  COALESCE((SELECT SUM(r.qty-r.consumed_qty-r.released_qty)
                    FROM stock_reservations r WHERE r.goods_id=item.goods_id
                    AND r.color_id IS NOT DISTINCT FROM item.color_id
                    AND (r.warehouse_id=analysis.warehouse_id OR r.warehouse_id IS NULL)
                    AND r.status=0 AND r.is_deleted=FALSE),0),
                  GREATEST(COALESCE((SELECT SUM(GREATEST(m.allocated_available_qty-COALESCE((
                      SELECT SUM(ent.effective_qty)
                      FROM v_preplan_stock_entitlement_beneficiary_balance ent
                      WHERE ent.beneficiary_analysis_id=item.analysis_id
                        AND ent.beneficiary_analysis_material_id=m.id),0),0))
                    FROM production_material_analysis_materials m
                    WHERE m.analysis_id=item.analysis_id AND m.active=TRUE
                      AND m.node_role='BOM_COMPONENT' AND m.goods_id=item.goods_id
                      AND m.color_id IS NOT DISTINCT FROM item.color_id),0)
                    -COALESCE((SELECT SUM(r.qty-r.consumed_qty-r.released_qty)
                      FROM stock_reservations r WHERE r.owner_type='PREPLAN_ANALYSIS'
                        AND r.owner_id=item.analysis_id AND r.goods_id=item.goods_id
                        AND r.color_id IS NOT DISTINCT FROM item.color_id
                        AND r.warehouse_id=analysis.warehouse_id AND r.status=0 AND r.is_deleted=FALSE
                        AND NOT EXISTS (SELECT 1 FROM preplan_stock_entitlement_events event
                                        WHERE event.stock_reservation_id=r.id)),0),0),
                  COALESCE((SELECT SUM(CASE WHEN event_kind='FULFILL' THEN qty_base ELSE -qty_base END)
                    FROM preplan_root_output_events e WHERE e.analysis_item_id=item.id),0),
                  item.sales_order_item_id,
                  COALESCE((SELECT SUM(LEAST(pi.qty,GREATEST(COALESCE(pi.iqty,0),0))
                      * COALESCE(pi.unit_rate,1))
                    FROM production_plans plan JOIN production_plan_items pi ON pi.plan_id=plan.id
                    WHERE plan.material_analysis_id=item.analysis_id
                      AND plan.material_analysis_item_id=item.id
                      AND plan.status=1 AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
                      AND pi.is_deleted=FALSE),0),
                  COALESCE((SELECT SUM(GREATEST(pi.qty-COALESCE(pi.iqty,0),0)
                      * COALESCE(pi.unit_rate,1))
                    FROM production_plans plan JOIN production_plan_items pi ON pi.plan_id=plan.id
                    WHERE plan.material_analysis_id=item.analysis_id
                      AND plan.material_analysis_item_id=item.id
                      AND plan.status IN (0,1) AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
                      AND pi.is_deleted=FALSE),0),
                  COALESCE((SELECT SUM(entitlement.effective_qty)
                      FROM v_preplan_stock_entitlement_beneficiary_balance entitlement
                      JOIN stock_reservations reservation ON reservation.id=entitlement.stock_reservation_id
                      WHERE entitlement.beneficiary_analysis_id=item.analysis_id
                        AND entitlement.beneficiary_analysis_material_id=root.id
                        AND reservation.warehouse_id=analysis.warehouse_id
                        AND reservation.status=0 AND NOT reservation.is_deleted),0)
                FROM production_material_analysis_items item
                JOIN production_material_analyses analysis ON analysis.id=item.analysis_id
                JOIN production_material_analysis_materials root ON root.id=item.root_material_id
                JOIN goods ON goods.id=item.goods_id
                LEFT JOIN stock_balances balance ON balance.warehouse_id=analysis.warehouse_id
                  AND balance.goods_id=item.goods_id AND balance.color_id IS NOT DISTINCT FROM item.color_id
                WHERE item.analysis_id=:analysisId AND item.is_deleted=FALSE
                ORDER BY item.line_priority,item.id
                """, "analysisId", analysisId)) {
            UUID materialId = (UUID) row[1];
            InventoryKey dimension = new InventoryKey((UUID) row[2], (UUID) row[3]);
            BigDecimal required = decimal(row[6]).multiply(decimal(row[4]))
                    .setScale(4, RoundingMode.CEILING).max(BigDecimal.ZERO);
            BigDecimal stock = decimal(row[9]).subtract(decimal(row[10])).max(BigDecimal.ZERO);
            BigDecimal publicAvailable = publicPools.computeIfAbsent(dimension,
                    ignored -> stock.subtract(decimal(row[11])).subtract(decimal(row[8]))
                            .max(BigDecimal.ZERO));
            boolean external = !"MAKE".equals(row[5]);
            BigDecimal fulfilled = decimal(row[12]).min(required);
            BigDecimal unassigned = required.subtract(fulfilled)
                    .subtract(futureCoverage.getOrDefault(materialId,BigDecimal.ZERO))
                    .max(BigDecimal.ZERO);
            BigDecimal ownQualified = decimal(row[16]).min(required.subtract(fulfilled).max(BigDecimal.ZERO));
            BigDecimal publicAllocated = row[13] == null ? BigDecimal.ZERO
                    : unassigned.subtract(ownQualified).max(BigDecimal.ZERO).min(publicAvailable);
            BigDecimal allocated = external
                    ? fulfilled.add(ownQualified).add(publicAllocated)
                    : decimal(row[14]).min(required);
            if (external) publicPools.put(dimension, publicAvailable.subtract(publicAllocated));
            em.createNativeQuery("""
                    UPDATE production_material_analysis_materials SET active=TRUE,
                      required_qty=:required,available_qty=:stock,reserved_qty=:reserved,
                      safety_stock_qty=:safety,allocated_available_qty=:allocated,
                      allocated_start_qty=:allocated,allocated_finish_qty=:allocated,
                      allocated_ship_qty=:allocated,shortage_qty=:shortage,
                      inbound_qty=:inbound,updated_at=now()
                    WHERE id=:id
                    """).setParameter("required", required).setParameter("stock", stock)
                    .setParameter("reserved", decimal(row[10])).setParameter("safety", decimal(row[8]))
                    .setParameter("allocated", allocated).setParameter("shortage", required.subtract(allocated))
                    .setParameter("inbound", external
                            ? futureCoverage.getOrDefault(materialId,BigDecimal.ZERO)
                            : decimal(row[15]))
                    .setParameter("id", materialId).executeUpdate();
        }
        em.createNativeQuery("""
                UPDATE production_material_analysis_items item
                SET ready_now_qty=0,ready_by_date_qty=0,ready_start_qty=0,ready_finish_qty=0,ready_ship_qty=0
                FROM production_material_analysis_materials root
                WHERE item.analysis_id=:id AND root.id=item.root_material_id
                  AND COALESCE(root.confirmed_route,'MAKE')<>'MAKE'
                """).setParameter("id",analysisId).executeUpdate();
        em.createNativeQuery("""
                UPDATE production_material_analyses analysis
                SET status=fn_material_analysis_fulfillment_status(analysis.id)
                WHERE analysis.id=:analysisId AND analysis.status<>'CANCELLED'
                """).setParameter("analysisId", analysisId).executeUpdate();
    }

    /** Explicit notify may allocate existing stock before creating only the external shortage. */
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean fulfillExisting(UUID analysisId, Collection<UUID> materialIds, String key) {
        boolean changed = false;
        for (UUID materialId : materialIds.stream().distinct().sorted().toList()) {
            Root root = lockRoot(materialId);
            if (root == null || root.salesOrderItemId() == null
                    || !root.analysisId().equals(analysisId) || "MAKE".equals(root.route())) continue;
            if (!root.salesSourceEligible()) {
                throw conflict("销售订单暂不能新增安排，请先完成财务确认并核对订单状态");
            }
            // An arrival during a sales amendment keeps its existing exact lot.
            // Once the source is approved again, hand over that same lot before
            // considering unreserved public stock or creating another order.
            if (fulfillWaitingOrigins(root)) {
                changed = true;
                root = lockRoot(materialId);
            }
            String command = "ROOT-STOCK:" + key + ":" + materialId;
            if (exists(command)) continue;
            BigDecimal qty = root.allocated().min(root.remainingBase());
            if (qty.signum() <= 0) continue;
            BigDecimal available = decimal(em.createNativeQuery("""
                    SELECT GREATEST(COALESCE(balance.qty,0)-COALESCE((
                      SELECT SUM(r.qty-r.consumed_qty-r.released_qty) FROM stock_reservations r
                      WHERE r.goods_id=:goodsId AND r.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                        AND (r.warehouse_id=:warehouseId OR r.warehouse_id IS NULL)
                        AND r.status=0 AND r.is_deleted=FALSE),0),0)
                    FROM stock_balances balance WHERE balance.goods_id=:goodsId
                      AND balance.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                      AND balance.warehouse_id=:warehouseId
                    """).setParameter("goodsId", root.goodsId()).setParameter("colorId", root.colorId())
                    .setParameter("warehouseId", root.warehouseId()).getResultStream().findFirst()
                    .orElse(BigDecimal.ZERO));
            if (available.compareTo(qty) < 0) throw conflict("根产品现货已变化，请重新分析后下达");
            transfer(root, qty, null, null, null, null, command);
            changed = true;
        }
        return changed;
    }

    /** Called after an exact IQC origin was recorded, in the same stock-in transaction. */
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean fulfillOrigin(UUID originId) {
        List<Object[]> origins = rows("""
                SELECT e.beneficiary_analysis_material_id,e.stock_reservation_id,
                  e.source_receipt_type,e.source_receipt_id
                FROM preplan_stock_entitlement_events e
                JOIN production_material_analysis_materials m ON m.id=e.beneficiary_analysis_material_id
                WHERE e.id=:id AND m.node_role='ROOT_SUPPLY'
                """, "id", originId);
        if (origins.isEmpty()) return false;
        Object[] origin = origins.getFirst();
        Root root = lockRoot((UUID) origin[0]);
        if (root == null || "MAKE".equals(root.route())) throw conflict("根产品供给路线已变化，不能入库交接");
        String key = "ROOT-IQC:" + originId;
        if (exists(key)) return true;
        if (!root.salesSourceEligible()) return false;
        var lot = entitlement.listAvailableBeneficiaryLots(root.analysisId(), root.materialId(),
                root.warehouseId(), root.goodsId(), root.colorId(), true).stream()
                .filter(value -> value.entitlementEventId().equals(originId)).findFirst()
                .orElseThrow(() -> conflict("根产品合格权益不存在或已被使用"));
        transferQualifiedLot(root, lot, (String) origin[2], (UUID) origin[3], key);
        return true;
    }

    private boolean fulfillWaitingOrigins(Root initial) {
        List<PreplanStockEntitlementService.AvailableLot> lots = entitlement
                .listAvailableBeneficiaryLots(initial.analysisId(), initial.materialId(),
                        initial.warehouseId(), initial.goodsId(), initial.colorId(), true)
                .stream().filter(lot -> "ORIGIN_IQC".equals(lot.originEventType())
                        || "ORIGIN_MAKE".equals(lot.originEventType())).toList();
        if (lots.isEmpty()) return false;
        Map<UUID, Object[]> origins = new HashMap<>();
        NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT origin.id,origin.source_receipt_type,origin.source_receipt_id,
                    EXISTS(SELECT 1 FROM preplan_root_output_events output
                        WHERE output.idempotency_key='ROOT-IQC:'||origin.id::text)
                FROM preplan_stock_entitlement_events origin WHERE origin.id IN (:ids)
                """).setParameter("ids", lots.stream()
                        .map(PreplanStockEntitlementService.AvailableLot::entitlementEventId).toList()))
                .forEach(row -> origins.put((UUID) row[0], row));
        Root root = initial;
        boolean changed = false;
        for (var lot : lots) {
            String key = "ROOT-IQC:" + lot.entitlementEventId();
            Object[] origin = origins.get(lot.entitlementEventId());
            if (origin == null) throw conflict("原合格入库来源已变化，请刷新后重试");
            if (Boolean.TRUE.equals(origin[3])) continue;
            transferQualifiedLot(root, lot, (String) origin[1], (UUID) origin[2], key);
            root = root.afterHandoff(lot.remainingQty());
            changed = true;
        }
        return changed;
    }

    private void transferQualifiedLot(Root root, PreplanStockEntitlementService.AvailableLot lot,
            String receiptType, UUID receiptId, String key) {
        BigDecimal qty = lot.remainingQty();
        if (qty.compareTo(root.remainingBase()) > 0) throw conflict("根产品合格入库超过剩余来源数量");
        UUID releaseId = entitlement.appendReleaseLot(UUID.randomUUID(), lot, qty, null, key + ":RELEASE");
        int released = em.createNativeQuery("""
                UPDATE stock_reservations SET released_qty=released_qty+:qty,
                  status=CASE WHEN qty-consumed_qty-released_qty-:qty=0 THEN 1 ELSE 0 END,
                  release_reason='ROOT_SUPPLY_HANDOFF',updated_at=now()
                WHERE id=:id AND qty-consumed_qty-released_qty>=:qty AND status=0 AND is_deleted=FALSE
                """).setParameter("qty", qty).setParameter("id", lot.stockReservationId()).executeUpdate();
        if (released != 1) throw conflict("根产品入库权益已被并发使用");
        transfer(root, qty, lot.stockReservationId(), releaseId, receiptType, receiptId, key);
    }


    public void addOutputReferences(UUID analysisId,
            Map<UUID,List<MaterialAnalysisContracts.DownstreamReference>> references) {
        for (Object[] row : rows("""
                SELECT e.root_material_id,e.id,e.route,e.qty_base,
                  CASE WHEN EXISTS(SELECT 1 FROM preplan_root_output_events rev WHERE rev.reversed_event_id=e.id)
                       THEN 'REVERSED' ELSE 'COMPLETED' END,
                  CASE WHEN e.source_receipt_id IS NULL THEN 'ROOT_STOCK_ALLOCATION'
                       ELSE 'ROOT_OUTPUT_FULFILLMENT' END
                FROM preplan_root_output_events e WHERE e.analysis_id=:id AND e.event_kind='FULFILL'
                ORDER BY e.created_at,e.id
                ""","id",analysisId)) {
            references.computeIfAbsent((UUID)row[0],ignored -> new java.util.ArrayList<>()).add(
                new MaterialAnalysisContracts.DownstreamReference(null,(String)row[2],(String)row[4],
                    (String)row[5],(UUID)row[1],null,decimal(row[3])));
        }
    }

    public boolean hasReversibleExistingOutput(UUID analysisId) {
        return !em.createNativeQuery("""
                SELECT e.id FROM preplan_root_output_events e
                JOIN stock_reservations r ON r.id=e.sales_reservation_id
                WHERE e.analysis_id=:id AND e.event_kind='FULFILL' AND e.source_receipt_id IS NULL
                  AND r.consumed_qty=0 AND r.released_qty=0 AND r.is_deleted=FALSE
                  AND NOT EXISTS(SELECT 1 FROM preplan_root_output_events rev WHERE rev.reversed_event_id=e.id)
                  AND NOT EXISTS(SELECT 1 FROM sales_shipment_items item
                    JOIN sales_shipments shipment ON shipment.id=item.shipment_id
                    WHERE item.order_item_id=e.sales_order_item_id AND item.is_deleted=FALSE
                      AND shipment.is_deleted=FALSE AND shipment.status=0
                      AND shipment.warehouse_id=e.warehouse_id
                      AND shipment.warehouse_work_status IN ('PICKING','PICKED'))
                LIMIT 1
                """).setParameter("id",analysisId).getResultList().isEmpty();
    }

    public void requireAnalysisCancellationSafe(UUID analysisId) {
        if (!em.createNativeQuery("""
                SELECT e.id FROM preplan_root_output_events e WHERE e.analysis_id=:id
                  AND e.event_kind='FULFILL'
                  AND NOT EXISTS(SELECT 1 FROM preplan_root_output_events rev WHERE rev.reversed_event_id=e.id)
                LIMIT 1
                """).setParameter("id",analysisId).getResultList().isEmpty()) {
            throw conflict("根产品已有产出交接，请先撤回现货交接或红冲来源入库，再取消分析");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void revokeExistingOutput(UUID analysisId,UUID eventId,String reason) {
        List<?> found=em.createNativeQuery("""
                SELECT id FROM preplan_root_output_events e WHERE id=:eventId AND analysis_id=:analysisId
                  AND event_kind='FULFILL' AND source_receipt_id IS NULL
                  AND NOT EXISTS(SELECT 1 FROM preplan_root_output_events rev WHERE rev.reversed_event_id=e.id)
                """).setParameter("eventId",eventId).setParameter("analysisId",analysisId).getResultList();
        if (found.isEmpty()) throw conflict("现货交接不存在、已撤回或必须由来源入库红冲");
        reverse(eventId,reason);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseReceipt(String receiptType, UUID receiptId) {
        List<UUID> eventIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT e.id FROM preplan_root_output_events e
                WHERE e.event_kind='FULFILL' AND e.source_receipt_type=:type AND e.source_receipt_id=:id
                  AND NOT EXISTS (SELECT 1 FROM preplan_root_output_events rev WHERE rev.reversed_event_id=e.id)
                ORDER BY e.analysis_item_id,e.id
                """, UUID.class).setParameter("type", receiptType).setParameter("id", receiptId), UUID.class);
        for (UUID id : eventIds) reverse(id, "来源入库红冲");
    }

    private void reverse(UUID eventId,String reason) {
        Object[] event = rows("""
                SELECT root_material_id,sales_reservation_id,qty_base FROM preplan_root_output_events
                WHERE id=:id FOR UPDATE
                """, "id", eventId).getFirst();
        Root root = lockRoot((UUID) event[0]);
        if (root == null) throw conflict("根产品交接来源丢失");
        BigDecimal before = fulfilled(root.itemId());
        UUID salesReservationId = (UUID) event[1];
        if (salesReservationId != null) {
            requireNoPicking(root);
            int changed = em.createNativeQuery("""
                    UPDATE stock_reservations SET released_qty=qty,status=1,updated_at=now()
                    WHERE id=:id AND consumed_qty=0 AND released_qty=0 AND is_deleted=FALSE
                    """).setParameter("id", salesReservationId).executeUpdate();
            if (changed != 1) throw conflict("根产品供给已发货或已释放，不能直接红冲入库");
        }
        em.createNativeQuery("""
                INSERT INTO preplan_root_output_events(
                  analysis_id,analysis_item_id,root_material_id,event_kind,reversed_event_id,
                  warehouse_id,goods_id,color_id,qty_base,source_reservation_id,
                  release_entitlement_event_id,sales_order_item_id,sales_reservation_id,
                  source_receipt_type,source_receipt_id,idempotency_key,created_by,route,reason)
                SELECT analysis_id,analysis_item_id,root_material_id,'REVERSE',id,
                  warehouse_id,goods_id,color_id,qty_base,source_reservation_id,
                  release_entitlement_event_id,sales_order_item_id,sales_reservation_id,
                  source_receipt_type,source_receipt_id,'ROOT-REVERSE:'||id::text,:actor,route,:reason
                FROM preplan_root_output_events WHERE id=:id
                """).setParameter("actor", currentUser.requireId()).setParameter("id", eventId)
                .setParameter("reason",reason).executeUpdate();
        updateSalesReserved(root, fulfilled(root.itemId()).subtract(before));
        em.createNativeQuery("""
                UPDATE production_material_analyses SET status='ACTIVE',updated_at=now()
                WHERE id=:id AND status='COMPLETED'
                """).setParameter("id", root.analysisId()).executeUpdate();
    }

    private void transfer(Root root, BigDecimal qty, UUID sourceReservation, UUID releaseEvent,
                          String receiptType, UUID receiptId, String key) {
        BigDecimal before = fulfilled(root.itemId());
        UUID saleReservation = null;
        if (root.salesOrderItemId() != null) {
            StockReservation reservation = salesReservations.reserve(root.salesOrderItemId(), root.goodsId(),
                    root.colorId(), root.warehouseId(), qty, StockReservation.SOURCE_ORDER,
                    "ROOT_SUPPLY_INBOUND", root.itemId());
            em.flush();
            saleReservation = reservation.getId();
        }
        em.createNativeQuery("""
                INSERT INTO preplan_root_output_events(
                  analysis_id,analysis_item_id,root_material_id,event_kind,warehouse_id,goods_id,color_id,
                  qty_base,source_reservation_id,release_entitlement_event_id,sales_order_item_id,
                  sales_reservation_id,source_receipt_type,source_receipt_id,idempotency_key,created_by,route)
                VALUES(:analysis,:item,:material,'FULFILL',:warehouse,:goods,:color,:qty,
                  :reservation,:release,:salesItem,:salesReservation,:receiptType,:receipt,:key,:actor,:route)
                """).setParameter("analysis", root.analysisId()).setParameter("item", root.itemId())
                .setParameter("material", root.materialId()).setParameter("warehouse", root.warehouseId())
                .setParameter("goods", root.goodsId()).setParameter("color", root.colorId()).setParameter("qty", qty)
                .setParameter("reservation", sourceReservation).setParameter("release", releaseEvent)
                .setParameter("salesItem", root.salesOrderItemId()).setParameter("salesReservation", saleReservation)
                .setParameter("receiptType", receiptType).setParameter("receipt", receiptId)
                .setParameter("key", key).setParameter("actor", currentUser.requireId())
                .setParameter("route",root.route()).executeUpdate();
        updateSalesReserved(root, fulfilled(root.itemId()).subtract(before));
    }

    private void updateSalesReserved(Root root, BigDecimal delta) {
        if (root.salesOrderItemId() == null || delta.signum()==0) return;
        int updated = em.createNativeQuery("""
                UPDATE sales_order_items item SET reserved_qty=reserved_qty+:delta,
                  chain_status=CASE
                    WHEN reserved_qty+:delta>=qty-COALESCE(shipped_qty,0)+COALESCE(returned_qty,0)-COALESCE(flag_qty,0) THEN 7
                    WHEN reserved_qty+:delta>0 THEN 1
                    WHEN COALESCE(planned_qty,0)>COALESCE(produced_qty,0) THEN 4 ELSE 2 END,
                  updated_at=now()
                WHERE item.id=:id AND item.is_deleted=FALSE AND reserved_qty+:delta>=0
                  AND (:delta<=0 OR reserved_qty+:delta<=
                    qty-COALESCE(shipped_qty,0)+COALESCE(returned_qty,0)-COALESCE(flag_qty,0)
                    -GREATEST(COALESCE(planned_qty,0)-COALESCE(produced_qty,0),0)
                    -COALESCE((SELECT SUM(pi.qty) FROM production_plan_items pi
                      JOIN production_plans p ON p.id=pi.plan_id WHERE pi.sales_order_item_id=item.id
                        AND pi.is_deleted=FALSE AND p.is_deleted=FALSE AND p.status=0 AND p.is_canceled=FALSE),0))
                """).setParameter("delta", delta).setParameter("id", root.salesOrderItemId()).executeUpdate();
        if (updated!=1) throw conflict("根产品供给与销售剩余数量不一致，事务已回滚");
    }

    private void requireNoPicking(Root root) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM sales_shipment_items item JOIN sales_shipments shipment ON shipment.id=item.shipment_id
                WHERE item.order_item_id=:orderItem AND item.is_deleted=FALSE
                  AND shipment.is_deleted=FALSE AND shipment.status=0
                  AND shipment.warehouse_id=:warehouse
                  AND shipment.warehouse_work_status IN ('PICKING','PICKED')
                """).setParameter("orderItem", root.salesOrderItemId())
                .setParameter("warehouse", root.warehouseId()).getSingleResult();
        if (count.longValue()>0) throw conflict("根产品已进入销售拣货，请先撤回仓库拣货再红冲供给");
    }

    private Root lockRoot(UUID materialId) {
        List<Object[]> matches = rows("""
                SELECT item.analysis_id,item.id,root.id,item.goods_id,item.color_id,analysis.warehouse_id,
                  item.sales_order_item_id,COALESCE(root.confirmed_route,'MAKE'),root.allocated_available_qty,
                  GREATEST(CEIL((item.requested_qty-item.submitted_qty-item.approved_qty)
                    *root.per_product_qty*10000)/10000-COALESCE((
                      SELECT SUM(CASE WHEN event_kind='FULFILL' THEN qty_base ELSE -qty_base END)
                      FROM preplan_root_output_events e WHERE e.analysis_item_id=item.id),0),0)
                FROM production_material_analysis_items item
                JOIN production_material_analysis_materials root ON root.id=item.root_material_id
                JOIN production_material_analyses analysis ON analysis.id=item.analysis_id
                WHERE root.id=:id AND item.is_deleted=FALSE AND analysis.is_deleted=FALSE
                """, "id", materialId);
        if (matches.isEmpty()) return null;
        Object[] row = matches.getFirst();
        inventoryLock.lock(new InventoryKey((UUID) row[3], (UUID) row[4]));
        em.createNativeQuery("SELECT id FROM production_material_analyses WHERE id=:id FOR UPDATE")
                .setParameter("id", row[0]).getSingleResult();
        em.createNativeQuery("SELECT id FROM production_material_analysis_items WHERE id=:id FOR UPDATE")
                .setParameter("id", row[1]).getSingleResult();
        boolean salesEligible = true;
        if (row[6]!=null) {
            List<Object[]> locked = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT item.id, (NOT item.is_deleted AND NOT document.is_deleted
                      AND document.status=1 AND document.finance_confirmed=TRUE
                      AND NOT COALESCE(document.is_stopped,FALSE) AND NOT document.is_closed)
                    FROM sales_order_items item JOIN sales_orders document ON document.id=item.order_id
                    WHERE item.id=:id
                    FOR UPDATE OF document,item
                    """).setParameter("id", row[6]));
            if (locked.isEmpty()) throw conflict("根产品原销售来源丢失，请先核对关联");
            salesEligible = Boolean.TRUE.equals(locked.getFirst()[1]);
        }
        Object[] current=rows("""
                SELECT root.allocated_available_qty,
                  GREATEST(CEIL((item.requested_qty-item.submitted_qty-item.approved_qty)
                    *root.per_product_qty*10000)/10000-COALESCE((
                      SELECT SUM(CASE WHEN event_kind='FULFILL' THEN qty_base ELSE -qty_base END)
                      FROM preplan_root_output_events e WHERE e.analysis_item_id=item.id),0),0)
                FROM production_material_analysis_items item
                JOIN production_material_analysis_materials root ON root.id=item.root_material_id
                WHERE item.id=:id
                ""","id",row[1]).getFirst();
        row[8]=current[0];
        row[9]=current[1];
        return new Root((UUID) row[0],(UUID) row[1],(UUID) row[2],(UUID) row[3],(UUID) row[4],
                (UUID) row[5],(UUID) row[6],(String) row[7],decimal(row[8]),decimal(row[9]),salesEligible);
    }

    private BigDecimal fulfilled(UUID itemId) {
        return decimal(em.createNativeQuery("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=:id")
                .setParameter("id",itemId).getSingleResult());
    }
    private boolean exists(String key) {
        return !em.createNativeQuery("SELECT id FROM preplan_root_output_events WHERE idempotency_key=:key")
                .setParameter("key",key).getResultList().isEmpty();
    }
    private List<Object[]> rows(String sql,String parameter,Object value) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter(parameter,value));
    }
    private static BigDecimal decimal(Object value) {
        return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());
    }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
    private record Root(UUID analysisId,UUID itemId,UUID materialId,UUID goodsId,UUID colorId,UUID warehouseId,
                        UUID salesOrderItemId,String route,BigDecimal allocated,BigDecimal remainingBase,
                        boolean salesSourceEligible) {
        Root afterHandoff(BigDecimal qty) {
            return new Root(analysisId,itemId,materialId,goodsId,colorId,warehouseId,salesOrderItemId,
                    route,allocated,remainingBase.subtract(qty),salesSourceEligible);
        }
    }
}
