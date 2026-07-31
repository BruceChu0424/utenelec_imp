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
     * Allocates only from the explicitly selected warehouse. Stock in another
     * warehouse is a transfer candidate, not an implicit source.
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

        List<AllocationRequest> ordered = requests.stream()
                .sorted(Comparator
                        .comparing((AllocationRequest r) ->
                                new InventoryKey(r.goodsId(), r.colorId()))
                        .thenComparing(AllocationRequest::warehouseId)
                        .thenComparing(AllocationRequest::demandId))
                .toList();
        List<AllocationResult> results = new ArrayList<>(ordered.size());
        for (AllocationRequest request : ordered) {
            results.add(allocateOne(request));
        }
        return results;
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
            return new ReleaseResult(BigDecimal.ZERO, 0);
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
        }
        return new ReleaseResult(released, changed);
    }

    private AllocationResult allocateOne(AllocationRequest request) {
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, demand_id, supply_id, qty,
                                       goods_id, color_id, warehouse_id
                                FROM stock_reservations
                                WHERE idempotency_key = :key
                                  AND is_deleted = FALSE
                                FOR UPDATE
                                """)
                        .setParameter("key", request.idempotencyKey()));
        if (!replay.isEmpty()) {
            Object[] row = replay.getFirst();
            requireReplayMatch(request, row);
            return new AllocationResult(
                    request.demandId(),
                    (UUID) row[0],
                    (UUID) row[2],
                    decimal(row[3]),
                    true);
        }

        List<Object[]> balances = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT b.id, b.qty,
                                       GREATEST(COALESCE(g.min_qty, 0), 0)
                                FROM goods g
                                JOIN stock_balances b
                                  ON b.goods_id = g.id
                                 AND b.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                                 AND b.warehouse_id = :warehouseId
                                WHERE g.id = :goodsId
                                  AND g.is_deleted = FALSE
                                ORDER BY b.id
                                FOR UPDATE OF b
                                """)
                        .setParameter("goodsId", request.goodsId())
                        .setParameter("colorId", request.colorId())
                        .setParameter("warehouseId", request.warehouseId()));
        if (balances.isEmpty()) {
            return new AllocationResult(
                    request.demandId(), null, null, BigDecimal.ZERO, false);
        }
        Object[] balance = balances.getFirst();
        UUID supplyId = (UUID) balance[0];
        if (supplyId == null) {
            return new AllocationResult(
                    request.demandId(), null, null, BigDecimal.ZERO, false);
        }

        BigDecimal onHand = decimal(balance[1]);
        BigDecimal safety = decimal(balance[2]);
        BigDecimal reserved = decimal(em.createNativeQuery("""
                        SELECT COALESCE(SUM(qty - consumed_qty - released_qty), 0)
                        FROM stock_reservations
                        WHERE is_deleted = FALSE
                          AND status = :effective
                          AND goods_id = :goodsId
                          AND color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                          AND (warehouse_id IS NULL OR warehouse_id = :warehouseId)
                        """)
                .setParameter("effective", STATUS_EFFECTIVE)
                .setParameter("goodsId", request.goodsId())
                .setParameter("colorId", request.colorId())
                .setParameter("warehouseId", request.warehouseId())
                .getSingleResult());
        BigDecimal available = onHand.subtract(reserved).subtract(safety).max(BigDecimal.ZERO);
        BigDecimal take = request.requiredQty().min(available);
        if (take.signum() <= 0) {
            return new AllocationResult(
                    request.demandId(), null, supplyId, BigDecimal.ZERO, false);
        }

        UUID allocationId = UUID.randomUUID();
        int inserted = em.createNativeQuery("""
                        INSERT INTO stock_reservations (
                            id, order_item_id, goods_id, color_id, warehouse_id,
                            qty, consumed_qty, released_qty, status, source,
                            source_doc_type, source_doc_id,
                            owner_type, owner_id, purpose, demand_id,
                            supply_type, supply_id, idempotency_key,
                            created_at, updated_at, created_by, updated_by,
                            is_deleted, lock_version
                        ) VALUES (
                            :id, NULL, :goodsId, :colorId, :warehouseId,
                            :qty, 0, 0, :status, :source,
                            'PRODUCTION_PLANNING_PACKAGE', :packageId,
                            'PRODUCTION_MATERIAL_DEMAND', :demandId,
                            'PRODUCTION_MATERIAL', :demandId,
                            'STOCK_BALANCE', :supplyId, :key,
                            now(), now(), :actorId, :actorId,
                            FALSE, 0
                        )
                        """)
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
        return new AllocationResult(
                request.demandId(), allocationId, supplyId, take, false);
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
            boolean replayed) {
    }

    public record ReleaseResult(BigDecimal releasedQty, int allocationCount) {
    }
}
