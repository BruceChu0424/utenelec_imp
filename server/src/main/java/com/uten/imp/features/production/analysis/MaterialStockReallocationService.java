package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.core.annotation.Order;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/**
 * 跨物料分析的显式让料与来源计划优先补齐。
 *
 * <p>它只移动 V309 entitlement 事件，不改写 V307 origin，也不创建第二套
 * 物理库存账。接受计划无需返还；来源计划保留高优先级未满足量，后续来源
 * 或接受计划自己的合格供给在入库事务内完成重新挂接。</p>
 */
@Order(0)
@Service
@RequiredArgsConstructor
public class MaterialStockReallocationService implements PreplanOriginEntitlementHook {

    private final EntityManager em;
    private final MaterialAnalysisService analysisService;
    private final PreplanStockEntitlementService entitlements;
    private final ProductionDocumentAccessPolicy access;
    private final InventoryMutationLock inventoryLock;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public PageResponse<CrossReallocationCandidate> candidates(
            UUID sourceAnalysisId,
            UUID sourceMaterialLineId,
            String keyword,
            int page,
            int size) {
        int safePage = Math.max(page, 1);
        int safeSize = Math.min(Math.max(size, 1), 100);
        Endpoint source = endpoint(sourceAnalysisId, sourceMaterialLineId, false);
        access.requireWritable(
                source.makerId(), "只能从本人可维护的物料分析发起让料", access.scope());
        validateSourceEndpoint(source);
        BigDecimal sourceQty = entitlements.listAvailableOriginalLots(
                        source.analysisId(), source.materialId(), source.warehouseId(),
                        source.goodsId(), source.colorId(), false).stream()
                .map(PreplanStockEntitlementService.AvailableLot::remainingQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add)
                .min(source.allocatedAvailableQty());
        if (sourceQty.signum() <= 0) {
            return new PageResponse<>(List.of(), safePage, safeSize, 0, 0);
        }

        OwnerVisibility.OwnerScope scope = access.scope();
        if (!scope.seeAll() && scope.visibleOwners().isEmpty()) {
            return new PageResponse<>(List.of(), safePage, safeSize, 0, 0);
        }
        String ownerPredicate = scope.seeAll()
                ? "analysis.maker_id IS NOT NULL"
                : "analysis.maker_id IN (:visibleOwners)";
        String normalized = normalizeKeyword(keyword);
        String keywordPredicate = normalized == null ? "" : """
                AND (
                    LOWER(COALESCE(item.source_ref, '')) LIKE :keyword
                    OR LOWER(COALESCE(product.code, '')) LIKE :keyword
                    OR LOWER(COALESCE(product.name, '')) LIKE :keyword
                    OR LOWER(analysis.id::text) LIKE :keyword
                )
                """;
        String fromAndWhere = """
                FROM production_material_analysis_materials material
                JOIN production_material_analyses analysis
                  ON analysis.id = material.analysis_id
                JOIN production_material_analysis_items item
                  ON item.id = material.analysis_item_id
                 AND item.analysis_id = analysis.id
                 AND item.is_deleted = FALSE
                JOIN warehouses warehouse ON warehouse.id = analysis.warehouse_id
                LEFT JOIN goods product ON product.id = item.goods_id
                WHERE analysis.id <> :sourceAnalysisId
                  AND analysis.is_deleted = FALSE
                  AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
                  AND analysis.warehouse_id = :warehouseId
                  AND material.active = TRUE
                  AND material.depth = 1
                  AND material.control_stage NOT IN ('SHIP', 'REFERENCE')
                  AND material.goods_id = :goodsId
                  AND material.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                  AND material.unit_id = :unitId
                  AND material.shortage_qty > 0
                  AND %s
                """.formatted(ownerPredicate) + keywordPredicate;

        Query countQuery = em.createNativeQuery("SELECT COUNT(*) " + fromAndWhere)
                .setParameter("sourceAnalysisId", sourceAnalysisId)
                .setParameter("warehouseId", source.warehouseId())
                .setParameter("goodsId", source.goodsId())
                .setParameter("colorId", source.colorId())
                .setParameter("unitId", source.unitId());
        bindScopeAndKeyword(countQuery, scope, normalized);
        long total = ((Number) countQuery.getSingleResult()).longValue();
        if (total == 0) {
            return new PageResponse<>(List.of(), safePage, safeSize, 0, 0);
        }

        Query rowsQuery = em.createNativeQuery("""
                SELECT analysis.id, analysis.version, analysis.fingerprint,
                       material.id, analysis.warehouse_id, warehouse.name,
                       item.delivery_date, material.shortage_qty,
                       item.source_ref, product.code, product.name
                """ + fromAndWhere + """
                ORDER BY item.delivery_date ASC NULLS LAST,
                         analysis.updated_at, analysis.id, material.id
                """)
                .setParameter("sourceAnalysisId", sourceAnalysisId)
                .setParameter("warehouseId", source.warehouseId())
                .setParameter("goodsId", source.goodsId())
                .setParameter("colorId", source.colorId())
                .setParameter("unitId", source.unitId())
                .setFirstResult((safePage - 1) * safeSize)
                .setMaxResults(safeSize);
        bindScopeAndKeyword(rowsQuery, scope, normalized);
        List<CrossReallocationCandidate> items = NativeQueryResults.objectArrayRows(rowsQuery)
                .stream()
                .map(row -> new CrossReallocationCandidate(
                        uuid(row[0]), ((Number) row[1]).longValue(), string(row[2]),
                        uuid(row[3]), uuid(row[4]), string(row[5]),
                        analysisLabel(uuid(row[0])),
                        firstNonBlank(string(row[8]),
                                displayLabel(string(row[9]), string(row[10]))),
                        localDate(row[6]), sourceQty, decimal(row[7])))
                .toList();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    @Transactional
    public AnalysisView create(
            UUID sourceAnalysisId, CrossReallocationRequest request) {
        tx.bind();
        if (sourceAnalysisId.equals(request.targetAnalysisId())) {
            throw validation("接受计划必须是另一份物料分析");
        }
        Endpoint sourceSnapshot = endpoint(
                sourceAnalysisId, request.sourceMaterialLineId(), false);
        inventoryLock.lock(new InventoryKey(
                sourceSnapshot.goodsId(), sourceSnapshot.colorId()));
        Map<UUID, MaterialAnalysisService.AnalysisHeader> headers = lockHeaders(
                sourceAnalysisId, request.targetAnalysisId());
        OwnerVisibility.OwnerScope scope = access.scope();
        access.requireWritable(headers.get(sourceAnalysisId).makerId(),
                "无权调整来源物料分析", scope);
        access.requireWritable(headers.get(request.targetAnalysisId()).makerId(),
                "无权调整接受物料分析", scope);

        String requestHash = requestHash(sourceAnalysisId, request);
        List<Object[]> replay = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, request_hash, from_analysis_id
                FROM preplan_material_reallocations
                WHERE created_by = :actorId AND idempotency_key = :key
                FOR UPDATE
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("key", request.idempotencyKey()));
        if (!replay.isEmpty()) {
            Object[] row = replay.getFirst();
            if (!requestHash.equals(string(row[1]))
                    || !sourceAnalysisId.equals(uuid(row[2]))) {
                throw conflict("同一幂等键已用于不同让料请求");
            }
            return analysisService.detailInternal(sourceAnalysisId, false);
        }

        analysisService.requireCurrent(headers.get(sourceAnalysisId),
                request.sourceVersion(), request.sourceFingerprint());
        analysisService.requireCurrent(headers.get(request.targetAnalysisId()),
                request.targetVersion(), request.targetFingerprint());
        Endpoint source = endpoint(
                sourceAnalysisId, request.sourceMaterialLineId(), true);
        Endpoint target = endpoint(
                request.targetAnalysisId(), request.targetMaterialLineId(), true);
        validatePair(source, target);
        requireNoOpenEndpointRelation(source.materialId(), target.materialId());
        requireNoLegacyBorrow(source.analysisId(), source.materialId());
        requireNoLegacyBorrow(target.analysisId(), target.materialId());

        BigDecimal qty = request.qty().setScale(4, RoundingMode.DOWN);
        List<PreplanStockEntitlementService.AvailableLot> lots =
                entitlements.listAvailableOriginalLots(
                        source.analysisId(), source.materialId(), source.warehouseId(),
                        source.goodsId(), source.colorId(), true);
        BigDecimal originalAvailable = lots.stream()
                .map(PreplanStockEntitlementService.AvailableLot::remainingQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add)
                .min(source.allocatedAvailableQty());
        if (qty.signum() <= 0 || qty.compareTo(originalAvailable) > 0) {
            throw conflict("来源计划可让料数量不足，当前最多可让 "
                    + quantityText(originalAvailable));
        }
        if (qty.compareTo(target.shortageQty()) > 0) {
            throw conflict("让料数量不能超过接受计划当前缺口 "
                    + quantityText(target.shortageQty()));
        }

        UUID reallocationId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO preplan_material_reallocations (
                    id, from_analysis_id, from_analysis_material_id,
                    to_analysis_id, to_analysis_material_id,
                    warehouse_id, goods_id, color_id, unit_id,
                    qty, priority_fulfilled_qty, status,
                    reason, idempotency_key, request_hash,
                    source_version, source_fingerprint,
                    target_version, target_fingerprint,
                    created_by, updated_by
                ) VALUES (
                    :id, :fromAnalysisId, :fromMaterialId,
                    :toAnalysisId, :toMaterialId,
                    :warehouseId, :goodsId, :colorId, :unitId,
                    :qty, 0, 'OPEN',
                    :reason, :key, :requestHash,
                    :sourceVersion, :sourceFingerprint,
                    :targetVersion, :targetFingerprint,
                    :actorId, :actorId
                )
                """)
                .setParameter("id", reallocationId)
                .setParameter("fromAnalysisId", source.analysisId())
                .setParameter("fromMaterialId", source.materialId())
                .setParameter("toAnalysisId", target.analysisId())
                .setParameter("toMaterialId", target.materialId())
                .setParameter("warehouseId", source.warehouseId())
                .setParameter("goodsId", source.goodsId())
                .setParameter("colorId", source.colorId())
                .setParameter("unitId", source.unitId())
                .setParameter("qty", qty)
                .setParameter("reason", request.reason().strip())
                .setParameter("key", request.idempotencyKey())
                .setParameter("requestHash", requestHash)
                .setParameter("sourceVersion", request.sourceVersion())
                .setParameter("sourceFingerprint",
                        request.sourceFingerprint().toLowerCase(Locale.ROOT))
                .setParameter("targetVersion", request.targetVersion())
                .setParameter("targetFingerprint",
                        request.targetFingerprint().toLowerCase(Locale.ROOT))
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();

        BigDecimal remaining = qty;
        int sequence = 0;
        for (PreplanStockEntitlementService.AvailableLot lot : lots) {
            if (remaining.signum() <= 0) break;
            BigDecimal take = remaining.min(lot.remainingQty());
            if (take.signum() <= 0) continue;
            sequence++;
            entitlements.appendPairedOutIn(
                    UUID.randomUUID(), lot,
                    "REALLOCATE_OUT", "REALLOCATE_IN",
                    target.analysisId(), target.materialId(), reallocationId, take,
                    "CROSS-REALLOCATE:" + reallocationId + ":" + sequence);
            remaining = remaining.subtract(take);
        }
        if (remaining.signum() != 0) {
            throw conflict("让料来源批次数量在事务内发生变化");
        }
        refreshBoth(source.analysisId(), target.analysisId());
        return analysisService.detailInternal(source.analysisId(), false);
    }

    @Transactional
    public AnalysisView revoke(
            UUID sourceAnalysisId,
            UUID reallocationId,
            CrossReallocationRevokeRequest request) {
        tx.bind();
        ReallocationHeader snapshot = reallocation(reallocationId, false);
        if (!sourceAnalysisId.equals(snapshot.fromAnalysisId())) {
            throw new ApiException(ErrorCode.NOT_FOUND, "让料记录不存在");
        }
        inventoryLock.lock(new InventoryKey(snapshot.goodsId(), snapshot.colorId()));
        Map<UUID, MaterialAnalysisService.AnalysisHeader> headers = lockHeaders(
                snapshot.fromAnalysisId(), snapshot.toAnalysisId());
        OwnerVisibility.OwnerScope scope = access.scope();
        access.requireWritable(headers.get(snapshot.fromAnalysisId()).makerId(),
                "无权撤销来源物料分析的让料", scope);
        access.requireWritable(headers.get(snapshot.toAnalysisId()).makerId(),
                "无权撤销接受物料分析的让料", scope);
        ReallocationHeader header = reallocation(reallocationId, true);
        String closeHash = revokeHash(sourceAnalysisId, reallocationId, request);
        if ("REVERSED".equals(header.status())) {
            if (Objects.equals(header.closeIdempotencyKey(), request.idempotencyKey())
                    && Objects.equals(header.closeRequestHash(), closeHash)) {
                return analysisService.detailInternal(sourceAnalysisId, false);
            }
            throw conflict("该让料已由另一撤销请求处理");
        }
        analysisService.requireCurrent(headers.get(header.fromAnalysisId()),
                request.sourceVersion(), request.sourceFingerprint());
        analysisService.requireCurrent(headers.get(header.toAnalysisId()),
                request.targetVersion(), request.targetFingerprint());
        if (!"OPEN".equals(header.status())
                || header.priorityFulfilledQty().signum() > 0) {
            throw conflict("来源计划已经开始优先补齐，不能直接撤销让料");
        }
        entitlements.reverseUnformalizedReallocation(
                header.id(), header.fromAnalysisId(), header.fromMaterialId(),
                header.toAnalysisId(), header.toMaterialId(), UUID.randomUUID(),
                "CROSS-REALLOCATE-REVOKE:" + header.id());
        int updated = em.createNativeQuery("""
                UPDATE preplan_material_reallocations
                SET status = 'REVERSED', closed_by = :actorId, closed_at = now(),
                    close_reason = :reason,
                    close_idempotency_key = :key,
                    close_request_hash = :requestHash,
                    lock_version = lock_version + 1,
                    updated_by = :actorId
                WHERE id = :id AND status = 'OPEN' AND lock_version = :version
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("reason", request.reason().strip())
                .setParameter("key", request.idempotencyKey())
                .setParameter("requestHash", closeHash)
                .setParameter("id", header.id())
                .setParameter("version", header.lockVersion())
                .executeUpdate();
        if (updated != 1) {
            throw conflict("让料记录已被并发修改，请刷新后重试");
        }
        refreshBoth(header.fromAnalysisId(), header.toAnalysisId());
        return analysisService.detailInternal(sourceAnalysisId, false);
    }

