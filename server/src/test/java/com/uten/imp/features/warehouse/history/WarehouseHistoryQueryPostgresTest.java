package com.uten.imp.features.warehouse.history;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseHistoryQueryPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    private static NamedParameterJdbcTemplate jdbc;

    @BeforeAll
    static void migrateCurrentHead() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword()));
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void everyWhitelistedProjectionParsesAgainstCurrentPostgresSchema() {
        for (WarehouseHistoryType type : WarehouseHistoryType.values()) {
            MapSqlParameterSource listParameters = new MapSqlParameterSource()
                    .addValue("status", (short) 0)
                    .addValue("date_from", null)
                    .addValue("date_to", null)
                    .addValue("keyword", "")
                    .addValue("keyword_pattern", "%%")
                    .addValue("limit", 20)
                    .addValue("offset", 0);
            assertEquals(
                    0,
                    jdbc.queryForList(
                            WarehouseHistoryQueries.listSql(type),
                            listParameters).size(),
                    type.name());
            assertEquals(
                    0L,
                    jdbc.queryForObject(
                            WarehouseHistoryQueries.countSql(type),
                            listParameters,
                            Long.class),
                    type.name());

            MapSqlParameterSource detailParameters =
                    new MapSqlParameterSource("id", UUID.randomUUID());
            assertEquals(
                    0,
                    jdbc.queryForList(
                            WarehouseHistoryQueries.detailHeaderSql(type),
                            detailParameters).size(),
                    type.name());
            assertEquals(
                    0,
                    jdbc.queryForList(
                            WarehouseHistoryQueries.detailLinesSql(type),
                            detailParameters).size(),
                    type.name());
        }
    }

    @Test
    void nullStatusBindsAcrossAllListProjections() {
        // 生产回形（2026-09-01 SQLState 42P18）：任务中心收货历史不带 status 时，
        // PG 无法推断 null 参数类型——可选过滤必须先 CAST 再判 NULL。
        for (WarehouseHistoryType type : WarehouseHistoryType.values()) {
            MapSqlParameterSource parameters = new MapSqlParameterSource()
                    .addValue("status", null)
                    .addValue("date_from", null)
                    .addValue("date_to", null)
                    .addValue("keyword", "")
                    .addValue("keyword_pattern", "%%")
                    .addValue("limit", 20)
                    .addValue("offset", 0);
            assertEquals(
                    0L,
                    jdbc.queryForObject(
                            WarehouseHistoryQueries.countSql(type),
                            parameters,
                            Long.class),
                    type.name());
            assertEquals(
                    0,
                    jdbc.queryForList(
                            WarehouseHistoryQueries.listSql(type),
                            parameters).size(),
                    type.name());
        }
    }
}
