package com.uten.imp.support;

import org.flywaydb.core.Flyway;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.SQLException;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Real migration column shapes for isolated SQL and function-oracle tests.
 *
 * <p>Copies columns, scalar defaults and primary/unique constraints from an
 * actually migrated catalog. It deliberately omits business CHECK/FK/trigger
 * behavior: these fixtures can represent inconsistent intermediate states to
 * exercise one query or guard. Full-chain tests must use MigratedSchemaBaseline.
 * A pre-migration fixture names its actual source version explicitly.
 */
public final class MigratedProjectionSchema {
    private static final String CURRENT = "current";
    private static final Map<String, Map<String, Shape>> CATALOGS = new ConcurrentHashMap<>();
    private record Shape(List<String> columns, List<String> keys) { }

    private MigratedProjectionSchema() { }

    /** Copies the exact catalog already migrated in this isolated database.
     * Unlike createCurrentTables, this intentionally retains CTAS semantics
     * (no defaults or constraints) for single-function projection oracles. */
    public static void copyEmptyTablesFromMigratedCatalog(Connection connection, String... tables) throws SQLException {
        copyCatalogTables(connection, false, false, tables);
    }

    /** Copies real test-chain facts into a rollback-only private schema. */
    public static void copyTablesWithDataFromMigratedCatalog(Connection connection, String... tables) throws SQLException {
        copyCatalogTables(connection, true, false, tables);
    }

    /** Preserves the original LIKE projection's defaults, CHECKs and indexes. */
    public static void copyConstrainedTablesFromMigratedCatalog(Connection connection, String... tables) throws SQLException {
        copyCatalogTables(connection, false, true, tables);
    }

    private static void copyCatalogTables(Connection connection, boolean data, boolean constraints, String... tables) throws SQLException {
        try (var statement = connection.createStatement(); var rows = statement.executeQuery("SELECT current_schema()")) {
            if (!rows.next() || rows.getString(1) == null || rows.getString(1).equals("public")) {
                throw new IllegalArgumentException("Projection copies require an explicit private target schema");
            }
        }
        try (var statement = connection.createStatement()) {
            for (String table : tables) {
                String relation = identifier(table);
                statement.execute("CREATE TABLE " + relation + (constraints
                        ? " (LIKE public." + relation + " INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES)"
                        : " AS SELECT * FROM public." + relation + (data ? "" : " WITH NO DATA")));
            }
        }
    }

    /** Query fixtures follow the compiled migration resources without a hard-coded head. */
    public static void createCurrentTables(JdbcTemplate target, String... tables) {
        createTables(target, CURRENT, tables);
    }

    public static void createTables(JdbcTemplate target, String version, String... tables) {
        if (!CURRENT.equals(version) && !version.matches("[1-9][0-9]*")) {
            throw new IllegalArgumentException("Explicit migration version required");
        }
        Map<String, Shape> catalog = CATALOGS.computeIfAbsent(version, MigratedProjectionSchema::readCatalog);
        for (String table : tables) {
            Shape shape = catalog.get(table);
            if (shape == null) throw new IllegalArgumentException("No migrated relation at V" + version + ": " + table);
            List<String> declarations = new ArrayList<>(shape.columns());
            declarations.addAll(shape.keys());
            target.execute("CREATE TABLE " + identifier(table) + " (" + String.join(",", declarations) + ")");
        }
    }

    private static Map<String, Shape> readCatalog(String version) {
        try (PostgreSQLContainer<?> source = new PostgreSQLContainer<>("postgres:16-alpine")) {
            source.start();
            var migration = Flyway.configure().dataSource(source.getJdbcUrl(), source.getUsername(), source.getPassword())
                    .locations("classpath:db/migration");
            if (!CURRENT.equals(version)) migration.target(version);
            migration.load().migrate();
            JdbcTemplate db = new JdbcTemplate(new DriverManagerDataSource(
                    source.getJdbcUrl(), source.getUsername(), source.getPassword()));
            Map<String, List<String>> columns = new LinkedHashMap<>();
            db.query("""
                    SELECT relation.relname,attribute.attname,
                           pg_catalog.format_type(attribute.atttypid,attribute.atttypmod),
                           pg_catalog.pg_get_expr(definition.adbin,definition.adrelid)
                    FROM pg_catalog.pg_class relation
                    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=relation.relnamespace
                    JOIN pg_catalog.pg_attribute attribute ON attribute.attrelid=relation.oid
                    LEFT JOIN pg_catalog.pg_attrdef definition
                      ON definition.adrelid=attribute.attrelid AND definition.adnum=attribute.attnum
                    WHERE namespace.nspname='public' AND relation.relkind IN('r','p','v','m')
                      AND attribute.attnum>0 AND NOT attribute.attisdropped
                    ORDER BY relation.relname,attribute.attnum
                    """, row -> {
                String declaration = identifier(row.getString(2)) + " " + row.getString(3);
                String defaultValue = row.getString(4);
                // A projection never consumes or fabricates a source database's
                // sequence or business-function result. Scalar defaults remain exact.
                if (defaultValue != null && scalarDefault(defaultValue)) declaration += " DEFAULT " + defaultValue;
                columns.computeIfAbsent(row.getString(1), ignored -> new ArrayList<>()).add(declaration);
            });
            Map<String, List<String>> keys = new LinkedHashMap<>();
            db.query("""
                    SELECT relation.relname,constraint_row.conname,
                           pg_catalog.pg_get_constraintdef(constraint_row.oid)
                    FROM pg_catalog.pg_constraint constraint_row
                    JOIN pg_catalog.pg_class relation ON relation.oid=constraint_row.conrelid
                    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=relation.relnamespace
                    WHERE namespace.nspname='public' AND constraint_row.contype IN('p','u')
                    ORDER BY relation.relname,constraint_row.conname
                    """, row -> {
                keys.computeIfAbsent(row.getString(1), ignored -> new ArrayList<>())
                        .add("CONSTRAINT " + identifier(row.getString(2)) + " " + row.getString(3));
            });
            Map<String, Shape> shapes = new LinkedHashMap<>();
            columns.forEach((table, fields) -> shapes.put(table,
                    new Shape(List.copyOf(fields), List.copyOf(keys.getOrDefault(table, List.of())))));
            return Map.copyOf(shapes);
        }
    }

    private static boolean scalarDefault(String expression) {
        return expression.equals("now()") || expression.equals("CURRENT_DATE")
                || expression.equals("CURRENT_TIMESTAMP") || expression.equals("gen_random_uuid()")
                || !expression.contains("(");
    }

    private static String identifier(String value) {
        if (!value.matches("[a-z_][a-z_0-9]*")) throw new IllegalArgumentException("Invalid catalog identifier");
        return '"' + value + '"';
    }
}
