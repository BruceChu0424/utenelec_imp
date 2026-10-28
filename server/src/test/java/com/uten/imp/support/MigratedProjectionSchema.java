package com.uten.imp.support;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.SQLException;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
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
    private static final Map<String, Catalog> CATALOGS = new ConcurrentHashMap<>();
    private record Shape(List<String> columns, List<String> keys) { }
    private record Catalog(Map<String, Shape> tables, Map<String, List<String>> functions,
            Set<String> importedDocumentTables, Map<String, String> views) { }

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

    /** Copies a real read view over explicitly cloned relations in a private schema.
     * The source is rendered without public on the search path so its dependencies
     * cannot silently resolve back to the migrated business tables. */
    public static void copyReadViewFromMigratedCatalog(Connection connection, String view, String... tables) throws SQLException {
        String schema;
        String searchPath;
        try (var statement = connection.createStatement();
                var rows = statement.executeQuery("SELECT current_schema(), current_setting('search_path')")) {
            if (!rows.next() || rows.getString(1) == null
                    || Set.of("public", "pg_catalog", "information_schema").contains(rows.getString(1))) {
                throw new IllegalArgumentException("Projection copies require an explicit private target schema");
            }
            schema = rows.getString(1);
            searchPath = rows.getString(2);
        }
        String targetSchema = identifier(schema);
        String targetView = identifier(view);
        String definition;
        try {
            try (var statement = connection.createStatement()) {
                statement.execute("SET search_path TO pg_catalog");
            }
            try (var statement = connection.prepareStatement("""
                    SELECT pg_catalog.pg_get_viewdef(relation.oid, true)
                    FROM pg_catalog.pg_class relation
                    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=relation.relnamespace
                    WHERE namespace.nspname='public' AND relation.relname=? AND relation.relkind='v'
                    """)) {
                statement.setString(1, view);
                try (var rows = statement.executeQuery()) {
                    if (!rows.next()) throw new IllegalArgumentException("No migrated read view: " + view);
                    definition = rows.getString(1);
                }
            }
        } finally {
            try (var statement = connection.prepareStatement("SELECT pg_catalog.set_config('search_path', ?, false)")) {
                statement.setString(1, searchPath);
                statement.execute();
            }
        }
        for (String table : tables) {
            String targetRelation = targetSchema + "." + identifier(table);
            try (var statement = connection.prepareStatement("SELECT pg_catalog.to_regclass(?)")) {
                statement.setString(1, targetRelation);
                try (var rows = statement.executeQuery()) {
                    if (!rows.next() || rows.getString(1) == null) {
                        throw new IllegalArgumentException("Missing private projection relation: " + table);
                    }
                }
            }
            String sourceRelation = "(?:public|\"public\")\\.(?:\"" + java.util.regex.Pattern.quote(table)
                    + "\"|" + java.util.regex.Pattern.quote(table) + ")(?![a-zA-Z_0-9$])";
            definition = definition.replaceAll(sourceRelation, java.util.regex.Matcher.quoteReplacement(targetRelation));
        }
        if (java.util.regex.Pattern.compile("(?:public|\"public\")\\.").matcher(definition).find()) {
            throw new IllegalArgumentException("Read projection has an uncloned public dependency: " + view);
        }
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE VIEW " + targetSchema + "." + targetView + " AS " + definition);
        }
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
                        ? " (LIKE public." + relation + " INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING GENERATED)"
                        : " AS SELECT * FROM public." + relation + (data ? "" : " WITH NO DATA")));
            }
        }
    }

    /** Query fixtures follow the compiled migration resources without a hard-coded head. */
    public static void createCurrentTables(JdbcTemplate target, String... tables) {
        createTables(target, CURRENT, tables);
    }

    /** Source column shapes for ambiguity/corruption oracles with test-owned keys.
     * Does not import production PRIMARY/UNIQUE constraints: deliberately duplicate
     * source identities must remain representable. Never use for full-chain tests. */
    public static void createCurrentColumns(JdbcTemplate target, String... tables) {
        createTables(target, CURRENT, false, tables);
    }

    /** Copies real current definitions into the same isolated projection fixture, in dependency order. */
    public static void createCurrentFunctions(JdbcTemplate target, String... names) {
        Catalog catalog = CATALOGS.computeIfAbsent(CURRENT, MigratedProjectionSchema::readCatalog);
        for (String name : names) {
            List<String> definitions = catalog.functions().get(name);
            if (definitions == null) throw new IllegalArgumentException("No migrated function: " + name);
            definitions.forEach(target::execute);
        }
    }

    /** Uses actual migrated view SQL, after callers model its real relations/functions. */
    public static void createCurrentViews(JdbcTemplate target, String... names) {
        Catalog catalog = CATALOGS.computeIfAbsent(CURRENT, MigratedProjectionSchema::readCatalog);
        for (String name : names) {
            String definition = catalog.views().get(name);
            if (definition == null) throw new IllegalArgumentException("No migrated view: " + name);
            target.execute("CREATE OR REPLACE VIEW public." + identifier(name) + " AS " + definition);
        }
    }

    /** Installs the real current imported-document policy for explicitly modeled projection tables.
     * Source ownership FKs remain the fixture's responsibility; this is not a full-chain schema.
     * Real marker triggers are essential: the production lookup rejects unregistered table names. */
    public static void installImportedDocumentPolicy(JdbcTemplate target, String... guardedTables) {
        Catalog catalog = CATALOGS.computeIfAbsent(CURRENT, MigratedProjectionSchema::readCatalog);
        for (String table : guardedTables) {
            identifier(table);
            if (!catalog.importedDocumentTables().contains(table)) {
                throw new IllegalArgumentException("Not a migrated imported-document relation: " + table);
            }
        }
        createCurrentFunctions(target,
                "fn_imported_business_document_roots",
                "fn_imported_business_document_maintenance_allowed",
                "fn_imported_business_document_table",
                "fn_imported_business_document_scope_table",
                "fn_imported_business_document_row_internal",
                "fn_imported_business_document_row",
                "fn_imported_business_document",
                "fn_guard_imported_business_document_archive",
                "fn_guard_imported_business_document_truncate");
        for (String table : guardedTables) {
            String relation = "public." + identifier(table);
            target.execute("CREATE TRIGGER trg_00_imported_business_archive_only BEFORE INSERT OR UPDATE OR DELETE ON "
                    + relation + " FOR EACH ROW EXECUTE FUNCTION public.fn_guard_imported_business_document_archive()");
            target.execute("ALTER TABLE " + relation + " ENABLE ALWAYS TRIGGER trg_00_imported_business_archive_only");
            target.execute("CREATE TRIGGER trg_00_imported_business_archive_truncate BEFORE TRUNCATE ON "
                    + relation + " FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_imported_business_document_truncate()");
            target.execute("ALTER TABLE " + relation + " ENABLE ALWAYS TRIGGER trg_00_imported_business_archive_truncate");
        }
    }

    public static void createTables(JdbcTemplate target, String version, String... tables) {
        createTables(target, version, true, tables);
    }

    private static void createTables(JdbcTemplate target, String version, boolean includeKeys, String... tables) {
        if (!CURRENT.equals(version) && !version.matches("[1-9][0-9]*")) {
            throw new IllegalArgumentException("Explicit migration version required");
        }
        Map<String, Shape> catalog = CATALOGS.computeIfAbsent(version, MigratedProjectionSchema::readCatalog).tables();
        for (String table : tables) {
            Shape shape = catalog.get(table);
            if (shape == null) throw new IllegalArgumentException("No migrated relation at V" + version + ": " + table);
            List<String> declarations = new ArrayList<>(shape.columns());
            if (includeKeys) declarations.addAll(shape.keys());
            target.execute("CREATE TABLE " + identifier(table) + " (" + String.join(",", declarations) + ")");
        }
    }

    private static Catalog readCatalog(String version) {
        try (PostgreSQLContainer source = new PostgreSQLContainer("postgres:16-alpine")) {
            source.start();
            var migration = com.uten.imp.testsupport.TestFlyway.configure().dataSource(source.getJdbcUrl(), source.getUsername(), source.getPassword())
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
            Map<String, List<String>> functions = new LinkedHashMap<>();
            db.query("""
                    SELECT procedure.proname, pg_catalog.pg_get_functiondef(procedure.oid)
                    FROM pg_catalog.pg_proc procedure
                    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=procedure.pronamespace
                    WHERE namespace.nspname='public' AND procedure.prokind='f'
                      AND procedure.proname LIKE 'fn_%'
                    ORDER BY procedure.proname, procedure.pronargs DESC, procedure.oid
                    """, row -> {
                functions.computeIfAbsent(row.getString(1), ignored -> new ArrayList<>()).add(row.getString(2));
            });
            functions.replaceAll((name, definitions) -> List.copyOf(definitions));
            Set<String> importedDocumentTables = Set.copyOf(db.queryForList("""
                    SELECT relation.relname FROM pg_trigger trigger_row
                    JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
                    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
                    WHERE namespace.nspname='public' AND NOT trigger_row.tgisinternal
                      AND trigger_row.tgname='trg_00_imported_business_archive_only'
                    """, String.class));
            Map<String, String> views = new LinkedHashMap<>();
            db.query("SELECT viewname,definition FROM pg_views WHERE schemaname='public' ORDER BY viewname",
                    (org.springframework.jdbc.core.RowCallbackHandler)
                            row -> views.put(row.getString(1), row.getString(2)));
            return new Catalog(Map.copyOf(shapes), Map.copyOf(functions), importedDocumentTables, Map.copyOf(views));
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
