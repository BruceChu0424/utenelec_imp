package com.uten.imp.features.measurement;

import com.uten.imp.common.util.CanonicalFingerprint;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.measurement.MeasurementLearningException.Code.DECISION_INVALID;
import static com.uten.imp.features.measurement.MeasurementLearningException.Code.IDEMPOTENCY_CONFLICT;
import static com.uten.imp.features.measurement.MeasurementLearningException.Code.INVALID_REVERSAL;
import static com.uten.imp.features.measurement.MeasurementLearningException.Code.VERSION_CONFLICT;

/**
 * In-memory domain aggregate. Persistence adapters may store its append-only
 * events and rebuild the current profile without changing the inference rules.
 */
public final class MeasurementLearningAggregate {

    public record MutationResult(MeasurementProfile profile, boolean replay) {
    }

    private final MeasurementProfileKey key;
    private final MeasurementLearningPolicy policy;
    private final List<MeasurementEvidence> evidenceEvents = new ArrayList<>();
    private final List<MeasurementDecision> decisionEvents = new ArrayList<>();
    private final Map<String, MeasurementEvidence> evidenceByIdempotencyKey =
            new HashMap<>();
    private final Map<String, MeasurementDecision> decisionByIdempotencyKey =
            new HashMap<>();
    private final Map<String, MeasurementEvidence> observationBySourceEventKey =
            new HashMap<>();
    private final Set<String> reversedFingerprints = new HashSet<>();
    private MeasurementCapturePreference manualOverride;
    private long version;
    private MeasurementProfile profile;

    public MeasurementLearningAggregate(
            MeasurementProfileKey key,
            MeasurementLearningPolicy policy) {
        if (key == null || policy == null) {
            throw new IllegalArgumentException("measurement aggregate input is required");
        }
        this.key = key;
        this.policy = policy;
        this.profile = policy.evaluate(key, List.of(), null, 0);
    }

    public static MeasurementLearningAggregate rehydrate(
            MeasurementProfileKey key,
            MeasurementLearningPolicy policy,
            List<MeasurementEvidence> evidence,
            List<MeasurementDecision> decisions,
            long persistedVersion) {
        MeasurementLearningAggregate aggregate =
                new MeasurementLearningAggregate(key, policy);
        for (MeasurementEvidence event : evidence) {
            if (event == null || !key.equals(event.key())
                    || aggregate.evidenceByIdempotencyKey.putIfAbsent(
                    event.idempotencyKey(), event) != null) {
                throw new IllegalArgumentException("persisted evidence stream is invalid");
            }
            if (event.observation()) {
                if (aggregate.observationBySourceEventKey.putIfAbsent(
                        event.sourceEventKey(), event) != null) {
                    throw new IllegalArgumentException("persisted business source is duplicated");
                }
            } else {
                MeasurementEvidence original = aggregate.observationByFingerprint(
                        event.reversesFingerprint());
                if (original == null
                        || aggregate.reversedFingerprints.contains(
                        event.reversesFingerprint())
                        || !sameReversalSource(original, event)) {
                    throw new IllegalArgumentException("persisted reversal stream is invalid");
                }
                aggregate.reversedFingerprints.add(event.reversesFingerprint());
            }
            aggregate.evidenceEvents.add(event);
        }
        for (MeasurementDecision decision : decisions) {
            if (decision == null || !key.equals(decision.key())
                    || aggregate.decisionByIdempotencyKey.putIfAbsent(
                    decision.idempotencyKey(), decision) != null) {
                throw new IllegalArgumentException("persisted decision stream is invalid");
            }
            aggregate.decisionEvents.add(decision);
            aggregate.manualOverride =
                    decision.action() == MeasurementDecisionAction.OVERRIDE
                            ? decision.preference() : null;
        }
        if (persistedVersion != evidence.size() + decisions.size()) {
            throw new IllegalArgumentException("persisted measurement version is inconsistent");
        }
        aggregate.version = persistedVersion;
        aggregate.rebuildProfile();
        return aggregate;
    }

    public synchronized MutationResult appendEvidence(
            MeasurementEvidence evidence,
            long expectedVersion) {
        if (evidence == null || !key.equals(evidence.key())) {
            throw new IllegalArgumentException("evidence belongs to another profile");
        }
        MeasurementEvidence existing = evidenceByIdempotencyKey.get(
                evidence.idempotencyKey());
        if (existing != null) {
            if (existing.fingerprint().equals(evidence.fingerprint())) {
                return new MutationResult(profile, true);
            }
            throw new MeasurementLearningException(
                    IDEMPOTENCY_CONFLICT,
                    "measurement evidence idempotency key has another payload");
        }
        requireVersion(expectedVersion);
        if (evidence.observation()) {
            MeasurementEvidence duplicateSource = observationBySourceEventKey.get(
                    evidence.sourceEventKey());
            if (duplicateSource != null) {
                throw new MeasurementLearningException(
                        IDEMPOTENCY_CONFLICT,
                        "measurement business source was already recorded");
            }
        } else {
            MeasurementEvidence original = observationByFingerprint(
                    evidence.reversesFingerprint());
            if (original == null
                    || reversedFingerprints.contains(evidence.reversesFingerprint())
                    || !sameReversalSource(original, evidence)) {
                throw new MeasurementLearningException(
                        INVALID_REVERSAL,
                        "measurement evidence reversal is not an active exact source");
            }
            reversedFingerprints.add(evidence.reversesFingerprint());
        }
        evidenceEvents.add(evidence);
        evidenceByIdempotencyKey.put(evidence.idempotencyKey(), evidence);
        if (evidence.observation()) {
            observationBySourceEventKey.put(evidence.sourceEventKey(), evidence);
        }
        version++;
        rebuildProfile();
        return new MutationResult(profile, false);
    }

