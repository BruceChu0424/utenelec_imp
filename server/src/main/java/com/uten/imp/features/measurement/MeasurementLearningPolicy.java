package com.uten.imp.features.measurement;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.Collection;
import java.util.EnumMap;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/** Pure inference. It proposes a preference but never confirms one automatically. */
public final class MeasurementLearningPolicy {

    private final int minimumIndependentDocuments;
    private final int minimumBusinessDays;

    public MeasurementLearningPolicy(
            int minimumIndependentDocuments,
            int minimumBusinessDays) {
        if (minimumIndependentDocuments < 1 || minimumBusinessDays < 1) {
            throw new IllegalArgumentException("learning thresholds must be positive");
        }
        this.minimumIndependentDocuments = minimumIndependentDocuments;
        this.minimumBusinessDays = minimumBusinessDays;
    }

    public static MeasurementLearningPolicy conservativeDefault() {
        return new MeasurementLearningPolicy(3, 2);
    }

    public MeasurementProfile evaluate(
            MeasurementProfileKey key,
            Collection<MeasurementEvidence> activeObservations,
            MeasurementCapturePreference manualOverride,
            long version) {
        if (key == null || activeObservations == null) {
            throw new IllegalArgumentException("learning input is required");
        }
        EnumMap<MeasurementCapturePreference, Set<UUID>> documents =
                new EnumMap<>(MeasurementCapturePreference.class);
        EnumMap<MeasurementCapturePreference, Set<LocalDate>> days =
                new EnumMap<>(MeasurementCapturePreference.class);
        for (MeasurementCapturePreference preference
                : MeasurementCapturePreference.values()) {
            documents.put(preference, new HashSet<>());
            days.put(preference, new HashSet<>());
        }

        int activeCount = 0;
        for (MeasurementEvidence evidence : activeObservations) {
            if (evidence == null || !evidence.observation()) continue;
            if (!key.equals(evidence.key())) {
                throw new IllegalArgumentException("evidence belongs to another profile");
            }
            activeCount++;
            evidence.classifyingPreference().ifPresent(preference -> {
                documents.get(preference).add(evidence.sourceDocumentId());
                days.get(preference).add(evidence.businessDate());
            });
        }

        int qDocs = documents.get(MeasurementCapturePreference.QUANTITY).size();
        int qDays = days.get(MeasurementCapturePreference.QUANTITY).size();
        int dDocs = documents.get(
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT).size();
        int dDays = days.get(
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT).size();
        boolean qQualified = qualifies(qDocs, qDays);
        boolean dQualified = qualifies(dDocs, dDays);
        boolean evidenceConflict = qQualified && dQualified;
        MeasurementCapturePreference inferred = qQualified == dQualified
                ? null
                : qQualified
                ? MeasurementCapturePreference.QUANTITY
                : MeasurementCapturePreference.QUANTITY_AND_WEIGHT;
        BigDecimal confidence = progress(qDocs, qDays).max(progress(dDocs, dDays));

        MeasurementProfileStatus status;
        MeasurementCapturePreference effective;
        boolean inferenceConflict;
        if (manualOverride != null) {
            status = MeasurementProfileStatus.CONFIRMED;
            effective = manualOverride;
            inferenceConflict = evidenceConflict
                    || (inferred != null && inferred != manualOverride);
            confidence = BigDecimal.ONE.setScale(4);
        } else if (evidenceConflict) {
            status = MeasurementProfileStatus.CONFLICT;
            effective = null;
            inferenceConflict = true;
        } else if (inferred != null) {
            status = MeasurementProfileStatus.PROVISIONAL;
            effective = inferred;
            inferenceConflict = false;
        } else {
            status = MeasurementProfileStatus.UNCLASSIFIED;
            effective = null;
            inferenceConflict = false;
        }

        return new MeasurementProfile(
                key, status, inferred, manualOverride, effective, confidence,
                activeCount, qDocs, qDays, dDocs, dDays,
                inferenceConflict, version);
    }

    private boolean qualifies(int documents, int days) {
        return documents >= minimumIndependentDocuments
                && days >= minimumBusinessDays;
    }

    private BigDecimal progress(int documents, int days) {
        BigDecimal documentProgress = BigDecimal.valueOf(documents)
                .divide(BigDecimal.valueOf(minimumIndependentDocuments),
                        4, RoundingMode.HALF_UP);
        BigDecimal dayProgress = BigDecimal.valueOf(days)
                .divide(BigDecimal.valueOf(minimumBusinessDays),
                        4, RoundingMode.HALF_UP);
        return documentProgress.min(dayProgress).min(BigDecimal.ONE)
                .setScale(4, RoundingMode.HALF_UP);
    }
}
