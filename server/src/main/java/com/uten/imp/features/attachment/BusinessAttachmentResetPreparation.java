package com.uten.imp.features.attachment;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Explicit test-data maintenance. The ordinary deletion worker remains the sole physical deleter. */
@Service
@RequiredArgsConstructor
public class BusinessAttachmentResetPreparation implements BusinessAttachmentResetPreparationPort {
    static final int BATCH_SIZE = 100;
    private final JdbcTemplate jdbc;
    private final StorageProviderRegistry storage;
    private final AttachmentObjectOutboxStore outbox;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final AuditService audit;

    private record Row(Item item, String snapshot) {}

    @Override @Transactional(readOnly = true)
    public Preview preview(UUID operatorId) {
        requireOperator(operatorId);
        return view(operatorId, read());
    }

    @Override @Transactional
    public Preview prepare(UUID operatorId, String operatorAccount, Confirmation confirmation) {
        requireOperator(operatorId);
        tx.bind();
        List<Row> rows = read();
        for (Row row : rows) {
            String table = switch (row.item().type()) {
                case "ATTACHMENT" -> "attachments";
                case "UPLOAD_SESSION" -> "attachment_upload_sessions";
                case "DELETE_OPERATION" -> "attachment_object_outbox";
                default -> throw new ApiException(ErrorCode.CONFLICT, "存在尚未识别的文件任务，请先对账");
            };
            jdbc.queryForList("SELECT id FROM " + table + " WHERE id=? FOR UPDATE", UUID.class, row.item().id());
        }
        rows = read();
        Preview locked = view(operatorId, rows);
        if (confirmation == null || !locked.database().equals(confirmation.database())
                || !locked.fingerprint().equals(confirmation.fingerprint())) {
            throw new ApiException(ErrorCode.CONFLICT, "目标数据库或文件状态已变化，请重新预览后确认");
        }
        for (Row row : rows) {
            switch (row.item().type()) {
                case "ATTACHMENT" -> queueAttachment(row.item().id(), operatorId);
                case "UPLOAD_SESSION" -> queueSession(row.item().id());
                case "DELETE_OPERATION" -> jdbc.update("""
                        UPDATE attachment_object_outbox SET available_at=least(available_at,now()),updated_at=now()
                        WHERE id=? AND status='FAILED'
                        """, row.item().id());
                default -> throw new IllegalStateException("Unrecognized preparation item");
            }
        }
        audit.logExplicit(operatorId, operatorAccount, "business_attachment_reset_prepare", "system_test",
                locked.database(), "reviewed=" + rows.size() + ",fingerprint=" + locked.fingerprint());
        return view(operatorId, read());
    }

    private void requireOperator(UUID operatorId) {
        var actor = current.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (!actor.isSuperAdmin() || !actor.getId().equals(operatorId)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "测试附件清理仅限超级管理员本人");
        }
    }

    private List<Row> read() {
        return jdbc.query("""
                SELECT blocker.entity_type,blocker.entity_id,blocker.owner_type,blocker.owner_id,blocker.reason,
                       coalesce(attachment.original_name,session.original_name,'文件删除任务') file_name,
                       coalesce(attachment.lifecycle_state::text,session.status,operation.status,'UNKNOWN') state,
                       session.expires_at,
                       coalesce(to_jsonb(attachment)::text,to_jsonb(session)::text,to_jsonb(operation)::text) snapshot
                FROM fn_business_attachment_reset_blockers() blocker
                LEFT JOIN attachments attachment ON blocker.entity_type='ATTACHMENT' AND attachment.id=blocker.entity_id
                LEFT JOIN attachment_upload_sessions session ON blocker.entity_type='UPLOAD_SESSION' AND session.id=blocker.entity_id
                LEFT JOIN attachment_object_outbox operation ON blocker.entity_type='DELETE_OPERATION' AND operation.id=blocker.entity_id
                ORDER BY blocker.entity_type,blocker.entity_id LIMIT ?
                """, (r, n) -> new Row(new Item(r.getString("entity_type"), r.getObject("entity_id", UUID.class),
                        r.getString("owner_type"), r.getObject("owner_id", UUID.class), r.getString("file_name"),
                        r.getString("state"), r.getTimestamp("expires_at") == null ? null : r.getTimestamp("expires_at").toInstant(),
                        r.getString("reason")), r.getString("snapshot")), BATCH_SIZE);
    }

    private Preview view(UUID actor, List<Row> rows) {
        String database = jdbc.queryForObject("SELECT current_database()", String.class);
        Long count = jdbc.queryForObject("SELECT count(*) FROM fn_business_attachment_reset_blockers()", Long.class);
        List<String> fingerprint = new ArrayList<>(List.of(database, actor.toString(), String.valueOf(count)));
        rows.forEach(row -> fingerprint.add(row.item().type() + ":" + row.item().id() + ":" + row.snapshot()));
        return new Preview(database, CanonicalFingerprint.sha256(fingerprint), count == null ? 0 : count,
                rows.stream().map(Row::item).toList(), count != null && count > rows.size());
    }

    private void queueAttachment(UUID id, UUID actor) {
        jdbc.query("""
                SELECT storage_key,storage_version,storage_provider,lifecycle_state FROM attachments
                WHERE id=? AND upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT')
                """, row -> {
            String provider = row.getString("storage_provider"), state = row.getString("lifecycle_state");
            if (!List.of("internal", "local").contains(provider) || !"CLEAN".equals(state)) return;
            storage.require(provider);
            jdbc.update("""
                    UPDATE attachments SET lifecycle_state='DELETE_PENDING',delete_requested_at=now(),
                        delete_requested_by=?,delete_failure=NULL,updated_at=now() WHERE id=? AND lifecycle_state='CLEAN'
                    """, actor, id);
            outbox.enqueueFinal(id, row.getString("storage_key"), row.getString("storage_version"), provider);
        }, id);
    }

    private void queueSession(UUID id) {
        jdbc.query("""
                SELECT storage_key,storage_provider,status,expires_at,staging_version,final_version
                FROM attachment_upload_sessions WHERE id=?
                  AND upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT')
                """, row -> {
            String provider = row.getString("storage_provider"), state = row.getString("status");
            Instant expires = row.getTimestamp("expires_at").toInstant();
            if (!List.of("internal", "local").contains(provider) || expires.isAfter(Instant.now())) return;
            String key = row.getString("storage_key"), stagingVersion = row.getString("staging_version");
            var staging = storage.require(provider).describe(key);
            if (staging.exists()) stagingVersion = staging.versionId();
            if (List.of("PENDING", "SCANNING").contains(state)) {
                jdbc.update("""
                        UPDATE attachment_upload_sessions SET status='EXPIRED',completed_at=now(),
                            last_failure_code='TEST_RESET_PREPARED',updated_at=now() WHERE id=?
                        """, id);
            }
            outbox.enqueueResetVerification(id, "DELETE_STAGING", key, stagingVersion, expires, provider);
            if (!"PROMOTED".equals(state)) {
                // A missing-version internal FINAL can only succeed when absent. Existing unknown versions
                // fail in the normal storage provider and must go through exact-object reconciliation.
                outbox.enqueueResetVerification(id, "DELETE_FINAL", key, row.getString("final_version"), expires, provider);
            }
        }, id);
    }
}
