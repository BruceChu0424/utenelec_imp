package com.uten.imp.support;

import com.uten.imp.migration.MigrationRehearsalSupport;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * {@link MigratedSchemaBaseline} 的冒烟验证：真实迁移基线 + 模板克隆机制
 * 真的能跑、克隆出的 schema 停在当前迁移头（拿最近的 V584/V595/V599 加列
 * 当探针列）、克隆库之间真的隔离。新 fixture 迁移到本机制前先看这里。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MigratedSchemaBaselinePostgresTest {

    private static final PostgreSQLContainer<?> TEMPLATE =
            MigratedSchemaBaseline.startMigratedContainer("migrated_baseline_smoke_template");

    @BeforeAll
    static void verifyTemplateHead() throws SQLException {
        String headSql = "SELECT max(version::int) FROM flyway_schema_history WHERE success";
        try (Connection connection = DriverManager.getConnection(
                TEMPLATE.getJdbcUrl(), TEMPLATE.getUsername(), TEMPLATE.getPassword());
             PreparedStatement history = connection.prepareStatement(headSql);
             ResultSet rows = history.executeQuery()) {
            assertTrue(rows.next());
            assertEquals(
                    Integer.parseInt(MigrationRehearsalSupport.CURRENT_HEAD_VERSION),
                    rows.getInt(1),
                    "模板库必须迁到当前迁移头");
        }
    }

    @AfterAll
    static void stopTemplate() {
        TEMPLATE.stop();
    }

    @Test
    void clonesCarryTheLatestMigratedColumnsAndStayIsolated() throws SQLException {
        try (Connection first = MigratedSchemaBaseline.cloneConnection(TEMPLATE, "baseline_smoke_first");
             Connection second = MigratedSchemaBaseline.cloneConnection(TEMPLATE, "baseline_smoke_second");
             Statement firstStatement = first.createStatement();
             Statement secondStatement = second.createStatement()) {

            assertColumn(first, "warehouses", "is_line_side", "V584 线边仓标记");
            assertColumn(first, "production_execution_segments", "continuous_supply",
                    "V595 持续生产");
            assertColumn(first, "production_execution_segments", "start_route",
                    "V599 开工路线");
            assertColumn(second, "production_execution_segments", "start_route",
                    "V599 开工路线");

            // 克隆隔离：只在一号克隆建表，二号克隆必须看不见。
            firstStatement.execute("CREATE TABLE isolation_probe(id integer)");
            String isolationSql = "SELECT count(*) FROM information_schema.tables WHERE table_name = 'isolation_probe'";
            try (ResultSet isolation = secondStatement.executeQuery(isolationSql)) {
                assertTrue(isolation.next());
                assertEquals(0, isolation.getInt(1), "克隆库之间必须互相隔离");
            }
        }
    }

    private static void assertColumn(
            Connection connection, String table, String column, String what) throws SQLException {
        String probeSql = "SELECT count(*) FROM information_schema.columns WHERE table_name = ? AND column_name = ?";
        try (PreparedStatement probe = connection.prepareStatement(probeSql)) {
            probe.setString(1, table);
            probe.setString(2, column);
            try (ResultSet rows = probe.executeQuery()) {
                assertTrue(rows.next());
                assertEquals(1, rows.getInt(1),
                        "克隆库应有列（迁移头探针）：" + table + "." + column + "（" + what + "）");
            }
        }
    }
}
