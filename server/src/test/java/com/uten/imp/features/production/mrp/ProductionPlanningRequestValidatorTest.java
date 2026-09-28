package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.execution.ProductionAssignmentValidator;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionPlanningRequestValidatorTest {

    private EntityManager em;
    private ProductionExecutionPlanningService planning;
    private Query warehouseQuery;
    private ProductionPlanningRequestValidator validator;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        planning = mock(ProductionExecutionPlanningService.class);
        warehouseQuery = query();
        when(warehouseQuery.getSingleResult()).thenReturn(1L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM warehouses")) {
                return warehouseQuery;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });
        validator = new ProductionPlanningRequestValidator(
                em, planning, mock(ProductionAssignmentValidator.class));
    }

    @Test
    void structuralPrecheckDoesNotReadMastersButLiveValidationStillRejectsADisabledWarehouse() {
        GeneratePlanningPackageRequest request=request("a".repeat(64));
        validator.validateRequestStructure(request);
        verify(em,never()).createNativeQuery(anyString());
        when(warehouseQuery.getSingleResult()).thenReturn(0L);
        assertThatThrownBy(()->validator.validateCurrent(UUID.randomUUID(),request))
                .isInstanceOf(ApiException.class).hasMessageContaining("目标发料仓不存在或已停用");
        verify(planning,never()).preview(any(),any());
    }

    @Test
    void rejectsStalePreviewFingerprint() {
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        when(planning.preview(any(), any())).thenReturn(
                snapshot("b".repeat(64), List.of(), List.of()));
        UUID analysisPlanId = UUID.randomUUID();
        when(planning.fromMaterialAnalysis(analysisPlanId)).thenReturn(true);

        assertThatThrownBy(() -> validator.validateCurrent(
                analysisPlanId, request))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessage("排产预览已过期：目标仓库存、占用、计划行或 BOM 已变化，请重新预览");
        // ADR-129 §2.6：手工计划按视图的计算用量排产，真实使用数量更新也会让预览过期。
        assertThatThrownBy(() -> validator.validateCurrent(
                UUID.randomUUID(), request))
                .isInstanceOf(ApiException.class)
                .hasMessage("排产预览已过期：目标仓库存、占用、计划行或 BOM 已变化，"
                        + "或用量已按真实数据更新，请重新预览");
        verify(planning, never()).applyRequested(any(), any());
    }

    @Test
    void rejectsNullRouteOrSegmentBeforeHashingAndPreview() {
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        request.setRoutes(java.util.Collections.singletonList(null));

        assertThatThrownBy(() -> validator.validateCurrent(
                UUID.randomUUID(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("\u4f9b\u7ed9\u8def\u7ebf");

        request.setRoutes(List.of());
        request.setSegments(java.util.Collections.singletonList(null));
        assertThatThrownBy(() -> validator.validateCurrent(
                UUID.randomUUID(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("\u6267\u884c\u5206\u6bb5");
        verify(planning, never()).preview(any(), any());
    }

    @Test
    void rejectsLegacySubplanItemsBeforePreview() {
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        request.setItems(List.of(new GenerateSubplansRequest.Line()));

        assertThatThrownBy(() -> validator.validateCurrent(
                UUID.randomUUID(), request))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("items 是旧自制子计划字段");
        verify(planning, never()).preview(any(), any());
    }

    @Test
    void rejectsZeroMaterialProductWithoutAnalysisLineage() {
        // 零料候选行只有挂上精确物料分析谱系才会授权为 DIRECT_MAKE；遗留行保持拦截。
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(
                request.getPreviewFingerprint(), List.of(),
                List.of(UUID.randomUUID()));
        when(planning.preview(any(), any())).thenReturn(snapshot);

        assertThatThrownBy(() -> validator.validateCurrent(
                UUID.randomUUID(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("缺少物料分析来源谱系");
        verify(planning, never()).applyRequested(any(), any());
    }

    @Test
    void allowsZeroMaterialProductWhenLineageWasResolvedByPreview() {
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(
                request.getPreviewFingerprint(), List.of(), List.of());
        when(planning.preview(any(), any())).thenReturn(snapshot);
        when(planning.applyRequested(snapshot, request.getSegments()))
                .thenReturn(new CompleteKitAllocator.Allocation(List.of(), Map.of()));

        assertThatCode(() -> validator.validateCurrent(UUID.randomUUID(), request))
                .doesNotThrowAnyException();
    }

    @Test
    void allowsMakeShortageWithoutChildBom() {
        // 自制叶子件（无下层 BOM）缺料合法：派生「造 N 个」裸子计划，不再拦截。
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        CompleteKitAllocator.ProductLine line = productLine(
                ProductionMaterialDemand.ROUTE_MAKE);
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(
                request.getPreviewFingerprint(), List.of(line), List.of());
        when(planning.preview(any(), any())).thenReturn(snapshot);
        when(planning.applyRequested(snapshot, request.getSegments()))
                .thenReturn(allocation(line,
                        ProductionMaterialDemand.ROUTE_MAKE, "1"));

        assertThatCode(() -> validator.validateCurrent(
                UUID.randomUUID(), request))
                .doesNotThrowAnyException();
    }

    @Test
    void buyShortageRequiresPurchaseRequestGeneration() {
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        CompleteKitAllocator.ProductLine line = productLine(
                ProductionMaterialDemand.ROUTE_BUY);
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(
                request.getPreviewFingerprint(), List.of(line), List.of());
        when(planning.preview(any(), any())).thenReturn(snapshot);
        when(planning.applyRequested(snapshot, request.getSegments()))
                .thenReturn(allocation(line,
                        ProductionMaterialDemand.ROUTE_BUY, "1"));

        assertThatThrownBy(() -> validator.validateCurrent(
                UUID.randomUUID(), request))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED))
                .hasMessageContaining("采购申请草稿");
    }

    @Test
    void analysisManagedBuyShortageCanPersistWaitingDraftWithoutDuplicateRequest() {
        GeneratePlanningPackageRequest request = request("a".repeat(64));
        CompleteKitAllocator.ProductLine line = productLine(
                ProductionMaterialDemand.ROUTE_BUY);
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(
                request.getPreviewFingerprint(), List.of(line), List.of());
        when(planning.preview(any(), any())).thenReturn(snapshot);
        when(planning.applyRequested(snapshot, request.getSegments()))
                .thenReturn(allocation(line,
                        ProductionMaterialDemand.ROUTE_BUY, "1"));
        when(planning.fromMaterialAnalysis(snapshot.planId())).thenReturn(true);

        assertThatCode(() -> validator.validateCurrent(
                snapshot.planId(), request)).doesNotThrowAnyException();
    }

    private static GeneratePlanningPackageRequest request(String fingerprint) {
        GeneratePlanningPackageRequest request =
                new GeneratePlanningPackageRequest();
        request.setWarehouseId(UUID.randomUUID());
        request.setIdempotencyKey("planning-draft-test");
        request.setPreviewFingerprint(fingerprint);
        request.setSegments(List.of());
        request.setRoutes(List.of());
        return request;
    }

    private static ProductionExecutionPlanningService.Snapshot snapshot(
            String fingerprint,
            List<CompleteKitAllocator.ProductLine> lines,
            List<UUID> unresolvedZeroMaterialLineageIds) {
        return new ProductionExecutionPlanningService.Snapshot(
                UUID.randomUUID(), UUID.randomUUID(), fingerprint,
                lines, Map.of(), unresolvedZeroMaterialLineageIds);
    }

    private static CompleteKitAllocator.ProductLine productLine(String route) {
        UUID sourceItemId = UUID.randomUUID();
        return new CompleteKitAllocator.ProductLine(
                sourceItemId, 1, UUID.randomUUID(), null, UUID.randomUUID(),
                BigDecimal.ONE, BigDecimal.ONE, LocalDate.now(),
                LocalDate.now(), null, null, null, "P-1", "Product",
                new CompleteKitAllocator.Priority(
                        LocalDate.now(), 1, sourceItemId),
                List.of(new CompleteKitAllocator.MaterialUsage(
                        UUID.randomUUID(), null, UUID.randomUUID(),
                        BigDecimal.ONE, route)),
                "b".repeat(64));
    }

    private static CompleteKitAllocator.Allocation allocation(
            CompleteKitAllocator.ProductLine line,
            String route,
            String shortage) {
        CompleteKitAllocator.MaterialUsage usage = line.materials().getFirst();
        CompleteKitAllocator.MaterialAllocation material =
                new CompleteKitAllocator.MaterialAllocation(
                        usage.goodsId(), usage.colorId(), usage.unitId(),
                        usage.perProductQty(), BigDecimal.ONE, BigDecimal.ZERO,
                        BigDecimal.ZERO, new BigDecimal(shortage), route);
        return new CompleteKitAllocator.Allocation(
                List.of(new CompleteKitAllocator.SegmentAllocation(
                        "segment", line,
                        ProductionExecutionSegment.STATUS_WAITING,
                        BigDecimal.ONE, List.of(material))),
                Map.of());
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }
}
