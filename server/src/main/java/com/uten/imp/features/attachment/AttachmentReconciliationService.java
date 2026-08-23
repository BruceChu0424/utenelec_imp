package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageService.StoredObjectRef;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.dto.AttachmentReconciliationFindingDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Records orphan evidence; deletion still requires a separate explicit approval. */
@Slf4j
@Service
@Profile("!cloud")
@RequiredArgsConstructor
public class AttachmentReconciliationService {
    private final StorageService storage;
    private final StorageProperties properties;
    private final JdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;
    private final AttachmentReconciliationApprovalTransaction approvalTransaction;

    @Scheduled(cron = "${uten.storage.reconciliation.cron:0 17 * * * *}", zone = "UTC")
    public void scheduledReconcile() {
        if (!properties.getReconciliation().isEnabled()) {
            return;
        }
        try {
            reconcileInventory(storage.inventory());
        } catch (RuntimeException error) {
            log.error("Attachment orphan reconciliation failed type={}",
                    error.getClass().getSimpleName());
        }
    }

    @Transactional
    public void reconcileInventory(List<StoredObjectRef> inventory) {
        if (!properties.getReconciliation().isEnabled()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "Attachment reconciliation is disabled");
        }
        for (StoredObjectRef object : inventory) {
            if (isReferenced(jdbc, object.location().name(), object.storageKey(),
                    object.versionId())) {
                jdbc.update("""
                        UPDATE attachment_reconciliation_findings
                        SET finding_state = 'IGNORED', resolved_at = now(), updated_at = now()
                        WHERE object_location = ? AND storage_key = ?
                          AND storage_version IS NOT DISTINCT FROM ?
                          AND finding_state = 'OBSERVED'
                        """, object.location().name(), object.storageKey(), object.versionId());
                continue;
            }
            String evidence = evidenceDigest(object);
            jdbc.update("""
                    INSERT INTO attachment_reconciliation_findings (
                        object_location, storage_key, storage_version, size_bytes,
                        observed_modified_at, evidence_sha256)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (
                        object_location, storage_key, (COALESCE(storage_version, ''))
                    ) DO UPDATE
                    SET size_bytes = EXCLUDED.size_bytes,
                        observed_modified_at = EXCLUDED.observed_modified_at,
                        evidence_sha256 = EXCLUDED.evidence_sha256,
                        observation_count = attachment_reconciliation_findings.observation_count + 1,
                        last_seen_at = now(), updated_at = now()
                    WHERE attachment_reconciliation_findings.finding_state = 'OBSERVED'
                    """,
                    object.location().name(), object.storageKey(), object.versionId(),
                    object.size(), object.lastModified(), evidence);
        }
    }

    @Transactional(readOnly = true)
    public List<AttachmentReconciliationFindingDto> listOpen() {
        AuthUser user = requireReconciler("attachment:reconcile:view");
        return jdbc.query("""
                SELECT id, object_location, storage_key, storage_version, size_bytes,
                       finding_state, observation_count, first_seen_at, last_seen_at,
                       evidence_sha256
                FROM attachment_reconciliation_findings
                WHERE finding_state IN ('OBSERVED','APPROVED','QUEUED')
                ORDER BY first_seen_at, id
                """, (result, rowNumber) -> map(result));
    }

    public void approveDelete(UUID findingId, String approvalReference) {
        AuthUser user = requireReconciler("attachment:reconcile:approve_delete");
        String reference = approvalReference == null ? "" : approvalReference.trim();
        if (!reference.matches("[A-Za-z0-9][A-Za-z0-9._:/ -]{2,254}")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Approval reference is not canonical");
        }
        Finding finding = jdbc.query("""
                SELECT id, object_location, storage_key, storage_version, size_bytes,
                       finding_state, observation_count, first_seen_at, evidence_sha256
                FROM attachment_reconciliation_findings WHERE id = ?
                """, result -> result.next() ? finding(result) : null, findingId);
        if (finding == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "Reconciliation finding not found");
        }
        StoredObjectRef exact = storage.inventory().stream()
                .filter(object -> object.location().name().equals(finding.location()))
                .filter(object -> object.storageKey().equals(finding.storageKey()))
                .filter(object -> Objects.equals(object.versionId(), finding.storageVersion()))
                .filter(object -> object.size() == finding.sizeBytes())
                .findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.CONFLICT,
                        "The exact orphan object version is no longer present"));
        if (!evidenceDigest(exact).equals(finding.evidenceSha256())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Orphan evidence changed; reconcile again before approval");
        }
        approvalTransaction.approve(findingId, user.getId(), reference);
    }

    private AuthUser requireReconciler(String permission) {
        AuthUser user = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.getEmployeeId() == null
                || !(user.isSuperAdmin()
                || user.getPermissions().contains(permission))) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        return user;
    }

    static boolean isReferenced(JdbcTemplate jdbc, String location,
                                String storageKey, String storageVersion) {
        String sql = "STAGING".equals(location) ? """
                SELECT EXISTS (
                    SELECT 1 FROM attachment_upload_sessions
                    WHERE storage_key = ? AND status IN ('PENDING','SCANNING')
                    UNION ALL
                    SELECT 1 FROM attachment_object_outbox
                    WHERE operation = 'DELETE_STAGING' AND storage_key = ?
                      AND storage_version IS NOT DISTINCT FROM ?
                      AND status <> 'SUCCEEDED'
                )
                """ : """
                SELECT EXISTS (
                    SELECT 1 FROM attachments
                    WHERE storage_key = ?
                      AND storage_version IS NOT DISTINCT FROM ?
                      AND lifecycle_state <> 'DELETED'
                    UNION ALL
                    SELECT 1 FROM attachment_object_outbox
                    WHERE operation = 'DELETE_FINAL' AND storage_key = ?
                      AND storage_version IS NOT DISTINCT FROM ?
                      AND status <> 'SUCCEEDED'
                )
                """;
        Boolean referenced = "STAGING".equals(location)
                ? jdbc.queryForObject(sql, Boolean.class,
                storageKey, storageKey, storageVersion)
                : jdbc.queryForObject(sql, Boolean.class,
                storageKey, storageVersion, storageKey, storageVersion);
        return Boolean.TRUE.equals(referenced);
    }

    static String evidenceDigest(StoredObjectRef object) {
        try {
            String canonical = object.location().name() + "\n"
                    + object.storageKey() + "\n"
                    + (object.versionId() == null ? "" : object.versionId()) + "\n"
                    + object.size() + "\n"
                    + (object.lastModified() == null ? "" : object.lastModified()) + "\n";
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256")
                            .digest(canonical.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            throw new IllegalStateException("Unable to hash attachment inventory evidence", e);
        }
    }

    private static AttachmentReconciliationFindingDto map(ResultSet result) throws SQLException {
        return new AttachmentReconciliationFindingDto(
                result.getObject("id", UUID.class),
                result.getString("object_location"),
                result.getString("storage_key"),
                result.getString("storage_version"),
                result.getLong("size_bytes"),
                result.getString("finding_state"),
                result.getInt("observation_count"),
                result.getTimestamp("first_seen_at").toInstant(),
                result.getTimestamp("last_seen_at").toInstant(),
                result.getString("evidence_sha256"));
    }

    private static Finding finding(ResultSet result) throws SQLException {
        return new Finding(
                result.getObject("id", UUID.class),
                result.getString("object_location"),
                result.getString("storage_key"),
                result.getString("storage_version"),
                result.getLong("size_bytes"),
                result.getString("finding_state"),
                result.getInt("observation_count"),
                result.getTimestamp("first_seen_at").toInstant(),
                result.getString("evidence_sha256"));
    }

    record Finding(UUID id, String location, String storageKey, String storageVersion,
                   long sizeBytes, String state, int observationCount,
                   Instant firstSeenAt, String evidenceSha256) {
    }
}
