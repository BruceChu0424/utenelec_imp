package com.uten.imp.features.measurement;

import com.uten.imp.features.measurement.MeasurementCaptureContracts.ProfileResolution;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.UUID;

@Repository
@RequiredArgsConstructor
public class JdbcMeasurementCaptureStore implements MeasurementCaptureStore {

    private final JdbcTemplate jdbc;

    @Override
    public List<ProfileResolution> resolveBatch(
            MeasurementOperationFamily family, Set<UUID> goodsIds) {
        List<UUID> ordered = goodsIds.stream()
                .sorted(java.util.Comparator.comparing(UUID::toString)).toList();
        String placeholders = String.join(
                ",", Collections.nCopies(ordered.size(), "?"));
        List<Object> parameters = new ArrayList<>();
        parameters.add(family.name());
        parameters.addAll(ordered);
        return jdbc.query("""
                SELECT resolution.id AS profile_id,
                       goods.id AS goods_id,
                       COALESCE(resolution.operation_family, ?) AS operation_family,
                       COALESCE(resolution.status, 'UNCLASSIFIED') AS status,
                       COALESCE(resolution.primary_input, 'BUSINESS_QUANTITY')
                           AS primary_input,
                       COALESCE(resolution.secondary_policy, 'OFFERED')
                           AS secondary_policy,
                       COALESCE(resolution.business_unit_id, goods.unit_id)
                           AS business_unit_id,
                       business_unit.name AS business_unit_name,
                       resolution.actual_weight_unit_id,
                       weight_unit.name AS actual_weight_unit_name,
                       COALESCE(resolution.confidence, 0) AS confidence,
                       COALESCE(resolution.active_evidence_count, 0)
                           AS active_evidence_count,
                       resolution.evidence_fingerprint,
                       COALESCE(resolution.version, 0) AS version,
                       resolution.last_evidence_at
                FROM goods
                LEFT JOIN v_measurement_capture_profile_resolution resolution
                  ON resolution.goods_id = goods.id
                 AND resolution.operation_family = ?
                LEFT JOIN units business_unit
                  ON business_unit.id = COALESCE(
                      resolution.business_unit_id, goods.unit_id)
                LEFT JOIN units weight_unit
                  ON weight_unit.id = resolution.actual_weight_unit_id
                WHERE goods.is_deleted = FALSE
                  AND goods.id IN (
                """ + placeholders + ") ORDER BY goods.id",
                (rs, rowNum) -> resolution(rs),
                duplicateFamilyParameter(parameters, family));
    }

    private static Object[] duplicateFamilyParameter(
            List<Object> parameters, MeasurementOperationFamily family) {
        List<Object> values = new ArrayList<>();
        values.add(family.name());
        values.add(family.name());
        values.addAll(parameters.subList(1, parameters.size()));
        return values.toArray();
    }

    @Override
    public LockedProfile lockOrCreate(
            MeasurementProfileKey key, UUID proposedActualWeightUnitId) {
        jdbc.update("""
                INSERT INTO measurement_capture_profiles(
                    goods_id, operation_family, business_unit_id,
                    actual_weight_unit_id)
                SELECT id, ?, unit_id, ?
                FROM goods
                WHERE id = ? AND is_deleted = FALSE
                ON CONFLICT (goods_id, operation_family) DO NOTHING
                """, key.operationFamily(), proposedActualWeightUnitId,
                key.goodsId());
        List<LockedProfile> rows = jdbc.query("""
                SELECT id, goods_id, operation_family, business_unit_id,
                       actual_weight_unit_id, version,
                       evidence_fingerprint, last_evidence_at
                FROM measurement_capture_profiles
                WHERE goods_id = ? AND operation_family = ?
                FOR UPDATE
                """, (rs, rowNum) -> new LockedProfile(
                rs.getObject("id", UUID.class),
                new MeasurementProfileKey(
                        rs.getObject("goods_id", UUID.class),
                        rs.getString("operation_family")),
                rs.getObject("business_unit_id", UUID.class),
                rs.getObject("actual_weight_unit_id", UUID.class),
                rs.getLong("version"),
                rs.getString("evidence_fingerprint"),
                offsetDateTime(rs.getObject("last_evidence_at"))),
                key.goodsId(), key.operationFamily());
        if (rows.size() != 1) {
            throw new IllegalArgumentException("goods does not exist or is deleted");
        }
        return rows.getFirst();
    }

