package com.uten.imp.features.admin.systemtest;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.Preview;
import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.UnpurgeableGroup;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 工作台「系统测试 · 清空业务数据」的服务端编排。
 *
 * <p>清空口径（迁移维护的逐表 CLEAR/PRESERVE 分类、TRUNCATE RESTART IDENTITY、主档金额/
 * 期初/安全库存/成本预算归零、六物化视图刷新、全套失败关闭校验、终局全员下线）
 * 全部实现在 V462 迁移创建的数据库函数 {@code business_data_reset()} 里，
 * 与 {@code server/ops/reset_business_data.sql}（psql 停机版）同一份清单，
 * 由 {@code BusinessDataResetSqlContractTest} 逐表锁定同步。</p>
 *
 * <p>本类只负责「运行中的应用」侧的编排：</p>
 * <ol>
 *   <li>{@link BusinessDataResetFeatureGate} 运行开关（仅 dev / internal-test 开启，
 *       生产与云端 fail closed）；</li>
 *   <li>业务附件前置分类：自动清理无法消化的阻塞（原件在 oss/legacy_unknown、状态非 CLEAN、
 *       上传凭证未到期、删除任务失败达告警阈值）在<b>排水之前</b>直接 409，附按原因分组的
 *       计数、文件名与处置指引——不让全站为注定失败的清空白白 503；</li>
 *   <li>{@link BusinessDataResetDrainGate} 排水：清空前对普通 API 回 503，
 *       等在途请求清零——替代 psql 版「停应用、零其它连接」的静默前提；</li>
 *   <li>业务附件自动清理（2026-09-09 用户口径「清空业务数据 = 连上传的文件一并清空」）：
 *       循环「预览→标删/入队→同步排水删除队列（物理删除 + 完成证明）」直到阻塞归零，
 *       总时长预算 {@link #ATTACHMENT_PURGE_BUDGET}，每轮 log.info；人事与货品主档附件受
 *       保护集（V549）豁免；</li>
 *   <li>绑定事务级审计 actor（app.actor_id / app.actor_account /
 *       app.audit_request_id），主档归零 UPDATE 的审计触发器把行归到实际点击的
 *       超管本人；</li>
 *   <li>调用 {@code business_data_reset()}（单事务），函数内任一校验失败即整体回滚，
 *       UT900 类拒绝映射 409 供发起人按提示处理；成功后清理内部存储遗留临时文件并写显式
 *       审计事件（含物理删除文件数），供 {@link #lastResult()} 在重登后回显。</li>
 * </ol>
 */
@Service
@RequiredArgsConstructor
@Slf4j
public class BusinessDataResetService {

    /** 排水等待上限：在途请求多为秒级；长导出等请求超时则放弃本次清空。 */
    static final long DRAIN_TIMEOUT_MILLIS = 45_000;

    /** 业务附件自动清理总时长预算（网关/客户端对该端点放宽到 10 分钟，留出清库本身的时间）。 */
    static final Duration ATTACHMENT_PURGE_BUDGET = Duration.ofMinutes(5);

    /** 附件清理轮次上限与单轮排水任务数上限（每轮 prepare 最多入队 100 项，防死循环）。 */
    static final int ATTACHMENT_PURGE_MAX_ROUNDS = 200;
    static final int ATTACHMENT_PURGE_MAX_DRAIN_PER_ROUND = 5_000;

    /** 用户可自行解除的拒绝（outbox 未清空/附件 owner 不安全/目录漂移等）→ 409。 */
    private static final String REFUSAL_SQLSTATE = "UT900";

    /** 显式审计事件的 action（{@link #lastResult()} 按它取最近一条）。 */
    static final String AUDIT_ACTION = "business_data_reset";

    private final DataSource dataSource;
    private final BusinessDataResetFeatureGate featureGate;
    private final BusinessDataResetDrainGate drainGate;
    private final AuditService auditService;
    private final BusinessAttachmentResetPreparationPort attachmentReset;

    /** 清空结果摘要（回显给发起人并写入审计事件）。 */
    public record Result(
            int clearedTableCount,
            long clearedRows,
            int preservedTableCount,
            long authorizationEpochAfter,
            /** 本次清空前自动清理阶段物理删除的附件对象数（原件 + 临时文件）。 */
            long deletedAttachmentFiles) {
    }

    /** 上次清空结果（来自 audit_log 最近一条显式事件；{@code available=false} 表示尚无记录）。 */
    public record LastResult(
            boolean available,
            Instant finishedAt,
            String operatorAccount,
            int clearedTableCount,
            long clearedRows,
            int preservedTableCount,
            long authorizationEpochAfter,
            long deletedAttachmentFiles,
            UUID operatorId,
            UUID attemptId) {

        static LastResult none() {
            return new LastResult(false, null, null, 0, 0, 0, 0, 0, null, null);
        }
    }

    public Result reset(UUID operatorId, String operatorAccount) {
        return reset(operatorId, operatorAccount, null);
    }

    /** Optional correlation only; it never retries or bypasses any reset gate. */
    public Result reset(UUID operatorId, String operatorAccount, UUID attemptId) {
        featureGate.requireEnabled();
        // 排水之前先分类：自动清理消化不了的阻塞直接 409，不进入排水（避免全站无谓 503）。
        rejectUnpurgeableAttachments(operatorId);
        boolean drained;
        try {
            drained = drainGate.beginDrain(DRAIN_TIMEOUT_MILLIS);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw new ApiException(ErrorCode.INTERNAL, "业务数据清空等待排水时被中断");
        }
        if (!drained) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "当前仍有进行中的请求（或已有清空在执行），请稍后重试");
        }
        Result result;
        try {
            // 2026-09-09 用户口径：清空业务数据=连业务附件一并清空。清库前先把
            // 业务附件/上传凭证/删除任务彻底清理（标删→物理删除→完成证明），
            // 使 V462 的 unsafe_attachment_owners 检查自然通过——不再要求发起人
            // 提前手动「清理业务附件」并等待异步 outbox。
            long deletionsBefore = attachmentReset.succeededDeletionCount();
            purgeBusinessAttachments(operatorId, operatorAccount);
            long deletedFiles = Math.max(0L, attachmentReset.succeededDeletionCount() - deletionsBefore);
            result = runReset(operatorId, operatorAccount, deletedFiles);
        } finally {
            drainGate.endReset();
        }
        cleanupScratchQuietly();
        try {
            auditService.logExplicit(
                    operatorId,
                    operatorAccount,
                    AUDIT_ACTION,
                    "system_test",
                    attemptId == null ? null : attemptId.toString(),
                    "cleared_tables=" + result.clearedTableCount()
                            + ",cleared_rows=" + result.clearedRows()
                            + ",preserved_tables=" + result.preservedTableCount()
                            + ",epoch=" + result.authorizationEpochAfter()
                            + ",deleted_attachment_files=" + result.deletedAttachmentFiles());
        } catch (RuntimeException auditFailure) {
            // 审计落库失败不改变清空结果本身，但必须留下日志证据。
            log.error("business_data_reset 审计事件写入失败", auditFailure);
        }
        return result;
    }

    /**
     * 清空前置分类（排水之前）：自动清理只走「CLEAN 且 internal/local 原件入队 → 排水删除队列」
     * 的乐观路径，其余阻塞（oss/legacy_unknown、LEGACY_UNVERIFIED/DELETED 缺证明、凭证未到期、
     * 删除任务失败达阈值…）必须先由维护人员处置——立即 409，按原因分组给计数、前 5 个文件名
     * 与一行处置指引。
     */
    private void rejectUnpurgeableAttachments(UUID operatorId) {
        List<UnpurgeableGroup> groups = attachmentReset.unpurgeableBlockers(operatorId);
        if (groups == null || groups.isEmpty()) {
            return;
        }
        long total = groups.stream().mapToLong(UnpurgeableGroup::count).sum();
        StringBuilder message = new StringBuilder()
                .append("业务附件存在 ").append(total).append(" 项无法自动清理的阻塞，未开始清空：");
        int namesShown = 0;
        for (int index = 0; index < groups.size(); index++) {
            UnpurgeableGroup group = groups.get(index);
            if (index > 0) {
                message.append("；");
            }
            message.append(group.reason()).append(" ×").append(group.count());
            StringBuilder names = new StringBuilder();
            for (String name : group.sampleFileNames() == null ? List.<String>of() : group.sampleFileNames()) {
                if (namesShown >= 5) {
                    break;
                }
                names.append(names.isEmpty() ? "" : "、").append(name);
                namesShown++;
            }
            if (!names.isEmpty()) {
                message.append("（文件：").append(names).append(total > namesShown ? "…" : "").append("）");
            }
        }
        message.append("。处置指引：原件/会话不在内部存储、状态异常或删除多次失败→先做附件对账；")
                .append("上传凭证仍有效→等待凭证过期后重试；删除任务失败→重试删除队列后再清空。");
        throw new ApiException(ErrorCode.CONFLICT, message.toString());
    }

    /**
     * 业务附件彻底清理（清空前置步骤，已在排水内）：循环「预览→标记删除/入队→同步排水
     * outbox（物理删除文件并落完成证明）」直到 blocker 归零。任一轮无进展即拒绝（防死循环）；
     * 附件量大时受总时长预算/轮次/单轮任务数上限保护，每轮 log.info 留证。
     */
    private void purgeBusinessAttachments(UUID operatorId, String operatorAccount) {
        Instant started = Instant.now();
        Preview before = attachmentReset.preview(operatorId);
        for (int round = 1; round <= ATTACHMENT_PURGE_MAX_ROUNDS; round++) {
            if (before.blockingCount() == 0) {
                return;
            }
            Duration elapsed = Duration.between(started, Instant.now());
            if (elapsed.compareTo(ATTACHMENT_PURGE_BUDGET) > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "业务附件清理超过 " + ATTACHMENT_PURGE_BUDGET.toMinutes() + " 分钟预算（仍剩 "
                                + before.blockingCount() + " 项），已删除的文件不会恢复；请稍后重试清空");
            }
            attachmentReset.prepare(operatorId, operatorAccount,
                    new BusinessAttachmentResetPreparationPort.Confirmation(
                            before.database(), before.fingerprint()));
            int drained = 0;
            while (drained < ATTACHMENT_PURGE_MAX_DRAIN_PER_ROUND && attachmentReset.drainNextDeletion()) {
                drained++; // 排水删除队列（含本轮与历史失败任务）
            }
            Preview after = attachmentReset.preview(operatorId);
            log.info("business_data_reset 附件自动清理第 {} 轮：阻塞 {} → {}，本轮排水 {} 项，累计 {} 秒",
                    round, before.blockingCount(), after.blockingCount(), drained,
                    Duration.between(started, Instant.now()).toSeconds());
            if (after.blockingCount() == 0) {
                return;
            }
            if (after.blockingCount() >= before.blockingCount()) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "业务附件清理无进展（仍剩 " + after.blockingCount()
                                + " 项阻塞，首项：" + firstBlockerSummary(after) + "），请核对文件后重试清空");
            }
            before = after;
        }
        throw new ApiException(ErrorCode.CONFLICT, "业务附件清理轮次超出上限，请重试清空");
    }

    private static String firstBlockerSummary(Preview preview) {
        return preview.items().isEmpty()
                ? "—"
                : preview.items().getFirst().type() + ":"
                        + preview.items().getFirst().message();
    }

    /** 清空成功后清理内部存储遗留的私有临时文件；失败只记日志，不影响已完成的清空。 */
    private void cleanupScratchQuietly() {
        try {
            int removed = attachmentReset.cleanupAbandonedScratch();
            if (removed > 0) {
                log.info("business_data_reset 已清理内部存储遗留临时文件 {} 个", removed);
            }
        } catch (RuntimeException failure) {
            log.warn("business_data_reset 内部存储临时文件清理失败（清空本身已完成）", failure);
        }
    }

    /** 上次清空结果：audit_log 最近一条 {@value #AUDIT_ACTION} 显式事件（重登后工作台回显）。 */
    public LastResult lastResult() {
        return lastResult(null, null);
    }

    /** A requested receipt is visible only to the authenticated original operator. */
    public LastResult lastResult(UUID operatorId, UUID attemptId) {
        featureGate.requireEnabled();
        if (attemptId != null && operatorId == null) {
            throw new ApiException(ErrorCode.UNAUTHORIZED, "请重新登录后核对清空结果");
        }
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement("SELECT actor_id, actor_account, target_id, result, created_at FROM audit_log WHERE action = ? AND event_source = 'business' AND target_type = 'system_test' AND (CAST(? AS uuid) IS NULL OR (target_id = ? AND actor_id = ?)) ORDER BY created_at DESC, id DESC LIMIT 1")) {
            statement.setString(1, AUDIT_ACTION);
            statement.setObject(2, attemptId);
            statement.setString(3, attemptId == null ? null : attemptId.toString());
            statement.setObject(4, operatorId);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) {
                    return LastResult.none();
                }
                Map<String, Long> values = parseResultSummary(rows.getString("result"));
                return new LastResult(
                        true,
                        rows.getTimestamp("created_at").toInstant(),
                        rows.getString("actor_account"),
                        (int) (long) values.getOrDefault("cleared_tables", 0L),
                        values.getOrDefault("cleared_rows", 0L),
                        (int) (long) values.getOrDefault("preserved_tables", 0L),
                        values.getOrDefault("epoch", 0L),
                        values.getOrDefault("deleted_attachment_files", 0L),
                        rows.getObject("actor_id", UUID.class),
                        parseAttemptId(rows.getString("target_id")));
            }
        } catch (SQLException ex) {
            throw new ApiException(ErrorCode.INTERNAL, "读取上次清空结果失败：" + ex.getMessage());
        }
    }

    private static UUID parseAttemptId(String value) {
        if (value == null) return null;
        try { return UUID.fromString(value); }
        catch (IllegalArgumentException historicalTarget) { return null; }
    }

    /** 解析审计 result 摘要 {@code k=v,k=v}（旧记录没有 deleted_attachment_files 时按 0）。 */
    static Map<String, Long> parseResultSummary(String summary) {
        Map<String, Long> values = new HashMap<>();
        if (summary == null || summary.isBlank()) {
            return values;
        }
        for (String pair : summary.split(",")) {
            int separator = pair.indexOf('=');
            if (separator <= 0) {
                continue;
            }
            try {
                values.put(pair.substring(0, separator).trim(), Long.parseLong(pair.substring(separator + 1).trim()));
            } catch (NumberFormatException ignored) {
                // 非数字片段（历史格式）忽略
            }
        }
        return values;
    }

    private Result runReset(UUID operatorId, String operatorAccount, long deletedAttachmentFiles) {
        try (Connection connection = dataSource.getConnection()) {
            boolean originalAutoCommit = connection.getAutoCommit();
            connection.setAutoCommit(false);
            try {
                Result result = runInTransaction(connection, operatorId, operatorAccount, deletedAttachmentFiles);
                connection.commit();
                return result;
            } catch (Exception ex) {
                try {
                    connection.rollback();
                } catch (SQLException rollbackFailure) {
                    log.error("业务数据清空回滚失败", rollbackFailure);
                }
                throw asApiException(ex);
            } finally {
                connection.setAutoCommit(originalAutoCommit);
            }
        } catch (SQLException ex) {
            throw new ApiException(
                    ErrorCode.INTERNAL,
                    "业务数据清空无法建立数据库连接：" + ex.getMessage());
        }
    }

    private Result runInTransaction(
            Connection connection, UUID operatorId, String operatorAccount, long deletedAttachmentFiles)
            throws SQLException {
        bindAuditActor(connection, operatorId, operatorAccount);
        setLockTimeout(connection);
        setStatementTimeout(connection);
        return callResetFunction(connection, deletedAttachmentFiles);
    }

    private void setLockTimeout(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SET LOCAL lock_timeout = '15s'")) {
            statement.executeUpdate();
        }
    }

    private void setStatementTimeout(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SET LOCAL statement_timeout = '30min'")) {
            statement.executeUpdate();
        }
    }

    /** 审计触发器读取的事务级 actor：实际点击清空的超管本人（值经绑定参数传入）。 */
    private void bindAuditActor(
            Connection connection, UUID operatorId, String operatorAccount) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SELECT set_config('app.actor_id', ?, true), set_config('app.actor_account', ?, true), set_config('app.audit_request_id', ?, true)")) {
            statement.setString(1, operatorId.toString());
            statement.setString(2, operatorAccount);
            statement.setString(3, currentRequestId());
            statement.executeQuery();
        }
    }

    private String currentRequestId() {
        try {
            var request = AuditRequestContext.currentRequest();
            if (request != null) {
                return AuditRequestContext.ensureRequestId(request).toString();
            }
        } catch (RuntimeException ignored) {
            // 无请求上下文（测试等场景）时退回独立 UUID。
        }
        return UUID.randomUUID().toString();
    }

    /** V462 函数完成全部清空/归零/校验/踢人，返回摘要；函数内失败即抛异常回滚。 */
    private Result callResetFunction(Connection connection, long deletedAttachmentFiles) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SELECT cleared_table_count, cleared_rows, preserved_table_count, authorization_epoch_after FROM business_data_reset()");
             ResultSet rows = statement.executeQuery()) {
            if (!rows.next()) {
                throw new ApiException(
                        ErrorCode.INTERNAL, "业务数据清空函数未返回摘要，已整体回滚");
            }
            return new Result(
                    rows.getInt("cleared_table_count"),
                    rows.getLong("cleared_rows"),
                    rows.getInt("preserved_table_count"),
                    rows.getLong("authorization_epoch_after"),
                    deletedAttachmentFiles);
        }
    }

    /** 拒绝类（UT900）→ 409 供发起人按提示处理；其余按内部错误并保留原因。 */
    private static ApiException asApiException(Exception error) {
        String message = rootMessage(error);
        if (error instanceof SQLException sqlException
                && REFUSAL_SQLSTATE.equals(sqlException.getSQLState())) {
            return new ApiException(ErrorCode.CONFLICT, message);
        }
        return new ApiException(
                ErrorCode.INTERNAL, "业务数据清空执行失败，已整体回滚：" + message);
    }

    private static String rootMessage(Throwable error) {
        Throwable current = error;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        String message = current.getMessage();
        return message == null ? current.getClass().getSimpleName() : message;
    }
}
