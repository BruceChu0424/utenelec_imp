package com.uten.imp.common.web;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-151 §4 在真实 PostgreSQL 上核对错误映射(不是手造的 ServerErrorMessage):
 * 我们自己的 PL/pgSQL 守卫 RAISE 中文原因 -> 服务端例程确实是 exec_stmt_raise -> 422 原样回显;
 * 唯一冲突 -> 409 中性文案; 读请求里的数据类错误(非法 uuid 文本) -> 500, 不说成用户填错。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GlobalExceptionHandlerPostgresTest {

    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static JdbcTemplate db;

    @BeforeAll
    static void open() throws SQLException {
        database = MigratedSchemaBaseline.openDatabase("global_exception_handler");
        db = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(),
                database.getPassword()));
    }

    @AfterAll
    static void close() throws SQLException {
        if (database != null) database.close();
    }

    @Test
    void realGuardRaiseIsEchoedAs422AndRealDuplicateIs409() {
        UUID root = UUID.randomUUID();
        UUID child = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id, code, name, status, is_accountable) VALUES (?, '001', '映射测试主仓', '使用', TRUE)",
                root);
        db.update("INSERT INTO warehouses(id, code, name, status, is_accountable, parent_id) "
                + "VALUES (?, 'MAP-1', '映射测试子仓', '使用', TRUE, ?)", child, root);

        // V800 两层树守卫: RAISE '<中文>' USING ERRCODE='23514', CONSTRAINT='warehouse_master_shape_guard'。
        DataIntegrityViolationException guard = captureIntegrity(
                () -> db.update("UPDATE warehouses SET parent_id = NULL WHERE id = ?", child));
        var guardResponse = new GlobalExceptionHandler().handleDataIntegrity(guard);
        assertThat(guardResponse.getStatusCode().value()).isEqualTo(422);
        assertThat(guardResponse.getBody().getMessage())
                .isEqualTo("仓库「映射测试子仓」是子仓, 不能改成独立的顶层仓 (全公司只有一个主仓)");

        // 主仓无条件不能停用(V800 停用前置条件), 同样是写给人看的中文守卫。
        var retire = new GlobalExceptionHandler().handleDataIntegrity(
                captureIntegrity(() -> db.update("UPDATE warehouses SET status = '禁用' WHERE id = ?", root)));
        assertThat(retire.getStatusCode().value()).isEqualTo(422);
        assertThat(retire.getBody().getMessage()).contains("它是主仓");

        // 真正的唯一冲突: 409 中性文案, 不回显约束原文。
        var duplicate = new GlobalExceptionHandler().handleDataIntegrity(captureIntegrity(
                () -> db.update("INSERT INTO warehouses(id, code, name, status) VALUES (?, 'MAP-2', 'x', '使用')", child)));
        assertThat(duplicate.getStatusCode().value()).isEqualTo(409);
        assertThat(duplicate.getBody().getMessage()).isEqualTo(GlobalExceptionHandler.DUPLICATE_MESSAGE);
    }

    @Test
    void dataErrorInsideAReadRequestIsAServerFault() {
        var request = new MockHttpServletRequest("GET", "/api/reports/any");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        try {
            DataAccessException error = captureAny(() -> db.queryForObject("SELECT CAST('' AS uuid)", UUID.class));
            var response = new GlobalExceptionHandler().handleOther(error);
            assertThat(response.getStatusCode().value()).isEqualTo(500);
            assertThat(response.getBody().getCode()).isEqualTo("INTERNAL");
        } finally {
            RequestContextHolder.resetRequestAttributes();
        }
    }

    private static DataIntegrityViolationException captureIntegrity(Runnable statement) {
        DataAccessException error = captureAny(statement);
        assertThat(error).isInstanceOf(DataIntegrityViolationException.class);
        return (DataIntegrityViolationException) error;
    }

    private static DataAccessException captureAny(Runnable statement) {
        DataAccessException[] holder = new DataAccessException[1];
        assertThatThrownBy(statement::run).isInstanceOfSatisfying(DataAccessException.class, error -> holder[0] = error);
        return holder[0];
    }
}
