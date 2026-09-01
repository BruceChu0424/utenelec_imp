package com.uten.imp.features.measurement;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MeasurementLearningAggregateTest {

    @Test
    void evidenceIsIdempotentAndReplayPrecedesStaleVersionFailure() {
        MeasurementProfileKey key = MeasurementEvidenceTest.key("stock_in");
        MeasurementLearningAggregate aggregate = aggregate(key);
        MeasurementEvidence evidence = quantity(
                key, "aggregate-key-001", UUID.randomUUID(), "2026-08-30");

        var created = aggregate.appendEvidence(evidence, 0);
        var replay = aggregate.appendEvidence(evidence, 0);

        assertThat(created.replay()).isFalse();
        assertThat(created.profile().version()).isEqualTo(1);
        assertThat(replay.replay()).isTrue();
        assertThat(aggregate.evidenceEvents()).hasSize(1);

        MeasurementEvidence changed = new MeasurementEvidence(
                evidence.eventId(), evidence.key(), evidence.idempotencyKey(),
                evidence.stage(), evidence.sourceDocumentType(),
                evidence.sourceDocumentId(), evidence.sourceItemId(),
                evidence.unitId(), new BigDecimal("2"), evidence.unitRate(),
                evidence.actualWeightUnitId(), evidence.actualWeight(),
                evidence.declaredPreference(), evidence.weightCaptureAvailable(),
                evidence.reversible(), evidence.businessDate(), null);
        assertThatThrownBy(() -> aggregate.appendEvidence(changed, 1))
                .isInstanceOfSatisfying(
                        MeasurementLearningException.class,
                        error -> assertThat(error.code()).isEqualTo(
                                MeasurementLearningException.Code.IDEMPOTENCY_CONFLICT));

        assertThatThrownBy(() -> aggregate.appendEvidence(
                quantity(key, "aggregate-key-002", UUID.randomUUID(), "2026-08-31"),
                0))
                .isInstanceOfSatisfying(
                        MeasurementLearningException.class,
                        error -> assertThat(error.code()).isEqualTo(
                                MeasurementLearningException.Code.VERSION_CONFLICT));
    }

    @Test
    void sameBusinessSourceCannotBeCountedAgainWithAnotherRetryKey() {
        MeasurementProfileKey key = MeasurementEvidenceTest.key("stock_in");
        MeasurementLearningAggregate aggregate = aggregate(key);
        MeasurementEvidence original = quantity(
                key, "aggregate-key-030", UUID.randomUUID(), "2026-08-30");
        aggregate.appendEvidence(original, 0);
        MeasurementEvidence duplicate = MeasurementEvidenceTest.evidence(
                UUID.randomUUID(), key, "aggregate-key-031",
                original.sourceDocumentId(), original.sourceItemId(),
                original.qty(), original.unitRate(),
                original.declaredPreference(), original.weightCaptureAvailable(),
                original.actualWeight(), original.businessDate());

        assertThatThrownBy(() -> aggregate.appendEvidence(duplicate, 1))
                .isInstanceOfSatisfying(
                        MeasurementLearningException.class,
                        error -> assertThat(error.code()).isEqualTo(
                                MeasurementLearningException.Code.IDEMPOTENCY_CONFLICT));
        assertThat(aggregate.evidenceEvents()).hasSize(1);
    }

    @Test
    void reversalIsAppendOnlyAndRemovesTheOriginalFromInference() {
        MeasurementProfileKey key = MeasurementEvidenceTest.key("purchase_receipt");
        MeasurementLearningAggregate aggregate = aggregate(key);
        MeasurementEvidence first = quantity(
                key, "aggregate-key-010", UUID.randomUUID(), "2026-08-30");
        aggregate.appendEvidence(first, 0);
        aggregate.appendEvidence(quantity(
                key, "aggregate-key-011", UUID.randomUUID(), "2026-08-30"), 1);
        aggregate.appendEvidence(quantity(
                key, "aggregate-key-012", UUID.randomUUID(), "2026-08-31"), 2);
        assertThat(aggregate.profile().status())
                .isEqualTo(MeasurementProfileStatus.PROVISIONAL);

        MeasurementEvidence reversal = MeasurementEvidence.reversalOf(
                first, UUID.randomUUID(), "aggregate-reverse-010",
                LocalDate.of(2026, 8, 31));
        aggregate.appendEvidence(reversal, 3);

        assertThat(aggregate.profile().status())
                .isEqualTo(MeasurementProfileStatus.UNCLASSIFIED);
        assertThat(aggregate.profile().activeEvidenceCount()).isEqualTo(2);
        assertThat(aggregate.evidenceEvents()).hasSize(4);
        assertThat(aggregate.appendEvidence(reversal, 0).replay()).isTrue();

        MeasurementEvidence secondReversal = MeasurementEvidence.reversalOf(
                first, UUID.randomUUID(), "aggregate-reverse-011",
                LocalDate.of(2026, 8, 31));
        assertThatThrownBy(() -> aggregate.appendEvidence(secondReversal, 4))
                .isInstanceOfSatisfying(
                        MeasurementLearningException.class,
                        error -> assertThat(error.code()).isEqualTo(
                                MeasurementLearningException.Code.INVALID_REVERSAL));
    }

    @Test
    void manualOverrideWinsOverConflictAndClearingItRestoresConflict() {
        MeasurementProfileKey key = MeasurementEvidenceTest.key("finished_in");
        MeasurementLearningAggregate aggregate = aggregate(key);
        long version = 0;
        for (int i = 0; i < 3; i++) {
            aggregate.appendEvidence(quantity(
                    key, "aggregate-quantity-" + (100 + i), UUID.randomUUID(),
                    i < 2 ? "2026-08-30" : "2026-08-31"), version++);
        }
        for (int i = 0; i < 3; i++) {
            aggregate.appendEvidence(dual(
                    key, "aggregate-dual-" + (100 + i),
                    i < 2 ? "2026-08-30" : "2026-08-31"), version++);
        }
        assertThat(aggregate.profile().status())
                .isEqualTo(MeasurementProfileStatus.CONFLICT);

        UUID decisionId = UUID.randomUUID();
        UUID actorId = UUID.randomUUID();
        OffsetDateTime now = OffsetDateTime.of(
                2026, 8, 31, 12, 0, 0, 0, ZoneOffset.UTC);
        var override = aggregate.override(
                MeasurementCapturePreference.QUANTITY, version++, decisionId,
                actorId, "业务负责人确认按数量采集", "decision-key-001", now);

        assertThat(override.profile().status())
                .isEqualTo(MeasurementProfileStatus.CONFIRMED);
        assertThat(override.profile().effectivePreference())
                .isEqualTo(MeasurementCapturePreference.QUANTITY);
        assertThat(override.profile().inferenceConflict()).isTrue();
        assertThat(aggregate.override(
                MeasurementCapturePreference.QUANTITY, 6, decisionId, actorId,
                "业务负责人确认按数量采集", "decision-key-001", now).replay())
                .isTrue();

        UUID clearDecisionId = UUID.randomUUID();
        var cleared = aggregate.clearOverride(
                version, clearDecisionId, actorId,
                "重新交由证据判定", "decision-clear-001", now.plusMinutes(1));
        assertThat(cleared.profile().status())
                .isEqualTo(MeasurementProfileStatus.CONFLICT);
        assertThat(aggregate.decisionEvents()).hasSize(2);
        assertThat(aggregate.clearOverride(
                7, clearDecisionId, actorId,
                "重新交由证据判定", "decision-clear-001", now.plusMinutes(1))
                .replay()).isTrue();
    }

    @Test
    void sameGoodsUsesIndependentProfilesPerOperationFamily() {
        UUID goodsId = UUID.randomUUID();
        MeasurementProfileKey purchase = new MeasurementProfileKey(
                goodsId, "purchase_receipt");
        MeasurementProfileKey sales = new MeasurementProfileKey(
                goodsId, "sales_ship");
        MeasurementLearningAggregate purchaseAggregate = aggregate(purchase);

        assertThatThrownBy(() -> purchaseAggregate.appendEvidence(
                quantity(sales, "aggregate-key-020", UUID.randomUUID(),
                        "2026-08-30"), 0))
                .isInstanceOf(IllegalArgumentException.class);
        assertThat(purchase).isNotEqualTo(sales);
    }

    private static MeasurementLearningAggregate aggregate(MeasurementProfileKey key) {
        return new MeasurementLearningAggregate(
                key, MeasurementLearningPolicy.conservativeDefault());
    }

    private static MeasurementEvidence quantity(
            MeasurementProfileKey key, String idempotencyKey,
            UUID documentId, String date) {
        return MeasurementEvidenceTest.evidence(
                UUID.randomUUID(), key, idempotencyKey, documentId,
                UUID.randomUUID(), BigDecimal.ONE, BigDecimal.ONE,
                MeasurementCapturePreference.QUANTITY, true, null,
                LocalDate.parse(date));
    }

    private static MeasurementEvidence dual(
            MeasurementProfileKey key, String idempotencyKey, String date) {
        return MeasurementEvidenceTest.evidence(
                UUID.randomUUID(), key, idempotencyKey, UUID.randomUUID(),
                UUID.randomUUID(), BigDecimal.ONE, BigDecimal.ONE,
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT, true,
                new BigDecimal("2.5000"), LocalDate.parse(date));
    }
}