    public synchronized MutationResult override(
            MeasurementCapturePreference preference,
            long expectedVersion,
            UUID eventId,
            UUID actorId,
            String reason,
            String idempotencyKey,
            OffsetDateTime decidedAt) {
        if (preference == null) {
            throw new MeasurementLearningException(
                    DECISION_INVALID, "manual preference is required");
        }
        return applyDecision(
                MeasurementDecisionAction.OVERRIDE, preference,
                expectedVersion, eventId, actorId, reason,
                idempotencyKey, decidedAt);
    }

    public synchronized MutationResult clearOverride(
            long expectedVersion,
            UUID eventId,
            UUID actorId,
            String reason,
            String idempotencyKey,
            OffsetDateTime decidedAt) {
        return applyDecision(
                MeasurementDecisionAction.CLEAR_OVERRIDE, null,
                expectedVersion, eventId, actorId, reason,
                idempotencyKey, decidedAt);
    }

    public synchronized MeasurementProfile profile() {
        return profile;
    }

    public synchronized List<MeasurementEvidence> evidenceEvents() {
        return List.copyOf(evidenceEvents);
    }

    public synchronized List<MeasurementDecision> decisionEvents() {
        return List.copyOf(decisionEvents);
    }

    public synchronized String evidenceFingerprint() {
        return CanonicalFingerprint.sha256(evidenceEvents.stream()
                .map(MeasurementEvidence::fingerprint)
                .toList());
    }

    private MutationResult applyDecision(
            MeasurementDecisionAction action,
            MeasurementCapturePreference preference,
            long expectedVersion,
            UUID eventId,
            UUID actorId,
            String reason,
            String idempotencyKey,
            OffsetDateTime decidedAt) {
        MeasurementDecision candidate = new MeasurementDecision(
                eventId, key, idempotencyKey, action, preference,
                actorId, reason, expectedVersion, expectedVersion + 1, decidedAt);
        MeasurementDecision existing = decisionByIdempotencyKey.get(
                candidate.idempotencyKey());
        if (existing != null) {
            if (existing.fingerprint().equals(candidate.fingerprint())) {
                return new MutationResult(profile, true);
            }
            throw new MeasurementLearningException(
                    IDEMPOTENCY_CONFLICT,
                    "measurement decision idempotency key has another payload");
        }
        if (action == MeasurementDecisionAction.CLEAR_OVERRIDE
                && manualOverride == null) {
            throw new MeasurementLearningException(
                    DECISION_INVALID, "measurement profile has no manual override");
        }
        requireVersion(expectedVersion);
        decisionEvents.add(candidate);
        decisionByIdempotencyKey.put(candidate.idempotencyKey(), candidate);
        manualOverride = action == MeasurementDecisionAction.OVERRIDE
                ? preference : null;
        version++;
        rebuildProfile();
        return new MutationResult(profile, false);
    }

    private void rebuildProfile() {
        profile = policy.evaluate(
                key, activeObservations(), manualOverride, version);
    }

    private List<MeasurementEvidence> activeObservations() {
        return evidenceEvents.stream()
                .filter(MeasurementEvidence::observation)
                .filter(event -> !reversedFingerprints.contains(event.fingerprint()))
                .toList();
    }

    private MeasurementEvidence observationByFingerprint(String fingerprint) {
        return evidenceEvents.stream()
                .filter(MeasurementEvidence::observation)
                .filter(event -> event.fingerprint().equals(fingerprint))
                .findFirst()
                .orElse(null);
    }

    private static boolean sameReversalSource(
            MeasurementEvidence original,
            MeasurementEvidence reversal) {
        return original.key().equals(reversal.key())
                && original.sourceDocumentType().equals(reversal.sourceDocumentType())
                && original.sourceDocumentId().equals(reversal.sourceDocumentId())
                && original.sourceItemId().equals(reversal.sourceItemId())
                && original.unitId().equals(reversal.unitId())
                && original.qty().compareTo(reversal.qty()) == 0
                && original.unitRate().compareTo(reversal.unitRate()) == 0
                && Objects.equals(
                        original.actualWeightUnitId(),
                        reversal.actualWeightUnitId())
                && sameNumber(original.actualWeight(), reversal.actualWeight())
                && original.declaredPreference() == reversal.declaredPreference();
    }

    private static boolean sameNumber(
            java.math.BigDecimal left,
            java.math.BigDecimal right) {
        return left == null ? right == null
                : right != null && left.compareTo(right) == 0;
    }

    private void requireVersion(long expectedVersion) {
        if (expectedVersion != version) {
            throw new MeasurementLearningException(
                    VERSION_CONFLICT,
                    "measurement profile version changed; refresh and retry");
        }
    }

}
