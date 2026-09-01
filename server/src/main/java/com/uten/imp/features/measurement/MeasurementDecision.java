package com.uten.imp.features.measurement;

import com.uten.imp.common.util.CanonicalFingerprint;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Append-only human decision; the aggregate projection may be rebuilt from it. */
public record MeasurementDecision(
        UUID eventId,
        MeasurementProfileKey key,
        String idempotencyKey,
        MeasurementDecisionAction action,
        MeasurementCapturePreference preference,
        UUID actorId,
        String reason,
        long expectedVersion,
        long resultingVersion,
        OffsetDateTime decidedAt) {

    public MeasurementDecision {
        if (eventId == null || key == null || action == null
                || actorId == null || decidedAt == null
                || expectedVersion < 0 || resultingVersion != expectedVersion + 1) {
            throw new IllegalArgumentException("measurement decision identity is invalid");
        }
        idempotencyKey = idempotencyKey == null ? "" : idempotencyKey.strip();
        if (!idempotencyKey.matches("[A-Za-z0-9._:-]{8,128}")) {
            throw new IllegalArgumentException("idempotencyKey is invalid");
        }
        reason = reason == null ? "" : reason.strip();
        if (reason.length() < 2 || reason.length() > 1000) {
            throw new IllegalArgumentException("decision reason is invalid");
        }
        if ((action == MeasurementDecisionAction.OVERRIDE) != (preference != null)) {
            throw new IllegalArgumentException("decision preference shape is invalid");
        }
    }

    public String fingerprint() {
        return CanonicalFingerprint.sha256(List.of(
                "eventId=" + eventId,
                "goodsId=" + key.goodsId(),
                "operationFamily=" + key.operationFamily(),
                "action=" + action,
                "preference=" + preference,
                "actorId=" + actorId,
                "reason=" + reason,
                "expectedVersion=" + expectedVersion));
    }
}
