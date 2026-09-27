package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.AggregateOriginalTargetAllocator.allocate;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertTimeout;

class AggregateOriginalTargetAllocatorTest {
    private static final UUID A = id(1), B = id(2), T1 = id(101), T2 = id(102);

    @Test void oneTargetUsesOnlyItsProvenOriginalsInStableOrder() {
        var result = allocate(Map.of(B, q("500"), A, q("100")), Map.of(T1, q("500")),
                Map.of(T1, List.of(B, A)), true);
        assertThat(result.allocatedQty()).isEqualByComparingTo("500");
        assertThat(result.byTarget().get(T1).keySet()).containsExactly(A, B);
        assertThat(result.byTarget().get(T1)).containsEntry(A, q("100.0000")).containsEntry(B, q("400.0000"));
    }

    @Test void excessOriginalQuantityCannotCoverAnUnrelatedTarget() {
        var originals = Map.of(A, q("1000"), B, q("100"));
        var targets = Map.of(T1, q("100"), T2, q("1000"));
        var scope = Map.of(T1, List.of(A), T2, List.of(B));
        var result = allocate(originals, targets, scope, false);
        assertThat(result.allocatedQty()).isEqualByComparingTo("200");
        assertThat(result.byTarget().get(T1)).containsOnlyKeys(A);
        assertThat(result.byTarget().get(T2)).containsOnlyKeys(B);
        assertThat(originals.get(A).subtract(result.byTarget().get(T1).get(A))).isEqualByComparingTo("900");
        assertError(ErrorCode.CONFLICT, () -> allocate(originals, targets, scope, true));
    }

    @Test void reverseAugmentingPathMovesFlexibleAAndFullyCoversRestrictedB() {
        var result = allocate(Map.of(A, q("500"), B, q("500")),
                Map.of(T1, q("500"), T2, q("500")),
                Map.of(T1, List.of(A, B), T2, List.of(A)), true);
        assertThat(result.allocatedQty()).isEqualByComparingTo("1000");
        assertThat(result.byTarget().get(T1)).containsExactlyEntriesOf(Map.of(B, q("500.0000")));
        assertThat(result.byTarget().get(T2)).containsExactlyEntriesOf(Map.of(A, q("500.0000")));
    }

    @Test void actualPartialClaimsAreRedistributedOnlyWithinActualOriginalCaps() {
        // A really adopted 100 and B 300; their earlier requests of 500 each must not reappear.
        var result = allocate(Map.of(A, q("100"), B, q("300")),
                Map.of(T1, q("150"), T2, q("250")),
                Map.of(T1, List.of(A, B), T2, List.of(B)), true);
        assertThat(result.allocatedQty()).isEqualByComparingTo("400");
        assertThat(result.byTarget().get(T1)).containsEntry(A, q("100.0000")).containsEntry(B, q("50.0000"));
        assertThat(result.byTarget().get(T2)).containsEntry(B, q("250.0000"));
    }

    @Test void theFinalOneTenThousandthIsNeverRoundedAway() {
        var result = allocate(Map.of(A, q("0.0001"), B, q("0.0002")),
                Map.of(T1, q("0.0002"), T2, q("0.0001")),
                Map.of(T1, List.of(A, B), T2, List.of(B)), true);
        assertThat(result.allocatedQty()).isEqualTo(q("0.0003"));
        assertThat(result.byTarget().get(T1)).containsEntry(A, q("0.0001")).containsEntry(B, q("0.0001"));
        assertThat(result.byTarget().get(T2)).containsEntry(B, q("0.0001"));
        assertError(ErrorCode.CONFLICT, () -> allocate(Map.of(A, q("0.0001")),
                Map.of(T1, q("0.0002")), Map.of(T1, List.of(A)), true));
    }

    @Test void largeAggregateTicksDoNotOverflowLong() {
        var originals = new LinkedHashMap<UUID, BigDecimal>();
        for (int i = 0; i < 20; i++) originals.put(id(i + 1), q("99999999999999.9999"));
        BigDecimal total = originals.values().stream().reduce(BigDecimal.ZERO, BigDecimal::add);
        assertThat(total.movePointRight(4).toBigIntegerExact()).isGreaterThan(BigInteger.valueOf(Long.MAX_VALUE));
        var result = allocate(originals, Map.of(T1, total), Map.of(T1, List.copyOf(originals.keySet())), true);
        assertThat(result.allocatedQty()).isEqualByComparingTo(total);
        assertThat(result.byTarget().get(T1)).hasSize(20);
        assertConserved(result, originals, Map.of(T1, total), Map.of(T1, List.copyOf(originals.keySet())));
    }

    @Test void equivalentDecimalScalesAndZeroCapacityAreSupported() {
        var result = allocate(Map.of(A, q("1.000000"), B, q("0.000000")),
                Map.of(T1, q("1"), T2, q("0")), Map.of(T1, List.of(A, B)), true);
        assertThat(result.byTarget().keySet()).containsExactly(T1, T2);
        assertThat(result.byTarget().get(T1)).containsExactlyEntriesOf(Map.of(A, q("1.0000")));
        assertThat(result.byTarget().get(T2)).isEmpty();
        assertThat(allocate(Map.of(), Map.of(), Map.of(), true).allocatedQty()).isEqualTo(q("0.0000"));
    }

