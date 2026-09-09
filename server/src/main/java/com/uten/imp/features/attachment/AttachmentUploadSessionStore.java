package com.uten.imp.features.attachment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.AttachmentUploadGrantService.Grant;
import lombok.RequiredArgsConstructor;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Durable upload reservations used for quotas, crash recovery and staging cleanup. */
@Service
@RequiredArgsConstructor
class AttachmentUploadSessionStore {
    private static final String ACTIVE = "('PENDING','SCANNING')";
    /** Compatibility window for reservations issued before expiry canonicalization. */
    private static final Duration LEGACY_EXPIRY_ROUNDING_TOLERANCE = Duration.ofNanos(1_000);

    private final JdbcTemplate jdbc;
    private final StorageProperties properties;

    @Transactional
    UUID reserve(Grant grant, String storageProvider) {
        List<String> locks = new ArrayList<>(List.of(
                "attachment-owner:" + grant.ownerType() + ":" + grant.ownerId(),
                "attachment-user:" + grant.userId()));
        locks.sort(Comparator.naturalOrder());
        for (String lock : locks) {
            jdbc.queryForObject(
                    "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text",
                    String.class,
                    lock);
        }

        Quota userQuota = quota(
                "user_id = ?", grant.userId());
        Quota ownerQuota = quota(
                "owner_type = ? AND owner_id = ?", grant.ownerType(), grant.ownerId());
        requireQuota(userQuota, properties.getMaxPendingPerUser(),
                properties.getMaxPendingBytesPerUser(), grant.sizeBytes(), "user");
        requireQuota(ownerQuota, properties.getMaxPendingPerOwner(),
                properties.getMaxPendingBytesPerOwner(), grant.sizeBytes(), "business record");

        UUID id = UUID.randomUUID();
        try {
            jdbc.update("""
                    INSERT INTO attachment_upload_sessions (
                        id, storage_key, owner_type, owner_id, user_id,
                        original_name, content_type, expected_size_bytes, expires_at, storage_provider)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    id,
                    grant.storageKey(),
                    grant.ownerType(),
                    grant.ownerId(),
                    grant.userId(),
                    grant.originalName(),
                    grant.contentType(),
                    grant.sizeBytes(),
                    Timestamp.from(grant.expiresAt()), storageProvider);
        } catch (DataIntegrityViolationException e) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Attachment upload reservation already exists");
        }
        return id;
    }

    @Transactional
    UploadSession claimForScan(Grant grant) {
        UploadSession session = findForUpdate(grant.storageKey());
        if (session == null || !session.matches(grant)) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    "Attachment upload reservation does not match the signed grant");
        }
        if (!session.expiresAt().isAfter(Instant.now())) {
            jdbc.update("""
                    UPDATE attachment_upload_sessions
                    SET status = 'EXPIRED', updated_at = now(),
                        last_failure_code = 'GRANT_EXPIRED'
                    WHERE id = ? AND status IN ('PENDING','SCANNING')
                    """, session.id());
            throw new ApiException(ErrorCode.CONFLICT,
                    "Attachment upload reservation expired; upload again");
        }
        if (!"PENDING".equals(session.status())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Attachment upload is already being processed");
        }
        jdbc.update("""
                UPDATE attachment_upload_sessions
                SET status = 'SCANNING', updated_at = now(), last_failure_code = NULL
                WHERE id = ? AND status = 'PENDING'
                """, session.id());
        return new UploadSession(
                session.id(), session.storageKey(), session.ownerType(), session.ownerId(),
                session.userId(), session.originalName(), session.contentType(),
                session.expectedSizeBytes(), session.expiresAt(), "SCANNING", session.storageProvider());
    }

    @Transactional
    void recordStaging(UUID sessionId, String versionId, String eTag, String sha256) {
        int changed = jdbc.update("""
                UPDATE attachment_upload_sessions
                SET staging_version = ?, staging_etag = ?, sha256 = ?, updated_at = now()
                WHERE id = ? AND status = 'SCANNING'
                """, versionId, eTag, sha256, sessionId);
        if (changed != 1) {
            throw new IllegalStateException("Attachment upload session lost its scan claim");
        }
    }

    @Transactional
    void releaseAfterTransientFailure(UUID sessionId, String failureCode) {
        jdbc.update("""
                UPDATE attachment_upload_sessions
                SET status = 'PENDING', last_failure_code = ?, updated_at = now()
                WHERE id = ? AND status = 'SCANNING'
                """, canonicalFailure(failureCode), sessionId);
    }

    @Transactional
    void reject(UUID sessionId, String failureCode, String scanEngine, String scanSignature) {
        jdbc.update("""
                UPDATE attachment_upload_sessions
                SET status = 'REJECTED', last_failure_code = ?, scan_engine = ?,
                    scan_signature = ?, completed_at = now(), updated_at = now()
                WHERE id = ? AND status = 'SCANNING'
                """, canonicalFailure(failureCode), scanEngine, scanSignature, sessionId);
    }

    @Transactional
    void completePromotion(UUID sessionId, String stagingVersion, String stagingEtag,
                           String sha256, String finalVersion, String finalEtag,
                           String scanEngine, String scanSignature,
                           long finalStoredSize, String finalEncoding) {
        int changed = jdbc.update("""
                UPDATE attachment_upload_sessions
                SET status = 'PROMOTED', staging_version = ?, staging_etag = ?,
                    sha256 = ?, final_version = ?, final_etag = ?,
                    scan_engine = ?, scan_signature = ?, final_stored_size_bytes = ?,
                    final_storage_encoding = ?, completed_at = now(), updated_at = now()
                WHERE id = ? AND status = 'SCANNING'
                """, stagingVersion, stagingEtag, sha256, finalVersion, finalEtag,
                scanEngine, scanSignature, finalStoredSize, finalEncoding, sessionId);
        if (changed != 1) {
            throw new IllegalStateException("Attachment upload session cannot complete promotion");
        }
    }

    UploadSession findByStorageKey(String storageKey) {
        return jdbc.query("""
                SELECT id, storage_key, owner_type, owner_id, user_id, original_name,
                       content_type, expected_size_bytes, expires_at, status, storage_provider
                FROM attachment_upload_sessions
                WHERE storage_key = ?
                """, result -> result.next() ? map(result) : null, storageKey);
    }

    ExpiredSession expireNext() {
        int staleMinutes = Math.max(1, properties.getOutbox().getStaleProcessingMinutes());
        return jdbc.query("""
                WITH candidate AS (
                    SELECT id
                    FROM attachment_upload_sessions
                    WHERE (status = 'PENDING' AND expires_at <= now())
                       OR (status = 'SCANNING'
                           AND expires_at <= now() - (? * interval '1 minute'))
                       OR (status = 'EXPIRED'
                           AND last_failure_code IN (
                               'EXPIRY_CLEANUP_PENDING', 'CLEANUP_LOOKUP_FAILED')
                           AND updated_at <= now() - interval '1 minute')
                    ORDER BY expires_at
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
                )
                UPDATE attachment_upload_sessions target
                SET status = 'EXPIRED', last_failure_code = 'EXPIRY_CLEANUP_PENDING',
                    completed_at = now(), updated_at = now()
                FROM candidate
                WHERE target.id = candidate.id
                RETURNING target.id, target.storage_key, target.storage_provider
                """, result -> result.next()
                        ? new ExpiredSession(
                        result.getObject("id", UUID.class), result.getString("storage_key"), result.getString("storage_provider"))
                        : null,
                staleMinutes);
    }

    void recordExpiryCleanup(UUID sessionId, String outcome) {
        jdbc.update("""
                UPDATE attachment_upload_sessions
                SET last_failure_code = ?, updated_at = now()
                WHERE id = ? AND status = 'EXPIRED'
                """, canonicalFailure(outcome), sessionId);
    }

    private UploadSession findForUpdate(String storageKey) {
        return jdbc.query("""
                SELECT id, storage_key, owner_type, owner_id, user_id, original_name,
                       content_type, expected_size_bytes, expires_at, status, storage_provider
                FROM attachment_upload_sessions
                WHERE storage_key = ?
                FOR UPDATE
                """, result -> result.next() ? map(result) : null, storageKey);
    }

    private Quota quota(String predicate, Object... arguments) {
        return jdbc.queryForObject("""
                SELECT count(*) AS pending_count,
                       COALESCE(sum(expected_size_bytes), 0) AS pending_bytes
                FROM attachment_upload_sessions
                WHERE status IN %s AND expires_at > now() AND %s
                """.formatted(ACTIVE, predicate),
                (result, rowNumber) -> new Quota(
                        result.getInt("pending_count"), result.getLong("pending_bytes")),
                arguments);
    }

    private static UploadSession map(ResultSet result) throws SQLException {
        return new UploadSession(
                result.getObject("id", UUID.class),
                result.getString("storage_key"),
                result.getString("owner_type"),
                result.getObject("owner_id", UUID.class),
                result.getObject("user_id", UUID.class),
                result.getString("original_name"),
                result.getString("content_type"),
                result.getLong("expected_size_bytes"),
                result.getTimestamp("expires_at").toInstant(),
                result.getString("status"), result.getString("storage_provider"));
    }

    private static void requireQuota(Quota current, int countLimit, long byteLimit,
                                     long requestedBytes, String scope) {
        if (current.count() >= countLimit
                || current.bytes() > byteLimit - requestedBytes) {
            throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE,
                    "Attachment pending quota exceeded for " + scope
                            + "; complete or expire earlier uploads first");
        }
    }

    private static String canonicalFailure(String value) {
        if (value == null || !value.matches("[A-Z0-9_]{1,64}")) {
            return "UNCLASSIFIED_FAILURE";
        }
        return value;
    }

    record UploadSession(UUID id, String storageKey, String ownerType, UUID ownerId,
                         UUID userId, String originalName, String contentType,
                         long expectedSizeBytes, Instant expiresAt, String status, String storageProvider) {
        boolean matches(Grant grant) {
            return Objects.equals(storageKey, grant.storageKey())
                    && Objects.equals(ownerType, grant.ownerType())
                    && Objects.equals(ownerId, grant.ownerId())
                    && Objects.equals(userId, grant.userId())
                    && Objects.equals(originalName, grant.originalName())
                    && Objects.equals(contentType, grant.contentType())
                    && expectedSizeBytes == grant.sizeBytes()
                    && expiryMatches(grant.expiresAt());
        }

        private boolean expiryMatches(Instant signedExpiry) {
            if (expiresAt == null || signedExpiry == null) {
                return false;
            }
            Duration difference = Duration.between(expiresAt, signedExpiry);
            if (difference.isNegative()) {
                difference = difference.negated();
            }
            // PostgreSQL rounded pre-fix nanosecond timestamps to the nearest
            // microsecond. Keep those already-issued grants usable, without
            // weakening any identity, object, type or size binding.
            return difference.compareTo(LEGACY_EXPIRY_ROUNDING_TOLERANCE) <= 0;
        }
    }

    record ExpiredSession(UUID id, String storageKey, String storageProvider) {
    }

    private record Quota(int count, long bytes) {
    }
}
