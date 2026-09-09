package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Stock-module facade for production material allocation.
 *
 * <p>Every quantity is a base-unit quantity. The caller owns the production
 * demand, while this facade is the only normal write path for physical stock
 * allocations. All goods/color advisory locks are acquired in stable order
 * before balance or reservation rows are locked.
 */
@Service
@RequiredArgsConstructor
public class ProductionMaterialAllocationFacade {

    private static final short STATUS_EFFECTIVE = 0;
    private static final short STATUS_DONE = 1;
    private static final short SOURCE_PRODUCTION_MATERIAL = 2;

    private final EntityManager em;
    private final InventoryMutationLock inventoryLock;
    private final TxSessionVars tx;

    @Transactional(propagation = Propagation.MANDATORY)
    public void lockDimensions(Collection<AllocationRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        lockMaterialDimensions(requests.stream()
                .map(request -> new MaterialDimension(
                        request.goodsId(), request.colorId()))
                .toList());
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void lockMaterialDimensions(Collection<MaterialDimension> dimensions) {
        if (dimensions == null || dimensions.isEmpty()) {
            return;
        }
        inventoryLock.lockAll(dimensions.stream()
                .map(dimension -> new InventoryKey(
                        dimension.goodsId(), dimension.colorId()))
                .toList());
    }

    /**
     * Allocates normal physical leaves inside the selected main warehouse.
     * Existing unsuffixed reservation keys remain readable for replay compatibility.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public List<AllocationResult> allocate(List<AllocationRequest> requests) {
        tx.bind();
        if (requests == null || requests.isEmpty()) {
            return List.of();
        }
        validateRequests(requests);
        lockDimensions(requests);
        lockDemandRows(requests);
        AllocationBatch batch = allocationBatch(requests, Map.of());

        List<AllocationRequest> ordered = requests.stream()
                .sorted(Comparator
                        .comparing((AllocationRequest r) ->
                                new InventoryKey(r.goodsId(), r.colorId()))
                        .thenComparing(AllocationRequest::warehouseId)
                        .thenComparing(AllocationRequest::demandId))
                .toList();
        List<AllocationResult> results = new ArrayList<>(ordered.size());
        for (AllocationRequest request : ordered) {
            BigDecimal remaining = request.requiredQty();
            List<UUID> warehouses = new ArrayList<>(batch.normalFor(request.warehouseId()));
            if (warehouses.remove(request.warehouseId()) || batch.replays.containsKey(request.idempotencyKey()))
                warehouses.addFirst(request.warehouseId());
            for (UUID warehouse : warehouses) {
                if (remaining.signum() <= 0) break;
                AllocationRequest physical = warehouse.equals(request.warehouseId())
                        ? new AllocationRequest(request.packageId(), request.demandId(), request.goodsId(),
                                request.colorId(), warehouse, remaining, request.idempotencyKey(), request.actorId())
                        : withWarehouse(request, warehouse, remaining, "STOCK");
                AllocationResult result = allocateOne(physical, BigDecimal.ZERO, false, batch);
                if (result.allocatedQty().signum() > 0) {
                    results.add(result); remaining = remaining.subtract(result.allocatedQty());
                }
            }
        }
        return results;
    }

    /** Keeps every physical reservation in its actual leaf warehouse. */
    @Transactional(propagation = Propagation.MANDATORY)
    public List<AllocationResult> allocateWithinMainWarehouse(
            List<AllocationRequest> requests,
            List<AllocationPreference> preferences) {
        tx.bind();
        if (requests == null || requests.isEmpty()) return List.of();
        validateRequests(requests);
        lockDimensions(requests);
        lockDemandRows(requests);
        Map<DemandWarehouse, OwnedSlice> prepared = new LinkedHashMap<>();
        if (preferences != null) for (AllocationPreference value : preferences) {
            if (value != null && value.warehouseId()!=null && value.qty()!=null && value.qty().signum()>0
                    && requests.stream().anyMatch(request -> request.demandId().equals(value.demandId())))
                prepared.merge(new DemandWarehouse(value.demandId(), value.warehouseId()),
                        new OwnedSlice(value.qty(), BigDecimal.ZERO), (left,right) ->
                                new OwnedSlice(left.qty().add(right.qty()), BigDecimal.ZERO));
        }
        AllocationBatch batch = allocationBatch(requests, prepared);
        List<AllocationResult> results = new ArrayList<>();
        for (AllocationRequest request : requests.stream()
                .sorted(Comparator.comparing(AllocationRequest::demandId)).toList()) {
            List<UUID> warehouses = batch.normalFor(request.warehouseId());
            BigDecimal remaining = request.requiredQty();
            Map<UUID, BigDecimal> owned = new LinkedHashMap<>();
            if (preferences != null) {
                preferences.stream()
                        .filter(value -> request.demandId().equals(value.demandId())
                                && value.warehouseId() != null
                                && value.qty() != null && value.qty().signum() > 0)
                        .sorted(Comparator.comparing(AllocationPreference::warehouseId))
                        .forEach(value -> owned.merge(
                                value.warehouseId(), value.qty(), BigDecimal::add));
            }
            BigDecimal outstandingOwned = owned.values().stream()
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (outstandingOwned.compareTo(remaining) > 0) {
                throw new ApiException(ErrorCode.CONFLICT, "分析备料权益超出本段需求");
            }
            for (Map.Entry<UUID, BigDecimal> entry : owned.entrySet()) {
                if (!warehouses.contains(entry.getKey())
                        || entry.getValue().compareTo(remaining) > 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "分析备料权益超出本段需求或所在主仓范围");
                }
                outstandingOwned = outstandingOwned.subtract(entry.getValue());
                batch.releaseOwned(request, entry.getKey());
                // One demand/stock-balance pair has one reservation. Include
                // this leaf's public stock without using another leaf's owned slice.
                AllocationResult result = allocateOne(withWarehouse(
                        request, entry.getKey(), remaining.subtract(outstandingOwned), "OWN"), BigDecimal.ZERO, false, batch);
                if (result.allocatedQty().compareTo(entry.getValue()) < 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "分析备料权益所在子仓可用库存不足，请刷新后重试");
                }
                results.add(withWarehouse(result, entry.getKey()));
                remaining = remaining.subtract(result.allocatedQty());
            }
            for (UUID warehouseId : warehouses) {
                if (remaining.signum() <= 0) break;
                if (owned.containsKey(warehouseId)) continue;
                AllocationResult result = allocateOne(withWarehouse(
                        request, warehouseId, remaining, "STOCK"), BigDecimal.ZERO, false, batch);
                if (result.allocatedQty().signum() > 0) {
                    results.add(withWarehouse(result, warehouseId));
                    remaining = remaining.subtract(result.allocatedQty());
                }
            }
        }
        return List.copyOf(results);
    }

    /**
     * Allocates freshly prepared, source-bound stock in its actual warehouse.
     * The caller formalizes these exact source slices in the same transaction.
     * Special-warehouse targets require a complete deferred FORMALIZE proof;
     * ordinary public stock keeps the existing normal/same-main warehouse rules.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public List<AllocationResult> allocateWithQualifiedSources(
            List<AllocationRequest> requests, List<QualifiedSourcePreference> preferences) {
        tx.bind();
        if (requests == null || requests.isEmpty()) return List.of();
        validateRequests(requests);
        lockDimensions(requests);
        lockDemandRows(requests);
        List<QualifiedSourcePreference> sources = preferences == null ? List.of() : List.copyOf(preferences);
        Map<SourceDemandKey, SourceProof> proofs = verifyPreparedSources(requests, sources);
        Map<DemandWarehouse, OwnedSlice> prepared = new LinkedHashMap<>();
        for (QualifiedSourcePreference source : sources) {
            SourceProof proof = proofs.get(new SourceDemandKey(source.sourceEntitlementEventId(), source.demandId()));
            prepared.merge(new DemandWarehouse(source.demandId(), source.warehouseId()),
                    new OwnedSlice(source.qty(), proof.qualified() ? source.qty() : BigDecimal.ZERO),
                    (left,right) -> new OwnedSlice(left.qty().add(right.qty()), left.qualifiedQty().add(right.qualifiedQty())));
        }
        AllocationBatch batch = allocationBatch(requests, prepared);
        List<AllocationResult> results = new ArrayList<>();
        for (AllocationRequest request : requests.stream()
                .sorted(Comparator.comparing(value -> value.demandId().toString())).toList()) {
            List<UUID> normal = batch.normalFor(request.warehouseId());
            Map<UUID, OwnedSlice> owned = new LinkedHashMap<>();
            for (QualifiedSourcePreference source : sources.stream()
                    .filter(value -> request.demandId().equals(value.demandId()))
                    .sorted(Comparator.comparing(value -> value.warehouseId().toString())).toList()) {
                SourceProof proof = proofs.get(new SourceDemandKey(source.sourceEntitlementEventId(), source.demandId()));
                OwnedSlice before = owned.getOrDefault(source.warehouseId(), new OwnedSlice(BigDecimal.ZERO, BigDecimal.ZERO));
                owned.put(source.warehouseId(), new OwnedSlice(before.qty().add(source.qty()),
                        before.qualifiedQty().add(proof.qualified() ? source.qty() : BigDecimal.ZERO)));
            }
            BigDecimal remaining = request.requiredQty();
            BigDecimal outstanding = owned.values().stream().map(OwnedSlice::qty).reduce(BigDecimal.ZERO, BigDecimal::add);
            if (outstanding.compareTo(remaining) > 0) throw allocationConflict("本批来源物料数量超过工单需求");
            for (var entry : owned.entrySet()) {
                OwnedSlice slice = entry.getValue();
                boolean requiresProof = !normal.contains(entry.getKey());
                if (requiresProof && slice.qualifiedQty().compareTo(slice.qty()) != 0)
                    throw allocationConflict("跨原仓库领料必须有本单据已验收合格的入库来源");
                outstanding = outstanding.subtract(slice.qty());
                batch.releaseOwned(request, entry.getKey());
                BigDecimal limit = requiresProof ? slice.qty() : remaining.subtract(outstanding);
                AllocationResult result = allocateOne(withWarehouse(request, entry.getKey(), limit, "OWN"),
                        slice.qualifiedQty(), requiresProof, batch);
                if (result.allocatedQty().compareTo(slice.qty()) < 0)
                    throw allocationConflict("本批物料所在仓库的实际可用数量已变化，请刷新后重试");
                results.add(withWarehouse(result, entry.getKey()));
                remaining = remaining.subtract(result.allocatedQty());
            }
            for (UUID warehouseId : normal) {
                if (remaining.signum() <= 0) break;
                if (owned.containsKey(warehouseId)) continue;
                AllocationResult result = allocateOne(withWarehouse(request, warehouseId, remaining, "STOCK"), BigDecimal.ZERO, false, batch);
                if (result.allocatedQty().signum() > 0) {
                    results.add(withWarehouse(result, warehouseId));
                    remaining = remaining.subtract(result.allocatedQty());
                }
            }
        }
        return List.copyOf(results);
    }

    private Map<SourceDemandKey, SourceProof> verifyPreparedSources(
            List<AllocationRequest> requests, List<QualifiedSourcePreference> sources) {
        Map<UUID, AllocationRequest> byDemand = new LinkedHashMap<>();
        for (AllocationRequest request : requests) {
            if (byDemand.put(request.demandId(), request) != null)
                throw allocationConflict("同一物料需求不能重复分配");
        }
        if (sources.isEmpty()) return Map.of();
        Map<UUID, BigDecimal> claimed = new LinkedHashMap<>();
        Map<UUID, BigDecimal> releasedClaims = new LinkedHashMap<>();
        for (QualifiedSourcePreference source : sources) {
            if (source == null || source.sourceEntitlementEventId() == null || source.sourceStockReservationId() == null
                    || source.demandId() == null || !byDemand.containsKey(source.demandId())
                    || source.warehouseId() == null || source.qty() == null || source.qty().signum() <= 0)
                throw allocationConflict("本批物料缺少可核对的来源或实际仓库");
            claimed.merge(source.sourceEntitlementEventId(), source.qty(), BigDecimal::add);
            releasedClaims.merge(source.sourceStockReservationId(), source.qty(), BigDecimal::add);
        }
        Map<SourceDemandKey, SourceProof> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT lot.entitlement_event_id, lot.stock_reservation_id, reservation.warehouse_id,
                       reservation.goods_id, reservation.color_id, lot.remaining_qty,
                       fn_preplan_reservation_has_qualified_origin(reservation.id), demand.id,
                       demand.package_id, demand.warehouse_id, reservation.released_qty
                FROM v_preplan_stock_entitlement_lot_balance lot
                JOIN stock_reservations reservation ON reservation.id=lot.stock_reservation_id
                  AND reservation.is_deleted=FALSE AND reservation.owner_type='PREPLAN_ANALYSIS'
                JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id
                  AND warehouse.is_deleted=FALSE AND warehouse.is_accountable=TRUE
                  AND COALESCE(warehouse.status,'')<>'禁用'
                  AND NOT EXISTS(SELECT 1 FROM warehouses child
                      WHERE child.parent_id=warehouse.id AND child.is_deleted=FALSE)
                JOIN production_material_demands demand ON demand.id IN (:demands)
                  AND demand.is_deleted=FALSE AND demand.goods_id=reservation.goods_id
                  AND demand.color_id IS NOT DISTINCT FROM reservation.color_id
                JOIN production_plans plan ON plan.id=demand.plan_id
                  AND plan.material_analysis_id=lot.beneficiary_analysis_id
                  AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,lot.beneficiary_analysis_material_id)
                WHERE lot.entitlement_event_id IN (:sources)
                ORDER BY lot.entitlement_event_id,demand.id
                """).setParameter("sources", claimed.keySet()).setParameter("demands", byDemand.keySet()))) {
            UUID source = (UUID) row[0], demand = (UUID) row[7];
            AllocationRequest request = byDemand.get(demand);
            if (!request.packageId().equals(row[8]) || !request.warehouseId().equals(row[9])
                    || !request.goodsId().equals(row[3]) || !Objects.equals(request.colorId(), row[4])) continue;
            result.put(new SourceDemandKey(source, demand), new SourceProof((UUID) row[1], (UUID) row[2],
                    decimal(row[5]), decimal(row[10]), Boolean.TRUE.equals(row[6])));
        }
        for (QualifiedSourcePreference source : sources) {
            SourceProof proof = result.get(new SourceDemandKey(source.sourceEntitlementEventId(), source.demandId()));
            if (proof == null || !proof.reservationId().equals(source.sourceStockReservationId())
                    || !proof.warehouseId().equals(source.warehouseId())
                    || claimed.get(source.sourceEntitlementEventId()).compareTo(proof.remainingQty()) > 0
                    || releasedClaims.get(source.sourceStockReservationId()).compareTo(proof.releasedQty()) > 0)
                throw allocationConflict("本批来源、所属工单或可用数量已变化，不能借用其他任务的物料");
        }
        return result;
    }

    private static ApiException allocationConflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
    private record SourceDemandKey(UUID sourceEventId, UUID demandId) {}
    private record SourceProof(UUID reservationId, UUID warehouseId, BigDecimal remainingQty,
                               BigDecimal releasedQty, boolean qualified) {}
    private record OwnedSlice(BigDecimal qty, BigDecimal qualifiedQty) {}

    private record DemandWarehouse(UUID demandId, UUID warehouseId) {}
    private record LeafKey(UUID warehouseId, MaterialDimension material) {}
    private record GroupKey(UUID mainWarehouseId, MaterialDimension material) {}

    private static final class StockPosition {
        final UUID id;
        final UUID mainWarehouse;
        BigDecimal free;
        StockPosition(UUID id, UUID mainWarehouse, BigDecimal free) {
            this.id = id; this.mainWarehouse = mainWarehouse; this.free = free;
        }
    }

    private static final class AllocationBatch {
        final Map<UUID, UUID> mainByWarehouse = new LinkedHashMap<>();
        final Map<UUID, List<UUID>> normalByMain = new LinkedHashMap<>();
        final java.util.Set<UUID> normalWarehouses = new java.util.HashSet<>();
        final Map<LeafKey, StockPosition> positions = new LinkedHashMap<>();
        final Map<String, Object[]> replays = new LinkedHashMap<>();
        final Map<DemandWarehouse, OwnedSlice> awaiting = new LinkedHashMap<>();
        final Map<LeafKey, BigDecimal> pendingOwned = new LinkedHashMap<>();
        final Map<GroupKey, BigDecimal> pendingUnqualified = new LinkedHashMap<>();
        final Map<GroupKey, BigDecimal> publicRemaining = new LinkedHashMap<>();

        List<UUID> normalFor(UUID warehouse) {
            return normalByMain.getOrDefault(mainByWarehouse.get(warehouse), List.of());
        }

        void releaseOwned(AllocationRequest request, UUID warehouse) {
            OwnedSlice own = awaiting.remove(new DemandWarehouse(request.demandId(), warehouse));
            if (own == null) return; // A replay is already represented by its existing reservation.
            MaterialDimension material = new MaterialDimension(request.goodsId(), request.colorId());
            pendingOwned.merge(new LeafKey(warehouse, material), own.qty().negate(), BigDecimal::add);
            if (normalWarehouses.contains(warehouse)) pendingUnqualified.merge(
                    new GroupKey(mainByWarehouse.get(warehouse), material),
                    own.qty().subtract(own.qualifiedQty()).negate(), BigDecimal::add);
        }
    }

    /** All reads are batched after the existing material/demand locks; no per-leaf lookup loop. */
    private AllocationBatch allocationBatch(List<AllocationRequest> requests,
                                             Map<DemandWarehouse, OwnedSlice> prepared) {
        AllocationBatch batch = new AllocationBatch();
        Map<UUID, AllocationRequest> byDemand = new LinkedHashMap<>();
        java.util.Set<UUID> requestedWarehouses = new java.util.LinkedHashSet<>();
        requests.forEach(request -> { byDemand.put(request.demandId(), request); requestedWarehouses.add(request.warehouseId()); });
        java.util.Set<UUID> selected = new java.util.LinkedHashSet<>(requestedWarehouses);
        prepared.keySet().forEach(source -> selected.add(source.warehouseId()));
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,fn_warehouse_main_id(id) FROM warehouses WHERE id IN (:warehouses) ORDER BY id
                """).setParameter("warehouses", selected))) {
            batch.mainByWarehouse.put((UUID) row[0], (UUID) row[1]);
        }
        java.util.Set<UUID> mains = new java.util.LinkedHashSet<>();
        requestedWarehouses.forEach(warehouse -> {
            UUID main = batch.mainByWarehouse.get(warehouse);
            if (main == null) throw allocationConflict("所选仓库已不存在，请刷新后重试");
            mains.add(main);
        });
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT warehouse.id,fn_warehouse_main_id(warehouse.id)
                FROM warehouses warehouse
                WHERE fn_warehouse_main_id(warehouse.id) IN (:mains)
                  AND NOT warehouse.is_deleted AND warehouse.is_accountable AND NOT warehouse.is_defective
                  AND COALESCE(warehouse.status,'')<>'禁用'
                  AND NOT EXISTS(SELECT 1 FROM warehouses child
                      WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)
                ORDER BY warehouse.id
                """).setParameter("mains", mains))) {
            UUID warehouse = (UUID) row[0], main = (UUID) row[1];
            batch.mainByWarehouse.put(warehouse, main);
            batch.normalWarehouses.add(warehouse);
            batch.normalByMain.computeIfAbsent(main, ignored -> new ArrayList<>()).add(warehouse);
        }
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,demand_id,supply_id,qty,goods_id,color_id,warehouse_id,idempotency_key,requires_qualified_origin
                FROM stock_reservations WHERE demand_id IN (:demands) AND NOT is_deleted
                ORDER BY goods_id,color_id NULLS FIRST,warehouse_id,id FOR UPDATE
                """).setParameter("demands", byDemand.keySet()))) batch.replays.put((String) row[7], row);

        selected.addAll(batch.normalWarehouses);
        java.util.Set<UUID> goods = requests.stream().map(AllocationRequest::goodsId)
                .collect(java.util.stream.Collectors.toSet());
        String identities = requests.stream().map(request -> request.goodsId() + "|"
                        + (request.colorId()==null ? "" : request.colorId().toString()))
                .distinct().sorted().collect(java.util.stream.Collectors.joining(","));
        Map<GroupKey, BigDecimal> freeByMain = new LinkedHashMap<>();
        Map<GroupKey, BigDecimal> safetyByMain = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT balance.id,balance.warehouse_id,balance.goods_id,balance.color_id,
                       balance.qty,COALESCE(reserved.qty,0),GREATEST(COALESCE(goods.min_qty,0),0)::numeric,
                       fn_warehouse_main_id(balance.warehouse_id)
                FROM stock_balances balance JOIN goods ON goods.id=balance.goods_id AND NOT goods.is_deleted
                LEFT JOIN LATERAL (
                    SELECT SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty) AS qty
                    FROM stock_reservations reservation
                    WHERE reservation.goods_id=balance.goods_id
                      AND reservation.color_id IS NOT DISTINCT FROM balance.color_id
                      AND (reservation.warehouse_id IS NULL OR reservation.warehouse_id=balance.warehouse_id)
                      AND NOT reservation.is_deleted AND reservation.status=0
                ) reserved ON TRUE
                WHERE balance.warehouse_id IN (:warehouses) AND balance.goods_id IN (:goods)
                  AND (balance.goods_id::text||'|'||COALESCE(balance.color_id::text,''))
                      =ANY(string_to_array(:identities,','))
                ORDER BY balance.goods_id,balance.color_id NULLS FIRST,balance.warehouse_id,balance.id
                FOR UPDATE OF balance
                """).setParameter("warehouses", selected).setParameter("goods", goods).setParameter("identities", identities))) {
            UUID warehouse = (UUID) row[1], main = (UUID) row[7];
            MaterialDimension dimension = new MaterialDimension((UUID) row[2], (UUID) row[3]);
            BigDecimal free = decimal(row[4]).subtract(decimal(row[5])).max(BigDecimal.ZERO);
            batch.positions.put(new LeafKey(warehouse, dimension), new StockPosition((UUID) row[0], main, free));
            if (batch.normalWarehouses.contains(warehouse)) {
                GroupKey group = new GroupKey(main, dimension);
                freeByMain.merge(group, free, BigDecimal::add);
                safetyByMain.merge(group, decimal(row[6]), BigDecimal::max);
            }
        }
        Map<LeafKey, BigDecimal> qualifiedPending = new LinkedHashMap<>();
        for (var source : prepared.entrySet()) {
            AllocationRequest request = byDemand.get(source.getKey().demandId());
            UUID warehouse = source.getKey().warehouseId();
            if (request == null || batch.replays.containsKey(request.idempotencyKey()+":OWN:"+warehouse)) continue;
            OwnedSlice own = source.getValue();
            MaterialDimension dimension = new MaterialDimension(request.goodsId(), request.colorId());
            LeafKey leaf = new LeafKey(warehouse, dimension);
            batch.awaiting.put(source.getKey(), own);
            batch.pendingOwned.merge(leaf, own.qty(), BigDecimal::add);
            qualifiedPending.merge(leaf, own.qualifiedQty(), BigDecimal::add);
            if (batch.normalWarehouses.contains(warehouse)) batch.pendingUnqualified.merge(
                    new GroupKey(batch.mainByWarehouse.get(warehouse), dimension),
                    own.qty().subtract(own.qualifiedQty()), BigDecimal::add);
        }
        qualifiedPending.forEach((leaf, quantity) -> {
            StockPosition position = batch.positions.get(leaf);
            if (position != null && batch.normalWarehouses.contains(leaf.warehouseId())) freeByMain.merge(
                    new GroupKey(position.mainWarehouse, leaf.material()), quantity.min(position.free).negate(), BigDecimal::add);
        });
        freeByMain.forEach((group, quantity) -> batch.publicRemaining.put(group,
                com.uten.imp.common.inventory.MainWarehouseStockBudget.publicBudget(quantity, safetyByMain.get(group))));
        return batch;
    }

    private static AllocationRequest withWarehouse(
            AllocationRequest request, UUID warehouseId, BigDecimal qty,
            String source) {
        return new AllocationRequest(request.packageId(), request.demandId(),
                request.goodsId(), request.colorId(), warehouseId, qty,
                request.idempotencyKey() + ":" + source + ":" + warehouseId,
                request.actorId());
    }

    private static AllocationResult withWarehouse(
            AllocationResult result, UUID warehouseId) {
        return new AllocationResult(result.demandId(), result.allocationId(),
                result.supplyId(), result.allocatedQty(), result.replayed(), warehouseId);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public ReleaseResult releaseByDemands(
            Collection<UUID> demandIds,
            String reason) {
        tx.bind();
        List<UUID> ids = demandIds == null
                ? List.of()
                : demandIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) {
            return new ReleaseResult(BigDecimal.ZERO, 0, List.of());
        }

        // Shared order with DRAW issue: advisory dimension -> demand ->
        // reservation/balance.  Reading dimensions is safe before the row
        // locks because a demand's material identity is immutable.
        List<Object[]> dimensions = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT DISTINCT goods_id, color_id
                                FROM production_material_demands
                                WHERE id IN (:ids)
                                  AND is_deleted = FALSE
                                ORDER BY goods_id, color_id NULLS FIRST
                                """)
                        .setParameter("ids", ids));
        inventoryLock.lockAll(dimensions.stream()
                .map(row -> new InventoryKey((UUID) row[0], (UUID) row[1]))
                .toList());
        lockDemandRowsByIds(ids);

        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, qty, consumed_qty, released_qty, status
                                FROM stock_reservations
                                WHERE demand_id IN (:ids)
                                  AND is_deleted = FALSE
                                ORDER BY goods_id, color_id NULLS FIRST, supply_id, id
                                FOR UPDATE
                                """)
                        .setParameter("ids", ids));
        if (rows.stream().anyMatch(row -> decimal(row[2]).signum() > 0)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "物料分配已经发生领用，必须先按领退料反向链处理");
        }

        BigDecimal released = BigDecimal.ZERO;
        int changed = 0;
        List<UUID> releasedReservationIds = new ArrayList<>();
        for (Object[] row : rows) {
            UUID id = (UUID) row[0];
            BigDecimal effective = decimal(row[1])
                    .subtract(decimal(row[2]))
                    .subtract(decimal(row[3]));
            short status = ((Number) row[4]).shortValue();
            if (status != STATUS_EFFECTIVE || effective.signum() <= 0) {
                continue;
            }
            int updated = em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET released_qty = released_qty + :qty,
                                status = :done,
                                release_reason = :reason,
                                lock_version = lock_version + 1,
                                updated_at = now()
                            WHERE id = :id
                              AND status = :effective
                              AND is_deleted = FALSE
                              AND qty - consumed_qty - released_qty = :qty
                            """)
                    .setParameter("qty", effective)
                    .setParameter("done", STATUS_DONE)
                    .setParameter("reason", normalizeReason(reason))
                    .setParameter("id", id)
                    .setParameter("effective", STATUS_EFFECTIVE)
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "物料分配已被并发修改，请刷新后重试");
            }
            released = released.add(effective);
            changed++;
            releasedReservationIds.add(id);
        }
        return new ReleaseResult(
                released, changed, List.copyOf(releasedReservationIds));
    }

    private AllocationResult allocateOne(AllocationRequest request, BigDecimal qualifiedQty,
                                         boolean requiresQualifiedOrigin, AllocationBatch batch) {
        Object[] replay = batch.replays.get(request.idempotencyKey());
        if (replay != null) {
            requireReplayMatch(request, replay);
            if (requiresQualifiedOrigin && !Boolean.TRUE.equals(replay[8]))
                throw allocationConflict("旧预留缺少本批合格来源证明，不能改成跨仓领料");
            return new AllocationResult(request.demandId(), (UUID) replay[0], (UUID) replay[2],
                    decimal(replay[3]), true, request.warehouseId());
        }
        LeafKey leaf = new LeafKey(request.warehouseId(), new MaterialDimension(request.goodsId(), request.colorId()));
        StockPosition position = batch.positions.get(leaf);
        if (position == null) return new AllocationResult(request.demandId(), null, null,
                BigDecimal.ZERO, false, request.warehouseId());
        UUID supplyId = position.id;
        BigDecimal physical = position.free.subtract(batch.pendingOwned.getOrDefault(leaf, BigDecimal.ZERO)).max(BigDecimal.ZERO);
        BigDecimal qualified = qualifiedQty.min(physical);
        GroupKey group = new GroupKey(position.mainWarehouse, leaf.material());
        BigDecimal publicLimit = requiresQualifiedOrigin || !batch.normalWarehouses.contains(request.warehouseId())
                ? BigDecimal.ZERO : batch.publicRemaining.getOrDefault(group, BigDecimal.ZERO)
                    .subtract(batch.pendingUnqualified.getOrDefault(group, BigDecimal.ZERO)).max(BigDecimal.ZERO);
        BigDecimal take = request.requiredQty().min(physical).min(qualified.add(publicLimit));
        if (take.signum() <= 0) return new AllocationResult(request.demandId(), null, supplyId,
                BigDecimal.ZERO, false, request.warehouseId());
        UUID allocationId = UUID.randomUUID();
        int inserted = em.createNativeQuery("""
                        INSERT INTO stock_reservations (
                            id, order_item_id, goods_id, color_id, warehouse_id,
                            qty, consumed_qty, released_qty, status, source,
                            source_doc_type, source_doc_id,
                            owner_type, owner_id, purpose, demand_id,
                            supply_type, supply_id, idempotency_key,
                            created_at, updated_at, created_by, updated_by,
                            is_deleted, lock_version%s
                        ) VALUES (
                            :id, NULL, :goodsId, :colorId, :warehouseId,
                            :qty, 0, 0, :status, :source,
                            'PRODUCTION_PLANNING_PACKAGE', :packageId,
                            'PRODUCTION_MATERIAL_DEMAND', :demandId,
                            'PRODUCTION_MATERIAL', :demandId,
                            'STOCK_BALANCE', :supplyId, :key,
                            now(), now(), :actorId, :actorId,
                            FALSE, 0%s
                        )
                        """.formatted(requiresQualifiedOrigin ? ", requires_qualified_origin" : "",
                                requiresQualifiedOrigin ? ", TRUE" : ""))
                .setParameter("id", allocationId)
                .setParameter("goodsId", request.goodsId())
                .setParameter("colorId", request.colorId())
                .setParameter("warehouseId", request.warehouseId())
                .setParameter("qty", take)
                .setParameter("status", STATUS_EFFECTIVE)
                .setParameter("source", SOURCE_PRODUCTION_MATERIAL)
                .setParameter("packageId", request.packageId())
                .setParameter("demandId", request.demandId())
                .setParameter("supplyId", supplyId)
                .setParameter("key", request.idempotencyKey())
                .setParameter("actorId", request.actorId())
                .executeUpdate();
        if (inserted != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "物料分配写入失败");
        }
        position.free = position.free.subtract(take);
        if (!requiresQualifiedOrigin) batch.publicRemaining.compute(group, (ignored, budget) ->
                (budget == null ? BigDecimal.ZERO : budget).subtract(take.subtract(qualified)));
        return new AllocationResult(
                request.demandId(), allocationId, supplyId, take, false, request.warehouseId());
    }

    private void lockDemandRows(List<AllocationRequest> requests) {
        List<UUID> demandIds = requests.stream()
                .map(AllocationRequest::demandId)
                .distinct()
                .sorted()
                .toList();
        List<?> locked = em.createNativeQuery("""
                        SELECT id
                        FROM production_material_demands
                        WHERE id IN (:ids)
                          AND is_deleted = FALSE
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("ids", demandIds)
                .getResultList();
        if (locked.size() != demandIds.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "Production material demand changed");
        }
    }

    private void lockDemandRowsByIds(List<UUID> demandIds) {
        if (demandIds.isEmpty()) {
            return;
        }
        List<?> locked = em.createNativeQuery("""
                        SELECT id
                        FROM production_material_demands
                        WHERE id IN (:ids)
                          AND is_deleted = FALSE
                        ORDER BY goods_id, color_id NULLS FIRST, id
                        FOR UPDATE
                        """)
                .setParameter("ids", demandIds)
                .getResultList();
        if (locked.size() != demandIds.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "Production material demand changed");
        }
    }

    private static void validateRequests(List<AllocationRequest> requests) {
        for (AllocationRequest request : requests) {
            if (request == null
                    || request.packageId() == null
                    || request.demandId() == null
                    || request.goodsId() == null
                    || request.warehouseId() == null
                    || request.requiredQty() == null
                    || request.requiredQty().signum() <= 0
                    || request.idempotencyKey() == null
                    || request.idempotencyKey().isBlank()) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "物料分配请求缺少必填字段或数量无效");
            }
        }
    }

    private static void requireReplayMatch(AllocationRequest request, Object[] row) {
        if (!request.demandId().equals(row[1])
                || !request.goodsId().equals(row[4])
                || !Objects.equals(request.colorId(), row[5])
                || !request.warehouseId().equals(row[6])
                || request.requiredQty().compareTo(decimal(row[3])) < 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "相同幂等键对应不同物料分配请求");
        }
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) {
            return BigDecimal.ZERO;
        }
        if (value instanceof BigDecimal decimal) {
            return decimal;
        }
        return new BigDecimal(value.toString());
    }

    private static String normalizeReason(String reason) {
        if (reason == null || reason.isBlank()) {
            return "计划包取消或红冲释放";
        }
        return reason.strip().substring(0, Math.min(reason.strip().length(), 500));
    }

    public record MaterialDimension(UUID goodsId, UUID colorId) {
    }

    public record AllocationRequest(
            UUID packageId,
            UUID demandId,
            UUID goodsId,
            UUID colorId,
            UUID warehouseId,
            BigDecimal requiredQty,
            String idempotencyKey,
            UUID actorId) {
    }

    public record AllocationResult(
            UUID demandId,
            UUID allocationId,
            UUID supplyId,
            BigDecimal allocatedQty,
            boolean replayed,
            UUID warehouseId) {
        public AllocationResult(UUID demandId, UUID allocationId, UUID supplyId,
                                BigDecimal allocatedQty, boolean replayed) {
            this(demandId, allocationId, supplyId, allocatedQty, replayed, null);
        }
    }

    public record AllocationPreference(UUID demandId, UUID warehouseId, BigDecimal qty) {
    }

    public record QualifiedSourcePreference(UUID demandId, UUID warehouseId, BigDecimal qty,
                                             UUID sourceEntitlementEventId, UUID sourceStockReservationId) {}

    public record ReleaseResult(
            BigDecimal releasedQty, int allocationCount, List<UUID> reservationIds) {
    }
}
