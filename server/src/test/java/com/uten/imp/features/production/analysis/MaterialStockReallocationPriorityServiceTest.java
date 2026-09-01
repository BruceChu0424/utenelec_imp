package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MaterialStockReallocationPriorityServiceTest {

    @Test
    void borrowerNextQualifiedLotGivesOnlyOpenPriorityToSourceAndLeavesRemainder() {
        Fixture f = fixture(false);

        f.service().applyPriorityForOriginEvent(f.originEventId());

        ArgumentCaptor<BigDecimal> moved = ArgumentCaptor.forClass(BigDecimal.class);
        verify(f.entitlements()).appendPairedOutIn(
                any(), eq(f.originLot()), eq("PRIORITY_OUT"), eq("PRIORITY_IN"),
                eq(f.sourceAnalysisId()), eq(f.sourceMaterialId()),
                eq(f.reallocationId()), moved.capture(), anyString());
        assertThat(moved.getValue()).isEqualByComparingTo("4");
        verify(f.entitlements(), never()).appendPrioritySatisfiedInPlace(
                any(), any(), any(), any(), anyString());
        assertThat(f.updateParameters())
                .containsEntry("fulfilled", new BigDecimal("4"))
                .containsEntry("status", "FULFILLED")
                .containsEntry("version", 0L);
        assertThat(f.originLot().remainingQty().subtract(moved.getValue()))
                .isEqualByComparingTo("6");
    }

    @Test
    void sourceOwnQualifiedLotSatisfiesPriorityInPlaceWithoutMovingBeneficiary() {
        Fixture f = fixture(true);

        f.service().applyPriorityForOriginEvent(f.originEventId());

        ArgumentCaptor<BigDecimal> satisfied = ArgumentCaptor.forClass(BigDecimal.class);
        verify(f.entitlements()).appendPrioritySatisfiedInPlace(
                any(), eq(f.originLot()), eq(f.reallocationId()),
                satisfied.capture(), anyString());
        assertThat(satisfied.getValue()).isEqualByComparingTo("4");
        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
        assertThat(f.updateParameters())
                .containsEntry("fulfilled", new BigDecimal("4"))
                .containsEntry("status", "FULFILLED");
    }

    @Test
    void unrelatedFirmExactLotCannotBeAutomaticallyTaken() {
        Fixture f = fixture(false);
        f.priorityRows().clear();

        f.service().applyPriorityForOriginEvent(f.originEventId());

        verify(f.entitlements(), never()).appendPairedOutIn(
                any(), any(), anyString(), anyString(), any(), any(),
                any(), any(), anyString());
        verify(f.entitlements(), never()).appendPrioritySatisfiedInPlace(
                any(), any(), any(), any(), anyString());
        assertThat(f.updateParameters()).isEmpty();
    }

    @Test
    void earlierOrderedHookMayConsumeTheCompleteOriginLot() {
        UUID originEvent = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        PreplanStockEntitlementService entitlements =
                mock(PreplanStockEntitlementService.class);
        MaterialStockReallocationService service =
                new MaterialStockReallocationService(
                        em, mock(MaterialAnalysisService.class), entitlements,
                        mock(ProductionDocumentAccessPolicy.class),
                        mock(InventoryMutationLock.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        service.applyPriorityForOriginEvent(originEvent);

        verify(entitlements).availableLotOrNull(originEvent, true);
        verify(em, never()).createNativeQuery(anyString());
    }

    private static Fixture fixture(boolean sourceOwnLot) {
        UUID sourceAnalysis = UUID.randomUUID();
        UUID sourceMaterial = UUID.randomUUID();
        UUID targetAnalysis = UUID.randomUUID();
        UUID targetMaterial = UUID.randomUUID();
        UUID reallocation = UUID.randomUUID();
        UUID originEvent = UUID.randomUUID();
        UUID actor = UUID.randomUUID();

        UUID lotAnalysis = sourceOwnLot ? sourceAnalysis : targetAnalysis;
        UUID lotMaterial = sourceOwnLot ? sourceMaterial : targetMaterial;
        PreplanStockEntitlementService.AvailableLot lot =
                new PreplanStockEntitlementService.AvailableLot(
                        originEvent, UUID.randomUUID(), UUID.randomUUID(),
                        lotAnalysis, lotMaterial, "ORIGIN_IQC", null,
                        UUID.randomUUID(), new BigDecimal("10"),
                        UUID.randomUUID(), null, UUID.randomUUID());
        List<Object[]> rows = new ArrayList<>();
        rows.add(new Object[]{
                reallocation, sourceAnalysis, sourceMaterial,
                targetAnalysis, targetMaterial,
                new BigDecimal("4"), BigDecimal.ZERO, "OPEN", 0L});
        Map<String, Object> updateParameters = new HashMap<>();

        EntityManager em = mock(EntityManager.class);
        Query select = parameterizedQuery(rows, null, null);
        Query update = parameterizedQuery(List.of(), null, updateParameters);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("SELECT id, from_analysis_id")) return select;
            if (sql.contains("UPDATE preplan_material_reallocations")) return update;
            throw new AssertionError("Unexpected priority SQL: " + sql);
        });

        PreplanStockEntitlementService entitlements =
                mock(PreplanStockEntitlementService.class);
        when(entitlements.availableLotOrNull(originEvent, true)).thenReturn(lot);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(actor);
        MaterialStockReallocationService service =
                new MaterialStockReallocationService(
                        em, mock(MaterialAnalysisService.class), entitlements,
                        mock(ProductionDocumentAccessPolicy.class),
                        mock(InventoryMutationLock.class), currentUser,
                        mock(TxSessionVars.class));
        return new Fixture(
                service, entitlements, lot, rows, updateParameters,
                originEvent, reallocation,
                sourceAnalysis, sourceMaterial);
    }

    private static Query parameterizedQuery(
            List<?> rows, Object scalar, Map<String, Object> parameters) {
        Query query = mock(Query.class);
        Map<String, Object> values = parameters == null
                ? new HashMap<>() : parameters;
        when(query.setParameter(anyString(), any())).thenAnswer(invocation -> {
            values.put(invocation.getArgument(0), invocation.getArgument(1));
            return query;
        });
        when(query.getResultList()).thenReturn(rows);
        when(query.getSingleResult()).thenReturn(scalar);
        when(query.executeUpdate()).thenReturn(1);
        return query;
    }

    private record Fixture(
            MaterialStockReallocationService service,
            PreplanStockEntitlementService entitlements,
            PreplanStockEntitlementService.AvailableLot originLot,
            List<Object[]> priorityRows,
            Map<String, Object> updateParameters,
            UUID originEventId,
            UUID reallocationId,
            UUID sourceAnalysisId,
            UUID sourceMaterialId) {
    }
}
