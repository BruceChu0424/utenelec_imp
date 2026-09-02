package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty V257 -> latest proof that V258 never copies goods bytea into audit JSON. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class CategoryDrivenCodeUpgradePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void start() {
        POSTGRES.start();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void v258InstallsBinaryRedactionBeforeBackfillingExistingGoods() throws Exception {
        flyway("257").migrate();
        UUID categoryId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        try (Connection connection = connection()) {
            try (PreparedStatement category = connection.prepareStatement("""
                    INSERT INTO material_categories (id, code, name, is_deleted)
                    VALUES (?, 'LEGACY-CAT', '历史分类', false)
                    """)) {
                category.setObject(1, categoryId);
                category.executeUpdate();
            }
            try (PreparedStatement goods = connection.prepareStatement("""
                    INSERT INTO goods (
                        id, category_id, code, name, ground_graph, product_graph1,
                        budget_graph, is_deleted)
                    VALUES (?, ?, 'HP000123', '带图片历史货品', ?, ?, ?, false)
                    """)) {
                goods.setObject(1, goodsId);
                goods.setObject(2, categoryId);
                goods.setBytes(3, new byte[64 * 1024]);
                goods.setBytes(4, new byte[64 * 1024]);
                goods.setBytes(5, new byte[64 * 1024]);
                goods.executeUpdate();
            }
            try (Statement clear = connection.createStatement()) {
                clear.executeUpdate("TRUNCATE audit_log");
            }
        }

        // V425 审计日志全新开始会在链中 TRUNCATE audit_log，V258 回填产生的
        // 脱敏证据必须在 V425 之前取证；先推进到 V424 再断言，随后继续到当前头。
        flyway("424").migrate();

        try (Connection connection = connection();
             PreparedStatement query = connection.prepareStatement("""
                     SELECT count(*) AS updates,
                            count(*) FILTER (
                                WHERE jsonb_exists_any(
                                          COALESCE(before, '{}'::jsonb),
                                          ARRAY['ground_graph','product_graph1','budget_graph'])
                                   OR jsonb_exists_any(
                                          COALESCE("after", '{}'::jsonb),
                                          ARRAY['ground_graph','product_graph1','budget_graph'])) AS leaked,
                            max(COALESCE(pg_column_size(before),0)
                                + COALESCE(pg_column_size("after"),0)) AS max_bytes
                     FROM audit_log
                     WHERE target_type='goods' AND action='update' AND target_id=?
                     """)) {
            query.setString(1, goodsId.toString());
            try (ResultSet rows = query.executeQuery()) {
                rows.next();
                assertTrue(rows.getLong("updates") > 0);
                assertEquals(0, rows.getLong("leaked"));
                assertTrue(rows.getLong("max_bytes") < 16 * 1024,
                        "migration audit rows must stay lightweight even when goods has bytea images");
            }
        }

        // 取证完成后继续 V425（清空审计）到当前迁移头，保持非空 257 基线全链演练。
        flyway(null).migrate();
    }

    private static Flyway flyway(String target) {
        var configuration = Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration");
        if (target != null) configuration.target(target);
        return configuration.load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
