package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MaterialAnalysisServiceBehaviorTest {

    @Test
    void manualSourceRequiresAStableReference() {
        MaterialAnalysisService service = service(mock(EntityManager.class),
                mock(ProductionDocumentAccessPolicy.class));
        PreviewItem missingReference = manualItem("   ");

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                service, "normalizePreviewItems", new Class<?>[]{List.class},
                List.of(missingReference)));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void manualReferenceReopensTheSameActiveAnalysisIgnoringCase() {
        EntityManager em = mock(EntityManager.class);
        ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        MaterialAnalysisService service = service(em, access);
        UUID analysisId = UUID.randomUUID();
        PreviewItem requested = manualItem("req-2026-001");

        Query matches = query(Collections.singletonList(
                new Object[]{analysisId, MaterialAnalysisService.STATUS_ACTIVE}));
        Query identities = query(Collections.singletonList(new Object[]{
                requested.sourceType(), null, requested.goodsId(), requested.colorId(),
                requested.unitId(), "  REQ-2026-001  "}));
        when(em.createNativeQuery(anyString())).thenReturn(matches, identities);

        UUID reused = invokePrivate(service, "findReusableAnalysis",
                new Class<?>[]{List.class}, List.of(requested));

        assertThat(reused).isEqualTo(analysisId);
        verify(matches).setParameter("sourceRef", "req-2026-001");
    }

    @Test
    void completedManualReferenceMustBeOpenedFromHistoryInsteadOfDuplicated() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));
        Query matches = query(Collections.singletonList(
                new Object[]{UUID.randomUUID(), "COMPLETED"}));
        when(em.createNativeQuery(anyString())).thenReturn(matches);

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                service, "findReusableAnalysis", new Class<?>[]{List.class},
                List.of(manualItem("REQ-HISTORY-001"))));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void historyListAppliesOwnerScopeCapsPagingAndReturnsRecoveryFields() {
        EntityManager em = mock(EntityManager.class);
        ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        MaterialAnalysisService service = service(em, access);
        UUID ownerId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        OffsetDateTime analyzedAt = OffsetDateTime.of(
                2026, 8, 8, 8, 0, 0, 0, ZoneOffset.UTC);
        OffsetDateTime updatedAt = analyzedAt.plusHours(2);
        OwnerVisibility.OwnerScope scope = new OwnerVisibility.OwnerScope(
                false, Set.of(ownerId));
        DocumentAccessPolicy.NativeReadScope nativeScope =
                new DocumentAccessPolicy.NativeReadScope(
                        "analysis.maker_id IN (:analysisOwners)",
                        "analysisOwners", Set.of(ownerId));
        when(access.scope()).thenReturn(scope);
        when(access.nativeReadScope("analysis.maker_id", "analysisOwners", scope))
                .thenReturn(nativeScope);

        Query count = queryWithSingleResult(2L);
        Object[] row = new Object[]{
                analysisId, "ACTIVE", 7L, "a".repeat(64), warehouseId,
                "W-01", "Main warehouse", analyzedAt, updatedAt, ownerId, "Owner",
                1, "SALES_ORDER_ITEM", "SO-2026-001", "FG-01 Finished good",
                bd("100"), bd("10"), bd("20"), bd("70"), bd("10"), bd("15")
        };
        Query data = query(Collections.singletonList(row));
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            sql.add(statement);
            return statement.startsWith("SELECT COUNT(*)") ? count : data;
        });

        var page = service.list(
                " so-2026 ", " active ", " sales_order_item ", 99, 1000);

        assertThat(page.getPage()).isEqualTo(1);
        assertThat(page.getSize()).isEqualTo(100);
        assertThat(page.getTotal()).isEqualTo(2);
        assertThat(page.getItems()).singleElement().satisfies(item -> {
            assertThat(item.analysisId()).isEqualTo(analysisId);
            assertThat(item.updatedAt()).isEqualTo(updatedAt);
            assertThat(item.sourceRefs()).containsExactly("SO-2026-001");
            assertThat(item.remainingQty()).isEqualByComparingTo("70");
        });
        verify(count).setParameter("analysisOwners", Set.of(ownerId));
        verify(data).setParameter("analysisOwners", Set.of(ownerId));
        assertThat(sql).anySatisfy(statement ->
                assertThat(statement).contains(
                        "NULLIF(btrim(source.source_ref),''), sales_order.bill_no"));
    }

    @Test
    void changedDirectBomSignatureBlocksFormalPlanning() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));
        UUID analysisId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID componentId = UUID.randomUUID();
        UUID productUnitId = UUID.randomUUID();
        UUID componentUnitId = UUID.randomUUID();
        UUID bomItemId = UUID.randomUUID();

        Query sources = query(Collections.singletonList(sourceRow(
                itemId, productId, productUnitId)));
        Query graphValidation = query(Collections.singletonList(
                new Object[]{false, false, false}));
        Query currentBom = query(Collections.singletonList(new Object[]{
                bomItemId, productId, componentId, null, componentUnitId, 1,
                bomItemId.toString(), null, bd("2"), "C-01", "Component", null,
                null, "piece", BigDecimal.ZERO, "\u91c7\u8d2d", false
        }));
        Query staleSnapshot = query(Collections.singletonList(new Object[]{
                bomItemId, componentId, null, componentUnitId, bd("3"), "BUY"
        }));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            if (statement.contains("FROM production_material_analysis_items ai")) {
                return sources;
            }
            if (statement.contains("WITH RECURSIVE walk AS")) {
                return graphValidation;
            }
            if (statement.contains("WITH RECURSIVE exp AS")) {
                return currentBom;
            }
            if (statement.contains("FROM production_material_analysis_materials")) {
                return staleSnapshot;
            }
            throw new AssertionError("unexpected SQL: " + statement);
        });

        ApiException error = assertThrows(ApiException.class,
                () -> service.requireCurrentBomSnapshot(analysisId, Set.of(itemId)));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void notifyStillRejectsAnUnconfirmedActionableRoute() {
        MaterialAnalysisCommandService commands = mock(
                MaterialAnalysisCommandService.class,
                org.mockito.Answers.CALLS_REAL_METHODS);
        UUID materialId = UUID.randomUUID();
        MaterialView material = material(materialId, false, null);
        AnalysisView view = new AnalysisView(
                UUID.randomUUID(), "ACTIVE", 1L, "a".repeat(64), "b".repeat(64),
                UUID.randomUUID(), OffsetDateTime.now(), List.of(), List.of(material),
                List.of(), List.of(), List.of());
        NotifyRequest request = new NotifyRequest(
                1L, "a".repeat(64), "notify-0001", null,
                List.of(materialId), List.of());

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                commands, "selectedGroups",
                new Class<?>[]{AnalysisView.class, NotifyRequest.class}, view, request));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    private static MaterialAnalysisService service(
            EntityManager em, ProductionDocumentAccessPolicy access) {
        return new MaterialAnalysisService(
                em, mock(SecurityContextCurrentUser.class), mock(TxSessionVars.class), access);
    }

    private static PreviewItem manualItem(String sourceRef) {
        return new PreviewItem(
                "OTHER", null, UUID.fromString("10000000-0000-0000-0000-000000000001"),
                null, UUID.fromString("20000000-0000-0000-0000-000000000001"),
                sourceRef, "manual production demand", LocalDate.of(2026, 8, 20),
                bd("100"));
    }

    private static Object[] sourceRow(UUID itemId, UUID goodsId, UUID unitId) {
        return new Object[]{
                itemId, "OTHER", null, null, null, null,
                LocalDate.of(2026, 8, 20), null,
                goodsId, "FG-01", "Finished good", null, null, null,
                unitId, "piece", BigDecimal.ONE, bd("100"), BigDecimal.ZERO,
                BigDecimal.ZERO, "BOM_REQUIRED", true, bd("100"), BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, null, false, false, false, false,
                "REQ-BOM-001", "BOM signature test", 1, bd("10"), bd("10")
        };
    }

    private static MaterialView material(
            UUID materialId, boolean routeConfirmed, String confirmedRoute) {
        UUID itemId = UUID.randomUUID();
        return new MaterialView(
                materialId, itemId, "node-1", "group-1", "material-1",
                UUID.randomUUID(), "M-01", "Material", null, null, null,
                UUID.randomUUID(), "piece", 1, List.of("Material"), null, null, null,
                BigDecimal.ONE, bd("100"), BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, bd("90"), null,
                "BUY", confirmedRoute, routeConfirmed, null, "BOM_REQUIRED", false,
                true, false, List.of(), List.of(), List.of());
    }

    private static Query query(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        org.mockito.Mockito.doReturn(rows).when(query).getResultList();
        return query;
    }

    private static Query queryWithSingleResult(Object value) {
        Query query = query(List.of());
        when(query.getSingleResult()).thenReturn(value);
        return query;
    }

    @SuppressWarnings("unchecked")
    private static <T> T invokePrivate(
            Object target, String methodName, Class<?>[] parameterTypes, Object... arguments) {
        try {
            Method method = target.getClass().getDeclaredMethod(methodName, parameterTypes);
            method.setAccessible(true);
            return (T) method.invoke(target, arguments);
        } catch (InvocationTargetException error) {
            if (error.getCause() instanceof RuntimeException runtime) {
                throw runtime;
            }
            throw new AssertionError(error.getCause());
        } catch (ReflectiveOperationException error) {
            throw new AssertionError(error);
        }
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
