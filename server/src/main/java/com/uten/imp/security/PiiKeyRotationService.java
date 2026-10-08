package com.uten.imp.security;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Explicit, bounded, resumable maintenance; never runs on application startup. */
@Service
@Profile("!cloud")
@PreAuthorize("principal.superAdmin and hasAuthority('pii_key_rotation:manage')")
public class PiiKeyRotationService {
    private final JdbcTemplate db;
    private final PiiCipherRewrapper cipher;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final AuditService audit;
    private final boolean enabled;

    public PiiKeyRotationService(JdbcTemplate db, PiiCipherRewrapper cipher, SecurityContextCurrentUser currentUser,
                                TxSessionVars tx, AuditService audit,
                                @Value("${uten.crypto.rotation.enabled:false}") boolean enabled,
                                @Value("${uten.deployment.site:local}") String site) {
        this.db = db; this.cipher = cipher; this.currentUser = currentUser; this.tx = tx; this.audit = audit;
        this.enabled = enabled && "local".equalsIgnoreCase(site);
    }

    public record Progress(UUID runId, String targetVersion, String status, long nextSequence,
                           long verifiedRows, long rewrappedCells, Map<String, Long> remainingByVersion,
                           boolean canRemoveOldKeys) { }
    private record Checkpoint(String targetVersion, String catalog, int targetIndex, String cursor,
                              long sequence, long verified, long rewrapped, String status) { }

    @Transactional(readOnly = true)
    public Progress status(UUID runId) {
        requireOperator();
        Checkpoint state = checkpoint(runId, false);
        return progress(runId, state, remaining(state.targetVersion()));
    }

