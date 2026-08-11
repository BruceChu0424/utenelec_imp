package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MaterialConsumptionMathTest {

    @Test
    void perUnitConsumptionKeepsTheExistingBomMeaning() {
        assertThat(MaterialConsumptionMath.required(
                bd("1000"), bd("0.0005"), "PER_UNIT", bd("1"), true))
                .isEqualByComparingTo("0.5000");
    }

    @Test
    void wholeCartonsRoundUpInsteadOfUnderstatingShippingDemand() {
        assertThat(MaterialConsumptionMath.required(
                bd("10"), bd("2"), "PER_PACKAGE", bd("6"), false))
                .isEqualByComparingTo("4.0000");
        assertThat(MaterialConsumptionMath.required(
                bd("6"), bd("2"), "PER_PACKAGE", bd("6"), false))
                .isEqualByComparingTo("2.0000");
    }

    @Test
    void divisiblePackagingMayBeConsumedProportionallyWhenExplicitlyAllowed() {
        assertThat(MaterialConsumptionMath.required(
                bd("3"), bd("1"), "PER_PACKAGE", bd("6"), true))
                .isEqualByComparingTo("0.5000");
    }

    @Test
    void fixedBatchAlwaysRoundsToAWholeBatch() {
        assertThat(MaterialConsumptionMath.required(
                bd("101"), bd("0.25"), "FIXED_BATCH", bd("100"), true))
                .isEqualByComparingTo("0.5000");
    }

    @Test
    void wholeCartonReadinessDoesNotTreatThreeCartonsWorthOfLabelsAsNineUnits() {
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        var dimension = new MaterialAnalysisService.MaterialDimension(
                goodsId, null, unitId);
        var packaging = new MaterialAnalysisService.BomNode(
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, unitId, 1, "node-1", null,
                BigDecimal.ONE, bd("2"), bd("0.333334"), bd("4"),
                "PK-01", "Carton labels", null, null, "piece",
                BigDecimal.ZERO, "BUY", false, "SHIP", "PER_PACKAGE",
                bd("6"), false, true);

        BigDecimal ready = MaterialAnalysisService.maxReadyExact(
                bd("10"), List.of(packaging), Map.of(dimension, bd("3")));

        assertThat(ready).isEqualByComparingTo("6.0000");
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
