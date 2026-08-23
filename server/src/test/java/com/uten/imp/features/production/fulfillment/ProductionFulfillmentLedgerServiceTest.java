package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
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
                        packageRepo, null, null, null, null, null);

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
                        packageRepo, null, null, null, null, null);

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

    @Test
    void exactDemandPersistsTheFrozenSegmentQuantityAndRuleFingerprint() {
        ProductionMaterialDemandRepository demandRepo =
                mock(ProductionMaterialDemandRepository.class);
        when(demandRepo.save(any(ProductionMaterialDemand.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));
        ProductionFulfillmentLedgerService service =
                new ProductionFulfillmentLedgerService(
                        null, demandRepo, null, null, null, null);
        ProductionPlanningPackage planningPackage =
                new ProductionPlanningPackage();
        planningPackage.setId(UUID.randomUUID());
        planningPackage.setPlanId(UUID.randomUUID());
        planningPackage.setWarehouseId(UUID.randomUUID());
        UUID segmentId = UUID.randomUUID();
        UUID sourceItemId = UUID.randomUUID();
        String fingerprint = "a".repeat(64);

        List<ProductionMaterialDemand> created = service.createDemands(
                planningPackage,
                List.of(new ProductionFulfillmentLedgerService.DemandDraft(
                        segmentId,
                        sourceItemId,
                        UUID.randomUUID(),
                        null,
                        UUID.randomUUID(),
                        new BigDecimal("0.000250"),
                        new BigDecimal("3"),
                        LocalDate.of(2026, 8, 9),
                        ProductionMaterialDemand.ROUTE_BUY,
                        "exact-demand-1",
                        ProductionMaterialDemand
                                .REQUIREMENT_MODE_EXACT_SNAPSHOT,
                        new BigDecimal("9999"),
                        fingerprint)));

        assertThat(created).singleElement().satisfies(demand -> {
            assertThat(demand.getRequirementMode()).isEqualTo(
                    ProductionMaterialDemand
                            .REQUIREMENT_MODE_EXACT_SNAPSHOT);
            assertThat(demand.getRequiredForProductQty())
                    .isEqualByComparingTo("9999");
            assertThat(demand.getRequiredQty()).isEqualByComparingTo("3");
            assertThat(demand.getRequirementFingerprint())
                    .isEqualTo(fingerprint);
        });
    }

    @Test
    void exactDemandFailsClosedWithoutAValidRuleFingerprint() {
        ProductionFulfillmentLedgerService service =
                new ProductionFulfillmentLedgerService(
                        null, mock(ProductionMaterialDemandRepository.class),
                        null, null, null, null);
        ProductionPlanningPackage planningPackage =
                new ProductionPlanningPackage();
        planningPackage.setId(UUID.randomUUID());
        planningPackage.setPlanId(UUID.randomUUID());
        planningPackage.setWarehouseId(UUID.randomUUID());

        assertThatThrownBy(() -> service.createDemands(
                planningPackage,
                List.of(new ProductionFulfillmentLedgerService.DemandDraft(
                        UUID.randomUUID(),
                        UUID.randomUUID(),
                        UUID.randomUUID(),
                        null,
                        UUID.randomUUID(),
                        new BigDecimal("0.000250"),
                        new BigDecimal("3"),
                        LocalDate.of(2026, 8, 9),
                        ProductionMaterialDemand.ROUTE_BUY,
                        "exact-demand-invalid",
                        ProductionMaterialDemand
                                .REQUIREMENT_MODE_EXACT_SNAPSHOT,
                        new BigDecimal("9999"),
                        "not-a-sha256"))))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED));
    }
}