    @Override
    public List<MeasurementEvidence> loadEvidence(UUID profileId) {
        return jdbc.query("""
                SELECT event_id, goods_id, operation_family, idempotency_key,
                       stage, source_document_type, source_document_id,
                       source_item_id, business_unit_id, business_qty,
                       unit_rate, actual_weight_unit_id, actual_weight,
                       declared_preference, weight_capture_available,
                       reversible, business_date, reverses_fingerprint
                FROM measurement_capture_evidence
                WHERE profile_id = ?
                ORDER BY recorded_at, event_id
                """, (rs, rowNum) -> new MeasurementEvidence(
                rs.getObject("event_id", UUID.class),
                new MeasurementProfileKey(
                        rs.getObject("goods_id", UUID.class),
                        rs.getString("operation_family")),
                rs.getString("idempotency_key"),
                MeasurementEvidenceStage.valueOf(rs.getString("stage")),
                rs.getString("source_document_type"),
                rs.getObject("source_document_id", UUID.class),
                rs.getObject("source_item_id", UUID.class),
                rs.getObject("business_unit_id", UUID.class),
                rs.getBigDecimal("business_qty"),
                rs.getBigDecimal("unit_rate"),
                rs.getObject("actual_weight_unit_id", UUID.class),
                rs.getBigDecimal("actual_weight"),
                MeasurementCapturePreference.fromStorageCode(
                        rs.getString("declared_preference")),
                rs.getBoolean("weight_capture_available"),
                rs.getBoolean("reversible"),
                rs.getObject("business_date", java.time.LocalDate.class),
                rs.getString("reverses_fingerprint")), profileId);
    }

    @Override
    public List<MeasurementDecision> loadDecisions(UUID profileId) {
        return jdbc.query("""
                SELECT event_id, goods_id, operation_family, idempotency_key,
                       action, preference, actor_id, reason,
                       expected_version, resulting_version, decided_at
                FROM measurement_capture_decision_events
                WHERE profile_id = ?
                ORDER BY resulting_version, event_id
                """, (rs, rowNum) -> new MeasurementDecision(
                rs.getObject("event_id", UUID.class),
                new MeasurementProfileKey(
                        rs.getObject("goods_id", UUID.class),
                        rs.getString("operation_family")),
                rs.getString("idempotency_key"),
                MeasurementDecisionAction.valueOf(rs.getString("action")),
                preference(rs.getString("preference")),
                rs.getObject("actor_id", UUID.class),
                rs.getString("reason"),
                rs.getLong("expected_version"),
                rs.getLong("resulting_version"),
                offsetDateTime(rs.getObject("decided_at"))), profileId);
    }

