package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MaterialStockReallocationServiceTest {

    private static final String SOURCE_FP = "a".repeat(64);
    private static final String TARGET_FP = "b".repeat(64);

    @Test
    void createMovesOnlyRequestedOriginalEntitlementAndRefreshesBothAnalyses() {
        Fixture f = fixture();
        CrossReallocationRequest request = f.request(new BigDecimal("4"), "create-once-0001");

        AnalysisView result = f.service().create(f.sourceAnalysisId(), request);

        assertThat(result).isSameAs(f.view());
        ArgumentCaptor<BigDecimal> qty = ArgumentCaptor.forClass(BigDecimal.class);
        verify(f.entitlements()).appendPairedOutIn(
                any(), eq(f.sourceLot()), eq("REALLOCATE_OUT"),
                eq("REALLOCATE_IN"), eq(f.targetAnalysisId()),
                eq(f.targetMaterialId()), any(), qty.capture(), anyString());
        assertThat(qty.getValue()).isEqualByComparingTo("4.0000");
        verify(f.inventoryLock()).lock(new InventoryKey(f.goodsId(), null));
        verify(f.analysisService()).requireCurrent(
                f.sourceHeader(), 3L, SOURCE_FP);
        verify(f.analysisService()).requireCurrent(
                f.targetHeader(), 7L, TARGET_FP);
        verify(f.analysisService()).refreshLocked(f.sourceAnalysisId());
        verify(f.analysisService()).refreshLocked(f.targetAnalysisId());
        verify(f.access(), times(2)).requireWritable(
                any(), anyString(), any(OwnerVisibility.OwnerScope.class));
    }

    @Test
    void createRejectsStaleTargetCasBeforeWritingHeaderOrEntitlement() {
        Fixture f = fixture();
        doThrow(new ApiException(ErrorCode.CONFLICT, "target snapshot changed"))
                .when(f.analysisService()).requireCurrent(
                        f.targetHeader(), 7L, TARGET_FP);

        assertThatThrownBy(() -> f.service().create(
                f.sourceAnalysisId(),
                f.request(new BigDecimal("4"), "stale-target-0001")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("target snapshot changed");

        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
        assertThat(f.insertParameters()).isEmpty();
    }

    @Test
    void createRequiresWriteScopeOnBothAnalyses() {
        Fixture f = fixture();
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "target is outside scope"))
                .when(f.access()).requireWritable(
                        eq(f.targetMakerId()), anyString(),
                        any(OwnerVisibility.OwnerScope.class));

        assertThatThrownBy(() -> f.service().create(
                f.sourceAnalysisId(),
                f.request(new BigDecimal("4"), "forbidden-target-01")))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.FORBIDDEN));

        verify(f.analysisService(), never()).requireCurrent(any(), any(), anyString());
        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
    }

    @Test
    void createRejectsWrongWarehouseOrMaterialDimension() {
        Fixture f = fixture();
        f.targetEndpoint()[8] = UUID.randomUUID();

        assertThatThrownBy(() -> f.service().create(
                f.sourceAnalysisId(),
                f.request(new BigDecimal("4"), "wrong-dimension-01")))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED))
                .hasMessageContaining("同仓库、同货品");

        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
        assertThat(f.insertParameters()).isEmpty();
    }

    @Test
    void createRejectsQuantityBeyondOriginalEntitlement() {
        Fixture f = fixture();

        assertThatThrownBy(() -> f.service().create(
                f.sourceAnalysisId(),
                f.request(new BigDecimal("10.0001"), "over-yield-000001")))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("最多可让 10");

        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
    }

    @Test
    void createReplaysSameIdempotencyPayloadWithoutMovingStockTwice() {
        Fixture f = fixture();
        CrossReallocationRequest request = f.request(
                new BigDecimal("4"), "replay-create-0001");
        String hash = PlanningPackageFingerprint.sha256(List.of(
                "CROSS-REALLOCATE-V1", f.sourceAnalysisId().toString(),
                f.sourceMaterialId().toString(), f.targetAnalysisId().toString(),
                f.targetMaterialId().toString(), "4", request.reason()));
        f.replayRows().add(new Object[]{UUID.randomUUID(), hash, f.sourceAnalysisId()});

        AnalysisView result = f.service().create(f.sourceAnalysisId(), request);

        assertThat(result).isSameAs(f.view());
        verify(f.analysisService(), never()).requireCurrent(any(), any(), anyString());
        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
        assertThat(f.insertParameters()).isEmpty();
    }

    @Test
    void createRejectsSameIdempotencyKeyWithDifferentPayload() {
        Fixture f = fixture();
        f.replayRows().add(new Object[]{
                UUID.randomUUID(), "0".repeat(64), f.sourceAnalysisId()});

        assertThatThrownBy(() -> f.service().create(
                f.sourceAnalysisId(),
                f.request(new BigDecimal("4"), "replay-conflict-01")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("同一幂等键已用于不同让料请求");

        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
    }

    @Test
    void revokeReturnsUnformalizedEntitlementAndRefreshesBothSides() {
        Fixture f = fixture();
        UUID reallocationId = UUID.randomUUID();
        f.reallocationRow(new Object[]{
                reallocationId, f.sourceAnalysisId(), f.sourceMaterialId(),
                f.targetAnalysisId(), f.targetMaterialId(), f.warehouseId(),
                f.goodsId(), null, f.unitId(), new BigDecimal("4"),
                BigDecimal.ZERO, "OPEN", 0L, null, null});
        CrossReallocationRevokeRequest request = new CrossReallocationRevokeRequest(
                3L, SOURCE_FP, 7L, TARGET_FP,
                "计划调整，撤销未使用让料", "revoke-once-0001");

        AnalysisView result = f.service().revoke(
                f.sourceAnalysisId(), reallocationId, request);

        assertThat(result).isSameAs(f.view());
        verify(f.entitlements()).reverseUnformalizedReallocation(
                eq(reallocationId), eq(f.sourceAnalysisId()),
                eq(f.sourceMaterialId()), eq(f.targetAnalysisId()),
                eq(f.targetMaterialId()), any(), anyString());
        assertThat(f.updateParameters()).containsEntry("key", "revoke-once-0001")
                .containsEntry("version", 0L);
        verify(f.analysisService()).refreshLocked(f.sourceAnalysisId());
        verify(f.analysisService()).refreshLocked(f.targetAnalysisId());
    }

    @Test
    void createRejectsSameAnalysisBeforeAnyDatabaseAccess() {
        Fixture f = fixture();
        CrossReallocationRequest request = new CrossReallocationRequest(
                3L, SOURCE_FP, f.sourceMaterialId(), f.sourceAnalysisId(),
                3L, SOURCE_FP, UUID.randomUUID(), BigDecimal.ONE,
                "不能自己让给自己", "same-analysis-001");

        assertThatThrownBy(() -> f.service().create(f.sourceAnalysisId(), request))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED));

        verify(f.em(), never()).createNativeQuery(anyString());
    }

    @Test
    void targetNextQualifiedSupplyIsRePeggedToTheSourcePriority() {
        UUID reallocationId = UUID.randomUUID();
        UUID originEventId = UUID.randomUUID();
        UUID sourceAnalysis = UUID.randomUUID();
        UUID sourceMaterial = UUID.randomUUID();
        UUID targetAnalysis = UUID.randomUUID();
        UUID targetMaterial = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        PreplanStockEntitlementService.AvailableLot targetOrigin =
                new PreplanStockEntitlementService.AvailableLot(
                        originEventId, UUID.randomUUID(), reservationId,
                        targetAnalysis, targetMaterial, "ORIGIN_IQC", null,
                        UUID.randomUUID(), new BigDecimal("10"),
                        goodsId, null, warehouseId);
        EntityManager em = mock(EntityManager.class);
        PreplanStockEntitlementService entitlements =
                mock(PreplanStockEntitlementService.class);
        SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
        UUID actorId = UUID.randomUUID();
        when(user.requireId()).thenReturn(actorId);
        when(entitlements.requireAvailableLot(originEventId, true))
                .thenReturn(targetOrigin);
        Map<String, Object> update = new HashMap<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("SELECT id, from_analysis_id")) {
                return parameterizedQuery(ignored -> List.<Object[]>of(new Object[]{
                        reallocationId, sourceAnalysis, sourceMaterial,
                        targetAnalysis, targetMaterial,
                        new BigDecimal("4"), BigDecimal.ZERO,
                        "OPEN", 0L}), null, null);
            }
            if (sql.contains("UPDATE preplan_material_reallocations")) {
                return parameterizedQuery(ignored -> List.of(), null,
                        new Mutation(update, 1));
            }
            throw new AssertionError("Unexpected priority SQL: " + sql);
        });
        MaterialStockReallocationService service = new MaterialStockReallocationService(
                em, mock(MaterialAnalysisService.class), entitlements,
                mock(ProductionDocumentAccessPolicy.class),
                mock(InventoryMutationLock.class), user, mock(TxSessionVars.class));

        service.applyPriorityForOriginEvent(originEventId);

        verify(entitlements).appendPairedOutIn(
                any(), eq(targetOrigin), eq("PRIORITY_OUT"), eq("PRIORITY_IN"),
                eq(sourceAnalysis), eq(sourceMaterial), eq(reallocationId),
                eq(new BigDecimal("4")), anyString());
        assertThat(update).containsEntry("fulfilled", new BigDecimal("4"))
                .containsEntry("status", "FULFILLED");
    }

    @Test
    void sourceOwnQualifiedSupplySatisfiesPriorityWithoutMovingItsEntitlement() {
        UUID reallocationId = UUID.randomUUID();
        UUID originEventId = UUID.randomUUID();
        UUID sourceAnalysis = UUID.randomUUID();
        UUID sourceMaterial = UUID.randomUUID();
        PreplanStockEntitlementService.AvailableLot sourceOrigin =
                new PreplanStockEntitlementService.AvailableLot(
                        originEventId, UUID.randomUUID(), UUID.randomUUID(),
                        sourceAnalysis, sourceMaterial, "ORIGIN_MAKE", null,
                        UUID.randomUUID(), new BigDecimal("3"),
                        UUID.randomUUID(), null, UUID.randomUUID());
        EntityManager em = mock(EntityManager.class);
        PreplanStockEntitlementService entitlements =
                mock(PreplanStockEntitlementService.class);
        SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
        when(user.requireId()).thenReturn(UUID.randomUUID());
        when(entitlements.requireAvailableLot(originEventId, true))
                .thenReturn(sourceOrigin);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("SELECT id, from_analysis_id")) {
                return parameterizedQuery(ignored -> List.<Object[]>of(new Object[]{
                        reallocationId, sourceAnalysis, sourceMaterial,
                        UUID.randomUUID(), UUID.randomUUID(),
                        new BigDecimal("4"), BigDecimal.ZERO,
                        "OPEN", 0L}), null, null);
            }
            if (sql.contains("UPDATE preplan_material_reallocations")) {
                return parameterizedQuery(ignored -> List.of(), null,
                        new Mutation(new HashMap<>(), 1));
            }
            throw new AssertionError("Unexpected priority SQL: " + sql);
        });
        MaterialStockReallocationService service = new MaterialStockReallocationService(
                em, mock(MaterialAnalysisService.class), entitlements,
                mock(ProductionDocumentAccessPolicy.class),
                mock(InventoryMutationLock.class), user, mock(TxSessionVars.class));

        service.applyPriorityForOriginEvent(originEventId);

        verify(entitlements).appendPrioritySatisfiedInPlace(
                any(), eq(sourceOrigin), eq(reallocationId),
                eq(new BigDecimal("3")), anyString());
        verify(entitlements, never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
    }

    @Test
    void endpointAcceptsJdbcDateAndTimestampWithoutStringGuessing() {
        Fixture f = fixture();
        f.targetEndpoint()[16] = java.sql.Timestamp.valueOf(
                LocalDate.of(2026, 9, 2).atStartOfDay());

        AnalysisView result = f.service().create(
                f.sourceAnalysisId(),
                f.request(new BigDecimal("4"), "jdbc-date-endpoint-1"));

        assertThat(result).isSameAs(f.view());
    }

    @Test
    void candidatesAcceptJdbcDateRowsAndReturnLocalDate() {
        UUID sourceAnalysis = UUID.randomUUID();
        UUID targetAnalysis = UUID.randomUUID();
        UUID sourceMaterial = UUID.randomUUID();
        UUID targetMaterial = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        Object[] sourceEndpoint = endpointRow(
                sourceAnalysis, warehouse, 3L, SOURCE_FP, UUID.randomUUID(),
                sourceMaterial, UUID.randomUUID(), goods, unit,
                new BigDecimal("10"), BigDecimal.ZERO);
        Object[] candidate = new Object[]{
                targetAnalysis, 7L, TARGET_FP, targetMaterial,
                warehouse, "主仓",
                java.sql.Date.valueOf(LocalDate.of(2026, 9, 3)),
                new BigDecimal("4"), "计划B", "P-B", "产品B"
        };
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("SELECT analysis.id, analysis.warehouse_id")) {
                return parameterizedQuery(
                        ignored -> List.<Object[]>of(sourceEndpoint), null, null);
            }
            if (sql.contains("SELECT COUNT(*)")) {
                return parameterizedQuery(ignored -> List.of(), 1L, null);
            }
            if (sql.contains("SELECT analysis.id, analysis.version")) {
                return parameterizedQuery(
                        ignored -> List.<Object[]>of(candidate), null, null);
            }
            throw new AssertionError("Unexpected candidate SQL: " + sql);
        });
        PreplanStockEntitlementService entitlements =
                mock(PreplanStockEntitlementService.class);
        when(entitlements.listAvailableOriginalLots(
                sourceAnalysis, sourceMaterial, warehouse, goods, null, false))
                .thenReturn(List.of(new PreplanStockEntitlementService.AvailableLot(
                        UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                        sourceAnalysis, sourceMaterial, "ORIGIN_IQC", null,
                        UUID.randomUUID(), new BigDecimal("10"),
                        goods, null, warehouse)));
        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(
                new OwnerVisibility.OwnerScope(true, Set.of()));
        MaterialStockReallocationService service =
                new MaterialStockReallocationService(
                        em, mock(MaterialAnalysisService.class), entitlements,
                        access, mock(InventoryMutationLock.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        var result = service.candidates(
                sourceAnalysis, sourceMaterial, null, 1, 20);

        assertThat(result.getItems()).singleElement().satisfies(item -> {
            assertThat(item.deliveryDate()).isEqualTo(LocalDate.of(2026, 9, 3));
            assertThat(item.sourceLendableQty()).isEqualByComparingTo("10");
            assertThat(item.shortageQty()).isEqualByComparingTo("4");
        });
    }

    private static Fixture fixture() {
        UUID sourceAnalysis = UUID.randomUUID();
        UUID targetAnalysis = UUID.randomUUID();
        UUID sourceMaterial = UUID.randomUUID();
        UUID targetMaterial = UUID.randomUUID();
        UUID sourceItem = UUID.randomUUID();
        UUID targetItem = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID sourceMaker = UUID.randomUUID();
        UUID targetMaker = UUID.randomUUID();
        UUID actor = UUID.randomUUID();
        Object[] sourceEndpoint = endpointRow(
                sourceAnalysis, warehouse, 3L, SOURCE_FP, sourceMaker,
                sourceMaterial, sourceItem, goods, unit,
                new BigDecimal("10"), new BigDecimal("0"));
        Object[] targetEndpoint = endpointRow(
                targetAnalysis, warehouse, 7L, TARGET_FP, targetMaker,
                targetMaterial, targetItem, goods, unit,
                BigDecimal.ZERO, new BigDecimal("10"));

        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        PreplanStockEntitlementService entitlements =
                mock(PreplanStockEntitlementService.class);
        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);
        InventoryMutationLock inventory = mock(InventoryMutationLock.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        AnalysisView view = mock(AnalysisView.class);
        MaterialAnalysisService.AnalysisHeader sourceHeader =
                new MaterialAnalysisService.AnalysisHeader(
                        sourceAnalysis, warehouse, "ACTIVE", 3L,
                        SOURCE_FP, OffsetDateTime.now(), sourceMaker);
        MaterialAnalysisService.AnalysisHeader targetHeader =
                new MaterialAnalysisService.AnalysisHeader(
                        targetAnalysis, warehouse, "ACTIVE", 7L,
                        TARGET_FP, OffsetDateTime.now(), targetMaker);
        when(analysis.lockHeader(sourceAnalysis)).thenReturn(sourceHeader);
        when(analysis.lockHeader(targetAnalysis)).thenReturn(targetHeader);
        when(analysis.detailInternal(sourceAnalysis, false)).thenReturn(view);
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        when(currentUser.requireId()).thenReturn(actor);

        PreplanStockEntitlementService.AvailableLot lot =
                new PreplanStockEntitlementService.AvailableLot(
                        UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                        sourceAnalysis, sourceMaterial, "ORIGIN_IQC", null,
                        UUID.randomUUID(), new BigDecimal("10"),
                        goods, null, warehouse);
        when(entitlements.listAvailableOriginalLots(
                sourceAnalysis, sourceMaterial, warehouse, goods, null, true))
                .thenReturn(List.of(lot));

        List<Object[]> replayRows = new java.util.ArrayList<>();
        Object[][] reallocationRow = new Object[1][];
        Map<String, Object> insertParameters = new HashMap<>();
        Map<String, Object> updateParameters = new HashMap<>();

        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("SELECT analysis.id, analysis.warehouse_id")) {
                return parameterizedQuery(parameters -> {
                    UUID analysisId = (UUID) parameters.get("analysisId");
                    return List.<Object[]>of(analysisId.equals(sourceAnalysis)
                            ? sourceEndpoint : targetEndpoint);
                }, null, null);
            }
            if (sql.contains("WHERE created_by = :actorId AND idempotency_key = :key")) {
                return parameterizedQuery(ignored -> List.copyOf(replayRows), null, null);
            }
            if (sql.contains("SELECT id, from_analysis_id, from_analysis_material_id")
                    && sql.contains("WHERE id = :id")) {
                return parameterizedQuery(ignored -> reallocationRow[0] == null
                        ? List.of() : List.<Object[]>of(reallocationRow[0]), null, null);
            }
            if (sql.contains("SELECT COUNT(*)")
                    && (sql.contains("preplan_material_reallocations")
                    || sql.contains("production_material_analysis_borrows"))) {
                return parameterizedQuery(ignored -> List.of(), 0L, null);
            }
            if (sql.contains("INSERT INTO preplan_material_reallocations")) {
                return parameterizedQuery(ignored -> List.of(), null,
                        new Mutation(insertParameters, 1));
            }
            if (sql.contains("UPDATE preplan_material_reallocations")) {
                return parameterizedQuery(ignored -> List.of(), null,
                        new Mutation(updateParameters, 1));
            }
            throw new AssertionError("Unexpected SQL in reallocation test: " + sql);
        });

        MaterialStockReallocationService service =
                new MaterialStockReallocationService(
                        em, analysis, entitlements, access, inventory,
                        currentUser, tx);
        return new Fixture(
                service, em, analysis, entitlements, access, inventory,
                view, sourceHeader, targetHeader, lot,
                sourceAnalysis, targetAnalysis, sourceMaterial, targetMaterial,
                warehouse, goods, unit, sourceMaker, targetMaker,
                sourceEndpoint, targetEndpoint, replayRows, reallocationRow,
                insertParameters, updateParameters);
    }

    private static Object[] endpointRow(
            UUID analysisId, UUID warehouseId, long version, String fingerprint,
            UUID makerId, UUID materialId, UUID itemId,
            UUID goodsId, UUID unitId,
            BigDecimal allocated, BigDecimal shortage) {
        return new Object[]{
                analysisId, warehouseId, "ACTIVE", version, fingerprint, makerId,
                materialId, itemId, goodsId, null, unitId,
                1, "START", allocated, shortage, true,
                java.sql.Date.valueOf(LocalDate.of(2026, 9, 1)),
                "生产计划测试行", "P-001", "测试产品"
        };
    }

    private static Query parameterizedQuery(
            Function<Map<String, Object>, List<?>> rows,
            Object scalar,
            Mutation mutation) {
        Query query = mock(Query.class);
        Map<String, Object> parameters = mutation == null
                ? new HashMap<>() : mutation.parameters();
        when(query.setParameter(anyString(), any())).thenAnswer(invocation -> {
            parameters.put(invocation.getArgument(0), invocation.getArgument(1));
            return query;
        });
        when(query.setFirstResult(anyInt())).thenReturn(query);
        when(query.setMaxResults(anyInt())).thenReturn(query);
        when(query.getResultList()).thenAnswer(ignored -> rows.apply(parameters));
        when(query.getSingleResult()).thenReturn(scalar);
        when(query.executeUpdate()).thenAnswer(ignored ->
                mutation == null ? 0 : mutation.result());
        return query;
    }

    private record Mutation(Map<String, Object> parameters, int result) {
    }

    private record Fixture(
            MaterialStockReallocationService service,
            EntityManager em,
            MaterialAnalysisService analysisService,
            PreplanStockEntitlementService entitlements,
            ProductionDocumentAccessPolicy access,
            InventoryMutationLock inventoryLock,
            AnalysisView view,
            MaterialAnalysisService.AnalysisHeader sourceHeader,
            MaterialAnalysisService.AnalysisHeader targetHeader,
            PreplanStockEntitlementService.AvailableLot sourceLot,
            UUID sourceAnalysisId,
            UUID targetAnalysisId,
            UUID sourceMaterialId,
            UUID targetMaterialId,
            UUID warehouseId,
            UUID goodsId,
            UUID unitId,
            UUID sourceMakerId,
            UUID targetMakerId,
            Object[] sourceEndpoint,
            Object[] targetEndpoint,
            List<Object[]> replayRows,
            Object[][] reallocationHolder,
            Map<String, Object> insertParameters,
            Map<String, Object> updateParameters) {

        CrossReallocationRequest request(BigDecimal qty, String key) {
            return new CrossReallocationRequest(
                    3L, SOURCE_FP, sourceMaterialId, targetAnalysisId,
                    7L, TARGET_FP, targetMaterialId, qty,
                    "缺料计划优先生产，让出合格现货", key);
        }

        void reallocationRow(Object[] row) {
            reallocationHolder[0] = row;
        }
    }
}
