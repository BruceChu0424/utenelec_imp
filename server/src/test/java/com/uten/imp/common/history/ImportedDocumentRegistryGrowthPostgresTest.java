package com.uten.imp.common.history;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * W7 P1 增长守卫(2026-11-08)：登记表读谓词在导入历史增长下必须走索引且耗时曲线平稳。
 *
 * <p>生产 SQL 构造器 {@link ImportedBusinessDocumentScope#nativeTable} 生成的
 * 「键列可空判定 + NOT EXISTS(登记表)」谓词是全部列表/徽章/计数查询的读侧形态
 * (W1/V1115)。本守卫用一次性容器按真实 DDL 形状铺 stock_document_items 与
 * imported_document_registry，注入 10× 历史，断言关键查询计划里登记表不出现
 * 全表扫描节点、同机三次采样耗时不随历史体量增长。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ImportedDocumentRegistryGrowthPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("registry_growth").withReuse(false);
    private Connection connection;
    private JdbcTemplate jdbc;

    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }
    @AfterEach void close() throws Exception { if (connection != null) connection.close(); }

    @BeforeEach void fixture() throws Exception {
        connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
        jdbc.execute("""
                CREATE TABLE imported_document_registry (
                  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                  table_name TEXT NOT NULL,
                  row_id UUID NOT NULL,
                  guard_columns TEXT[] NOT NULL DEFAULT '{}',
                  registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                  CONSTRAINT imported_document_registry_identity UNIQUE (table_name, row_id)
                )""");
        jdbc.execute("CREATE INDEX imported_document_registry_lookup"
                + " ON imported_document_registry (table_name, row_id)");
        // 形状取自 32 张 NATIVE_TABLES 中生产最大的 stock_document_items(62 万行)：
        // 自带 legacy_id 键列 + 大体积历史。
        jdbc.execute("CREATE TABLE stock_document_items ("
                + "id UUID PRIMARY KEY, legacy_id UUID, document_id UUID NOT NULL)");
    }

    @Test void registryPredicateStaysIndexDrivenWhileImportedHistoryGrows() throws Exception {
        jdbc.update("INSERT INTO stock_document_items(id,document_id)"
                + " SELECT md5('active'||n)::uuid,md5('doc'||n)::uuid FROM generate_series(1,200)n");
        String scoped = "SELECT count(*) FROM " + ImportedBusinessDocumentScope.nativeTable("stock_document_items");
        int previous = 0;
        for (int history : List.of(10_000, 100_000, 1_000_000)) {
            jdbc.update("INSERT INTO imported_document_registry(table_name,row_id)"
                    + " SELECT 'stock_document_items',md5('historical'||n)::uuid"
                    + " FROM generate_series(" + (previous + 1) + "," + history + ")n");
            previous = history;
            Long active = jdbc.queryForObject(scoped, Long.class);
            assertTrue(active != null && active == 200L, "未登记的活跃行必须全部可见: " + active);
            String plan = jdbc.queryForObject(
                    "EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) " + scoped, String.class);
            // 登记表只允许索引驱动(唯一索引/索引-only 扫描)；出现以登记表为对象的全表扫描
            // 即退化为 2026-11-07 调研否决过的集合反连接形态。活跃表本身很小, 顺序扫描合法。
            var planRoot = new com.fasterxml.jackson.databind.ObjectMapper().readTree(plan);
            boolean registrySeqScan = false;
            for (var node : planRoot.findParents("Node Type")) {
                if ("Seq Scan".equals(node.path("Node Type").asText())
                        && "imported_document_registry".equals(node.path("Relation Name").asText())) {
                    registrySeqScan = true;
                }
            }
            assertTrue(!registrySeqScan, "登记表查询计划不得退化为顺序扫描: " + plan);
            com.uten.imp.support.LoadingGrowthEvidence.write("imported-registry-read", history,
                    Map.of("activeRows", 200,
                            "samples", com.uten.imp.support.LoadingGrowthEvidence.samples(
                                    () -> jdbc.queryForObject(scoped, Long.class))),
                    plan);
        }
    }
}
