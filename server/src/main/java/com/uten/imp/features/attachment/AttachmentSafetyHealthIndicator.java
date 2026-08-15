package com.uten.imp.features.attachment;

import com.uten.imp.config.props.StorageProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

@Component("attachmentSafety")
@RequiredArgsConstructor
final class AttachmentSafetyHealthIndicator implements HealthIndicator {
    private final JdbcTemplate jdbc;
    private final StorageProperties properties;
    private final AttachmentMalwareScanner scanner;

    @Override
    public Health health() {
        long pending = count("""
                SELECT count(*) FROM attachment_upload_sessions
                WHERE status IN ('PENDING','SCANNING') AND expires_at > now()
                """);
        long failedDeletes = count("""
                SELECT count(*) FROM attachment_object_outbox
                WHERE status = 'FAILED' AND attempts >= ?
                """, properties.getOutbox().getAlertAfterAttempts());
        long backlog = count("""
                SELECT count(*) FROM attachment_object_outbox
                WHERE status IN ('PENDING','PROCESSING','FAILED')
                """);
        long unresolvedOrphans = count("""
                SELECT count(*) FROM attachment_reconciliation_findings
                WHERE finding_state IN ('OBSERVED','APPROVED','QUEUED')
                """);

        Health.Builder result;
        if (!properties.isUploadsEnabled()) {
            result = Health.up().withDetail("uploadIntake", "DISABLED_NO_GO");
        } else if (!scanner.probe()) {
            result = Health.down().withDetail("scanner", "UNAVAILABLE");
        } else if (failedDeletes > 0
                || backlog >= properties.getOutbox().getAlertBacklog()
                || unresolvedOrphans > 0) {
            result = Health.down().withDetail("lifecycle", "OPERATOR_ATTENTION_REQUIRED");
        } else {
            result = Health.up().withDetail("uploadIntake", "READY");
        }
        return result
                .withDetail("pendingUploads", pending)
                .withDetail("objectDeleteBacklog", backlog)
                .withDetail("failedObjectDeletes", failedDeletes)
                .withDetail("unresolvedOrphans", unresolvedOrphans)
                .withDetail("reconciliationEnabled",
                        properties.getReconciliation().isEnabled())
                .build();
    }

    private long count(String sql, Object... arguments) {
        Long value = jdbc.queryForObject(sql, Long.class, arguments);
        return value == null ? 0 : value;
    }
}
