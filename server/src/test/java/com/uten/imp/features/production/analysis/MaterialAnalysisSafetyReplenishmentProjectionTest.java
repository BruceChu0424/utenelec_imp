package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MaterialAnalysisSafetyReplenishmentProjectionTest {

    @Test
    void exactDemandEntitlementNeverReducesThePublicSafetyGap() {
        BigDecimal movable = MaterialAnalysisService
                .availableIncludingOwnAfterSafety(
                        new BigDecimal("0"),
                        new BigDecimal("10000"),
                        new BigDecimal("200000"));
        BigDecimal safetyGap = MaterialAnalysisService
                .publicSafetyReplenishmentGap(
                        new BigDecimal("200000"),
                        new BigDecimal("0"),
                        new BigDecimal("0"));

        assertThat(movable).isEqualByComparingTo("0.0000");
        assertThat(safetyGap).isEqualByComparingTo("200000.0000");
    }

    @Test
    void openPublicSafetySupplyIsNettedOnceAndResultIsClamped() {
        assertThat(MaterialAnalysisService.publicSafetyReplenishmentGap(
                new BigDecimal("200000"),
                new BigDecimal("10000"),
                new BigDecimal("150000")))
                .isEqualByComparingTo("40000.0000");
        assertThat(MaterialAnalysisService.publicSafetyReplenishmentGap(
                new BigDecimal("200000"),
                new BigDecimal("210000"),
                new BigDecimal("5000")))
                .isEqualByComparingTo("0.0000");
    }

    @Test
    void exactDemandBlockedBySafetyIsNotPurchasedAgain() {
        assertThat(MaterialAnalysisService.unboundDemandSupplyGap(
                new BigDecimal("10000"),
                new BigDecimal("0"),
                new BigDecimal("10000")))
                .isEqualByComparingTo("0.0000");
        assertThat(MaterialAnalysisService.unboundDemandSupplyGap(
                new BigDecimal("10000"),
                new BigDecimal("4000"),
                new BigDecimal("6000")))
                .isEqualByComparingTo("4000.0000");
    }

    @Test
    void optionalSafetyQuantityHashIsScaleIndependentButKeepsNullDistinct() {
        assertThat(MaterialAnalysisCommandService.canonicalOptionalQuantity(
                new BigDecimal("100")))
                .isEqualTo(MaterialAnalysisCommandService.canonicalOptionalQuantity(
                        new BigDecimal("100.0000")));
        assertThat(MaterialAnalysisCommandService.canonicalOptionalQuantity(null))
                .isNotEqualTo(MaterialAnalysisCommandService.canonicalOptionalQuantity(
                        BigDecimal.ZERO));
    }

    @Test
    void futureDemandCannotAppearReadyBeforePublicSafetyGapIsFilled() {
        MaterialAnalysisService.MaterialDimension dimension =
                new MaterialAnalysisService.MaterialDimension(
                        UUID.randomUUID(), null, UUID.randomUUID());
        LocalDate demandEta = LocalDate.of(2026, 9, 1);
        LocalDate safetyEta = LocalDate.of(2026, 9, 3);

        List<MaterialAnalysisService.InboundLot> usable =
                MaterialAnalysisService.netFutureSupplyAfterSafety(
                        List.of(
                                new MaterialAnalysisService.InboundLot(
                                        dimension, demandEta, new BigDecimal("20")),
                                new MaterialAnalysisService.InboundLot(
                                        dimension, safetyEta, new BigDecimal("100"))),
                        Map.of(dimension, new BigDecimal("100")));

        assertThat(usable).containsExactly(
                new MaterialAnalysisService.InboundLot(
                        dimension, safetyEta, new BigDecimal("20.0000")));
    }
}
