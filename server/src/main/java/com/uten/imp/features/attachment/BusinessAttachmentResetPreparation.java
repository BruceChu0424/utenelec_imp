package com.uten.imp.features.attachment;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.InternalStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Array;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/** Explicit test-data maintenance. The ordinary deletion worker remains the sole physical deleter. */
@Service
@RequiredArgsConstructor
public class BusinessAttachmentResetPreparation implements BusinessAttachmentResetPreparationPort {
    static final int BATCH_SIZE = 100;

    /**
     * 清空业务数据时受保护（不入删除队列、不计阻塞、不物理删除）的附件 owner 类型：
     * 人事档案/劳动合同 + 货品主档（goods 表在 business_data_reset() 中 PRESERVE，其图片/图纸
     * 随主档保留）。与 V549 {@code fn_business_attachment_reset_blockers()} 的保护集必须一致；
     * 本类读取/计数/入队四处只认这一份集合（以 CSV 绑定参数传入 SQL，不拼接）。
     */
    public static final Set<String> PROTECTED_OWNER_TYPES = Set.of("EMPLOYEE", "EMPLOYEE_CONTRACT", "GOODS");
    static final String PROTECTED_OWNER_TYPES_CSV = String.join(",", new TreeSet<>(PROTECTED_OWNER_TYPES));

    private final JdbcTemplate jdbc;
    private final StorageProviderRegistry storage;
    private final AttachmentObjectOutboxStore outbox;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final AuditService audit;
    private final AttachmentObjectOutboxProcessor outboxProcessor;
    private final StorageProperties properties;
    /** 仅 uten.storage.provider=internal 时存在；其它 provider 下清空后无临时目录可清。 */
    private final ObjectProvider<InternalStorageService> internalStorage;

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

    /**
     * 自动清理无法消化的阻塞项按原因分组。自动清理只走「CLEAN 且 internal/local 的原件入队 →
     * 排水删除队列」这一条乐观路径，因此以下情形必须先由维护人员处置：原件在 oss/legacy_unknown、
     * 原件状态非 CLEAN/标删中（LEGACY_UNVERIFIED、DELETED 缺证明）、标删却没有删除任务、上传会话
     * 不在 internal/local 或凭证未到期、删除任务失败次数达告警阈值、成功却缺完成时间。
     */
    @Override @Transactional(readOnly = true)
    public List<UnpurgeableGroup> unpurgeableBlockers(UUID operatorId) {
        requireOperator(operatorId);
        return jdbc.query("""
                WITH blocker AS (
                    SELECT CASE
                             WHEN b.entity_type='ATTACHMENT' AND a.storage_provider NOT IN ('internal','local')
                                  THEN '原件不在内部/本地存储（' || a.storage_provider || '），需先附件对账'
                             WHEN b.entity_type='ATTACHMENT' AND a.lifecycle_state NOT IN ('CLEAN','DELETE_PENDING','DELETE_FAILED')
                                  THEN '原件状态为 ' || a.lifecycle_state || '，需先附件对账'
                             WHEN b.entity_type='ATTACHMENT' AND a.lifecycle_state IN ('DELETE_PENDING','DELETE_FAILED')
                                  AND NOT EXISTS (SELECT 1 FROM attachment_object_outbox pending
                                                  WHERE pending.attachment_id=a.id AND pending.operation='DELETE_FINAL'
                                                    AND pending.status IN ('PENDING','PROCESSING','FAILED'))
                                  THEN '原件已标删但没有对应的删除任务，需先附件对账'
                             WHEN b.entity_type='UPLOAD_SESSION' AND s.storage_provider NOT IN ('internal','local')
                                  THEN '上传会话不在内部/本地存储（' || s.storage_provider || '），需先附件对账'
                             WHEN b.entity_type='UPLOAD_SESSION' AND s.expires_at>now()
                                  THEN '上传凭证仍有效，需等待到期后重试'
                             WHEN b.entity_type='DELETE_OPERATION' AND o.status='FAILED' AND o.attempts>=?
                                  THEN '文件删除任务失败次数已达告警阈值，需先重试删除队列或附件对账'
                             WHEN b.entity_type='DELETE_OPERATION' AND o.status='SUCCEEDED' AND o.completed_at IS NULL
                                  THEN '文件删除任务已成功但缺完成时间，需先附件对账'
                           END AS reason,
                           coalesce(a.original_name,s.original_name,o.storage_key,b.entity_id::text) AS file_name
                    FROM fn_business_attachment_reset_blockers() b
                    LEFT JOIN attachments a ON b.entity_type='ATTACHMENT' AND a.id=b.entity_id
                    LEFT JOIN attachment_upload_sessions s ON b.entity_type='UPLOAD_SESSION' AND s.id=b.entity_id
                    LEFT JOIN attachment_object_outbox o ON b.entity_type='DELETE_OPERATION' AND o.id=b.entity_id
                    WHERE upper(btrim(b.owner_type)) <> ALL(string_to_array(?, ','))
                )
                SELECT reason, count(*) AS total, (array_agg(file_name ORDER BY file_name))[1:5] AS samples
                FROM blocker WHERE reason IS NOT NULL
                GROUP BY reason ORDER BY total DESC, reason
                """, (r, n) -> new UnpurgeableGroup(r.getString("reason"), r.getLong("total"), samples(r.getArray("samples"))),
                properties.getOutbox().getAlertAfterAttempts(), PROTECTED_OWNER_TYPES_CSV);
    }

