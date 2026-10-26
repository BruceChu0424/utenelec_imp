package com.uten.imp.features.master.history;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Every whitelisted compact label projection parses against the real forward-migrated catalog. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MasterRecordHistoryReferenceSchemaPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static NamedParameterJdbcTemplate jdbc;
    @BeforeAll static void baseline() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("history_reference_schema");
        jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(
                database.getJdbcUrl(), database.getUsername(), database.getPassword()));
    }
    @AfterAll static void close() throws Exception { if (database != null) database.close(); }

    @ParameterizedTest @ValueSource(strings = {"goods", "clients", "suppliers", "colors", "units", "moulds",
            "currencies", "warehouses", "accounts", "payment_styles", "settlement_methods", "material_categories",
            "client_categories", "supplier_categories", "mould_categories"})
    void onlyExistingTypedLabelColumnsAreRead(String table) {
        String sql = ReflectionTestUtils.invokeMethod(MasterRecordHistoryService.class,
                "referenceLabelSql", table, "TRUE");
        assertThat(jdbc.queryForList(sql, Map.of("ids", List.of(UUID.randomUUID())))).isEmpty();
    }
}
