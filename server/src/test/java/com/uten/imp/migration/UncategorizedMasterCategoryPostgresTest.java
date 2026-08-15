package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class UncategorizedMasterCategoryPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrateNonEmptySchema() throws Exception {
        POSTGRES.start();
        flyway("271").migrate();

        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            statement.execute("""
                    INSERT INTO client_categories
                        (legacy_id, code, code_prefix, name, is_deleted, deleted_at)
                    VALUES (910001, 'OLD-CLIENT-CATEGORY', 'CX', '已删客户分类', true, now());
                    INSERT INTO mould_categories
                        (legacy_id, code, code_prefix, name, is_deleted, deleted_at)
                    VALUES (910001, 'OLD-MOULD-CATEGORY', 'MX', '已删模具分类', true, now());
                    INSERT INTO supplier_categories
                        (legacy_id, code, code_prefix, name, is_deleted, deleted_at)
                    VALUES (910001, 'OLD-SUPPLIER-CATEGORY', 'SX', '已删供应商分类', true, now());

                    INSERT INTO clients (code, name, category_id, status, code_sequence) VALUES
                        ('V272-CLIENT-NULL', '待归类客户', NULL, '使用', 910001),
                        ('CX910002', '树外客户',
                            (SELECT id FROM client_categories WHERE legacy_id=910001),
                            '使用', 910002);
                    UPDATE clients SET code_managed=true,
                        code_prefix_category_id=(SELECT id FROM client_categories WHERE legacy_id=910001)
                    WHERE code='CX910002';
                    INSERT INTO clients
                        (code, name, category_id, status, code_sequence, is_deleted, deleted_at)
                    VALUES ('V272-DELETED-CLIENT', '已删除客户',
                        (SELECT id FROM client_categories WHERE legacy_id=910001),
                        '禁用', 910003, true, now());
                    INSERT INTO moulds (code, name, category_id, status, code_sequence) VALUES
                        ('V272-MOULD-NULL', '待归类模具', NULL, '使用', 910001),
                        ('MX910002', '树外模具',
                            (SELECT id FROM mould_categories WHERE legacy_id=910001),
                            '使用', 910002);
                    UPDATE moulds SET code_managed=true,
                        code_prefix_category_id=(SELECT id FROM mould_categories WHERE legacy_id=910001)
                    WHERE code='MX910002';
                    INSERT INTO suppliers (code, name, category_id, status, code_sequence) VALUES
                        ('V272-SUPPLIER-NULL', '待归类供应商', NULL, '使用', 910001),
                        ('SX910002', '树外供应商',
                            (SELECT id FROM supplier_categories WHERE legacy_id=910001),
                            '使用', 910002);
                    UPDATE suppliers SET code_managed=true,
                        code_prefix_category_id=(SELECT id FROM supplier_categories WHERE legacy_id=910001)
                    WHERE code='SX910002';
                    """);
        }

        assertThat(flyway("272").migrate().migrationsExecuted).isEqualTo(1);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void upgradeMakesEveryActiveMasterReachableAndCategoryColumnsRequired() throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertThat(scalarLong(statement, """
                    SELECT count(*) FROM (
                        SELECT c.id FROM clients c
                        JOIN client_categories category ON category.id=c.category_id
                        WHERE c.is_deleted=false AND category.is_deleted=false
                          AND c.code IN ('V272-CLIENT-NULL', 'CX910002')
                        UNION ALL
                        SELECT m.id FROM moulds m
                        JOIN mould_categories category ON category.id=m.category_id
                        WHERE m.is_deleted=false AND category.is_deleted=false
                          AND m.code IN ('V272-MOULD-NULL', 'MX910002')
                        UNION ALL
                        SELECT s.id FROM suppliers s
                        JOIN supplier_categories category ON category.id=s.category_id
                        WHERE s.is_deleted=false AND category.is_deleted=false
                          AND s.code IN ('V272-SUPPLIER-NULL', 'SX910002')
                    ) reachable
                    """)).isEqualTo(6);
            assertThat(scalarLong(statement, """
                    SELECT count(*) FROM information_schema.columns
                    WHERE table_schema='public'
                      AND table_name IN ('clients','moulds','suppliers')
                      AND column_name='category_id'
                      AND is_nullable='NO'
                    """)).isEqualTo(3);
            assertThat(scalarLong(statement, """
                    SELECT count(*) FROM (
                        SELECT id FROM clients
                        WHERE code='CX910002' AND code_managed=false
                          AND code_prefix_category_id IS NULL
                        UNION ALL
                        SELECT id FROM moulds
                        WHERE code='MX910002' AND code_managed=false
                          AND code_prefix_category_id IS NULL
                        UNION ALL
                        SELECT id FROM suppliers
                        WHERE code='SX910002' AND code_managed=false
                          AND code_prefix_category_id IS NULL
                    ) normalized_code_metadata
                    """)).isEqualTo(3);
            assertThat(scalarLong(statement, """
                    SELECT count(*) FROM (
                        SELECT id FROM client_categories
                        WHERE legacy_id=-1 AND code='SYS_UNCATEGORIZED_CLIENT'
                          AND name='未分类' AND is_deleted=false
                        UNION ALL
                        SELECT id FROM mould_categories
                        WHERE legacy_id=-1 AND code='SYS_UNCATEGORIZED_MOULD'
                          AND name='未分类' AND is_deleted=false
                        UNION ALL
                        SELECT id FROM supplier_categories
                        WHERE legacy_id=-1 AND code='SYS_UNCATEGORIZED_SUPPLIER'
                          AND name='未分类' AND is_deleted=false
                    ) roots
                    """)).isEqualTo(3);
        }
    }

    @Test
    void rawNullWritesAreNormalizedButDeletedCategoriesAndRootMutationFailClosed()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            statement.execute("""
                    INSERT INTO clients (code, name, category_id, status, code_sequence)
                    VALUES ('V272-RAW-NULL', '原始写入', NULL, '使用', 910005)
                    """);
            assertThat(scalarLong(statement, """
                    SELECT count(*) FROM clients client
                    JOIN client_categories category ON category.id=client.category_id
                    WHERE client.code='V272-RAW-NULL' AND category.legacy_id=-1
                    """)).isEqualTo(1);

            assertThrows(SQLException.class, () -> statement.execute("""
                    INSERT INTO suppliers (code, name, category_id, status, code_sequence)
                    VALUES ('V272-DELETED-REF', '非法分类',
                        (SELECT id FROM supplier_categories WHERE legacy_id=910001),
                        '使用', 910003)
                    """));
            assertThrows(SQLException.class, () -> statement.execute("""
                    UPDATE client_categories SET name='被篡改'
                    WHERE legacy_id=-1
                    """));
            assertThrows(SQLException.class, () -> statement.execute("""
                    UPDATE clients SET is_deleted=false, deleted_at=NULL
                    WHERE code='V272-DELETED-CLIENT'
                    """));

            statement.execute("""
                    INSERT INTO client_categories (legacy_id, code, name)
                    VALUES (910002, 'ACTIVE-CLIENT-CATEGORY', '仍有客户的分类');
                    INSERT INTO clients (code, name, category_id, status, code_sequence)
                    VALUES ('V272-ACTIVE-CLIENT', '活动客户',
                        (SELECT id FROM client_categories WHERE legacy_id=910002),
                        '使用', 910004);
                    INSERT INTO supplier_categories (legacy_id, code, name)
                    VALUES (910002, 'ACTIVE-SUPPLIER-CATEGORY', '仍有供应商的分类');
                    INSERT INTO suppliers (code, name, category_id, status, code_sequence)
                    VALUES ('V272-ACTIVE-SUPPLIER', '活动供应商',
                        (SELECT id FROM supplier_categories WHERE legacy_id=910002),
                        '使用', 910004);
                    """);
            assertThrows(SQLException.class, () -> statement.execute("""
                    UPDATE client_categories SET is_deleted=true, deleted_at=now()
                    WHERE legacy_id=910002
                    """));
            assertThrows(SQLException.class, () -> statement.execute("""
                    UPDATE supplier_categories SET is_deleted=true, deleted_at=now()
                    WHERE legacy_id=910002
                    """));
        }
    }

    private static Flyway flyway(String target) {
        var configuration = Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration");
        if (target != null) configuration.target(target);
        return configuration.load();
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static long scalarLong(Statement statement, String sql) throws SQLException {
        try (var result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }
}
