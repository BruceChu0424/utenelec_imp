package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.execution.ProductionAssignmentValidator;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** Shared fail-closed validation for a saved draft and formal V1 confirmation. */
@Service
@RequiredArgsConstructor
public class ProductionPlanningRequestValidator {

    private final EntityManager em;
    private final ProductionExecutionPlanningService planning;
    private final ProductionAssignmentValidator assignmentValidator;

    public Validated validateCurrent(
            java.util.UUID planId,
            GeneratePlanningPackageRequest request) {
        validateRequestShape(request);
        ProductionExecutionPlanningService.Snapshot snapshot =
                planning.preview(planId, request.getWarehouseId());
        if (!snapshot.fingerprint().equalsIgnoreCase(
                request.getPreviewFingerprint())) {
            throw conflict("预排草案已过期：目标仓库存、占用、计划明细或 BOM 已变化，请重新计算");
        }
        return validateAgainstSnapshot(request, snapshot);
    }

    public Validated validateAgainstSnapshot(
            GeneratePlanningPackageRequest request,
            ProductionExecutionPlanningService.Snapshot snapshot) {
        Map<CompleteKitAllocator.MaterialKey, String> routes =
                authoritativeRoutes(request, snapshot);
        if (!snapshot.noBomPlanItemIds().isEmpty()) {
            throw conflict("生产计划存在未获 DIRECT_MAKE 或逐计划例外放行的无 BOM 行");
        }
        CompleteKitAllocator.Allocation allocation =
                planning.applyRequested(snapshot, request.getSegments());
        requirePurchaseGeneration(request, allocation);
        return new Validated(snapshot, routes, allocation);
    }

    public void validateRequestShape(GeneratePlanningPackageRequest request) {
        if (request == null
                || request.getWarehouseId() == null
                || request.getIdempotencyKey() == null
                || request.getIdempotencyKey().isBlank()
                || request.getPreviewFingerprint() == null
                || !request.getPreviewFingerprint()
                        .matches("(?i)[0-9a-f]{64}")) {
            throw validation("预排草案缺少仓库、幂等键或有效预览指纹");
        }
        if (request.getItems() != null && !request.getItems().isEmpty()) {
            throw conflict("items 是旧自制子计划字段，不能用于执行分段预排");
        }
        if (request.getRoutes() != null
                && request.getRoutes().stream().anyMatch(route ->
                        route == null
                                || route.getGoodsId() == null
                                || route.getSupplyRoute() == null
                                || !List.of(
                                        ProductionMaterialDemand.ROUTE_BUY,
                                        ProductionMaterialDemand.ROUTE_SUBCONTRACT)
                                        .contains(route.getSupplyRoute()
                                                .strip().toUpperCase(Locale.ROOT)))) {
            throw validation("供给路线缺少物料或有效路线");
        }
        if (request.getSegments() != null
                && request.getSegments().stream().anyMatch(segment ->
                        segment == null
                                || segment.getClientSegmentKey() == null
                                || segment.getClientSegmentKey().isBlank()
                                || segment.getSourcePlanItemId() == null
                                || segment.getRequestedStatus() == null
                                || !List.of("READY", "WAITING").contains(
                                        segment.getRequestedStatus())
                                || segment.getPlannedQty() == null
                                || segment.getPlannedQty().signum() <= 0
                                || segment.getBomFingerprint() == null
                                || !segment.getBomFingerprint().matches(
                                        "(?i)[0-9a-f]{64}"))) {
            throw validation("执行分段缺少来源行、数量、状态、键或有效 BOM 指纹");
        }
        assignmentValidator.validateAll(request.getSegments() == null
                ? List.of()
                : request.getSegments().stream()
                        .map(segment -> new ProductionAssignmentValidator.Assignment(
                                segment.getWorkshopDepartmentId(),
                                segment.getTeamDepartmentId(),
                                segment.getResponsibleEmployeeId(),
                                segment.getPlanBeginDate(),
                                segment.getPlanEndDate()))
                        .toList());
        long warehouse = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM warehouses
                        WHERE id = :id AND is_deleted = FALSE
                        """)
                .setParameter("id", request.getWarehouseId())
                .getSingleResult()).longValue();
        if (warehouse != 1) {
            throw new ApiException(
                    ErrorCode.NOT_FOUND, "目标发料仓不存在或已停用");
        }
    }

    private static void requirePurchaseGeneration(
            GeneratePlanningPackageRequest request,
            CompleteKitAllocator.Allocation allocation) {
        boolean hasBuyShortage = allocation.segments().stream()
                .flatMap(segment -> segment.materials().stream())
                .anyMatch(material ->
                        ProductionMaterialDemand.ROUTE_BUY.equals(
                                material.supplyRoute())
                                && material.shortageQty().signum() > 0);
        if (hasBuyShortage && !request.isGeneratePurchaseRequest()) {
            throw validation("存在外购物料缺口，必须同时生成采购申请草稿");
        }
    }

    private static Map<CompleteKitAllocator.MaterialKey, String>
            authoritativeRoutes(
                    GeneratePlanningPackageRequest request,
                    ProductionExecutionPlanningService.Snapshot snapshot) {
        Map<CompleteKitAllocator.MaterialKey, String> result =
                new LinkedHashMap<>();
        snapshot.productLines().stream()
                .flatMap(line -> line.materials().stream())
                .forEach(material -> {
                    CompleteKitAllocator.MaterialKey key =
                            new CompleteKitAllocator.MaterialKey(
                                    material.goodsId(), material.colorId());
                    String previous = result.putIfAbsent(
                            key, material.supplyRoute());
                    if (previous != null
                            && !previous.equals(material.supplyRoute())) {
                        throw conflict("同一物料颜色维度存在冲突的主档供给路线");
                    }
                });
        if (request.getRoutes() == null) {
            return result;
        }
        for (GeneratePlanningPackageRequest.MaterialRoute route
                : request.getRoutes()) {
            if (route == null || route.getGoodsId() == null) {
                throw validation("供给路线缺少物料标识");
            }
            CompleteKitAllocator.MaterialKey key =
                    new CompleteKitAllocator.MaterialKey(
                            route.getGoodsId(), route.getColorId());
            if (!result.containsKey(key)) {
                throw validation("供给路线不属于当前 BOM 物料");
            }
            String requested = route.getSupplyRoute() == null
                    ? ""
                    : route.getSupplyRoute().strip()
                            .toUpperCase(Locale.ROOT);
            if (!ProductionMaterialDemand.ROUTE_BUY.equals(requested)
                    && !ProductionMaterialDemand.ROUTE_SUBCONTRACT.equals(
                            requested)) {
                throw validation("供给路线只能为采购或委外");
            }
            if (!result.get(key).equals(requested)) {
                throw conflict("所选供给路线与货品主档不一致，请先修正主档或重新预排");
            }
        }
        return result;
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    public record Validated(
            ProductionExecutionPlanningService.Snapshot snapshot,
            Map<CompleteKitAllocator.MaterialKey, String> routes,
            CompleteKitAllocator.Allocation allocation) {
    }
}
