package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.Duration;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.AggregatePrivateCoveragePropagation.propagate;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertTimeout;

class AggregatePrivateCoveragePropagationTest {
    private static final UUID A = id(1), B = id(2), S = id(100), T1 = id(200), T2 = id(300), D = id(400);

    @Test void directPrivateFactsRemainAtTheirOwnNodeAndResultIsDeeplyImmutable() {
        var direct = new LinkedHashMap<>(Map.of(S, Map.of(A, q("5"))));
        var result = propagate(direct, Map.of(), Set.of(A));
        assertThat(result.get(S)).isEqualTo(Map.of(A, q("5.0000")));
        assertThat(direct.get(S)).isEqualTo(Map.of(A, q("5")));
        assertThatThrownBy(() -> result.put(T1, Map.of())).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> result.get(S).put(B, q("1"))).isInstanceOf(UnsupportedOperationException.class);
    }

    @Test void aKnownSourceIsBudgetedOnceAcrossEveryOutgoingEdge() {
        var result = propagate(Map.of(S, Map.of(A, q("5"), B, q("5"))),
                Map.of(T1, Map.of(S, q("8")), T2, Map.of(S, q("8"))), Set.of(A, B));
        assertThat(result.get(T1)).isEqualTo(Map.of(A, q("5.0000"), B, q("3.0000")));
        assertThat(result.get(T2)).isEqualTo(Map.of(B, q("2.0000")));
        assertThat(sum(result.get(T1)).add(sum(result.get(T2)))).isEqualByComparingTo("10");
        assertThat(sum(result.get(S))).isEqualByComparingTo("10");
    }

    @Test void eachActualEdgeQuotaBoundsTheAttributedAmount() {
        var result = propagate(Map.of(S, Map.of(A, q("10"))),
                Map.of(T1, Map.of(S, q("2")), T2, Map.of(S, q("3"))), Set.of(A));
        assertThat(sum(result.get(T1))).isEqualByComparingTo("2");
        assertThat(sum(result.get(T2))).isEqualByComparingTo("3");
        assertThat(sum(result.get(S))).isEqualByComparingTo("10");
    }

    @Test void aDiamondAndAnotherLevelNeverMultiplyTheSameSourceCoverage() {
        UUID end = id(500);
        var result = propagate(Map.of(S, Map.of(A, q("10"))),
                Map.of(T1, Map.of(S, q("6")), T2, Map.of(S, q("6")),
                        D, Map.of(T1, q("6"), T2, q("6")), end, Map.of(D, q("20"))), Set.of(A));
        assertThat(sum(result.get(T1))).isEqualByComparingTo("6");
        assertThat(sum(result.get(T2))).isEqualByComparingTo("4");
        assertThat(result.get(D)).isEqualTo(Map.of(A, q("10.0000")));
        assertThat(result.get(end)).isEqualTo(Map.of(A, q("10.0000")));
    }

    @Test void independentDirectAndIncomingFactsAddIncludingTheSameOriginal() {
        var result = propagate(Map.of(S, Map.of(A, q("5")), T1, Map.of(A, q("2"), B, q("3"))),
                Map.of(T1, Map.of(S, q("5")), D, Map.of(T1, q("20"))), Set.of(A, B));
        assertThat(result.get(T1)).isEqualTo(Map.of(A, q("7.0000"), B, q("3.0000")));
        assertThat(result.get(D)).isEqualTo(result.get(T1));
    }

    @Test void anOriginalWithoutPrivateProofUsesOnlyItsActualOutgoingEvidence() {
        var result = propagate(Map.of(),
                Map.of(T1, Map.of(S, q("2")), T2, Map.of(S, q("3")), D, Map.of(T2, q("8"))), Set.of(S));
        assertThat(result.get(S)).isEqualTo(Map.of(S, q("5.0000")));
        assertThat(result.get(T1)).isEqualTo(Map.of(S, q("2.0000")));
        assertThat(result.get(T2)).isEqualTo(Map.of(S, q("3.0000")));
        assertThat(result.get(D)).isEqualTo(Map.of(S, q("3.0000")));
    }

    @Test void existingProofDisablesSelfFallbackForAnUnprovenRemainder() {
        var result = propagate(Map.of(S, Map.of(A, q("5"))), Map.of(T1, Map.of(S, q("8"))), Set.of(A, S));
        assertThat(result.get(T1)).isEqualTo(Map.of(A, q("5.0000")));
        assertThat(result.get(T1)).doesNotContainKey(S);
        var ownAndOther = propagate(Map.of(S, Map.of(A, q("5"), S, q("2"))),
                Map.of(T1, Map.of(S, q("10"))), Set.of(A, S));
        assertThat(sum(ownAndOther.get(T1))).isEqualByComparingTo("7");
        assertThat(ownAndOther.get(T1)).containsEntry(S, q("2.0000"));
    }

    @Test void unknownCanonicalEvidenceDoesNotBecomeAnInventedOriginal() {
        UUID unknown = id(999);
        var result = propagate(Map.of(S, Map.of(A, q("2"))),
                Map.of(T1, Map.of(S, q("2"), unknown, q("3"), B, q("4")), D, Map.of(T1, q("20"))), Set.of(A, B));
        assertThat(result.get(unknown)).isEmpty();
        assertThat(result.get(T1)).isEqualTo(Map.of(A, q("2.0000"), B, q("4.0000")));
        assertThat(result.get(D)).isEqualTo(result.get(T1));
        assertThat(result.get(D)).doesNotContainKey(unknown).doesNotContainKey(T1);
    }

    @Test void explicitHistoricCanonicalOriginalProofIsNotDroppedByTheFallbackWhitelist() {
        UUID historic = id(999);
        var result = propagate(Map.of(S, Map.of(historic, q("3"))),
                Map.of(T1, Map.of(S, q("2"))), Set.of(A, B));
        assertThat(result.get(T1)).isEqualTo(Map.of(historic, q("2.0000")));
    }

    @Test void graphTopologyTakesPrecedenceOverUuidOrMapIterationOrder() {
        UUID highSource = id(900), lowMiddle = id(10), end = id(20);
        var result = propagate(Map.of(highSource, Map.of(A, q("4"))),
                Map.of(end, Map.of(lowMiddle, q("3")), lowMiddle, Map.of(highSource, q("5"))), Set.of(A));
        assertThat(result.keySet()).containsExactly(lowMiddle, end, highSource);
        assertThat(result.get(end)).isEqualTo(Map.of(A, q("3.0000")));
        var reversed = new LinkedHashMap<UUID, Map<UUID, BigDecimal>>();
        reversed.put(lowMiddle, Map.of(highSource, q("5")));
        reversed.put(end, Map.of(lowMiddle, q("3")));
        assertThat(propagate(Map.of(highSource, Map.of(A, q("4"))), reversed, Set.of(A))).isEqualTo(result);
    }

    @Test void singleTicksRemainConservedAcrossAQuotaBoundaryAndMerge() {
        var result = propagate(Map.of(S, Map.of(A, q("0.0001"), B, q("0.0002"))),
                Map.of(T1, Map.of(S, q("0.0002")), T2, Map.of(S, q("0.0002")),
                        D, Map.of(T1, q("0.0002"), T2, q("0.0002"))), Set.of(A, B));
        assertThat(sum(result.get(T1))).isEqualTo(q("0.0002"));
        assertThat(sum(result.get(T2))).isEqualTo(q("0.0001"));
        assertThat(result.get(D)).isEqualTo(Map.of(A, q("0.0001"), B, q("0.0002")));
    }

    @Test void positiveCyclesFailEvenWhenNoSourceHasKnownCoverage() {
        assertError(ErrorCode.CONFLICT, () -> propagate(Map.of(),
                Map.of(S, Map.of(T1, q("1")), T1, Map.of(S, q("1"))), Set.of()));
        assertError(ErrorCode.CONFLICT, () -> propagate(Map.of(S, Map.of(A, q("5"))),
                Map.of(S, Map.of(S, q("1"))), Set.of(A)));
        var zeros = propagate(Map.of(S, Map.of(A, q("1.000000"))),
                Map.of(S, Map.of(T1, q("0")), T1, Map.of(S, q("0.000000"))), Set.of(A));
        assertThat(zeros.get(S)).isEqualTo(Map.of(A, q("1.0000")));
        assertThat(zeros.get(T1)).isEmpty();
    }

    @Test void invalidIdentityAndQuantityFactsAreRejectedBeforePropagation() {
        for (BigDecimal bad : new BigDecimal[] {q("-1"), q("0.00001"), null}) {
            var amounts = new HashMap<UUID, BigDecimal>();
            amounts.put(A, bad);
            assertError(ErrorCode.VALIDATION_FAILED, () -> propagate(Map.of(S, amounts), Map.of(), Set.of(A)));
            assertError(ErrorCode.VALIDATION_FAILED, () -> propagate(Map.of(), Map.of(T1, amounts), Set.of(A)));
        }
        var missingIdentity = new HashMap<UUID, BigDecimal>();
        missingIdentity.put(null, q("1"));
        assertError(ErrorCode.VALIDATION_FAILED, () -> propagate(Map.of(S, missingIdentity), Map.of(), Set.of(A)));
        assertError(ErrorCode.VALIDATION_FAILED, () -> propagate(Map.of(), Map.of(T1, missingIdentity), Set.of(A)));
        var missingAmounts = new HashMap<UUID, Map<UUID, BigDecimal>>();
        missingAmounts.put(S, null);
        assertError(ErrorCode.VALIDATION_FAILED, () -> propagate(missingAmounts, Map.of(), Set.of(A)));
        assertError(ErrorCode.VALIDATION_FAILED, () -> propagate(null, Map.of(), Set.of(A)));
    }

    @Test void aDeepHistoryUsesIterativePropagation() {
        assertTimeout(Duration.ofSeconds(10), () -> {
            UUID original = id(90_000);
            var edges = new LinkedHashMap<UUID, Map<UUID, BigDecimal>>();
            for (int i = 1; i <= 10_000; i++) edges.put(id(i + 1), Map.of(id(i), q("0.0001")));
            var result = propagate(Map.of(id(1), Map.of(original, q("0.0001"))), edges, Set.of());
            assertThat(result).hasSize(10_001);
            assertThat(result.get(id(10_001))).isEqualTo(Map.of(original, q("0.0001")));
        });
    }

    @Test void accumulatedPrivateTicksCanExceedLongWithoutLoss() {
        var proof = new LinkedHashMap<UUID, BigDecimal>();
        for (int i = 0; i < 20; i++) proof.put(id(i + 1), q("99999999999999.9999"));
        BigDecimal total = sum(proof);
        assertThat(total.movePointRight(4).toBigIntegerExact()).isGreaterThan(BigInteger.valueOf(Long.MAX_VALUE));
        var result = propagate(Map.of(S, proof), Map.of(T1, Map.of(S, total)), Set.of());
        assertThat(sum(result.get(T1))).isEqualByComparingTo(total);
        assertThat(result.get(T1)).hasSize(20);
    }

    @Test void randomizedFanoutsConserveEachOriginalAndEachActualEdge() {
        Random random = new Random(927_2026);
        for (int iteration = 0; iteration < 200; iteration++) {
            var proof = new LinkedHashMap<UUID, BigDecimal>();
            var inherited = new LinkedHashMap<UUID, Map<UUID, BigDecimal>>();
            for (int i = 0; i < 5; i++) proof.put(id(i + 1), ticks(random.nextInt(10)));
            BigDecimal edgeTotal = BigDecimal.ZERO;
            for (int i = 0; i < 7; i++) {
                BigDecimal quota = ticks(random.nextInt(10));
                inherited.put(id(1000 + i), Map.of(S, quota));
                edgeTotal = edgeTotal.add(quota);
            }
            var result = propagate(Map.of(S, proof), inherited, Set.of());
            var used = new HashMap<UUID, BigDecimal>();
            for (var target : inherited.entrySet()) {
                assertThat(sum(result.get(target.getKey()))).isLessThanOrEqualTo(target.getValue().get(S));
                result.get(target.getKey()).forEach((original, quantity) -> used.merge(original, quantity, BigDecimal::add));
            }
            used.forEach((original, quantity) -> assertThat(quantity).isLessThanOrEqualTo(proof.get(original)));
            assertThat(sum(used)).isEqualByComparingTo(sum(proof).min(edgeTotal));
        }
    }

    private static void assertError(ErrorCode code, Runnable command) {
        assertThatThrownBy(command::run).isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(code));
    }

    private static BigDecimal sum(Map<UUID, BigDecimal> amounts) {
        return amounts.values().stream().reduce(BigDecimal.ZERO, BigDecimal::add);
    }
    private static UUID id(long suffix) { return new UUID(0, suffix); }
    private static BigDecimal q(String amount) { return new BigDecimal(amount); }
    private static BigDecimal ticks(int quantity) { return new BigDecimal(BigInteger.valueOf(quantity), 4); }
}
