package com.uten.imp.features.production.analysis;

import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PreplanAnalysisCancellationSliceServiceTest {

    @Test
    void fulfilledSourceCancellationReleasesOnlySourceBeneficiarySlice()
            throws Exception {
        CancellationFixture fixture =
                fixture(new BigDecimal("4"), List.of(), true);

        fixture.service().releaseForAnalysis(
                fixture.analysisId(), "取消来源计划", "cancel-source-0001");

        verify(fixture.entitlement()).appendReleaseForBeneficiaryAnalysis(
                eq(fixture.analysisId()), eq(fixture.analysisId()), anyString());
        verify(fixture.sliceUpdate()).setParameter(
                "releaseQty", new BigDecimal("4"));
        verify(fixture.sliceUpdate()).executeUpdate();
        verify(fixture.closeUpdate()).setParameter(eq("closeKey"), anyString());
        verify(fixture.closeUpdate()).setParameter(eq("closeHash"), anyString());
        verify(fixture.closeUpdate()).executeUpdate();
        assertSliceSafeSql(fixture, "from_analysis_id");
    }

    @Test
    void fulfilledTargetCancellationReleasesOnlyTargetBeneficiarySlice()
            throws Exception {
        CancellationFixture fixture =
                fixture(new BigDecimal("6"), List.of(), true);

        fixture.service().releaseForAnalysis(
                fixture.analysisId(), "取消接受计划", "cancel-target-0001");

        verify(fixture.entitlement()).appendReleaseForBeneficiaryAnalysis(
                eq(fixture.analysisId()), eq(fixture.analysisId()), anyString());
        verify(fixture.sliceUpdate()).setParameter(
                "releaseQty", new BigDecimal("6"));
        verify(fixture.sliceUpdate()).executeUpdate();
        verify(fixture.closeUpdate()).executeUpdate();
        assertSliceSafeSql(fixture, "to_analysis_id");
    }

    @Test
    void legacyReservationWithoutAnyEntitlementEventStillUsesWholeRowRelease() {
        UUID reservationId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        List<Object[]> legacyRows = List.<Object[]>of(new Object[]{
                reservationId, BigDecimal.TEN, BigDecimal.ZERO,
                BigDecimal.ZERO, goodsId, colorId, (short) 0, null
        });
        CancellationFixture fixture = fixture(null, legacyRows, false);

        fixture.service().releaseForAnalysis(
                fixture.analysisId(), "取消遗留分析", "cancel-legacy-0001");

        verify(fixture.entitlement()).appendReleaseForBeneficiaryAnalysis(
                eq(fixture.analysisId()), eq(fixture.analysisId()), anyString());
        verify(fixture.entitlement()).appendReleaseForReservation(
                reservationId, reservationId,
                "PREPLAN-RELEASE:" + reservationId);
        verify(fixture.legacyUpdate()).setParameter("id", reservationId);
        verify(fixture.legacyUpdate()).executeUpdate();
        assertThat(fixture.sql())
                .anySatisfy(sql -> assertThat(sql)
                        .contains("SELECT r.id, r.qty")
                        .contains("NOT EXISTS")
                        .contains("event.stock_reservation_id = r.id"))
                .anySatisfy(sql -> assertThat(sql)
                        .contains("SET released_qty = qty"));
    }

    private static void assertSliceSafeSql(
            CancellationFixture fixture, String endpointColumn) {
        assertThat(fixture.sql())
                .anySatisfy(sql -> assertThat(sql)
                        .contains("status IN ('OPEN', 'PARTIAL')")
                        .doesNotContain("'FULFILLED'"))
                .anySatisfy(sql -> assertThat(sql)
                        .contains("SET released_qty = released_qty + :releaseQty")
                        .contains("ELSE :effective")
                        .contains("ELSE release_reason"))
                .anySatisfy(sql -> assertThat(sql)
                        .contains("SELECT r.id, r.qty")
                        .contains("NOT EXISTS")
                        .contains("preplan_stock_entitlement_events event"))
                .anySatisfy(sql -> assertThat(sql)
                        .contains("reallocation.status = 'FULFILLED'")
                        .contains(endpointColumn))
                .anySatisfy(sql -> assertThat(sql)
                        .contains("SET status = 'CANCELLED'")
                        .contains("close_idempotency_key = :closeKey")
                        .contains("close_request_hash = :closeHash"));
        assertThat(fixture.sql().stream()
                .filter(sql -> sql.contains("UPDATE stock_reservations"))
                .toList())
                .allSatisfy(sql -> assertThat(sql)
                        .doesNotContain("SET released_qty = qty"));
    }

    private static CancellationFixture fixture(
            BigDecimal sliceQty,
            List<Object[]> legacyRows,
            boolean fulfilled) {
        EntityManager em = mock(EntityManager.class);
        Query openRelations = query(List.of(), 0);
        Query sliceUpdate = query(List.of(), 1);
        Query legacyScope = query(legacyRows, 0);
        Query reallocationSafety = query(List.of(), 0);
        Query beneficiarySafety = query(List.of(), 0);
        Query fulfilledRows = query(
                fulfilled
                        ? List.<Object[]>of(
                                new Object[]{UUID.randomUUID(), 3L})
                        : List.of(),
                0);
        Query closeUpdate = query(List.of(), 1);
        Query legacyUpdate = query(List.of(), 1);
        java.util.List<String> sql = new java.util.ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0, String.class);
            sql.add(statement);
            if (statement.contains("status IN ('OPEN', 'PARTIAL')")) {
                return openRelations;
            }
            if (statement.contains(
                    "SET released_qty = released_qty + :releaseQty")) {
                return sliceUpdate;
            }
            if (statement.contains("SELECT r.id, r.qty")) {
                return legacyScope;
            }
            if (statement.contains(
                    "JOIN preplan_stock_entitlement_events event")) {
                return reallocationSafety;
            }
            if (statement.contains(
                    "JOIN preplan_analysis_stock_exact_pegs exact_peg")) {
                return beneficiarySafety;
            }
            if (statement.contains(
                    "SELECT reallocation.id, reallocation.lock_version")) {
                return fulfilledRows;
            }
            if (statement.contains("SET status = 'CANCELLED'")) {
                return closeUpdate;
            }
            if (statement.contains("SET released_qty = qty")) {
                return legacyUpdate;
            }
            throw new AssertionError("Unexpected cancellation SQL: " + statement);
        });

        PreplanStockEntitlementService entitlement =
                mock(PreplanStockEntitlementService.class);
        UUID analysisId = UUID.randomUUID();
        if (sliceQty == null) {
            when(entitlement.appendReleaseForBeneficiaryAnalysis(
                    eq(analysisId), eq(analysisId), anyString()))
                    .thenReturn(List.of());
        } else {
            when(entitlement.appendReleaseForBeneficiaryAnalysis(
                    eq(analysisId), eq(analysisId), anyString()))
                    .thenReturn(List.of(
                            new PreplanStockEntitlementService.ReservationRelease(
                                    UUID.randomUUID(), UUID.randomUUID(),
                                    UUID.randomUUID(), sliceQty)));
        }
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        PreplanAnalysisStockPegService service =
                new PreplanAnalysisStockPegService(
                        em, mock(TxSessionVars.class), currentUser,
                        mock(InventoryMutationLock.class), entitlement,
                        mock(ObjectProvider.class));
        return new CancellationFixture(
                service, entitlement, sliceUpdate, closeUpdate,
                legacyUpdate, analysisId, sql);
    }

    private static Query query(List<?> rows, int updated) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenAnswer(ignored -> rows);
        when(query.executeUpdate()).thenReturn(updated);
        return query;
    }

    private record CancellationFixture(
            PreplanAnalysisStockPegService service,
            PreplanStockEntitlementService entitlement,
            Query sliceUpdate,
            Query closeUpdate,
            Query legacyUpdate,
            UUID analysisId,
            List<String> sql) {
    }
}
