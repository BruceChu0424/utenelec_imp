package com.uten.imp.features.measurement;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MeasurementEvidenceTest {

    @Test
    void decimalScaleDoesNotChangeTheEvidenceFingerprint() {
        UUID eventId = UUID.randomUUID();
        UUID documentId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        MeasurementProfileKey key = key("purchase_receipt");
        MeasurementEvidence left = evidence(
                eventId, key, "evidence-key-001", documentId, itemId,
                new BigDecimal("10.0"), new BigDecimal("1.000000"),
                MeasurementCapturePreference.QUANTITY, true, null,
                LocalDate.of(2026, 8, 30));
        MeasurementEvidence right = new MeasurementEvidence(
                eventId, key, "evidence-key-001", MeasurementEvidenceStage.POSTED,
                left.sourceDocumentType(), documentId, itemId, left.unitId(),
                new BigDecimal("10.0000"), BigDecimal.ONE,
                left.actualWeightUnitId(), null,
                MeasurementCapturePreference.QUANTITY, true, true,
                LocalDate.of(2026, 8, 30), null);

        assertThat(left.fingerprint()).isEqualTo(right.fingerprint());
    }

    @Test
    void emptyWeightFromNonCapturingSourceIsNotQuantityCounterEvidence() {
        MeasurementEvidence evidence = evidence(
                UUID.randomUUID(), key("sales_ship"), "evidence-key-002",
                UUID.randomUUID(), UUID.randomUUID(), BigDecimal.ONE,
                BigDecimal.ONE, MeasurementCapturePreference.QUANTITY,
                false, null, LocalDate.of(2026, 8, 30));

        assertThat(evidence.classifyingPreference()).isEmpty();
    }

    @Test
    void dualEvidenceRequiresExplicitActualWeightAndWeightUnit() {
        assertThatThrownBy(() -> evidence(
                UUID.randomUUID(), key("stock_in"), "evidence-key-003",
                UUID.randomUUID(), UUID.randomUUID(), BigDecimal.ONE,
                BigDecimal.ONE,
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT,
                true, null, LocalDate.of(2026, 8, 30)))
                .isInstanceOf(IllegalArgumentException.class);

        MeasurementEvidence dual = evidence(
                UUID.randomUUID(), key("stock_in"), "evidence-key-004",
                UUID.randomUUID(), UUID.randomUUID(), BigDecimal.ONE,
                BigDecimal.ONE,
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT,
                true, new BigDecimal("2.5000"),
                LocalDate.of(2026, 8, 30));
        assertThat(dual.classifyingPreference())
                .contains(MeasurementCapturePreference.QUANTITY_AND_WEIGHT);
        assertThat(dual.actualWeightUnitId()).isNotNull();
    }

    @Test
    void reversalKeepsExactUuidAndUnitFactsAndTargetsOriginalFingerprint() {
        MeasurementEvidence original = evidence(
                UUID.randomUUID(), key("iqc_pass"), "evidence-key-005",
                UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("3"),
                BigDecimal.ONE,
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT,
                true, new BigDecimal("10"), LocalDate.of(2026, 8, 30));
        MeasurementEvidence reversal = MeasurementEvidence.reversalOf(
                original, UUID.randomUUID(), "evidence-reverse-005",
                LocalDate.of(2026, 8, 31));

        assertThat(reversal.stage()).isEqualTo(MeasurementEvidenceStage.REVERSED);
        assertThat(reversal.reversesFingerprint()).isEqualTo(original.fingerprint());
        assertThat(reversal.sourceDocumentId()).isEqualTo(original.sourceDocumentId());
        assertThat(reversal.unitId()).isEqualTo(original.unitId());
        assertThat(reversal.actualWeightUnitId())
                .isEqualTo(original.actualWeightUnitId());
    }

    @Test
    void domainPreferencesMapExplicitlyToStableStorageCodes() {
        assertThat(MeasurementCapturePreference.QUANTITY.storageCode())
                .isEqualTo("BUSINESS_QUANTITY");
        assertThat(MeasurementCapturePreference.QUANTITY_AND_WEIGHT.storageCode())
                .isEqualTo("BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT");
        assertThat(MeasurementCapturePreference.fromStorageCode(
                "BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT"))
                .isEqualTo(MeasurementCapturePreference.QUANTITY_AND_WEIGHT);
    }

    static MeasurementEvidence evidence(
            UUID eventId,
            MeasurementProfileKey key,
            String idempotencyKey,
            UUID documentId,
            UUID itemId,
            BigDecimal qty,
            BigDecimal rate,
            MeasurementCapturePreference preference,
            boolean weightCaptureAvailable,
            BigDecimal weight,
            LocalDate date) {
        return new MeasurementEvidence(
                eventId, key, idempotencyKey, MeasurementEvidenceStage.POSTED,
                "TEST_DOCUMENT", documentId, itemId, UUID.randomUUID(),
                qty, rate, weight == null ? null : UUID.fromString(
                "00000000-0000-0000-0000-000000000901"),
                weight, preference, weightCaptureAvailable, true, date, null);
    }

    static MeasurementProfileKey key(String family) {
        return new MeasurementProfileKey(UUID.randomUUID(), family);
    }
}