    @Override
    public void insertEvidence(
            UUID profileId, MeasurementEvidence evidence,
            BigDecimal reliability, UUID recordedBy) {
        UUID reversesEventId = null;
        if (evidence.stage() == MeasurementEvidenceStage.REVERSED) {
            reversesEventId = jdbc.queryForObject("""
                    SELECT event_id FROM measurement_capture_evidence
                    WHERE profile_id = ? AND evidence_fingerprint = ?
                    """, UUID.class, profileId, evidence.reversesFingerprint());
        }
        requireOne(jdbc.update("""
                INSERT INTO measurement_capture_evidence(
                    event_id, profile_id, goods_id, operation_family,
                    idempotency_key, stage, source_document_type,
                    source_document_id, source_item_id, source_event_key,
                    business_qty, business_unit_id, unit_rate,
                    actual_weight, actual_weight_unit_id,
                    declared_preference, weight_capture_available,
                    reliability, reversible, business_date,
                    reverses_event_id, reverses_fingerprint,
                    payload_fingerprint, evidence_fingerprint, recorded_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                evidence.eventId(), profileId, evidence.key().goodsId(),
                evidence.key().operationFamily(), evidence.idempotencyKey(),
                evidence.stage().name(), evidence.sourceDocumentType(),
                evidence.sourceDocumentId(), evidence.sourceItemId(),
                evidence.sourceEventKey(), evidence.qty(), evidence.unitId(),
                evidence.unitRate(), evidence.actualWeight(),
                evidence.actualWeightUnitId(),
                evidence.declaredPreference().storageCode(),
                evidence.weightCaptureAvailable(), reliability,
                evidence.reversible(), evidence.businessDate(),
                reversesEventId, evidence.reversesFingerprint(),
                evidence.payloadFingerprint(), evidence.fingerprint(), recordedBy));
    }

    @Override
    public void insertDecision(
            UUID profileId, MeasurementDecision decision,
            String evidenceFingerprint) {
        requireOne(jdbc.update("""
                INSERT INTO measurement_capture_decision_events(
                    event_id, profile_id, goods_id, operation_family,
                    idempotency_key, action, preference, actor_id, reason,
                    expected_version, resulting_version,
                    evidence_fingerprint, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, decision.eventId(), profileId, decision.key().goodsId(),
                decision.key().operationFamily(), decision.idempotencyKey(),
                decision.action().name(),
                decision.preference() == null ? null
                        : decision.preference().storageCode(),
                decision.actorId(), decision.reason(), decision.expectedVersion(),
                decision.resultingVersion(), evidenceFingerprint,
                decision.decidedAt()));
    }

    @Override
    public boolean updateProfile(
            LockedProfile locked, MeasurementProfile next,
            UUID actualWeightUnitId, String evidenceFingerprint,
            boolean evidenceMutation) {
        int changed = jdbc.update("""
                UPDATE measurement_capture_profiles
                SET status = ?, inferred_preference = ?,
                    manual_override_preference = ?, effective_preference = ?,
                    actual_weight_unit_id = COALESCE(?, actual_weight_unit_id),
                    confidence = ?, active_evidence_count = ?,
                    quantity_document_count = ?, quantity_day_count = ?,
                    quantity_and_weight_document_count = ?,
                    quantity_and_weight_day_count = ?,
                    inference_conflict = ?, evidence_fingerprint = ?,
                    version = ?,
                    last_evidence_at = CASE WHEN ? THEN now()
                                            ELSE last_evidence_at END
                WHERE id = ? AND version = ?
                """, next.status().name(), storage(next.inferredPreference()),
                storage(next.manualOverride()), storage(next.effectivePreference()),
                actualWeightUnitId, next.confidence(), next.activeEvidenceCount(),
                next.quantityDocumentCount(), next.quantityDayCount(),
                next.quantityAndWeightDocumentCount(),
                next.quantityAndWeightDayCount(), next.inferenceConflict(),
                evidenceFingerprint, next.version(), evidenceMutation,
                locked.profileId(), locked.version());
        return changed == 1;
    }

    private static ProfileResolution resolution(ResultSet rs) throws SQLException {
        return new ProfileResolution(
                rs.getObject("profile_id", UUID.class),
                rs.getObject("goods_id", UUID.class),
                rs.getString("operation_family"), rs.getString("status"),
                rs.getString("primary_input"), rs.getString("secondary_policy"),
                rs.getObject("business_unit_id", UUID.class),
                rs.getString("business_unit_name"),
                rs.getObject("actual_weight_unit_id", UUID.class),
                rs.getString("actual_weight_unit_name"),
                rs.getBigDecimal("confidence"),
                rs.getLong("active_evidence_count"),
                rs.getString("evidence_fingerprint"), rs.getLong("version"),
                offsetDateTime(rs.getObject("last_evidence_at")),
                rs.getObject("profile_id", UUID.class) != null);
    }

    private static MeasurementCapturePreference preference(String value) {
        return value == null ? null
                : MeasurementCapturePreference.fromStorageCode(value);
    }

    private static String storage(MeasurementCapturePreference value) {
        return value == null ? null : value.storageCode();
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime offset) return offset;
        if (value instanceof Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        return OffsetDateTime.parse(value.toString());
    }

    private static void requireOne(int changed) {
        if (changed != 1) {
            throw new IllegalStateException("measurement persistence conflict");
        }
    }
}
