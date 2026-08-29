package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Savepoint;
import java.sql.Statement;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsCostIntegrityPostgresTest {

    private static final UUID GOODS_ID =
            UUID.fromString("fb046578-af6a-4701-88e6-cd79f04b1a77");

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_goods_cost_v421")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrate() throws Exception {
        POSTGRES.start();
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            statement.execute("""
                    CREATE TABLE goods (
                        id UUID PRIMARY KEY,
                        code TEXT,
                        source_e NUMERIC(18,4),
                        work_e NUMERIC(18,4),
                        lacquer_e NUMERIC(18,4),
                        incidental_e NUMERIC(18,4),
                        plating_e NUMERIC(18,4),
                        casing_e NUMERIC(18,4),
                        manage_e NUMERIC(18,4),
                        polish_e NUMERIC(18,4),
                        electric_e NUMERIC(18,4),
                        machining_e NUMERIC(18,4),
                        lost_e NUMERIC(18,4),
                        rent_e NUMERIC(18,4),
                        make_e NUMERIC(18,4),
                        work_rate NUMERIC(18,4),
                        lost_rate NUMERIC(18,4),
                        make_rate NUMERIC(18,4),
                        rent_rate NUMERIC(18,4),
                        total NUMERIC(18,4),
                        c_total NUMERIC(18,4),
                        g_total NUMERIC(18,4),
                        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
                    );
                    CREATE TABLE audit_log (
                        id BIGSERIAL PRIMARY KEY,
                        actor_account TEXT,
                        action TEXT NOT NULL,
                        target_type TEXT,
                        target_id TEXT,
                        before JSONB,
                        "after" JSONB,
                        result TEXT,
                        event_source TEXT NOT NULL,
                        http_path TEXT,
                        status_code INTEGER,
                        risk_level TEXT GENERATED ALWAYS AS (
                            CASE
                                WHEN lower(coalesce(action, '') || ' ' || coalesce(result, ''))
                                     ~ '(refresh_reuse|reuse_detected)'
                                    THEN 'critical'
                                WHEN lower(coalesce(action, '')) IN ('delete', 'http_delete')
                                    THEN 'high'
                                WHEN coalesce(status_code, 0) >= 400
                                    THEN 'medium'
                                ELSE 'low'
                            END
                        ) STORED,
                        event_category TEXT GENERATED ALWAYS AS (
                            CASE
                                WHEN lower(coalesce(action, ''))
                                     IN ('insert', 'update', 'delete')
                                    THEN 'data_change'
                                ELSE 'business'
                            END
                        ) STORED,
                        device_capture_status VARCHAR(16) NOT NULL,
                        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                    );
                    INSERT INTO goods(
                        id, code, source_e, machining_e, incidental_e, lacquer_e,
                        plating_e, casing_e, polish_e, work_rate, lost_rate,
                        rent_rate, make_rate, total, c_total, g_total)
                    VALUES (
                        'fb046578-af6a-4701-88e6-cd79f04b1a77',
                        'UTZJ1001', 0, -0.0950, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        -0.0950, -0.0950, -0.0950);
                    """);
            statement.execute(resource(
                    "db/migration/V421__goods_cost_integrity_and_ledger_amount.sql"));
            connection.commit();
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void recordsOriginalsRepairsDerivedValuesAndRejectsFutureInvalidWrites()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertThat(text(statement, """
                    SELECT machining_e || '|' || total || '|' || c_total || '|' || g_total
                    FROM goods WHERE id='%s'
                    """.formatted(GOODS_ID)))
                    .isEqualTo("0.0000|0.0000|0.0000|0.0000");

            assertThat(text(statement, """
                    SELECT concat_ws(
                               '|',
                               (before->>'reason'),
                               (before->'values'->>'machining_e'),
                               ("after"->>'strategy'),
                               ("after"->'values'->>'c_total'))
                    FROM audit_log
                    WHERE target_type='goods_cost_integrity' AND target_id='%s'
                    """.formatted(GOODS_ID)))
                    .isEqualTo(
                            "NEGATIVE_OR_OUT_OF_RANGE_GOODS_COST_OR_RATE"
                            + "|-0.0950|CLAMP_INPUTS_AND_RECOMPUTE_DERIVED_COSTS_V1|0.0000");
            assertThat(text(statement, """
                    SELECT risk_level || '|' || event_category
                    FROM audit_log
                    WHERE target_type='goods_cost_integrity' AND target_id='%s'
                    """.formatted(GOODS_ID)))
                    .isEqualTo("low|data_change");

            connection.setAutoCommit(false);
            Savepoint amountPoint = connection.setSavepoint();
            SQLException negativeAmount = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE goods SET machining_e=-0.0001 WHERE id='%s'
                            """.formatted(GOODS_ID)));
            assertThat(negativeAmount.getSQLState()).isEqualTo("23514");
            connection.rollback(amountPoint);

            Savepoint ratePoint = connection.setSavepoint();
            SQLException excessiveRate = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE goods SET make_rate=100.0001 WHERE id='%s'
                            """.formatted(GOODS_ID)));
            assertThat(excessiveRate.getSQLState()).isEqualTo("23514");
            connection.rollback(ratePoint);
            connection.rollback();
        }
    }

    @Test
    void generatedAuditClassificationsRejectExplicitValues() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            SQLException generatedColumn = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            INSERT INTO audit_log(
                                action, target_type, result, event_source,
                                risk_level, event_category, device_capture_status)
                            VALUES (
                                'update', 'generated-column-gate', 'success', 'test',
                                'high', 'data_remediation', 'legacy')
                            """));

            assertThat(generatedColumn.getSQLState()).isEqualTo("428C9");
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static String resource(String path) throws Exception {
        try (var stream = GoodsCostIntegrityPostgresTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(stream).as(path).isNotNull();
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private static String text(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).isTrue();
            return result.getString(1);
        }
    }
}
