package com.uten.imp.features.master;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class CategorySiblingNamePostgresTest {
    private static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");
    private static final List<String> TABLES = List.of("material_categories", "client_categories",
            "supplier_categories", "mould_categories", "payment_styles");

    @BeforeAll static void prepare() throws Exception {
        DB.start();
        var dataSource = new org.springframework.jdbc.datasource.DriverManagerDataSource(
                DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        // The oracle installs V959 itself; preserve its genuine pre-migration
        // column/default/key shapes without copying future triggers or invented columns.
        com.uten.imp.support.MigratedProjectionSchema.createTables(
                new org.springframework.jdbc.core.JdbcTemplate(dataSource), "958", TABLES.toArray(String[]::new));
        try (var connection = connection(); var sql = connection.createStatement()) {
            // Existing ambiguous history must remain readable after upgrading.
            try(var insert=connection.prepareStatement("INSERT INTO material_categories(id,name) VALUES (?,'历史重复'),(?,'历史重复')")) {
                insert.setObject(1,UUID.randomUUID());insert.setObject(2,UUID.randomUUID());insert.executeUpdate();
            }
            try (var source = CategorySiblingNamePostgresTest.class.getResourceAsStream(
                    "/db/migration/V959__category_sibling_names.sql")) {
                assertNotNull(source);
                sql.execute(new String(source.readAllBytes(), StandardCharsets.UTF_8));
            }
        }
    }

    @AfterAll static void stop() { DB.stop(); }

    @Test void everyCategoryRejectsSiblingCreateRenameMoveAndRestoreButAllowsOtherParents() throws Exception {
        for (String table : TABLES) {
            UUID firstParent = UUID.randomUUID(), otherParent = UUID.randomUUID();
            UUID first = insert(table, "1分类", firstParent);
            UUID other = insert(table, "1分类", otherParent);
            SQLException createError = assertThrows(SQLException.class, () -> insert(table, " 1分类 ", firstParent));
            assertEquals("23505", createError.getSQLState());
            UUID rename = insert(table, "2分类", firstParent);
            assertThrows(SQLException.class, () -> update(table, rename, "name", "1分类"));
            assertThrows(SQLException.class, () -> update(table, other, "parent_id", firstParent));
            update(table, first, "is_deleted", true);
            insert(table, "1分类", firstParent);
            assertThrows(SQLException.class, () -> update(table, first, "is_deleted", false));
            insert(table, "顶层", null);
            assertThrows(SQLException.class, () -> insert(table, "顶层", null));
        }
    }

    @Test void financialRootNamesAreScopedToTheirBusinessCategory() throws Exception {
        try (var connection = connection(); var sql = connection.prepareStatement(
                "INSERT INTO payment_styles(id,name,category) VALUES (?,'账户','INCOME'),(?,'账户','EXPENSE')")) {
            sql.setObject(1,UUID.randomUUID());sql.setObject(2,UUID.randomUUID());sql.executeUpdate();
        }
    }

    @Test void concurrentCreatesCannotCommitTheSameSiblingName() throws Exception {
        UUID parent = UUID.randomUUID();
        try (var first = connection(); var executor = Executors.newSingleThreadExecutor()) {
            first.setAutoCommit(false);
            try (var sql = first.prepareStatement("INSERT INTO material_categories(id,name,parent_id) VALUES (?,'并发分类',?)")) {
                sql.setObject(1,UUID.randomUUID());sql.setObject(2,parent);sql.executeUpdate();
            }
            var started = new CountDownLatch(1);
            var second = executor.submit(() -> {
                started.countDown();
                return assertThrows(SQLException.class, () -> insert("material_categories", "并发分类", parent)).getSQLState();
            });
            assertTrue(started.await(5, TimeUnit.SECONDS));
            assertThrows(TimeoutException.class, () -> second.get(200, TimeUnit.MILLISECONDS));
            first.commit();
            assertEquals("23505", second.get(10, TimeUnit.SECONDS));
        }
    }

    @Test void upgradePreservesExistingDuplicateHistoryWithoutPermittingAnotherDuplicate() throws Exception {
        try (var connection = connection(); var sql = connection.createStatement()) {
            assertEquals(2, sql.executeUpdate("UPDATE material_categories SET name=name WHERE name='历史重复'"));
        }
        assertThrows(SQLException.class, () -> insert("material_categories", "历史重复", null));
    }

    private static UUID insert(String table, String name, UUID parent) throws SQLException {
        UUID id = UUID.randomUUID();
        String command = "payment_styles".equals(table)
                ? "INSERT INTO payment_styles(id,name,parent_id,category) VALUES (?,?,?,'EXPENSE')"
                : "INSERT INTO " + table + "(id,name,parent_id) VALUES (?,?,?)";
        try (var connection = connection(); var sql = connection.prepareStatement(
                command)) {
            sql.setObject(1, id); sql.setString(2, name); sql.setObject(3, parent); sql.executeUpdate();
        }
        return id;
    }

    private static void update(String table, UUID id, String column, Object value) throws SQLException {
        String assignment=switch(column) {
            case "name" -> "name=?";
            case "parent_id" -> "parent_id=?";
            case "is_deleted" -> "is_deleted=?";
            default -> throw new IllegalArgumentException("Unsupported category test field");
        };
        try (var connection = connection(); var sql = connection.prepareStatement(
                "UPDATE " + table + " SET " + assignment + " WHERE id=?")) {
            sql.setObject(1,value);sql.setObject(2,id);sql.executeUpdate();
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
    }
}