    /** 入库 origin 后执行：A 自身供给原地满足；B 下一批供给优先重新挂给 A。 */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyPriorityForOriginEvent(UUID originEventId) {
        tx.bind();
        PreplanStockEntitlementService.AvailableLot lot =
                entitlements.requireAvailableLot(originEventId, true);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, from_analysis_id, from_analysis_material_id,
                       to_analysis_id, to_analysis_material_id,
                       qty, priority_fulfilled_qty, status, lock_version
                FROM preplan_material_reallocations
                WHERE status IN ('OPEN', 'PARTIAL')
                  AND (
                      (from_analysis_id = :analysisId
                       AND from_analysis_material_id = :materialId)
                      OR
                      (to_analysis_id = :analysisId
                       AND to_analysis_material_id = :materialId)
                  )
                ORDER BY created_at, id
                FOR UPDATE
                """)
                .setParameter("analysisId", lot.beneficiaryAnalysisId())
                .setParameter("materialId", lot.beneficiaryAnalysisMaterialId()));
        if (rows.isEmpty()) return;
        BigDecimal remainingSupply = lot.remainingQty();
        int sequence = 0;
        for (Object[] row : rows) {
            if (remainingSupply.signum() <= 0) break;
            UUID id = uuid(row[0]);
            UUID fromAnalysisId = uuid(row[1]);
            UUID fromMaterialId = uuid(row[2]);
            UUID toAnalysisId = uuid(row[3]);
            UUID toMaterialId = uuid(row[4]);
            BigDecimal requested = decimal(row[5]);
            BigDecimal fulfilled = decimal(row[6]);
            BigDecimal open = requested.subtract(fulfilled).max(BigDecimal.ZERO);
            BigDecimal take = remainingSupply.min(open);
            if (take.signum() <= 0) continue;
            sequence++;
            String key = "CROSS-PRIORITY:" + originEventId + ":" + id
                    + ":" + sequence;
            if (fromAnalysisId.equals(lot.beneficiaryAnalysisId())
                    && fromMaterialId.equals(lot.beneficiaryAnalysisMaterialId())) {
                entitlements.appendPrioritySatisfiedInPlace(
                        UUID.randomUUID(), lot, id, take, key + ":IN-PLACE");
            } else if (toAnalysisId.equals(lot.beneficiaryAnalysisId())
                    && toMaterialId.equals(lot.beneficiaryAnalysisMaterialId())) {
                entitlements.appendPairedOutIn(
                        UUID.randomUUID(), lot,
                        "PRIORITY_OUT", "PRIORITY_IN",
                        fromAnalysisId, fromMaterialId, id, take, key);
            } else {
                continue;
            }
            BigDecimal nextFulfilled = fulfilled.add(take);
            String nextStatus = nextFulfilled.compareTo(requested) >= 0
                    ? "FULFILLED" : "PARTIAL";
            int updated = em.createNativeQuery("""
                    UPDATE preplan_material_reallocations
                    SET priority_fulfilled_qty = :fulfilled,
                        status = :status,
                        lock_version = lock_version + 1,
                        updated_by = :actorId
                    WHERE id = :id AND lock_version = :version
                      AND status IN ('OPEN', 'PARTIAL')
                    """)
                    .setParameter("fulfilled", nextFulfilled)
                    .setParameter("status", nextStatus)
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", id)
                    .setParameter("version", ((Number) row[8]).longValue())
                    .executeUpdate();
            if (updated != 1) {
                throw conflict("优先补齐记录已被并发修改");
            }
            remainingSupply = remainingSupply.subtract(take);
        }
    }

    private Map<UUID, MaterialAnalysisService.AnalysisHeader> lockHeaders(UUID... ids) {
        List<UUID> ordered = List.of(ids).stream().distinct().sorted().toList();
        Map<UUID, MaterialAnalysisService.AnalysisHeader> result =
                new LinkedHashMap<>();
        for (UUID id : ordered) result.put(id, analysisService.lockHeader(id));
        return result;
    }

    private Endpoint endpoint(UUID analysisId, UUID materialId, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE OF material, item" : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis.id, analysis.warehouse_id, analysis.status,
                       analysis.version, analysis.fingerprint, analysis.maker_id,
                       material.id, material.analysis_item_id,
                       material.goods_id, material.color_id, material.unit_id,
                       material.depth, material.control_stage,
                       material.allocated_available_qty, material.shortage_qty,
                       material.active, item.delivery_date, item.source_ref,
                       product.code, product.name
                FROM production_material_analysis_materials material
                JOIN production_material_analyses analysis
                  ON analysis.id = material.analysis_id
                JOIN production_material_analysis_items item
                  ON item.id = material.analysis_item_id
                 AND item.analysis_id = analysis.id
                LEFT JOIN goods product ON product.id = item.goods_id
                WHERE analysis.id = :analysisId
                  AND material.id = :materialId
                  AND analysis.is_deleted = FALSE
                  AND item.is_deleted = FALSE
                """ + lock)
                .setParameter("analysisId", analysisId)
                .setParameter("materialId", materialId));
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "物料分析节点不存在");
        }
        Object[] row = rows.getFirst();
        return new Endpoint(
                uuid(row[0]), uuid(row[1]), string(row[2]),
                ((Number) row[3]).longValue(), string(row[4]), uuid(row[5]),
                uuid(row[6]), uuid(row[7]), uuid(row[8]), uuid(row[9]), uuid(row[10]),
                ((Number) row[11]).intValue(), string(row[12]),
                decimal(row[13]), decimal(row[14]), Boolean.TRUE.equals(row[15]),
                localDate(row[16]), firstNonBlank(string(row[17]),
                        displayLabel(string(row[18]), string(row[19]))));
    }

    private ReallocationHeader reallocation(UUID id, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE" : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, from_analysis_id, from_analysis_material_id,
                       to_analysis_id, to_analysis_material_id,
                       warehouse_id, goods_id, color_id, unit_id,
                       qty, priority_fulfilled_qty, status, lock_version,
                       close_idempotency_key, close_request_hash
                FROM preplan_material_reallocations
                WHERE id = :id
                """ + lock).setParameter("id", id));
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "让料记录不存在");
        }
        Object[] row = rows.getFirst();
        return new ReallocationHeader(
                uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]), uuid(row[4]),
                uuid(row[5]), uuid(row[6]), uuid(row[7]), uuid(row[8]),
                decimal(row[9]), decimal(row[10]), string(row[11]),
                ((Number) row[12]).longValue(), string(row[13]), string(row[14]));
    }

    private void validateSourceEndpoint(Endpoint source) {
        if (!List.of(MaterialAnalysisService.STATUS_ACTIVE,
                        MaterialAnalysisService.STATUS_PARTIAL)
                .contains(source.status())
                || source.warehouseId() == null || !source.active()
                || source.depth() != 1
                || MaterialAnalysisService.STAGE_SHIP.equals(source.controlStage())
                || MaterialAnalysisService.STAGE_REFERENCE.equals(source.controlStage())) {
            throw conflict("该物料节点当前不能跨计划让料");
        }
    }

    private void validatePair(Endpoint source, Endpoint target) {
        validateSourceEndpoint(source);
        validateSourceEndpoint(target);
        if (source.analysisId().equals(target.analysisId())) {
            throw validation("跨计划让料不能选择同一物料分析");
        }
        if (!Objects.equals(source.warehouseId(), target.warehouseId())
                || !Objects.equals(source.goodsId(), target.goodsId())
                || !Objects.equals(source.colorId(), target.colorId())
                || !Objects.equals(source.unitId(), target.unitId())) {
            throw validation("只能在同仓库、同货品、同颜色和同基本单位之间让料");
        }
        if (target.shortageQty().signum() <= 0) {
            throw conflict("接受计划已经没有该物料缺口");
        }
    }

    private void requireNoOpenEndpointRelation(UUID sourceMaterialId, UUID targetMaterialId) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM preplan_material_reallocations
                WHERE status IN ('OPEN', 'PARTIAL')
                  AND (
                      from_analysis_material_id IN (:ids)
                      OR to_analysis_material_id IN (:ids)
                  )
                """).setParameter("ids", List.of(sourceMaterialId, targetMaterialId))
                .getSingleResult();
        if (count.longValue() > 0) {
            throw conflict("其中一个物料节点已有未补齐的跨计划让料，请先完成或撤销");
        }
    }

    private void requireNoLegacyBorrow(UUID analysisId, UUID materialId) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM production_material_analysis_borrows
                WHERE analysis_id = :analysisId AND status = 'ACTIVE'
                  AND (from_material_id = :materialId OR to_material_id = :materialId)
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("materialId", materialId)
                .getSingleResult();
        if (count.longValue() > 0) {
            throw conflict("该节点仍有分析内调配，必须先撤销后再跨计划让料");
        }
    }

    private void refreshBoth(UUID left, UUID right) {
        List.of(left, right).stream().distinct().sorted()
                .forEach(analysisService::refreshLocked);
    }

    private static void bindScopeAndKeyword(
            Query query, OwnerVisibility.OwnerScope scope, String keyword) {
        if (!scope.seeAll()) query.setParameter("visibleOwners", scope.visibleOwners());
        if (keyword != null) query.setParameter("keyword", "%" + keyword + "%");
    }

    private static String requestHash(
            UUID sourceAnalysisId, CrossReallocationRequest request) {
        return PlanningPackageFingerprint.sha256(List.of(
                "CROSS-REALLOCATE-V1", sourceAnalysisId.toString(),
                request.sourceMaterialLineId().toString(),
                request.targetAnalysisId().toString(),
                request.targetMaterialLineId().toString(),
                request.qty().stripTrailingZeros().toPlainString(),
                request.reason().strip()));
    }

    private static String revokeHash(
            UUID sourceAnalysisId, UUID reallocationId,
            CrossReallocationRevokeRequest request) {
        return PlanningPackageFingerprint.sha256(List.of(
                "CROSS-REALLOCATE-REVOKE-V1", sourceAnalysisId.toString(),
                reallocationId.toString(), request.reason().strip()));
    }

    private static String normalizeKeyword(String value) {
        if (value == null || value.isBlank()) return null;
        return value.strip().toLowerCase(Locale.ROOT);
    }

    private static String analysisLabel(UUID id) {
        return "物料分析 " + id.toString().substring(0, 8).toUpperCase(Locale.ROOT);
    }

    private static String displayLabel(String code, String name) {
        if (code == null || code.isBlank()) return name;
        if (name == null || name.isBlank()) return code;
        return code + " · " + name;
    }

    private static String firstNonBlank(String first, String fallback) {
        return first == null || first.isBlank() ? fallback : first;
    }

    private static String quantityText(BigDecimal value) {
        return value.max(BigDecimal.ZERO).stripTrailingZeros().toPlainString();
    }

    private static UUID uuid(Object value) {
        return value == null ? null : (UUID) value;
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toLocalDateTime().toLocalDate();
        }
        throw new IllegalStateException(
                "Unsupported SQL date type: " + value.getClass().getName());
    }

    private static String string(Object value) {
        return value == null ? null : value.toString();
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record Endpoint(
            UUID analysisId, UUID warehouseId, String status,
            long version, String fingerprint, UUID makerId,
            UUID materialId, UUID analysisItemId,
            UUID goodsId, UUID colorId, UUID unitId,
            int depth, String controlStage,
            BigDecimal allocatedAvailableQty, BigDecimal shortageQty,
            boolean active, LocalDate deliveryDate, String productLabel) {
    }

    private record ReallocationHeader(
            UUID id, UUID fromAnalysisId, UUID fromMaterialId,
            UUID toAnalysisId, UUID toMaterialId,
            UUID warehouseId, UUID goodsId, UUID colorId, UUID unitId,
            BigDecimal qty, BigDecimal priorityFulfilledQty,
            String status, long lockVersion,
            String closeIdempotencyKey, String closeRequestHash) {
    }
}
