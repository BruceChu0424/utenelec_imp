package com.uten.imp.features.production.plan;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionPlanMaterialProgressTest {

    @Test
    void distinguishesMissingLegacyAndBrokenExecutionPackagesFromRealWaiting() {
        assertThat(ProductionPlanService.deriveMaterialProgress(
                false, null, 0, 0, BigDecimal.ZERO, BigDecimal.ZERO, false).state())
                .isEqualTo("NOT_PLANNED");
        assertThat(ProductionPlanService.deriveMaterialProgress(
                true, 0, 0, 0, BigDecimal.ZERO, BigDecimal.ZERO, false).state())
                .isEqualTo("LEGACY_UNSUPPORTED");
        assertThat(ProductionPlanService.deriveMaterialProgress(
                true, 1, 0, 0, BigDecimal.ZERO, BigDecimal.ZERO, false).state())
                .isEqualTo("DATA_ERROR");
        assertThat(ProductionPlanService.deriveMaterialProgress(
                true, 1, 2, 0, new BigDecimal("100"), BigDecimal.ZERO, false).state())
                .isEqualTo("WAITING");
    }

    @Test
    void reportsReadyProductionQuantityAndWhetherAnySegmentCanStart() {
        var partial = ProductionPlanService.deriveMaterialProgress(
                true, 1, 5, 3,
                new BigDecimal("100"), new BigDecimal("60"), true);

        assertThat(partial.state()).isEqualTo("PARTIAL");
        assertThat(partial.percent()).isEqualTo(0.6d);
        assertThat(partial.readySegmentCount()).isEqualTo(3);
        assertThat(partial.canStartNow()).isTrue();

        var ready = ProductionPlanService.deriveMaterialProgress(
                true, 1, 5, 5,
                new BigDecimal("100"), new BigDecimal("100"), false);
        assertThat(ready.state()).isEqualTo("READY");
        assertThat(ready.percent()).isEqualTo(1.0d);
    }
}