    private static List<String> samples(Array array) throws java.sql.SQLException {
        if (array == null) return List.of();
        Object raw = array.getArray();
        List<String> names = new ArrayList<>();
        if (raw instanceof Object[] values) {
            for (Object value : values) names.add(value == null ? "" : value.toString());
        }
        return List.copyOf(names);
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
                WHERE upper(btrim(blocker.owner_type)) <> ALL(string_to_array(?, ','))
                ORDER BY blocker.entity_type,blocker.entity_id LIMIT ?
                """, (r, n) -> new Row(new Item(r.getString("entity_type"), r.getObject("entity_id", UUID.class),
                        r.getString("owner_type"), r.getObject("owner_id", UUID.class), r.getString("file_name"),
                        r.getString("state"), r.getTimestamp("expires_at") == null ? null : r.getTimestamp("expires_at").toInstant(),
                        r.getString("reason")), r.getString("snapshot")), PROTECTED_OWNER_TYPES_CSV, BATCH_SIZE);
    }

    private Preview view(UUID actor, List<Row> rows) {
        String database = jdbc.queryForObject("SELECT current_database()", String.class);
        Long count = jdbc.queryForObject("""
                SELECT count(*) FROM fn_business_attachment_reset_blockers()
                WHERE upper(btrim(owner_type)) <> ALL(string_to_array(?, ','))
                """, Long.class, PROTECTED_OWNER_TYPES_CSV);
        List<String> fingerprint = new ArrayList<>(List.of(database, actor.toString(), String.valueOf(count)));
        rows.forEach(row -> fingerprint.add(row.item().type() + ":" + row.item().id() + ":" + row.snapshot()));
        return new Preview(database, CanonicalFingerprint.sha256(fingerprint), count == null ? 0 : count,
                rows.stream().map(Row::item).toList(), count != null && count > rows.size());
    }

    private void queueAttachment(UUID id, UUID actor) {
        jdbc.query("""
                SELECT storage_key,storage_version,storage_provider,lifecycle_state FROM attachments
                WHERE id=? AND upper(btrim(owner_type)) <> ALL(string_to_array(?, ','))
                """, row -> {
            String provider = row.getString("storage_provider"), state = row.getString("lifecycle_state");
            if (!List.of("internal", "local").contains(provider) || !"CLEAN".equals(state)) return;
            storage.require(provider);
            jdbc.update("""
                    UPDATE attachments SET lifecycle_state='DELETE_PENDING',delete_requested_at=now(),
                        delete_requested_by=?,delete_failure=NULL,updated_at=now() WHERE id=? AND lifecycle_state='CLEAN'
                    """, actor, id);
            outbox.enqueueFinal(id, row.getString("storage_key"), row.getString("storage_version"), provider);
        }, id, PROTECTED_OWNER_TYPES_CSV);
    }

    private void queueSession(UUID id) {
        jdbc.query("""
                SELECT storage_key,storage_provider,status,expires_at,staging_version,final_version
                FROM attachment_upload_sessions WHERE id=?
                  AND upper(btrim(owner_type)) <> ALL(string_to_array(?, ','))
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
        }, id, PROTECTED_OWNER_TYPES_CSV);
    }

    @Override
    public boolean drainNextDeletion() {
        return outboxProcessor.processNext();
    }

    @Override @Transactional(readOnly = true)
    public long succeededDeletionCount() {
        Long count = jdbc.queryForObject(
                "SELECT count(*) FROM attachment_object_outbox WHERE status='SUCCEEDED' AND completed_at IS NOT NULL",
                Long.class);
        return count == null ? 0 : count;
    }

    @Override
    public int cleanupAbandonedScratch() {
        InternalStorageService internal = internalStorage.getIfAvailable();
        return internal == null ? 0 : internal.cleanupAbandonedScratch();
    }
}
