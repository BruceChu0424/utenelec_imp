package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionFulfillmentLedgerServiceTest {

    @ParameterizedTest
    @ValueSource(strings = {
            ProductionPlanningPackage.STATUS_CANCELLED,
            ProductionPlanningPackage.STATUS_REVERSED
    })
    void terminalPackageCannotBeReplayedAsSuccessfulConfirmation(String status) {
        UUID planId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        String requestHash = "request-hash";
        String fingerprint = "a".repeat(64);
        String key = "confirm-key-0001";
        ProductionPlanningPackageRepository packageRepo =
                mock(ProductionPlanningPackageRepository.class);
        ProductionPlanningPackage existing = new ProductionPlanningPackage();
        existing.setPlanId(planId);
        existing.setWarehouseId(warehouseId);
        existing.setIdempotencyKey(key);
        existing.setRequestHash(requestHash);
        existing.setPreviewFingerprint(fingerprint);
        existing.setStatus(status);
        when(packageRepo.lockByPlanAndKey(planId, key))
                .thenReturn(Optional.of(existing));
        ProductionFulfillmentLedgerService service =
                new ProductionFulfillmentLedgerService(
                        packageRepo, null, null, null, null);

        assertThatThrownBy(() -> service.beginConfirmation(
                planId, warehouseId, key, requestHash, fingerprint))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("\u65b0\u7684\u5e42\u7b49\u952e");

        verify(packageRepo, never()).lockConfirmedByPlan(planId);
    }

    @Test
    void confirmationReplayUsesTheSameTrimmedIdempotencyKey() {
        UUID planId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        String requestHash = "request-hash";
        String fingerprint = "a".repeat(64);
        String key = "confirm-key-0002";
        ProductionPlanningPackageRepository packageRepo =
                mock(ProductionPlanningPackageRepository.class);
        ProductionPlanningPackage existing = new ProductionPlanningPackage();
        existing.setPlanId(planId);
        existing.setWarehouseId(warehouseId);
        existing.setIdempotencyKey(key);
        existing.setRequestHash(requestHash);
        existing.setPreviewFingerprint(fingerprint);
        existing.setStatus(ProductionPlanningPackage.STATUS_CONFIRMED);
        when(packageRepo.lockByPlanAndKey(planId, key))
                .thenReturn(Optional.of(existing));
        ProductionFulfillmentLedgerService service =
                new ProductionFulfillmentLedgerService(
                        packageRepo, null, null, null, null);

        ProductionFulfillmentLedgerService.BeginConfirmation result =
                service.beginConfirmation(
                        planId,
                        warehouseId,
                        "  " + key + "  ",
                        requestHash,
                        fingerprint);

        assertThat(result.replayed()).isTrue();
        assertThat(result.planningPackage()).isSameAs(existing);
    }
}
