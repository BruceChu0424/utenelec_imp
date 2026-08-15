package com.uten.imp.features.attachment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.UUID;

@Service
@RequiredArgsConstructor
class AttachmentReconciliationApprovalTransaction {
    private final JdbcTemplate jdbc;
    private final StorageProperties properties;
    private final AttachmentObjectOutboxStore outbox;

    @Transactional
    void approve(UUID findingId, UUID userId, String approvalReference) {
        AttachmentReconciliationService.Finding finding = jdbc.query("""
                SELECT id, object_location, storage_key, storage_version, size_bytes,
                       finding_state, observation_count, first_seen_at, evidence_sha256
                FROM attachment_reconciliation_findings
                WHERE id = ?
                FOR UPDATE
                """, result -> result.next()
                        ? new AttachmentReconciliationService.Finding(
                        result.getObject("id", UUID.class),
                        result.getString("object_location"),
                        result.getString("storage_key"),
                        result.getString("storage_version"),
                        result.getLong("size_bytes"),
                        result.getString("finding_state"),
                        result.getInt("observation_count"),
                        result.getTimestamp("first_seen_at").toInstant(),
                        result.getString("evidence_sha256"))
                        : null,
                findingId);
        if (finding == null || !"OBSERVED".equals(finding.state())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Reconciliation finding is no longer approvable");
        }
        jdbc.queryForObject(
                "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text",
                String.class,
                "attachment-object:" + finding.storageKey());
        if (AttachmentReconciliationService.isReferenced(
                jdbc, finding.location(), finding.storageKey(), finding.storageVersion())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Object became referenced; deletion approval was cancelled");
        }
        Instant earliest = Instant.now().minusSeconds(
                Math.max(1, properties.getReconciliation().getOrphanGraceHours()) * 3600L);
        if (finding.observationCount() < 2 || finding.firstSeenAt().isAfter(earliest)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Orphan needs two observations and the full grace period before deletion");
        }
        jdbc.update("""
                UPDATE attachment_reconciliation_findings
                SET finding_state = 'QUEUED', approved_at = now(), approved_by = ?,
                    approval_reference = ?, updated_at = now()
                WHERE id = ? AND finding_state = 'OBSERVED'
                """, userId, approvalReference, findingId);
        if ("STAGING".equals(finding.location())) {
            outbox.enqueueStaging(null, finding.storageKey(), finding.storageVersion());
        } else {
            outbox.enqueueFinal(null, finding.storageKey(), finding.storageVersion());
        }
    }
}
