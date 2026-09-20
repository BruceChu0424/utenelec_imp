package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ExecutionMaterialCapacityPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("execution_capacity").withUsername("test").withPassword("test-only");
    private static JdbcTemplate jdbc;

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
    }

    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test
    void wholePackagesAndFixedBatchesDoNotUseTheFullLotAverage() {
        for (String basis : new String[]{"PER_PACKAGE", "FIXED_BATCH"}) {
            String curve = curve(basis, "2", "10", false, "1");
            assertThat(required(curve, "0")).isEqualByComparingTo("0");
            assertThat(required(curve, "0.0001")).isEqualByComparingTo("2");
            assertThat(required(curve, "10")).isEqualByComparingTo("2");
            assertThat(required(curve, "10.0001")).isEqualByComparingTo("4");
            assertThat(required(curve, "11")).isEqualByComparingTo("4");
        }
    }

    @Test
    void partialPackagesRoundEachPhysicalRequirementUpAndConvertProductUnits() {
        assertThat(required(curve("PER_PACKAGE", "1", "3", true, "1"), "1"))
                .isEqualByComparingTo("0.3334");
        assertThat(required(curve("PER_UNIT", "0.125", "1", true, "12"), "2"))
                .isEqualByComparingTo("3");
        assertThat(required(curve("FIXED_BATCH", "2", "10", true, "1"), "11"))
                .isEqualByComparingTo("4");
    }

    @Test
    void repeatedMaterialPathsKeepEachFrozenRuleBeforeSumming() {
        String snapshot = """
                {"productUnitRate":1,"rules":[
                  {"consumptionBasis":"PER_UNIT","bomQty":0.2,"basisOutputQty":1,"allowPartialPackage":true},
                  {"consumptionBasis":"FIXED_BATCH","bomQty":2,"basisOutputQty":10,"allowPartialPackage":false}]}
                """;
        assertThat(required(snapshot,"11")).isEqualByComparingTo("6.2");
        assertThat(required(snapshot,"1")).isEqualByComparingTo("2.2");
    }

    @Test
    void malformedRulesFailInsteadOfBecomingZeroMaterial() {
        assertThatThrownBy(() -> required(curve("UNKNOWN", "1", "1", true, "1"),"1"))
                .hasMessageContaining("Unsupported frozen material consumption basis");
        assertThatThrownBy(() -> required(curve("PER_UNIT", "0", "1", true, "1"),"1"))
                .hasMessageContaining("Invalid frozen material consumption quantities");
        assertThatThrownBy(() -> required("{\"productUnitRate\":1,\"rules\":[]}","1"))
                .hasMessageContaining("Invalid frozen material consumption rules");
        assertThatThrownBy(() -> required("{}","1"))
                .hasMessageContaining("Invalid frozen material consumption rules");
        assertThatThrownBy(() -> required("{\"productUnitRate\":1}","1"))
                .hasMessageContaining("Invalid frozen material consumption rules");
    }

    @Test
    void materialAndArrivalHotPathsHaveDemandAndOriginIndexes() {
        assertThat(jdbc.queryForObject("SELECT fn_execution_material_net_issued_qty(?)",BigDecimal.class,
                java.util.UUID.randomUUID())).isEqualByComparingTo("0");
        assertThat(jdbc.queryForObject("SELECT indexdef FROM pg_indexes WHERE indexname='idx_material_stock_posting_demand_capacity'",
                String.class)).contains("demand_id, posting_type");
        assertThat(jdbc.queryForObject("SELECT indexdef FROM pg_indexes WHERE indexname='idx_preplan_entitlement_origin_group'",
                String.class)).contains("event_group_id, stock_reservation_id");
    }

    private static BigDecimal required(String snapshot, String quantity) {
        return jdbc.queryForObject("SELECT fn_material_snapshot_required(CAST(? AS jsonb), ?)",
                BigDecimal.class, snapshot, new BigDecimal(quantity));
    }

    private static String curve(String basis, String qty, String output, boolean partial, String rate) {
        return "{\"productUnitRate\":" + rate + ",\"rules\":[{\"consumptionBasis\":\"" + basis
                + "\",\"bomQty\":" + qty + ",\"basisOutputQty\":" + output
                + ",\"allowPartialPackage\":" + partial + "}]}";
    }
}