    @Transactional(timeout = 30)
    public Progress batch(UUID runId, String targetVersion, long expectedSequence, int limit) {
        AuthUser actor = requireOperator();
        if (!Boolean.TRUE.equals(db.queryForObject("""
                SELECT current_setting('log_parameter_max_length')='0'
                   AND current_setting('log_parameter_max_length_on_error')='0'
                """,Boolean.class))) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "当前数据库连接仍可能记录加解密参数；请先关闭普通与错误语句参数日志，再办理密钥轮换");
        }
        if (runId == null || expectedSequence < 0 || limit < 1 || limit > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "轮换任务、批次序号或批量大小无效；每批限 1—100 行");
        }
        if (!Objects.equals(targetVersion, cipher.currentVersion())) {
            throw new ApiException(ErrorCode.CONFLICT, "请求的目标密钥版本与当前实例不一致，请重新核对配置");
        }
        if (!Boolean.TRUE.equals(db.queryForObject(
                "SELECT pg_try_advisory_xact_lock(hashtextextended('uten-pii-key-rotation',0))", Boolean.class))) {
            throw new ApiException(ErrorCode.CONFLICT, "另一批密钥轮换正在执行，请稍后核对任务进度");
        }
        db.update("""
                INSERT INTO pii_key_rotation_runs(id,target_version,catalog_version,started_by,updated_by)
                VALUES (?,?,?,?,?) ON CONFLICT(id) DO NOTHING
                """, runId,targetVersion,PiiRotationCatalog.VERSION,actor.getId(),actor.getId());
        Checkpoint state = checkpoint(runId, true);
        if (!state.targetVersion().equals(targetVersion) || !state.catalog().equals(PiiRotationCatalog.VERSION)) {
            throw new ApiException(ErrorCode.CONFLICT, "原轮换任务的版本或字段目录已变化，请使用新的任务标识");
        }
        if (expectedSequence > state.sequence()) {
            throw new ApiException(ErrorCode.CONFLICT, "轮换批次序号超前，请先读取已提交进度");
        }
        if (state.sequence() > 0) verifyCurrentKeyWitness(targetVersion);
        if (expectedSequence < state.sequence() || !"RUNNING".equals(state.status())) {
            return progress(runId, state, remaining(targetVersion));
        }
        tx.bind();
        int targetIndex = state.targetIndex();
        String cursor = state.cursor();
        long verified = state.verified();
        long rewrapped = state.rewrapped();
        int budget = limit;
        while (budget > 0 && targetIndex < PiiRotationCatalog.TARGETS.size()) {
            var target = PiiRotationCatalog.TARGETS.get(targetIndex);
            List<Map<String,Object>> rows = db.queryForList("SELECT " + target.keySql() + " AS source_key, "
                    + String.join(",",target.columns())
                    + (target.table().equals("profile_change_requests") ? ", fn_profile_change_snapshot_requires_encryption(field_code) AS profile_field_allowed" : "")
                    + " FROM " + target.table() + " WHERE (" + target.predicate()
                    + ") AND (" + target.keySql() + ") > ? ORDER BY " + target.keySql() + " LIMIT ? FOR UPDATE", cursor, budget);
            if (target.table().equals("profile_change_requests")) tx.bindProfileChangeSnapshotCodecV1();
            for (var row : rows) {
                if (target.table().equals("profile_change_requests") && !Boolean.TRUE.equals(row.get("profile_field_allowed"))) {
                    throw new ApiException(ErrorCode.CONFLICT,"审批快照字段策略与密文格式不一致，本批未修改");
                }
                List<String> changes = new ArrayList<>();
                List<Object> parameters = new ArrayList<>();
                for (String column : target.columns()) {
                    final PiiCipherRewrapper.Result result;
                    try {
                        result = cipher.rewrap((String) row.get(column),target.payloadPrefix());
                    } catch (RuntimeException unreadable) {
                        throw new ApiException(ErrorCode.CONFLICT,
                                "密文核验失败，本批及检查点已回滚；请核对历史密钥或数据完整性后重试。表：" + target.table()
                                        + "，记录：" + row.get("source_key") + "，字段：" + column);
                    }
                    if (result.changed()) {
                        changes.add(column + "=?"); parameters.add(result.cipher()); rewrapped++;
                    }
                }
                cursor = (String) row.get("source_key");
                if (!changes.isEmpty()) {
                    parameters.add(cursor);
                    final int updated;
                    try {
                        updated = db.update("UPDATE " + target.table() + " SET " + String.join(",",changes)
                                + " WHERE (" + target.keySql() + ")=?",parameters.toArray());
                    } catch (RuntimeException rejected) {
                        throw new ApiException(ErrorCode.CONFLICT,"密文维护写入被拒绝，本批及检查点已回滚；请核对维护权限与数据守卫");
                    }
                    if (updated != 1) throw new ApiException(ErrorCode.CONFLICT,"轮换期间来源记录发生变化，本批已回滚");
                }
                verified++; budget--;
            }
            if (rows.isEmpty() || budget > 0) { targetIndex++; cursor = ""; }
            // Profile approval locks its request before employee PII. Never hold
            // both tables in maintenance's opposite catalog order in one batch.
            if (!rows.isEmpty()) break;
        }
        Map<String,Long> remaining = targetIndex == PiiRotationCatalog.TARGETS.size() ? remaining(targetVersion) : Map.of();
        String status = targetIndex < PiiRotationCatalog.TARGETS.size() ? "RUNNING"
                : remaining.isEmpty() ? "SCANNED" : "RESCAN_REQUIRED";
        db.update("""
                UPDATE pii_key_rotation_runs SET target_index=?, cursor_key=?, batch_sequence=batch_sequence+1,
                    verified_rows=?,rewrapped_cells=?,status=?,updated_by=?,updated_at=now() WHERE id=?
                """,targetIndex,cursor,verified,rewrapped,status,actor.getId(),runId);
        audit.logCommittedChange(actor.getId(),actor.getLoginAccount(),"pii_key_rotation.batch",
                "pii_key_rotation_runs",runId.toString(),"success; PII 密钥轮换批次已提交",
                Map.of("targetVersion",targetVersion,"verifiedRows",verified,"rewrappedCells",rewrapped,
                        "nextSequence",state.sequence()+1,"status",status));
        return progress(runId,new Checkpoint(targetVersion,state.catalog(),targetIndex,cursor,
                state.sequence()+1,verified,rewrapped,status),remaining);
    }

    private AuthUser requireOperator() {
        if (!enabled) throw new ApiException(ErrorCode.FORBIDDEN,"当前实例未开启本地 PII 密钥轮换维护");
        AuthUser actor = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED,"请先登录"));
        if (!actor.isSuperAdmin() || actor.getImpersonatedBy() != null || !Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM users WHERE id=? AND is_super_admin AND status='active' AND NOT is_deleted)
                """,Boolean.class,actor.getId()))) {
            throw new ApiException(ErrorCode.FORBIDDEN,"仅当前有效的超级管理员本人可以办理密钥轮换维护");
        }
        return actor;
    }

    private Checkpoint checkpoint(UUID runId, boolean lock) {
        List<Checkpoint> rows = db.query("""
                SELECT target_version,catalog_version,target_index,cursor_key,batch_sequence,verified_rows,rewrapped_cells,status
                FROM pii_key_rotation_runs WHERE id=?
                """ + (lock ? " FOR UPDATE" : ""), (row,index) -> new Checkpoint(row.getString(1),row.getString(2),row.getInt(3),
                row.getString(4),row.getLong(5),row.getLong(6),row.getLong(7),row.getString(8)),runId);
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND,"轮换任务不存在");
        return rows.getFirst();
    }

    /** A resumed process cannot replace a key while retaining its old version label. */
    private void verifyCurrentKeyWitness(String version) {
        for (var target : PiiRotationCatalog.TARGETS) {
            List<String> current = db.queryForList("SELECT value FROM " + target.table()
                    + " CROSS JOIN LATERAL (VALUES "
                    + target.columns().stream().map(column -> "("+column+")").collect(java.util.stream.Collectors.joining(","))
                    + ") cipher(value) WHERE (" + target.predicate() + ") AND strpos(value,':')>1"
                    + " AND split_part(value,':',1)=? LIMIT 1",String.class,version);
            if (current.isEmpty()) continue;
            try { cipher.rewrap(current.getFirst(),target.payloadPrefix()); }
            catch (RuntimeException invalidKey) {
                throw new ApiException(ErrorCode.CONFLICT,"当前版本密钥无法读取已提交密文，请恢复该版本的原密钥；本批未修改");
            }
            return;
        }
    }

    /** A fresh inventory catches legacy writes behind a completed checkpoint. */
    private Map<String,Long> remaining(String targetVersion) {
        List<String> scans = new ArrayList<>();
        for (var target : PiiRotationCatalog.TARGETS) {
            scans.add("SELECT value FROM " + target.table() + " CROSS JOIN LATERAL (VALUES "
                    + target.columns().stream().map(column -> "("+column+")").collect(java.util.stream.Collectors.joining(","))
                    + ") cipher(value) WHERE (" + target.predicate() + ") AND value IS NOT NULL");
        }
        Map<String,Long> result = new LinkedHashMap<>();
        db.query("WITH values_to_check AS (" + String.join(" UNION ALL ",scans) + """
                ), versions AS (
                    SELECT CASE WHEN value ~ '^[A-Za-z0-9._-]{1,64}:' THEN split_part(value,':',1)
                                WHEN strpos(value,':')=0 THEN ':unversioned' ELSE ':invalid' END AS version
                    FROM values_to_check
                ) SELECT version,count(*) FROM versions WHERE version<>? GROUP BY version ORDER BY version
                """, row -> { result.put(row.getString(1),row.getLong(2)); },targetVersion);
        Long unclassified = db.queryForObject("SELECT count(*) FROM profile_change_requests WHERE value_encoding='LEGACY_UNKNOWN'",Long.class);
        if (unclassified != null && unclassified > 0) result.put(":unclassified-profile-snapshots",unclassified);
        return Map.copyOf(result);
    }

    private static Progress progress(UUID id, Checkpoint state, Map<String,Long> remaining) {
        String status = "SCANNED".equals(state.status()) && !remaining.isEmpty() ? "RESCAN_REQUIRED" : state.status();
        return new Progress(id,state.targetVersion(),status,state.sequence(),state.verified(),state.rewrapped(),remaining,false);
    }
}