    @Test void missingEdgesLeaveOriginalCapacityUnallocatedWithoutInventingIdentity() {
        var result = allocate(Map.of(A, q("10")), Map.of(T1, q("10")), Map.of(), false);
        assertThat(result.allocatedQty()).isEqualByComparingTo("0");
        assertThat(result.byTarget().get(T1)).isEmpty();
        assertError(ErrorCode.CONFLICT, () -> allocate(Map.of(A, q("10")), Map.of(T1, q("10")), Map.of(), true));
    }

    @Test void mapAndEdgeIterationOrderDoNotChangeTheAllocation() {
        UUID low = UUID.fromString("7fffffff-ffff-ffff-ffff-ffffffffffff");
        UUID high = UUID.fromString("80000000-0000-0000-0000-000000000000");
        var first = allocate(Map.of(high, q("1"), low, q("1")), Map.of(T2, q("1"), T1, q("1")),
                Map.of(T2, List.of(high, low), T1, List.of(low, high)), true);
        var originals = new LinkedHashMap<UUID, BigDecimal>();
        originals.put(low, q("1")); originals.put(high, q("1"));
        var second = allocate(originals, Map.of(T1, q("1"), T2, q("1")),
                Map.of(T1, List.of(high, low), T2, List.of(low, high)), true);
        assertThat(first).isEqualTo(second);
        assertThat(first.byTarget().get(T1)).containsOnlyKeys(low);
    }

