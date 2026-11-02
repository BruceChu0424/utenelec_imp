package com.uten.imp.features.finance.gl;

import com.uten.imp.support.FinanceReportTestAccess;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Executes the owning manufacturing-output SQL against independent business-date facts. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GlManufacturingBusinessCalendarPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;

    @BeforeAll static void start() {
        PG.start();
        var source = new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        db = new JdbcTemplate(source);
        named = new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db, "stock_movements", "subcontract_receipts", "subcontract_receipt_items");
        // Shanghai 2025-12-31 23:59:59; outside the selected business year.
        movement("2025-12-31T15:59:59Z", "900");
        // First instant of the business year; UTC is still December.
        movement("2025-12-31T16:00:00Z", "11.11");
        // Last instant of January and first instant of February in Shanghai.
        movement("2026-01-31T15:59:59Z", "22.22");
        movement("2026-01-31T16:00:00Z", "33.33");
        movement("2026-12-31T15:59:59Z", "44.44");
        movement("2026-12-31T16:00:00Z", "800");
        // Reversals carry the original positive amount; the direction provides the sign.
        movement("2026-01-15T00:00:00Z", "150");
        db.update("INSERT INTO stock_movements(transaction_date,movement_type,source_doc_type,goods_id,warehouse_id,direction,qty,amount_local) VALUES(TIMESTAMPTZ '2026-01-15T00:00:00Z',13,'STOCK_DOC',?,?,-1,1,150)",UUID.randomUUID(),UUID.randomUUID());
        // A partially valued month is unknown, not its known portion or zero.
        movement("2026-03-01T00:00:00Z", null);
        movement("2026-03-02T00:00:00Z", "5");
    }

    @AfterAll static void stop() { PG.stop(); }

    @ParameterizedTest @ValueSource(strings={"UTC", "America/Denver", "Asia/Shanghai"})
    void outputMonthsAndYearExclusionsDoNotDependOnDatabaseSessionTimezone(String timezone) {
        var em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> query(call.getArgument(0), timezone));
        var service = new GlReportService(em, mock(GlReportLineSource.class), FinanceReportTestAccess.company());
        BigDecimal[] months = ReflectionTestUtils.invokeMethod(service, "finishedInMonthly", 2026);
        assertThat(months).isNotNull();
        assertThat(months[1]).isEqualByComparingTo("33.33");
        assertThat(months[2]).isEqualByComparingTo("33.33");
        assertThat(months[12]).isEqualByComparingTo("44.44");
        assertThat(months[3]).isNull();
        assertThat(months[4]).isZero();
        BigDecimal annual = java.util.Arrays.stream(months).filter(java.util.Objects::nonNull)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        assertThat(annual).isEqualByComparingTo("111.10");
    }

    @Test void manufacturingRowsPreserveAnUnvaluedMonthWhileEmptyMonthsRemainZero() {
        var em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> query(call.getArgument(0), "UTC"));
        var lines = mock(GlReportLineSource.class);
        when(lines.bindings(org.mockito.ArgumentMatchers.anyCollection()))
                .thenReturn(new GlReportLineSource.Bindings(Map.of()));
        var result = new GlReportService(em, lines, FinanceReportTestAccess.company()).manufacturingExpense(2026);
        var output = result.rows().stream().filter(row -> "生产产值".equals(row.get("item")))
                .findFirst().orElseThrow();
        assertThat((BigDecimal)output.get("m1")).isEqualByComparingTo("33.33");
        assertThat(output.get("m3")).isNull();
        assertThat((BigDecimal)output.get("m4")).isZero();
        assertThat(output.get("basis").toString()).contains("待核实金额");
    }

    private static void movement(String instant, String amount) {
        db.update("INSERT INTO stock_movements(transaction_date,movement_type,source_doc_type,goods_id,warehouse_id,direction,qty,amount_local) VALUES(?::timestamptz,13,'STOCK_DOC',?,?,1,1,?::numeric)",
                instant, UUID.randomUUID(), UUID.randomUUID(), amount);
    }

    private static Query query(String sql, String timezone) {
        Query result = mock(Query.class);
        Map<String,Object> parameters = new LinkedHashMap<>();
        when(result.setParameter(anyString(), any())).thenAnswer(call -> {
            parameters.put(call.getArgument(0),call.getArgument(1)); return result;
        });
        when(result.getResultList()).thenAnswer(call -> {
            // Each query opens a fresh connection, so set timezone on that exact connection.
            return named.execute(sql, parameters, statement -> {
                try (var session = statement.getConnection().prepareStatement("SELECT set_config('TimeZone', ?, false)")) {
                    session.setString(1, timezone);
                    try (var configured = session.executeQuery()) {
                        assertThat(configured.next()).isTrue();
                        assertThat(configured.getString(1)).isEqualTo(timezone);
                    }
                }
                try (var rows = statement.executeQuery()) {
                    var output = new java.util.ArrayList<Object[]>();
                    while (rows.next()) output.add(new Object[]{rows.getInt(1),rows.getBigDecimal(2)});
                    return output;
                }
            });
        });
        return result;
    }
}
