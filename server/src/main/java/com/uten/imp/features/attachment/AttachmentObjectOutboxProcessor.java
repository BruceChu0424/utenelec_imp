package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.config.props.StorageProperties;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Duration;
import java.util.UUID;

/** Idempotent external object deletion worker; the database intent always commits first. */
@Slf4j
@Service
public class AttachmentObjectOutboxProcessor {
    private final JdbcTemplate jdbc;
    private final StorageProviderRegistry storageProviders;
    private final StorageProperties properties;
    /** 原件物理删除成功后清掉派生的 Office 预览缓存（缓存不是业务对象，删失败只记日志）。 */
    private final AttachmentPreviewEvictor previews;
    private final TransactionTemplate receiptTransactions;

    public AttachmentObjectOutboxProcessor(JdbcTemplate jdbc,StorageProviderRegistry storageProviders,
            StorageProperties properties,AttachmentPreviewEvictor previews,PlatformTransactionManager transactions) {
        this.jdbc=jdbc;this.storageProviders=storageProviders;this.properties=properties;this.previews=previews;
        receiptTransactions=new TransactionTemplate(transactions);
        receiptTransactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        receiptTransactions.setTimeout(30);
    }

    public boolean processNext() {
        OutboxItem item = receiptTransactions.execute(status->claimNext());
        if (item == null) {
            return false;
        }
        try {
            StorageService storage=storageProviders.require(item.storageProvider());
            OutboxItem receiptItem=item;
            if ("DELETE_STAGING".equals(item.operation())) {
                receiptItem=deleteStaging(storage,item);
                if(receiptItem==null)return true;
            } else if ("DELETE_FINAL".equals(item.operation())) {
                storage.delete(item.storageKey(), item.storageVersion());
            } else {
                throw new IllegalStateException("Unknown attachment outbox operation");
            }
            OutboxItem completed=receiptItem;
            receiptTransactions.executeWithoutResult(status->markSucceeded(completed));
        } catch (RuntimeException error) {
            receiptTransactions.executeWithoutResult(status->markFailed(item,error));
        }
        return true;
    }

    private OutboxItem deleteStaging(StorageService storage,OutboxItem item) {
        OutboxItem target=item;
        if("internal".equals(item.storageProvider())&&item.storageVersion()==null) {
            var observed=storage.describe(item.storageKey());
            if(observed.exists()) {
                String version=observed.versionId();
                if(version==null||version.isBlank())throw new IllegalStateException("Staging object has no confirmed internal version");
                target=receiptTransactions.execute(status->{
                    int changed=jdbc.update("""
                            UPDATE attachment_object_outbox SET storage_version=?,updated_at=now()
                            WHERE id=? AND status='PROCESSING' AND attempts=? AND storage_version IS NULL
                            """,version,item.id(),item.attempts());
                    return changed==1?new OutboxItem(item.id(),item.attachmentId(),item.operation(),item.storageKey(),version,item.attempts(),item.storageProvider()):null;
                });
                if(target==null)return null;
            }
        }
        storage.deleteStaging(target.storageKey(),target.storageVersion());
        return target;
    }

    private OutboxItem claimNext() {
        int staleMinutes = Math.max(1, properties.getOutbox().getStaleProcessingMinutes());
        return jdbc.query("""
                WITH candidate AS (
                    SELECT id
                    FROM attachment_object_outbox
                    WHERE (
                        status IN ('PENDING','FAILED') AND available_at <= now()
                    ) OR (
                        status = 'PROCESSING'
                        AND locked_at < now() - (? * interval '1 minute')
                    )
                    ORDER BY available_at, created_at
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
                )
                UPDATE attachment_object_outbox target
                SET status = 'PROCESSING', attempts = attempts + 1,
                    locked_at = now(), updated_at = now(), last_error = NULL
                FROM candidate
                WHERE target.id = candidate.id
                RETURNING target.id, target.attachment_id, target.operation,
                          target.storage_key, target.storage_version, target.attempts, target.storage_provider
                """, result -> result.next() ? map(result) : null, staleMinutes);
    }

    private void markSucceeded(OutboxItem item) {
        int changed=jdbc.update("""
                UPDATE attachment_object_outbox
                SET status = 'SUCCEEDED', completed_at = now(), locked_at = NULL,
                    updated_at = now(), last_error = NULL
                WHERE id = ? AND status = 'PROCESSING' AND attempts = ?
                """, item.id(),item.attempts());
        if(changed!=1)return;
        if (item.attachmentId() != null && "DELETE_FINAL".equals(item.operation())) {
            jdbc.update("""
                    UPDATE attachments
                    SET lifecycle_state = 'DELETED', delete_failure = NULL, updated_at = now()
                    WHERE id = ? AND lifecycle_state IN ('DELETE_PENDING','DELETE_FAILED')
                    """, item.attachmentId());
            try {
                previews.evict(item.attachmentId());
            } catch (RuntimeException error) {
                log.warn("Attachment preview cache eviction failed id={} type={}",
                        item.attachmentId(), error.getClass().getSimpleName());
            }
        }
        String location = "DELETE_STAGING".equals(item.operation()) ? "STAGING" : "FINAL";
        jdbc.update("""
                UPDATE attachment_reconciliation_findings
                SET finding_state = 'RESOLVED', resolved_at = now(), updated_at = now()
                WHERE storage_provider = ? AND object_location = ? AND storage_key = ?
                  AND storage_version IS NOT DISTINCT FROM ?
                  AND finding_state = 'QUEUED'
                """, item.storageProvider(), location, item.storageKey(), item.storageVersion());
    }

    private void markFailed(OutboxItem item, RuntimeException error) {
        int exponent = Math.min(item.attempts(), 10);
        long backoffSeconds = Math.min(3600L, 1L << exponent);
        String errorCode = error.getClass().getSimpleName();
        if (errorCode.length() > 200) {
            errorCode = errorCode.substring(0, 200);
        }
        int changed=jdbc.update("""
                UPDATE attachment_object_outbox
                SET status = 'FAILED', available_at = now() + (? * interval '1 second'),
                    locked_at = NULL, updated_at = now(), last_error = ?
                WHERE id = ? AND status = 'PROCESSING' AND attempts = ?
                """, backoffSeconds, errorCode, item.id(),item.attempts());
        if(changed!=1)return;
        if (item.attachmentId() != null && "DELETE_FINAL".equals(item.operation())) {
            jdbc.update("""
                    UPDATE attachments
                    SET lifecycle_state = 'DELETE_FAILED', delete_failure = ?, updated_at = now()
                    WHERE id = ? AND lifecycle_state IN ('DELETE_PENDING','DELETE_FAILED')
                    """, errorCode, item.attachmentId());
        }
        if (item.attempts() >= properties.getOutbox().getAlertAfterAttempts()) {
            log.error("Attachment object deletion needs operator attention id={} attempts={} operation={}",
                    item.id(), item.attempts(), item.operation());
        } else {
            log.warn("Attachment object deletion deferred id={} attempt={} type={}",
                    item.id(), item.attempts(), errorCode);
        }
    }

    private static OutboxItem map(ResultSet result) throws SQLException {
        return new OutboxItem(
                result.getObject("id", UUID.class),
                result.getObject("attachment_id", UUID.class),
                result.getString("operation"),
                result.getString("storage_key"),
                result.getString("storage_version"),
                result.getInt("attempts"), result.getString("storage_provider"));
    }

    private record OutboxItem(UUID id, UUID attachmentId, String operation,
                              String storageKey, String storageVersion, int attempts, String storageProvider) {
    }
}