    @Test void badQuantitiesAreRejectedOnEitherSideBeforeComputingFlow() {
        for (BigDecimal invalid : List.of(q("-1"), q("0.00001"), q("3.14159"))) {
            assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(Map.of(A, invalid),
                    Map.of(T1, q("1")), Map.of(T1, List.of(A)), false));
            assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(Map.of(A, q("1")),
                    Map.of(T1, invalid), Map.of(T1, List.of(A)), false));
        }
        var nullQuantity = new HashMap<UUID, BigDecimal>();
        nullQuantity.put(A, null);
        assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(nullQuantity, Map.of(), Map.of(), false));
        var nullId = new HashMap<UUID, BigDecimal>();
        nullId.put(null, q("0"));
        assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(nullId, Map.of(), Map.of(), false));
        assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(null, Map.of(), Map.of(), false));
    }

    @Test void unknownNullAndDuplicateIdentityEdgesAreRejectedEvenAtZeroCapacity() {
        var originals = Map.of(A, q("0"));
        var targets = Map.of(T1, q("0"));
        for (var badScope : List.of(Map.of(T2, List.of(A)), Map.of(T1, List.of(B)),
                Map.of(T1, List.of(A, A)), Map.of(T1, Collections.<UUID>singletonList(null)))) {
            assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(originals, targets, badScope, false));
        }
        var nullEdges = new HashMap<UUID, List<UUID>>();
        nullEdges.put(T1, null);
        assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(originals, targets, nullEdges, false));
        assertError(ErrorCode.VALIDATION_FAILED, () -> allocate(originals, targets, null, false));
    }

    @Test void resultIsDeeplyImmutableAndDoesNotMutateInputs() {
        var originals = new LinkedHashMap<>(Map.of(A, q("1")));
        var scope = new LinkedHashMap<>(Map.of(T1, new ArrayList<>(List.of(A))));
        var result = allocate(originals, Map.of(T1, q("1")), new LinkedHashMap<>(scope), true);
        assertThat(originals).containsExactlyEntriesOf(Map.of(A, q("1")));
        assertThat(scope.get(T1)).containsExactly(A);
        assertThatThrownBy(() -> result.byTarget().put(T2, Map.of())).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> result.byTarget().get(T1).put(B, q("1"))).isInstanceOf(UnsupportedOperationException.class);
    }

    @Test void tenThousandOriginalsAndFiveHundredTargetsUseOnlyTheSparseProvenEdges() {
        assertTimeout(Duration.ofSeconds(10), () -> {
            var originals = new LinkedHashMap<UUID, BigDecimal>();
            var targets = new LinkedHashMap<UUID, BigDecimal>();
            var scope = new LinkedHashMap<UUID, List<UUID>>();
            for (int i = 0; i < 500; i++) {
                UUID target = id(100_000 + i);
                targets.put(target, q("20"));
                scope.put(target, new ArrayList<>());
            }
            for (int i = 0; i < 10_000; i++) {
                UUID original = id(i + 1);
                originals.put(original, q("1"));
                scope.get(id(100_000 + i % 500)).add(original);
            }
            var result = allocate(originals, targets, scope, true);
            assertThat(result.allocatedQty()).isEqualByComparingTo("10000");
            assertConserved(result, originals, targets, scope);
        });
    }

    @Test void longAlternatingPathIsReassignedWithoutRecursiveStackGrowth() {
        var originals = new LinkedHashMap<UUID, BigDecimal>();
        var targets = new LinkedHashMap<UUID, BigDecimal>();
        var scope = new LinkedHashMap<UUID, List<UUID>>();
        for (int i = 0; i < 500; i++) {
            originals.put(id(i + 1), q("1"));
            targets.put(id(10_000 + i), q("1"));
            scope.put(id(10_000 + i), new ArrayList<>());
        }
        for (int i = 0; i < 499; i++) {
            scope.get(id(10_000 + i)).add(id(i + 1));
            scope.get(id(10_001 + i)).add(id(i + 1));
        }
        scope.get(id(10_000)).add(id(500));
        var result = allocate(originals, targets, scope, true);
        assertThat(result.allocatedQty()).isEqualByComparingTo("500");
        assertThat(result.byTarget().get(id(10_000))).containsOnlyKeys(id(500));
        assertConserved(result, originals, targets, scope);
    }

    @Test void oneHistoricalOriginalMayResolveToMoreThanFiveHundredTargets() {
        var targets = new LinkedHashMap<UUID, BigDecimal>();
        var scope = new LinkedHashMap<UUID, List<UUID>>();
        for (int i = 0; i < 501; i++) {
            UUID target = id(10_000 + i);
            targets.put(target, q("1"));
            scope.put(target, List.of(A));
        }
        var result = allocate(Map.of(A, q("501")), targets, scope, true);
        assertThat(result.byTarget()).hasSize(501);
        assertThat(result.allocatedQty()).isEqualByComparingTo("501");
    }

    @Test void smallRandomGraphsMatchAnIndependentExhaustiveMinimumCutOracle() {
        Random random = new Random(927_2026);
        for (int iteration = 0; iteration < 200; iteration++) {
            int[] originalTicks = new int[3], targetTicks = new int[4];
            var originals = new LinkedHashMap<UUID, BigDecimal>();
            var targets = new LinkedHashMap<UUID, BigDecimal>();
            var scope = new LinkedHashMap<UUID, List<UUID>>();
            for (int i = 0; i < 3; i++) originals.put(id(i + 1), ticks(originalTicks[i] = random.nextInt(4)));
            for (int j = 0; j < 4; j++) {
                UUID target = id(101 + j);
                targets.put(target, ticks(targetTicks[j] = random.nextInt(4)));
                var permitted = new ArrayList<UUID>();
                for (int i = 0; i < 3; i++) if (random.nextBoolean()) permitted.add(id(i + 1));
                scope.put(target, permitted);
            }
            int minimum = Integer.MAX_VALUE;
            for (int mask = 0; mask < 8; mask++) {
                int cut = 0;
                for (int i = 0; i < 3; i++) if ((mask & (1 << i)) == 0) cut += originalTicks[i];
                for (int j = 0; j < 4; j++) {
                    boolean reached = false;
                    for (int i = 0; i < 3; i++) {
                        if ((mask & (1 << i)) != 0 && scope.get(id(101 + j)).contains(id(i + 1))) reached = true;
                    }
                    if (reached) cut += targetTicks[j];
                }
                minimum = Math.min(minimum, cut);
            }
            var result = allocate(originals, targets, scope, false);
            assertThat(result.allocatedQty()).as("random graph %s", iteration).isEqualByComparingTo(ticks(minimum));
            assertConserved(result, originals, targets, scope);
        }
    }

    private static void assertConserved(AggregateOriginalTargetAllocator.Flow result,
                                        Map<UUID, BigDecimal> originals, Map<UUID, BigDecimal> targets,
                                        Map<UUID, List<UUID>> scope) {
        Map<UUID, BigDecimal> usedOriginals = new HashMap<>();
        BigDecimal total = BigDecimal.ZERO;
        for (var target : result.byTarget().entrySet()) {
            BigDecimal subtotal = BigDecimal.ZERO;
            for (var source : target.getValue().entrySet()) {
                assertThat(scope.get(target.getKey())).contains(source.getKey());
                assertThat(source.getValue()).isPositive().hasScaleOf(4);
                subtotal = subtotal.add(source.getValue());
                usedOriginals.merge(source.getKey(), source.getValue(), BigDecimal::add);
            }
            assertThat(subtotal).isLessThanOrEqualTo(targets.get(target.getKey()));
            total = total.add(subtotal);
        }
        usedOriginals.forEach((id, amount) -> assertThat(amount).isLessThanOrEqualTo(originals.get(id)));
        assertThat(total).isEqualByComparingTo(result.allocatedQty());
    }

    private static void assertError(ErrorCode code, Runnable command) {
        assertThatThrownBy(command::run).isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(code));
    }

    private static UUID id(long suffix) { return new UUID(0, suffix); }
    private static BigDecimal q(String value) { return new BigDecimal(value); }
    private static BigDecimal ticks(int quantity) { return new BigDecimal(BigInteger.valueOf(quantity), 4); }
}
