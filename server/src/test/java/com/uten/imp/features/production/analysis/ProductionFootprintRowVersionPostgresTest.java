package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;

import static org.junit.jupiter.api.Assertions.*;

/**
 * 预锁锁后复核的行变化判据(ADR-107): 发现结果里每行带 {@code xmin} 行版本, 不再对整行做哈希。
 * 这里在真库上钉住它依赖的 PostgreSQL 行为: 任何 UPDATE(哪怕值没变)都会换版本,
 * 只加行锁不换版本, 另一个事务提交的修改一定能被看到。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionFootprintRowVersionPostgresTest {
    @Test
    void everyUpdateChangesTheRowVersionWhileRowLocksDoNot() throws Exception {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            try (var setup = connect(postgres); var statement = setup.createStatement()) {
                statement.execute("CREATE TABLE version_probe(id int PRIMARY KEY, qty numeric(18,4), note text)");
                statement.execute("INSERT INTO version_probe VALUES (1, 10, '中文,括号()')");
            }
            try (var mine = connect(postgres); var other = connect(postgres)) {
                mine.setAutoCommit(false);
                String original = version(mine);
                assertEquals(original, version(mine), "Reading twice is stable");
                try (var lock = mine.createStatement()) {
                    lock.execute("SELECT id FROM version_probe WHERE id=1 FOR UPDATE");
                }
                assertEquals(original, version(mine), "A row lock is not a row change");
                mine.rollback();

                try (var committed = other.createStatement()) {
                    committed.execute("UPDATE version_probe SET qty=qty WHERE id=1");
                }
                String afterSameValue = version(mine);
                assertNotEquals(original, afterSameValue,
                        "A committed value-identical UPDATE is still observed (conservative: it only triggers a retry)");
                mine.rollback();

                try (var own = mine.createStatement()) {
                    own.execute("UPDATE version_probe SET note='改过' WHERE id=1");
                }
                assertNotEquals(afterSameValue, version(mine), "This transaction's own write is observed as well");
                mine.rollback();
                assertEquals(afterSameValue, version(mine), "Rolled-back writes leave the committed version");
                mine.rollback();
            }
        }
    }

    private static Connection connect(PostgreSQLContainer<?> postgres) throws Exception {
        return DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
    }

    private static String version(Connection connection) throws Exception {
        try (var statement = connection.createStatement();
             var rows = statement.executeQuery("SELECT xmin::text FROM version_probe WHERE id=1")) {
            assertTrue(rows.next());
            return rows.getString(1);
        }
    }
}
