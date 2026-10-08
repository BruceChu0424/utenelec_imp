package com.uten.imp.features.admin.systemtest;

import com.uten.imp.application.port.BusinessTestResetFilesPort;
import com.uten.imp.application.port.BusinessTestResetFilesPort.Actor;
import com.uten.imp.application.port.BusinessTestResetFilesPort.Check;
import com.uten.imp.application.port.BusinessTestResetFilesPort.Purge;
import com.uten.imp.application.port.BusinessTestResetFilesPort.Refusal;
import com.uten.imp.application.port.BusinessTestResetFilesPort.ResetFilesFailure;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.extern.slf4j.Slf4j;
import org.postgresql.util.PSQLException;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.datasource.DataSourceUtils;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 工作台「系统测试 · 清空业务数据」的服务端编排(ADR-067、ADR-155)。
 *
 * <p>清空口径(逐表 CLEAR/PRESERVE 分类、TRUNCATE RESTART IDENTITY、主档金额/期初归零、
 * 物化视图刷新、全套失败关闭校验、终局全员下线)全部实现在数据库函数 {@code business_data_reset()} 里，
 * 分类只写在该函数体内一处。哪些物理文件属于测试数据只由 {@code fn_business_test_reset_objects()} 一条规则决定，
 * 数据库能判断的拒绝条件只由 {@code fn_business_data_reset_refusals()} 一处判断。</p>
 *
 * <p>本类只负责运行中应用侧的编排，顺序固定：</p>
 * <ol>
 *   <li>运行开关；另一次清空正在进行就立即拒绝(不写受理回执)；</li>
 *   <li>受理回执(ADR-067 §9)，之后唯一的截止点 = 受理时刻 + {@link BusinessDataResetTimings#filesBudget()}；</li>
 *   <li>数据库确认在职超管本人；与弹窗预览同一个检查(调用身份 + 数据库拒绝原因 + 存储实地核对)，
 *       有任何拒绝原因就不进排水；</li>
 *   <li>排水；</li>
 *   <li>清空事务(锁持有到提交)：加锁 → 再检查并全量核对(有问题一个都不删) → 逐个删除测试文件并确认不在
 *       → 把清单指纹交给 {@code business_data_reset()}，函数先再跑一次拒绝检查，再按同一把锁重算指纹核对；
 *       完成回执与清空同一事务提交，供 {@link #lastResult()} 在重登后回显；</li>
 *   <li>已经物理删除过文件之后的任何失败，文案开头都写明「本次已经物理删除了 d 个测试文件」，
 *       失败回执只存原因码、数量和不含文件名的摘要。</li>
 * </ol>
 */
@Service
@Slf4j
public class BusinessDataResetService {

    /** 用户可自行解除的拒绝 → 409。 */
    static final String REFUSAL_SQLSTATE = "UT900";
    /** 测试文件清单与清空时的清单不一致(直接调用时还有文件没删) → 409。 */
    static final String OBJECT_SET_CHANGED_SQLSTATE = "UT901";
    static final String LOCK_TIMEOUT_SQLSTATE = "55P03";
    static final String CATALOG_PARSE_SQLSTATE = "XX000";

    /** 显式审计事件的 action（{@link #lastResult()} 按它取最近一条）。 */
    static final String AUDIT_ACTION = "business_data_reset";

    /**
     * 受理回执(ADR-067 §9)：请求进入服务的第一步就独立提交一条 audit_log，之后才排水/清库。
     * 有它没有完成回执 = 受理后仍在执行(或随进程消亡已回滚)；没有它 = 服务器从未收到该请求，
     * 客户端可据此撤销本地待确认记录，而不是靠「查不到完成回执」去猜。
     */
    static final String AUDIT_ACTION_RECEIVED = "business_data_reset_received";

    /** 受理后明确失败的回执；提交确认丢失的不确定结果不写。 */
    static final String AUDIT_ACTION_FAILED = "business_data_reset_failed";

    /**
     * 本进程实例标识，写进受理回执：受理它的进程已不在而又没有完成/失败回执，说明清库事务
     * 已随进程消亡整体回滚(完成回执与清库同一事务提交)，客户端可以确定地撤销待确认记录。
     */
    static final UUID SERVER_INSTANCE_ID = UUID.randomUUID();

    private static final int RECEIPT_RESULT_LIMIT = 480;
    private static final int RECEIPT_REASON_LIMIT = 6;

    /**
     * 提交确认丢失(可能已提交)的不确定结果：不写失败回执，只提示重登核对。
     * 专用错误码 {@link ErrorCode#RESET_OUTCOME_UNCERTAIN}：客户端只把它(和网络层失败)当「结果待确认」，
     * 其它 500 都是明确失败、照原文显示。
     */
    static final class UncertainResetOutcome extends ApiException {
        UncertainResetOutcome(String message) {
            super(ErrorCode.RESET_OUTCOME_UNCERTAIN, message);
        }

        UncertainResetOutcome withDeletedFiles(long deleted) {
            UncertainResetOutcome reported = new UncertainResetOutcome(
                    getMessage() + "(本次已物理删除 " + deleted + " 个测试文件)");
            reported.initCause(getCause() == null ? this : getCause());
            return reported;
        }
    }

    private final DataSource dataSource;
    private final PlatformTransactionManager transactionManager;
    private final BusinessDataResetFeatureGate featureGate;
    private final BusinessDataResetDrainGate drainGate;
    private final AuditService auditService;
    private final BusinessTestResetFilesPort files;
    private final BusinessDataResetTimings timings;
    private final Clock clock;

    @Autowired
    public BusinessDataResetService(DataSource dataSource, PlatformTransactionManager transactionManager,
                                    BusinessDataResetFeatureGate featureGate, BusinessDataResetDrainGate drainGate,
                                    AuditService auditService, BusinessTestResetFilesPort files) {
        this(dataSource, transactionManager, featureGate, drainGate, auditService, files, BusinessDataResetTimings.DEFAULT);
    }

    /** Tests shorten the time limits; production always uses {@link BusinessDataResetTimings#DEFAULT}. */
    public BusinessDataResetService(DataSource dataSource, PlatformTransactionManager transactionManager,
                                    BusinessDataResetFeatureGate featureGate, BusinessDataResetDrainGate drainGate,
                                    AuditService auditService, BusinessTestResetFilesPort files,
                                    BusinessDataResetTimings timings) {
        this.dataSource = dataSource;
        this.transactionManager = transactionManager;
        this.featureGate = featureGate;
        this.drainGate = drainGate;
        this.auditService = auditService;
        this.files = files;
        this.timings = timings;
        this.clock = Clock.systemUTC();
    }

    /** 清空结果摘要（回显给发起人并写入审计事件）。 */
    public record Result(
            int clearedTableCount,
            long clearedRows,
            int preservedTableCount,
            long authorizationEpochAfter,
            /** 本次清空物理删除的测试文件数。 */
            long deletedAttachmentFiles,
            /** 随清空清除的处理失败、已停止重试的后台事件数。 */
            long deadBackgroundEventsCleared) {
    }

    /**
     * 上次清空结果（来自 audit_log 最近一条显式事件；{@code available=false} 表示尚无记录）。
     * 带 attemptId 查询时另附该请求的受理/失败回执(ADR-067 §9)：
     * {@code attemptReceived=false} 表示服务器从未收到该请求；
     * {@code attemptReceivedByCurrentServer=false} 表示受理它的进程已重启、未完成的事务已回滚；
     * {@code attemptFailed=true} 表示受理后明确失败并附原因摘要，
     * {@code attemptDeletedAttachmentFiles} 是失败前已经物理删除的测试文件数。
     */
    public record LastResult(
            boolean available,
            Instant finishedAt,
            String operatorAccount,
            int clearedTableCount,
            long clearedRows,
            int preservedTableCount,
            long authorizationEpochAfter,
            long deletedAttachmentFiles,
            long deadBackgroundEventsCleared,
            UUID operatorId,
            UUID attemptId,
            boolean attemptReceived,
            Instant attemptReceivedAt,
            boolean attemptReceivedByCurrentServer,
            boolean attemptFailed,
            String attemptFailureMessage,
            long attemptDeletedAttachmentFiles) {

        static LastResult none() {
            return new LastResult(false, null, null, 0, 0, 0, 0, 0, 0, null, null,
                    false, null, false, false, null, 0);
        }

        LastResult withReceipts(boolean received, Instant receivedAt, boolean byCurrentServer,
                                boolean failed, String failureMessage, long failureDeletedFiles) {
            return new LastResult(available, finishedAt, operatorAccount, clearedTableCount, clearedRows,
                    preservedTableCount, authorizationEpochAfter, deletedAttachmentFiles, deadBackgroundEventsCleared,
                    operatorId, attemptId, received, receivedAt, byCurrentServer, failed, failureMessage,
                    failureDeletedFiles);
        }
    }

    /** 清空弹窗预览：与清空排水前同一个检查，不删除任何文件。 */
    public Check preview(UUID operatorId, String operatorAccount) {
        featureGate.requireEnabled();
        refuseIfAnotherResetRunning();
        requireConfirmedSuperAdmin(operatorId, operatorAccount);
        try {
            return files.check(new Actor(operatorId, operatorAccount), timings.previewInspection());
        } catch (ResetFilesFailure failure) {
            throw anotherResetIfBusy(failure);
        }
    }

    public Result reset(UUID operatorId, String operatorAccount) {
        return reset(operatorId, operatorAccount, null);
    }

    /** Optional correlation only; it never retries or bypasses any reset gate. */
    public Result reset(UUID operatorId, String operatorAccount, UUID attemptId) {
        featureGate.requireEnabled();
        // 在受理回执之前：没有回执 = 没执行，客户端据此可撤销待确认记录。
        refuseIfAnotherResetRunning();
        Instant deadline = clock.instant().plus(timings.filesBudget());
        UUID effectiveAttemptId = attemptId == null ? UUID.randomUUID() : attemptId;
        // 受理回执先于一切(ADR-067 §9)：写不进去就不清库——「没有受理回执」必须严格等价于「没执行」。
        recordAttemptReceived(operatorId, operatorAccount, effectiveAttemptId);
        AtomicLong deleted = new AtomicLong();
        try {
            return resetAfterReceipt(operatorId, operatorAccount, effectiveAttemptId, deadline, deleted);
        } catch (UncertainResetOutcome uncertain) {
            throw deleted.get() == 0 ? uncertain : uncertain.withDeletedFiles(deleted.get());
        } catch (RuntimeException failure) {
            RuntimeException reported = report(failure, deleted.get());
            recordAttemptFailed(operatorId, operatorAccount, effectiveAttemptId, reported, deleted.get());
            throw reported;
        }
    }

    private void recordAttemptReceived(UUID operatorId, String operatorAccount, UUID attemptId) {
        try {
            auditService.logExplicit(operatorId, operatorAccount, AUDIT_ACTION_RECEIVED, "system_test",
                    attemptId.toString(), "received,server=" + SERVER_INSTANCE_ID);
        } catch (RuntimeException ex) {
            ApiException refused = new ApiException(ErrorCode.INTERNAL,
                    "清空请求的受理回执写入失败，本次未执行清空，请稍后重试：" + rootMessage(ex));
            refused.initCause(ex);
            throw refused;
        }
    }

    private void recordAttemptFailed(UUID operatorId, String operatorAccount, UUID attemptId,
                                     RuntimeException failure, long deleted) {
        try {
            auditService.logExplicit(operatorId, operatorAccount, AUDIT_ACTION_FAILED, "system_test",
                    attemptId.toString(), failureReceipt(failure, deleted));
        } catch (RuntimeException receiptFailure) {
            log.warn("business_data_reset 失败回执写入失败（原失败原因照常返回）", receiptFailure);
        }
    }

    /**
     * 这些原因的服务器原文不含文件名，而且「重新检查」看不到它们(只在提交清空时出现)：
     * 失败回执里写原文的原因部分(原因对象的 message 只放原因，不带结果和下一步)，结尾给出对应的下一步。
     */
    private static final Set<String> RECEIPT_ORIGINAL_TEXT_REASONS =
            Set.of("DB_FAILED", "OBJECT_SET_CHANGED", "CALLER_NOT_AUTHORIZED", "CALLER_NAMESPACE");

    /**
     * 失败回执(D17)：只存原因码、数量和不含文件名的摘要，总长不超过 {@value #RECEIPT_RESULT_LIMIT}。
     * 完整文案(含文件名)只出现在 HTTP 响应和弹窗「重新检查」的结果里；
     * {@link #RECEIPT_ORIGINAL_TEXT_REASONS} 的原文不含文件名，直接写进摘要。
     */
    static String failureReceipt(RuntimeException failure, long deleted) {
        String code = failure instanceof ApiException api ? api.getCode().name() : ErrorCode.INTERNAL.name();
        List<Refusal> reasons = failure instanceof ResetFilesFailure files
                ? files.reasons().stream().filter(r -> !"FILES_DELETED".equals(r.code())).toList()
                : List.of();
        StringBuilder codes = new StringBuilder();
        for (Refusal reason : reasons.subList(0, Math.min(RECEIPT_REASON_LIMIT, reasons.size()))) {
            codes.append(codes.isEmpty() ? "" : ";").append(reason.code()).append(':').append(reason.count());
        }
        String head = "failed,code=" + code + ",deleted_attachment_files=" + deleted
                + ",reasons=" + codes + ",message=";
        String outcome = deleted > 0
                ? "本次已物理删除 " + deleted + " 个测试文件，数据没有清空。"
                : "没有删除文件，也没有清空数据。";
        String summary;
        if (!reasons.isEmpty()) {
            List<String> parts = new ArrayList<>();
            Refusal explained = null;
            for (Refusal reason : reasons) {
                String part;
                if (RECEIPT_ORIGINAL_TEXT_REASONS.contains(reason.code())) {
                    if (explained == null) explained = reason;
                    part = cause(reason.message());
                } else {
                    part = receiptLabel(reason);
                }
                if (!parts.contains(part)) parts.add(part);
            }
            String tail = outcome + (explained == null
                    ? "完整原因(含文件名)请在清空弹窗点「重新检查」查看。"
                    : receiptNextStep(explained.code()));
            String body = "失败原因：" + String.join("；", parts) + "。";
            int room = RECEIPT_RESULT_LIMIT - head.length() - tail.length();
            if (body.length() > room) body = body.substring(0, Math.max(0, room - 1)) + "…";
            summary = body + tail;
        } else {
            String original = failure.getMessage() == null ? failure.getClass().getSimpleName() : failure.getMessage();
            summary = original.length() > 200 ? original.substring(0, 199) + "…" : original;
            int room = RECEIPT_RESULT_LIMIT - head.length();
            if (summary.length() > room) summary = summary.substring(0, Math.max(0, room - 1)) + "…";
        }
        return head + summary;
    }

    private static String receiptLabel(Refusal reason) {
        long n = reason.count();
        String code = reason.code();
        if (code.startsWith("CATALOG_")) return "程序版本问题(数据表登记)";
        return switch (code) {
            case "BACKGROUND_EVENTS_PENDING" -> "后台事件排队中 " + n + " 条";
            case "PROTECTED_DELETE_TASKS_PENDING" -> "保留文件的删除任务未完成 " + n + " 个";
            case "PROTECTED_DELETE_TASKS_STUCK" -> "保留文件的删除任务卡住 " + n + " 个";
            case "UNSUPPORTED_STORAGE" -> n + " 个文件在系统删不了的存储";
            case "AUTHORIZATION_STATE_MISSING" -> "登录状态记录缺失(程序缺陷)";
            case "ACTIVE_STORAGE_OSS" -> "附件存储是阿里云直传";
            case "STORAGE_UNAVAILABLE" -> "存储目录无法访问(" + n + " 个文件)";
            case "LOCAL_NOT_CONFIGURED", "INTERNAL_NOT_CONFIGURED" -> "服务器没配置文件所在的存储(" + n + " 个文件)";
            case "VERSION_MISMATCH" -> "文件版本对不上 " + n + " 个";
            case "NOT_A_FILE" -> "存储位置上不是系统文件 " + n + " 个";
            case "LOCAL_LEGACY_LAYOUT" -> "本地旧版平铺文件 " + n + " 个";
            case "KEY_INVALID" -> "存储编号格式不对 " + n + " 个";
            case "READ_FAILED" -> "读文件失败 " + n + " 个";
            case "DELETE_FAILED", "STILL_PRESENT" -> "删除文件失败";
            case "DELETE_UNCONFIRMED" -> "删除后无法再次核对";
            case "BUDGET" -> "删除用完时间";
            case "INSPECTION_BUDGET" -> "核对用完时间";
            case "LOCK_TIMEOUT", "DB_LOCK_TIMEOUT" -> "数据被其他程序占用";
            case "READ_TIMEOUT" -> "读取文件清单超时";
            case "DB_READ_FAILED" -> "读取文件清单时数据库出错";
            case "OBJECT_SET_CHANGED" -> "文件清单不一致(程序缺陷)";
            case "DB_REFUSED" -> "数据库拒绝清空";
            case "DB_FAILED" -> "数据库执行失败";
            case "DRAIN_TIMEOUT" -> "其他操作未结束";
            case "DRAIN_INTERRUPTED" -> "等待其他操作时被中断";
            case "ANOTHER_RESET" -> "另一位超级管理员正在清空";
            case "NOT_SUPER_ADMIN" -> "操作人不是在职超级管理员本人";
            case "OPERATOR_CHECK_FAILED" -> "核对操作人时数据库出错";
            case "CALLER_NOT_AUTHORIZED" -> "服务器连接数据库的账号无权清空(服务器配置问题)";
            case "CALLER_NAMESPACE" -> "数据库里有与清空程序内部临时表同名的数据表";
            default -> "其它原因";
        };
    }

    /** 写了服务器原文的失败回执结尾：这几类在「重新检查」里看不到，直接给下一步。 */
    private static String receiptNextStep(String code) {
        return switch (code) {
            case "CALLER_NOT_AUTHORIZED" -> "再次提交也会失败，请让维护人员检查服务器连接数据库的账号后再清空。";
            case "CALLER_NAMESPACE" -> "再次提交也会失败，请联系开发人员处理后再清空。";
            case "OBJECT_SET_CHANGED" -> "请联系开发人员。";
            default -> "请稍后重新点「确认清空」；如果再次出现，请联系开发人员。";
        };
    }

    /** 原因原文去掉首尾空白和结尾句号(回执里统一补)。 */
    private static String cause(String text) {
        String trimmed = text == null ? "" : text.strip();
        while (trimmed.endsWith("。")) trimmed = trimmed.substring(0, trimmed.length() - 1).strip();
        return trimmed;
    }

    private Result resetAfterReceipt(UUID operatorId, String operatorAccount, UUID attemptId,
                                     Instant deadline, AtomicLong deleted) {
        requireConfirmedSuperAdmin(operatorId, operatorAccount);
        Duration remaining = Duration.between(clock.instant(), deadline);
        Duration precheck = remaining.isNegative() ? Duration.ZERO
                : (remaining.compareTo(timings.precheckInspection()) < 0 ? remaining : timings.precheckInspection());
        Check check;
        try {
            check = files.check(new Actor(operatorId, operatorAccount), precheck);
        } catch (ResetFilesFailure failure) {
            throw anotherResetIfBusy(failure);
        }
        // 有任何拒绝原因就不进排水(避免全站为注定失败的清空白白 503)。核对不完的部分在锁内删除前再核对。
        if (check.refused()) {
            throw BusinessTestResetFilesPort.refused(check.refusals());
        }
        BusinessDataResetDrainGate.DrainOutcome drained;
        try {
            drained = drainGate.beginDrain(timings.drainTimeout().toMillis());
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw failure(ErrorCode.INTERNAL, "DRAIN_INTERRUPTED",
                    "业务数据清空等待其他操作结束时被中断，本次没有删除任何文件，也没有清空数据。");
        }
        switch (drained) {
            case ANOTHER_RESET -> throw anotherReset();
            case IN_FLIGHT_TIMEOUT -> throw failure(ErrorCode.CONFLICT, "DRAIN_TIMEOUT",
                    "还有其他人的操作在进行中，等了 " + wholeSeconds(timings.drainTimeout())
                            + " 秒仍未结束；本次没有删除任何文件，也没有清空数据。请稍后重新点「确认清空」。");
            case STARTED -> { }
        }
        Result result;
        try {
            result = runReset(operatorId, operatorAccount, attemptId, deadline, deleted);
        } finally {
            drainGate.endReset();
        }
        cleanupScratchQuietly();
        return result;
    }

    /** 另一次清空正在进行：立即拒绝，不等待也不排水。 */
    private void refuseIfAnotherResetRunning() {
        if (drainGate.blockingNewRequests()) {
            throw anotherReset();
        }
    }

    private static ResetFilesFailure anotherReset() {
        return failure(ErrorCode.CONFLICT, "ANOTHER_RESET",
                "另一位超级管理员正在清空业务数据，请等它完成后再操作(完成后所有人都需要重新登录)。本次没有删除任何文件，也没有清空数据。");
    }

    /** 检查时等锁超时：如果正好有另一次清空在进行，就按另一次清空说明。 */
    private ResetFilesFailure anotherResetIfBusy(ResetFilesFailure failure) {
        boolean lockTimeout = failure.reasons().stream().anyMatch(r -> "LOCK_TIMEOUT".equals(r.code()));
        return lockTimeout && drainGate.blockingNewRequests() ? anotherReset() : failure;
    }

    /** 数据库确认在职超级管理员本人(预览与清空都查)。 */
    private void requireConfirmedSuperAdmin(UUID operatorId, String operatorAccount) {
        boolean confirmed = false;
        if (operatorId != null && operatorAccount != null) {
            try (Connection connection = dataSource.getConnection();
                 PreparedStatement statement = connection.prepareStatement(
                         "SELECT EXISTS(SELECT 1 FROM users WHERE id=? AND login_account=? AND is_super_admin"
                                 + " AND status='active' AND NOT is_deleted)")) {
                statement.setObject(1, operatorId);
                statement.setString(2, operatorAccount);
                try (ResultSet rows = statement.executeQuery()) {
                    confirmed = rows.next() && rows.getBoolean(1);
                }
            } catch (SQLException ex) {
                log.warn("business_data_reset 核对清空操作人时数据库出错 sqlstate={}", ex.getSQLState(), ex);
                throw failure(ErrorCode.INTERNAL, "OPERATOR_CHECK_FAILED",
                        "核对清空操作人时数据库出错，本次没有删除任何文件，也没有清空数据。请稍后重试；如果再次出现，请联系开发人员。");
            }
        }
        if (!confirmed) {
            throw failure(ErrorCode.FORBIDDEN, "NOT_SUPER_ADMIN",
                    "只有在职的超级管理员本人可以清空业务数据。请用自己的超级管理员账号重新登录后再试。");
        }
    }

    /**
     * 已经物理删除过文件之后的任何失败(D16)：开头写明已删除数，回执原因附带 FILES_DELETED。
     * 没有删除过文件时，以「原因：」开头的文案前面补一句「清空没有完成，业务数据没有清空」。
     */
    static RuntimeException report(RuntimeException failure, long deleted) {
        if (!(failure instanceof ApiException api)) return failure;
        String message = api.getMessage() == null ? "" : api.getMessage();
        List<Refusal> reasons = failure instanceof ResetFilesFailure files ? files.reasons() : List.of();
        if (deleted == 0) {
            if (!message.startsWith("原因：")) return failure;
            ResetFilesFailure reported = new ResetFilesFailure(api.getCode(),
                    "清空没有完成，业务数据没有清空。" + message, reasons);
            reported.initCause(failure);
            return reported;
        }
        List<Refusal> withDeleted = new ArrayList<>(reasons);
        withDeleted.add(new Refusal("FILES_DELETED", deleted, ""));
        String reason = message.startsWith("原因：") ? message : "原因：" + message;
        ResetFilesFailure reported = new ResetFilesFailure(api.getCode(),
                "本次已经物理删除了 " + deleted + " 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。"
                        + reason + "已删除的文件下次不会重复处理。", withDeleted);
        reported.initCause(failure);
        return reported;
    }

    /** 清空成功后清理内部存储遗留的私有临时文件；失败只记日志，不影响已完成的清空。 */
    private void cleanupScratchQuietly() {
        try {
            int removed = files.cleanupAbandonedScratch();
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
        try (Connection connection = dataSource.getConnection()) {
            LastResult completion = LastResult.none();
            try (PreparedStatement statement = connection.prepareStatement("""
                    SELECT actor_id,actor_account,target_id,result,created_at FROM (
                        SELECT id,actor_id,actor_account,target_id,result,created_at,action,event_source,target_type FROM public.audit_log
                        UNION ALL
                        SELECT id,actor_id,actor_account,target_id,result,created_at,action,event_source,target_type FROM public.audit_log_archive
                    ) receipts
                    WHERE action=? AND event_source='business' AND target_type='system_test'
                      AND (CAST(? AS uuid) IS NULL OR (target_id=? AND actor_id=?))
                    ORDER BY created_at DESC,id DESC LIMIT 1
                    """)) {
                statement.setString(1, AUDIT_ACTION);
                statement.setObject(2, attemptId);
                statement.setString(3, attemptId == null ? null : attemptId.toString());
                statement.setObject(4, operatorId);
                try (ResultSet rows = statement.executeQuery()) {
                    if (rows.next()) {
                        Map<String, Long> values = parseResultSummary(rows.getString("result"));
                        completion = new LastResult(
                                true,
                                rows.getTimestamp("created_at").toInstant(),
                                rows.getString("actor_account"),
                                (int) (long) values.getOrDefault("cleared_tables", 0L),
                                values.getOrDefault("cleared_rows", 0L),
                                (int) (long) values.getOrDefault("preserved_tables", 0L),
                                values.getOrDefault("epoch", 0L),
                                values.getOrDefault("deleted_attachment_files", 0L),
                                values.getOrDefault("dead_events_cleared", 0L),
                                rows.getObject("actor_id", UUID.class),
                                parseAttemptId(rows.getString("target_id")),
                                false, null, false, false, null, 0);
                    }
                }
            }
            if (attemptId == null) return completion;
            return withAttemptReceipts(connection, completion, operatorId, attemptId);
        } catch (SQLException ex) {
            throw new ApiException(ErrorCode.INTERNAL, "读取上次清空结果失败：" + ex.getMessage());
        }
    }

    /** 同一请求的受理/失败回执(ADR-067 §9)：只认同一操作者、同一 attemptId。 */
    private static LastResult withAttemptReceipts(
            Connection connection, LastResult completion, UUID operatorId, UUID attemptId) throws SQLException {
        boolean received = false;
        Instant receivedAt = null;
        boolean byCurrentServer = false;
        boolean failed = false;
        String failureMessage = null;
        long failureDeletedFiles = 0;
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT action,result,created_at FROM (
                    SELECT id,actor_id,target_id,result,created_at,action,event_source,target_type FROM public.audit_log
                    UNION ALL
                    SELECT id,actor_id,target_id,result,created_at,action,event_source,target_type FROM public.audit_log_archive
                ) receipts
                WHERE action IN (?,?) AND event_source='business' AND target_type='system_test'
                  AND target_id=? AND actor_id=?
                ORDER BY created_at ASC,id ASC
                """)) {
            statement.setString(1, AUDIT_ACTION_RECEIVED);
            statement.setString(2, AUDIT_ACTION_FAILED);
            statement.setString(3, attemptId.toString());
            statement.setObject(4, operatorId);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    String result = rows.getString("result") == null ? "" : rows.getString("result");
                    if (AUDIT_ACTION_RECEIVED.equals(rows.getString("action"))) {
                        received = true;
                        receivedAt = rows.getTimestamp("created_at").toInstant();
                        byCurrentServer = result.contains("server=" + SERVER_INSTANCE_ID);
                    } else {
                        failed = true;
                        int marker = result.indexOf("message=");
                        failureMessage = marker < 0 ? result : result.substring(marker + "message=".length());
                        failureDeletedFiles = parseResultSummary(marker < 0 ? result : result.substring(0, marker))
                                .getOrDefault("deleted_attachment_files", 0L);
                    }
                }
            }
        }
        return completion.withReceipts(received, receivedAt, byCurrentServer, failed, failureMessage, failureDeletedFiles);
    }

    private static UUID parseAttemptId(String value) {
        if (value == null) return null;
        try { return UUID.fromString(value); }
        catch (IllegalArgumentException historicalTarget) { return null; }
    }

    /** 解析审计 result 摘要 {@code k=v,k=v}(旧记录缺的键按 0；非数字片段忽略)。 */
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
                // 非数字片段(原因码、文字摘要)忽略
            }
        }
        return values;
    }

    private Result runReset(UUID operatorId, String operatorAccount, UUID attemptId,
                            Instant deadline, AtomicLong deleted) {
        // JpaTransactionManager exposes its physical connection through the same DataSource:
        // the locks, the file purge, the reset function and the JPA completion receipt all share
        // one transaction that commits before the caller releases the drain gate.
        TransactionTemplate transaction = new TransactionTemplate(transactionManager);
        transaction.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        transaction.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
        // 清空整库是真正的长任务: 事务上限与下面 SET LOCAL statement_timeout 同为 30 分钟,
        // 不受全局 40 秒默认事务上限约束(ADR-107)。
        transaction.setTimeout(30 * 60);
        try {
            return transaction.execute(status -> {
                Connection connection = DataSourceUtils.getConnection(dataSource);
                try {
                    bindAuditActor(connection, operatorId, operatorAccount);
                    setLockTimeout(connection);
                    setStatementTimeout(connection);
                    setIdleTimeout(connection);
                    Purge purge = files.purge(deadline, deleted);
                    declareObjectFingerprint(connection, purge.fingerprint());
                    Result result = callResetFunction(connection, purge);
                    auditService.logCommitted(
                            operatorId,
                            operatorAccount,
                            AUDIT_ACTION,
                            "system_test",
                            attemptId == null ? null : attemptId.toString(),
                            "cleared_tables=" + result.clearedTableCount()
                                    + ",cleared_rows=" + result.clearedRows()
                                    + ",preserved_tables=" + result.preservedTableCount()
                                    + ",epoch=" + result.authorizationEpochAfter()
                                    + ",deleted_attachment_files=" + result.deletedAttachmentFiles()
                                    + ",dead_events_cleared=" + result.deadBackgroundEventsCleared());
                    return result;
                } catch (ApiException ex) {
                    throw ex;
                } catch (SQLException | RuntimeException ex) {
                    // Inside the callback nothing has committed: the whole transaction rolls back.
                    throw asApiException(ex);
                } finally {
                    DataSourceUtils.releaseConnection(connection, dataSource);
                }
            });
        } catch (ApiException ex) {
            throw ex;
        } catch (RuntimeException ex) {
            // A lost commit acknowledgement can follow a committed reset.
            // Its receipt is atomic, so require reconciliation instead of
            // claiming rollback or encouraging another destructive request.
            ApiException uncertain = new UncertainResetOutcome(
                    "业务数据清空未确认完成，请重新登录核对本次结果（系统没能确认保存完成）");
            uncertain.initCause(ex);
            throw uncertain;
        }
    }

    private void setLockTimeout(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SELECT set_config('lock_timeout', ?, true)")) {
            statement.setString(1, timings.resetLockTimeout().toMillis() + "ms");
            statement.executeQuery().close();
        }
    }

    private void setStatementTimeout(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SET LOCAL statement_timeout = '30min'")) {
            statement.executeUpdate();
        }
    }

    /** 删除文件期间连接在事务内空闲，会话默认的空闲上限会杀掉连接。 */
    private void setIdleTimeout(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "SET LOCAL idle_in_transaction_session_timeout = '30min'")) {
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
            statement.executeQuery().close();
        }
    }

    /** 已删除并确认的测试文件清单指纹：清空函数在同一把锁下重算并核对。 */
    private void declareObjectFingerprint(Connection connection, String fingerprint) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT set_config('app.business_test_reset_objects', ?, true)")) {
            statement.setString(1, fingerprint);
            statement.executeQuery().close();
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

    /** 数据库函数完成全部清空/归零/校验/踢人，返回摘要；函数内失败即抛异常回滚。 */
    private Result callResetFunction(Connection connection, Purge purge) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SELECT cleared_table_count, cleared_rows, preserved_table_count, authorization_epoch_after FROM business_data_reset()");
             ResultSet rows = statement.executeQuery()) {
            if (!rows.next()) {
                String cause = "业务数据清空函数没有返回结果摘要，已整体回滚(程序缺陷)";
                throw new ResetFilesFailure(ErrorCode.INTERNAL, cause + "。请联系开发人员。",
                        List.of(new Refusal("DB_FAILED", 0, cause)));
            }
            return new Result(
                    rows.getInt("cleared_table_count"),
                    rows.getLong("cleared_rows"),
                    rows.getInt("preserved_table_count"),
                    rows.getLong("authorization_epoch_after"),
                    purge.deletedFiles(),
                    purge.deadBackgroundEvents());
        }
    }

    /** 清空事务里的数据库错误：拒绝类按数据库原文 409，其余 500 并说明已整体回滚。 */
    private ApiException asApiException(Exception error) {
        SQLException sql = sqlException(error);
        String state = sql == null ? null : sql.getSQLState();
        String original = sql == null ? rootMessage(error) : serverMessage(sql);
        if (REFUSAL_SQLSTATE.equals(state)) {
            return failure(ErrorCode.CONFLICT, "DB_REFUSED", original);
        }
        if (OBJECT_SET_CHANGED_SQLSTATE.equals(state)) {
            // The receipt keeps only the cause; the response keeps the database text verbatim.
            String cause = original.replaceFirst("^原因：", "").replace("本次没有清空任何数据，请联系开发人员。", "").strip();
            return new ResetFilesFailure(ErrorCode.CONFLICT, original,
                    List.of(new Refusal("OBJECT_SET_CHANGED", 0, cause.isEmpty() ? original : cause)));
        }
        if (LOCK_TIMEOUT_SQLSTATE.equals(state)) {
            return failure(ErrorCode.CONFLICT, "DB_LOCK_TIMEOUT",
                    "原因：清空数据时有其他程序占用了数据表，等了 " + wholeSeconds(timings.resetLockTimeout())
                            + " 秒仍没有结束。请稍后重新点「确认清空」；如果再次出现，请联系开发人员。");
        }
        if (CATALOG_PARSE_SQLSTATE.equals(state)) {
            return failure(ErrorCode.INTERNAL, "DB_FAILED", original);
        }
        // The receipt keeps the cause without the next step; its own ending gives the next step.
        String cause = "业务数据清空执行失败，已整体回滚：" + original;
        return new ResetFilesFailure(ErrorCode.INTERNAL,
                cause + "。请重新点「确认清空」；如果再次出现，请联系开发人员。",
                List.of(new Refusal("DB_FAILED", 0, cause)));
    }

    private static ResetFilesFailure failure(ErrorCode code, String reason, String message) {
        return new ResetFilesFailure(code, message, List.of(new Refusal(reason, 0, message)));
    }

    private static long wholeSeconds(Duration duration) {
        return Math.max(1, (duration.toMillis() + 999) / 1000);
    }

    private static SQLException sqlException(Throwable error) {
        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
            if (cause instanceof SQLException sql) return sql;
            if (cause.getCause() == cause) break;
        }
        return null;
    }

    /** 数据库原文(不带 ERROR: 前缀和 Where: 上下文)，与数据库文案逐字相同。 */
    private static String serverMessage(SQLException error) {
        if (error instanceof PSQLException psql && psql.getServerErrorMessage() != null
                && psql.getServerErrorMessage().getMessage() != null) {
            return psql.getServerErrorMessage().getMessage();
        }
        return rootMessage(error);
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
