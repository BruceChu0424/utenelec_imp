package com.uten.imp.features.measurement;

import com.uten.imp.features.measurement.MeasurementCaptureContracts.ProfileResolution;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;

public interface MeasurementCaptureStore {

    List<ProfileResolution> resolveBatch(
            MeasurementOperationFamily family, Set<UUID> goodsIds);

    LockedProfile lockOrCreate(
            MeasurementProfileKey key, UUID proposedActualWeightUnitId);

    List<MeasurementEvidence> loadEvidence(UUID profileId);

    List<MeasurementDecision> loadDecisions(UUID profileId);

    void insertEvidence(
            UUID profileId,
            MeasurementEvidence evidence,
            BigDecimal reliability,
            UUID recordedBy);

    void insertDecision(
            UUID profileId,
            MeasurementDecision decision,
            String evidenceFingerprint);

    boolean updateProfile(
            LockedProfile locked,
            MeasurementProfile next,
            UUID actualWeightUnitId,
            String evidenceFingerprint,
            boolean evidenceMutation);

    record LockedProfile(
            UUID profileId,
            MeasurementProfileKey key,
            UUID businessUnitId,
            UUID actualWeightUnitId,
            long version,
            String evidenceFingerprint,
            OffsetDateTime lastEvidenceAt) {
    }
}
