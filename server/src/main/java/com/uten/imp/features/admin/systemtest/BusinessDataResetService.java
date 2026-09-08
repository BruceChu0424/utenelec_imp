package com.uten.imp.features.admin.systemtest;

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
 *   <li>{@link BusinessDataResetDrainGate} 排水：清空前对普通 API 回 503，
 *       等在途请求清零——替代 psql 版「停应用、零其它连接」的静默前提；</li>
 *   <li>绑定事务级审计 actor（app.actor_id / app.actor_account /
 *       app.audit_request_id），主档归零 UPDATE 的审计触发器把行归到实际点击的
 *       超管本人；</li>
 *   <li>调用 {@code business_data_reset()}（单事务），函数内任一校验失败即整体回滚，
 *       UT900 类拒绝映射 409 供发起人按提示处理。</li>
 * </ol>
 */
@Service
@RequiredArgsConstructor
@Slf4j
public class BusinessDataResetService {

    /** 排水等待上限：在途请求多为秒级；长导出等请求超时则放弃本次清空。 */
    static final long DRAIN_TIMEOUT_MILLIS = 45_000;

    /** 用户可自行解除的拒绝（outbox 未清空/附件 owner 不安全/目录漂移等）→ 409。 */
    private static final String REFUSAL_SQLSTATE = "UT900";

    private final DataSource dataSource;
    private final BusinessDataResetFeatureGate featureGate;
    private final BusinessDataResetDrainGate drainGate;
    private final AuditService auditService;

    /** 清空结果摘要（回显给发起人并写入审计事件）。 */
    public record Result(
            int clearedTableCount,
            long clearedRows,
            int preservedTableCount,
            long authorizationEpochAfter) {
    }

    public Result reset(UUID operatorId, String operatorAccount) {
        featureGate.requireEnabled();
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
            result = runReset(operatorId, operatorAccount);
        } finally {
            drainGate.endReset();
        }
        try {
            auditService.logExplicit(
                    operatorId,
                    operatorAccount,
                    "business_data_reset",
                    "system_test",
                    null,
                    "cleared_tables=" + result.clearedTableCount()
                            + ",cleared_rows=" + result.clearedRows()
                            + ",preserved_tables=" + result.preservedTableCount()
                            + ",epoch=" + result.authorizationEpochAfter());
        } catch (RuntimeException auditFailure) {
            // 审计落库失败不改变清空结果本身，但必须留下日志证据。
            log.error("business_data_reset 审计事件写入失败", auditFailure);
        }
        return result;
    }

    private Result runReset(UUID operatorId, String operatorAccount) {
        try (Connection connection = dataSource.getConnection()) {
            boolean originalAutoCommit = connection.getAutoCommit();
            connection.setAutoCommit(false);
            try {
                Result result = runInTransaction(connection, operatorId, operatorAccount);
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
            Connection connection, UUID operatorId, String operatorAccount) throws SQLException {
        bindAuditActor(connection, operatorId, operatorAccount);
        setLockTimeout(connection);
        setStatementTimeout(connection);
        return callResetFunction(connection);
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
    private Result callResetFunction(Connection connection) throws SQLException {
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
                    rows.getLong("authorization_epoch_after"));
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
