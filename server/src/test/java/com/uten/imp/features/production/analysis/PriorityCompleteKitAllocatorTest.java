package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class PriorityCompleteKitAllocatorTest {

    @Test
    void scarceSharedMaterialBelongsToHigherPriorityProductOnly() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        var result = PriorityCompleteKitAllocator.allocate(List.of(
                demand(first, 1, "6", Map.of("X", bd("1"))),
                demand(second, 2, "6", Map.of("X", bd("1")))),
                Map.of("X", bd("6")));

        assertThat(result.readyByItem().get(first)).isEqualByComparingTo("6.0000");
        assertThat(result.readyByItem().get(second)).isEqualByComparingTo("0.0000");
        assertThat(result.shortageByItem().get(first).get("X"))
                .isEqualByComparingTo("0.0000");
        assertThat(result.shortageByItem().get(second).get("X"))
                .isEqualByComparingTo("6.0000");
    }

    @Test
    void incompleteHighPriorityKitDoesNotStarveACompleteLowerPriorityProduct() {
        UUID productA = UUID.randomUUID();
        UUID productB = UUID.randomUUID();
        var result = PriorityCompleteKitAllocator.allocate(List.of(
                demand(productA, 1, "6", Map.of("X", bd("1"), "Y", bd("1"))),
                demand(productB, 2, "6", Map.of("X", bd("1")))),
                Map.of("X", bd("6"), "Y", BigDecimal.ZERO));

        assertThat(result.readyByItem().get(productA)).isEqualByComparingTo("0.0000");
        assertThat(result.readyByItem().get(productB)).isEqualByComparingTo("6.0000");
        assertThat(result.shortageByItem().get(productA).get("X"))
                .isEqualByComparingTo("6.0000");
        assertThat(result.shortageByItem().get(productA).get("Y"))
                .isEqualByComparingTo("6.0000");
        assertThat(result.shortageByItem().get(productB).get("X"))
                .isEqualByComparingTo("0.0000");
    }

    @Test
    void changingPriorityChangesTheAuthoritativeOwnerOfSharedStock() {
        UUID productA = UUID.randomUUID();
        UUID productB = UUID.randomUUID();
        var result = PriorityCompleteKitAllocator.allocate(List.of(
                demand(productA, 2, "6", Map.of("X", bd("1"))),
                demand(productB, 1, "6", Map.of("X", bd("1")))),
                Map.of("X", bd("6")));

        assertThat(result.readyByItem().get(productA)).isEqualByComparingTo("0.0000");
        assertThat(result.readyByItem().get(productB)).isEqualByComparingTo("6.0000");
    }

    @Test
    void duplicateBomRowsAreAggregatedBeforeCompleteKitDivision() {
        UUID product = UUID.randomUUID();
        var result = PriorityCompleteKitAllocator.allocate(List.of(
                demand(product, 1, "100", Map.of("X", bd("2")))),
                Map.of("X", bd("100")));

        assertThat(result.readyByItem().get(product)).isEqualByComparingTo("50.0000");
        assertThat(result.allocatedByItem().get(product).get("X"))
                .isEqualByComparingTo("100.0000");
    }

    @Test
    void selectingOnlyAnUnallocatedLowPriorityProductCannotBypassSnapshot() {
        BigDecimal ready = MaterialAnalysisService.authoritativeReadyQty(
                bd("6"), BigDecimal.ZERO);

        assertThat(ready).isEqualByComparingTo("0.0000");
        assertThat(ready.compareTo(bd("6"))).isNegative();
    }

    @Test
    void readyPartialBatchCanGenerateWithoutRoutingTheUnreadyRemainder() {
        BigDecimal ready = MaterialAnalysisService.authoritativeReadyQty(
                bd("10"), bd("10"));

        assertThat(ready).isEqualByComparingTo("10.0000");
        assertThat(MaterialAnalysisService.canGenerateReadyBatch(bd("10"), ready))
                .isTrue();
        assertThat(MaterialAnalysisService.canGenerateReadyBatch(bd("100"), ready))
                .isFalse();
    }

    private static PriorityCompleteKitAllocator.Demand<String> demand(
            UUID id, int priority, String quantity, Map<String, BigDecimal> usage) {
        return new PriorityCompleteKitAllocator.Demand<>(
                id, priority, bd(quantity), usage, false);
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
