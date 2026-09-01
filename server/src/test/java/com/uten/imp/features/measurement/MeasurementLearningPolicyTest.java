package com.uten.imp.features.measurement;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MeasurementLearningPolicyTest {

    private final MeasurementLearningPolicy policy =
            MeasurementLearningPolicy.conservativeDefault();

    @Test
    void threeIndependentDocumentsAcrossTwoDaysCreateOnlyAProvisionalCandidate() {
        MeasurementProfileKey key = MeasurementEvidenceTest.key("purchase_receipt");
        List<MeasurementEvidence> evidence = List.of(
                evidence(key, UUID.randomUUID(), "policy-key-001", "2026-08-30"),
                evidence(key, UUID.randomUUID(), "policy-key-002", "2026-08-30"),
                evidence(key, UUID.randomUUID(), "policy-key-003", "2026-08-31"));

        MeasurementProfile profile = policy.evaluate(key, evidence, null, 3);

        assertThat(profile.status()).isEqualTo(MeasurementProfileStatus.PROVISIONAL);
        assertThat(profile.inferredPreference())
                .isEqualTo(MeasurementCapturePreference.QUANTITY);
        assertThat(profile.effectivePreference())
                .isEqualTo(MeasurementCapturePreference.QUANTITY);
        assertThat(profile.confidence()).isEqualByComparingTo(BigDecimal.ONE);
    }

    @Test
    void multipleItemsFromOneDocumentDoNotSatisfyIndependentDocumentThreshold() {
        MeasurementProfileKey key = MeasurementEvidenceTest.key("purchase_receipt");
        UUID documentId = UUID.randomUUID();
        List<MeasurementEvidence> evidence = List.of(
                evidence(key, documentId, "policy-key-004", "2026-08-30"),
                evidence(key, documentId, "policy-key-005", "2026-08-31"),
                evidence(key, documentId, "policy-key-006", "2026-08-31"));

        MeasurementProfile profile = policy.evaluate(key, evidence, null, 3);

        assertThat(profile.status()).isEqualTo(MeasurementProfileStatus.UNCLASSIFIED);
        assertThat(profile.quantityDocumentCount()).isEqualTo(1);
    }

    @Test
    void conflictNeverUsesMajorityVote() {
        MeasurementProfileKey key = MeasurementEvidenceTest.key("warehouse_in");
        List<MeasurementEvidence> evidence = new ArrayList<>();
        for (int i = 0; i < 10; i++) {
            evidence.add(evidence(
                    key, UUID.randomUUID(), "quantity-key-" + (100 + i),
                    i == 0 ? "2026-08-30" : "2026-08-31"));
        }
        evidence.add(dual(key, "dual-policy-001", "2026-08-30"));
        evidence.add(dual(key, "dual-policy-002", "2026-08-30"));
        evidence.add(dual(key, "dual-policy-003", "2026-08-31"));

        MeasurementProfile profile = policy.evaluate(key, evidence, null, 13);

        assertThat(profile.status()).isEqualTo(MeasurementProfileStatus.CONFLICT);
        assertThat(profile.effectivePreference()).isNull();
        assertThat(profile.inferenceConflict()).isTrue();
    }

    @Test
    void evidenceFromAnotherOperationFamilyIsRejected() {
        MeasurementProfileKey purchase = MeasurementEvidenceTest.key("purchase_receipt");
        MeasurementProfileKey sales = new MeasurementProfileKey(
                purchase.goodsId(), "sales_ship");

        assertThatThrownBy(() -> policy.evaluate(
                purchase, List.of(evidence(
                        sales, UUID.randomUUID(), "policy-key-007", "2026-08-30")),
                null, 0))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static MeasurementEvidence evidence(
            MeasurementProfileKey key, UUID documentId,
            String idempotencyKey, String date) {
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
                new BigDecimal("2.5"), LocalDate.parse(date));
    }
}
