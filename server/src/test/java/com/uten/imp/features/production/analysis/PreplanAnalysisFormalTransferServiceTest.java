package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanAnalysisPegPort.FormalReservationSlice;
import com.uten.imp.application.port.PreplanAnalysisPegPort.PreparedPlanTransfer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PreplanAnalysisFormalTransferServiceTest {

    @Test
    void readyDemandBindsEveryPreparedLotToThePersistedFormalReservation() {
        Fixture f = fixture();
        UUID packageId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID formalReservationId = UUID.randomUUID();
        PreparedPlanTransfer first = prepared(demandId, "4");
        PreparedPlanTransfer second = prepared(demandId, "6");

        f.service().formalizePlanDemandTransfers(
                packageId, List.of(first, second),
                List.of(new FormalReservationSlice(
                        demandId, formalReservationId, new BigDecimal("10"))));

        verify(f.entitlements()).appendFormalize(
                eq(packageId), eq(first.sourceEntitlementEventId()),
                eq(first.sourceStockReservationId()),
                eq(first.beneficiaryAnalysisId()),
                eq(first.beneficiaryAnalysisMaterialId()),
                eq(first.qty()), eq(packageId), eq(demandId),
                eq(formalReservationId), anyString());
        verify(f.entitlements()).appendFormalize(
                eq(packageId), eq(second.sourceEntitlementEventId()),
                eq(second.sourceStockReservationId()),
                eq(second.beneficiaryAnalysisId()),
                eq(second.beneficiaryAnalysisMaterialId()),
                eq(second.qty()), eq(packageId), eq(demandId),
                eq(formalReservationId), anyString());
    }

    @Test
    void formalReservationMustCoverAllPreparedEntitlementSlices() {
        Fixture f = fixture();
        UUID packageId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        PreparedPlanTransfer first = prepared(demandId, "4");
        PreparedPlanTransfer second = prepared(demandId, "6");

        assertThatThrownBy(() -> f.service().formalizePlanDemandTransfers(
                packageId, List.of(first, second),
                List.of(new FormalReservationSlice(
                        demandId, UUID.randomUUID(), new BigDecimal("9.9999")))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("does not cover");

        verify(f.entitlements(), never()).appendFormalize(
                eq(packageId), eq(first.sourceEntitlementEventId()),
                eq(first.sourceStockReservationId()),
                eq(first.beneficiaryAnalysisId()),
                eq(first.beneficiaryAnalysisMaterialId()),
                eq(first.qty()), eq(packageId), eq(demandId),
                org.mockito.ArgumentMatchers.any(), anyString());
    }

    @Test
    void cancelledUnissuedFormalReservationRestoresEventAndPhysicalSourceLot() {
        Fixture f = fixture();
        UUID formalReservationId = UUID.randomUUID();
        PreplanStockEntitlementService.Formalization formalization =
                new PreplanStockEntitlementService.Formalization(
                        UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                        UUID.randomUUID(), new BigDecimal("4"), UUID.randomUUID(), null,
                        UUID.randomUUID(),
                        UUID.randomUUID(), UUID.randomUUID(),
                        formalReservationId);
        when(f.entitlements().listActiveFormalizations(
                List.of(formalReservationId), true))
                .thenReturn(List.of(formalization));

        f.service().restorePlanDemandTransfers(
                List.of(formalReservationId), "计划包取消恢复");

        verify(f.entitlements()).appendRestore(
                eq(formalization.targetPackageId()), eq(formalization), anyString());
        verify(f.entitlements()).restorePhysicalAfterFormalRelease(
                formalization.sourceStockReservationId(), formalization.qty());
    }

    private static PreparedPlanTransfer prepared(UUID demandId, String qty) {
        return new PreparedPlanTransfer(
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), demandId, new BigDecimal(qty));
    }

    @SuppressWarnings("unchecked")
    private static Fixture fixture() {
        PreplanStockEntitlementService entitlements =
                mock(PreplanStockEntitlementService.class);
        PreplanAnalysisStockPegService service =
                new PreplanAnalysisStockPegService(
                        mock(EntityManager.class), mock(TxSessionVars.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(InventoryMutationLock.class), entitlements,
                        mock(ObjectProvider.class));
        return new Fixture(service, entitlements);
    }

    private record Fixture(
            PreplanAnalysisStockPegService service,
            PreplanStockEntitlementService entitlements) {
    }
}
