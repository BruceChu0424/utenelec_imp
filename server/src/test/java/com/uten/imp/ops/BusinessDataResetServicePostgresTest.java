package com.uten.imp.ops;

import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditLogRepository;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemtest.BusinessDataResetDrainGate;
import com.uten.imp.features.admin.systemtest.BusinessDataResetFeatureGate;
import com.uten.imp.features.admin.systemtest.BusinessDataResetService;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.postgresql.Driver;
import org.springframework.jdbc.datasource.SimpleDriverDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;

/**
 * 工作台「清空业务数据」的真实库执行证明（V462 函数 + 服务编排全链路）：
 * 种子业务行被清空、主档金额归零且行数保留、identity 序列重启、
 * 全局 epoch 递增踢掉所有 staff token、refresh_tokens 被清空、
 * outbox 待处理事件按 UT900 拒绝为 409、可重复执行。
 *
 * <p>写法约束（Mimosa 写入门）：每条 SQL 在各自方法内内联字面量，经独立
 * Statement/PreparedStatement 执行；不存在把 SQL 字符串当参数传递的帮手。</p>
 */
@Testcontainers(disabledWithoutDocker = true)
class BusinessDataResetServicePostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("uten_business_reset")
                    .withUsername("uten")
                    .withPassword("uten");

    @Test
    void resetsBusinessDataZeroesProjectionsRestartsIdentityAndKicksEveryone() throws Exception {
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();

        SimpleDriverDataSource dataSource = new SimpleDriverDataSource(
                new Driver(), POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());

        insertSeedDepartment(dataSource);
        insertSeedEmployee(dataSource);
        insertSeedUser(dataSource);
        insertSeedRefreshToken(dataSource);
        long epochBefore = readEpoch(dataSource);

        BusinessDataResetService service = new BusinessDataResetService(
                dataSource,
                new BusinessDataResetFeatureGate(true),
                new BusinessDataResetDrainGate(),
                new AuditService(mock(AuditLogRepository.class), mock(AuditDeviceContext.class)));

        // —— 阶段一：outbox 有待处理事件 → UT900 拒绝（409）——
        insertSeedBusinessOutboxRow(dataSource, (short) 0);
        ApiException refused = assertThrows(ApiException.class,
                () -> service.reset(UUID.randomUUID(), "superadmin"));
        assertThat(refused.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(refused.getMessage()).contains("待处理或失败事件");
        assertThat(countBusinessOutbox(dataSource)).isEqualTo(1);

        // —— 阶段二：事件已处理 → 种子齐备后执行清空 ——
        markSeedBusinessOutboxProcessed(dataSource);
        insertSeedBusinessOutboxRow(dataSource, (short) 1);
        insertSeedAccount(dataSource);

        long auditBefore = countAuditLog(dataSource);
        long usersBefore = countUsers(dataSource);

        var result = service.reset(UUID.randomUUID(), "superadmin");

        // V463/V464：+purchase/subcontract_order_item_sources 两张 CLEAR 表（222→224）。
        assertThat(result.clearedTableCount()).isEqualTo(224);
        assertThat(result.preservedTableCount()).isEqualTo(96);
        // cleared_rows 只统计 CLEAR 表：2 条 business_outbox（refresh_tokens 属 PRESERVE，
        // 在终局校验后单独清空，不计入）
        assertThat(result.clearedRows()).isEqualTo(2);
        assertThat(result.authorizationEpochAfter()).isEqualTo(epochBefore + 1);

        // 业务事实清空 + identity 序列重启（TRUNCATE RESTART IDENTITY 的直接证据：
        // 清空后 nextval 从 1 重新开始）
        assertThat(countBusinessOutbox(dataSource)).isZero();
        assertThat(nextPostingSeqValue(dataSource)).isEqualTo(1);

        // 保留主档：行数不变、五个金额字段全部归零
        assertThat(countUsers(dataSource)).isEqualTo(usersBefore);
        assertThat(countAccounts(dataSource)).isEqualTo(1);
        assertThat(countFullyZeroedAccounts(dataSource)).isEqualTo(1);
        assertThat(queryZeroedPaymentStyle(dataSource)).isEqualTo(1);

        // 全员下线：epoch 已递增、refresh_tokens 已清空
        assertThat(readEpoch(dataSource)).isEqualTo(epochBefore + 1);
        assertThat(countRefreshTokens(dataSource)).isZero();

        // 主档归零 UPDATE 不停审计：审计行有增长
        assertThat(countAuditLog(dataSource)).isGreaterThan(auditBefore);

        // —— 阶段三：清空后可再次执行（幂等可重复）——
        insertSeedBusinessOutboxRow(dataSource, (short) 1);
        var second = service.reset(UUID.randomUUID(), "superadmin");
        assertThat(second.clearedRows()).isEqualTo(1);
        assertThat(second.authorizationEpochAfter()).isEqualTo(epochBefore + 2);
    }

    private void insertSeedDepartment(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO departments(code, name, level) VALUES ('TEST', '清空测试部', '一级部门')");
        }
    }

    private void insertSeedEmployee(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO employees(code, full_name, id_type, department_id, hire_date, status, employment_type) SELECT 'T0001', '清空测试员', '身份证', id, current_date, 'active', 'regular' FROM departments WHERE code = 'TEST'");
        }
    }

    private void insertSeedUser(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO users(employee_id, login_account, password_hash, must_change_password, status) SELECT id, 't0001', 'x', false, 'active' FROM employees WHERE code = 'T0001'");
        }
    }

    private void insertSeedRefreshToken(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO refresh_tokens(user_id, session_id, token_hash, expires_at) SELECT id, gen_random_uuid(), 'seed-hash', now() + interval '7 days' FROM users WHERE login_account = 't0001'");
        }
    }

    private void insertSeedBusinessOutboxRow(
            SimpleDriverDataSource dataSource, short status) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     "INSERT INTO business_outbox(id, event_type, aggregate_type, dedupe_key, status) VALUES (gen_random_uuid(), 'TEST_EVENT', 'TEST_AGGREGATE', 'seed-' || gen_random_uuid()::text, ?)")) {
            statement.setShort(1, status);
            statement.executeUpdate();
        }
    }

    private void markSeedBusinessOutboxProcessed(SimpleDriverDataSource dataSource)
            throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("UPDATE business_outbox SET status = 1, processed_at = now()");
        }
    }

    private void insertSeedAccount(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO payment_styles(code, name, category, init_balance) VALUES ('999', '清空测试账户类别', 'ACCOUNT', 88)");
        }
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO currencies(code, name, exchange_rate, status) VALUES ('CNY-T', '清空测试币', 1, '使用')");
        }
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO accounts(name, code, account_type, style_id, currency_id, init_balance, receipts_total, payments_total, balance_adjustments_total, balance_current) SELECT '清空测试账户', 'ACCT-TEST-1', 'CASH', ps.id, c.id, 100, 200, 300, 50, 50 FROM payment_styles ps CROSS JOIN currencies c WHERE ps.code = '999' AND ps.category = 'ACCOUNT' AND c.code = 'CNY-T'");
        }
    }

    private long readEpoch(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT epoch FROM authorization_state WHERE singleton_id = 1")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countBusinessOutbox(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM business_outbox")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long nextPostingSeqValue(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT nextval('finance_reconciliations_posting_seq_seq')")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countUsers(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM users")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countAccounts(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM accounts")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countFullyZeroedAccounts(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT count(*) FROM accounts WHERE init_balance = 0 AND receipts_total = 0 AND payments_total = 0 AND balance_adjustments_total = 0 AND balance_current = 0")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countRefreshTokens(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM refresh_tokens")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long queryZeroedPaymentStyle(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT count(*) FROM payment_styles WHERE code = '999' AND COALESCE(init_balance, 0) = 0")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countAuditLog(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM audit_log")) {
            rows.next();
            return rows.getLong(1);
        }
    }
}
