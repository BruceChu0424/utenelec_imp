package com.uten.imp.support;

import org.flywaydb.core.Flyway;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.function.Consumer;
import java.util.function.Supplier;

/**
 * Real migration fixtures: one fresh, fully migrated template per test JVM, with
 * a private database clone for every lease. No template survives a JVM/CI run.
 *
 * <p>Use {@link #openDatabase(String)} for tests of the current business schema.
 * Close the lease after JDBC connections and Spring contexts are closed. Closing
 * a lease drops only that clone; only the JVM shutdown hook owns the container.
 * Tests of empty/older/partial migrations or cluster-wide roles must continue to
 * own their dedicated containers, using the compatibility helpers if useful.
 * The shared template is never exposed or opened by fixture consumers.
 */
public final class MigratedSchemaBaseline {
    private MigratedSchemaBaseline() { }

    private static final class Shared {
        private static final TemplatePool POOL = new TemplatePool(
                () -> new PostgreSQLContainer<>("postgres:16-alpine")
                        .withDatabaseName("uten_migrated_template")
                        .withReuse(false),
                MigratedSchemaBaseline::migrate);

        static {
            Runtime.getRuntime().addShutdownHook(new Thread(POOL::close, "migrated-schema-cleanup"));
        }
    }

    /** A new isolated current-schema database; labels need not be globally unique. */
    public static ScopedDatabase openDatabase(String label) throws SQLException {
        return Shared.POOL.open(label);
    }

    static int processMigrationCount() {
        return Shared.POOL.migrationCount();
    }

    /** A database lease deliberately has no container/start/stop API. */
    public static final class ScopedDatabase implements AutoCloseable {
        private final TemplatePool owner;
        private final String name;
        private final String jdbcUrl;
        private final String username;
        private final String password;
        private boolean closed;

        private ScopedDatabase(TemplatePool owner, PostgreSQLContainer<?> template, String name) {
            this.owner = owner;
            this.name = name;
            this.jdbcUrl = jdbcUrlFor(template, name);
            this.username = template.getUsername();
            this.password = template.getPassword();
        }

        public String getJdbcUrl() {
            synchronized (owner) {
                owner.requireOpen(this);
                return jdbcUrl;
            }
        }

        public String getUsername() { return username; }
        public String getPassword() { return password; }

        public Connection openConnection() throws SQLException {
            synchronized (owner) {
                owner.requireOpen(this);
                return DriverManager.getConnection(jdbcUrl, username, password);
            }
        }

        @Override
        public void close() throws SQLException {
            owner.release(this);
        }
    }

    /** Package visibility allows lifecycle/failure tests without exposing ownership to consumers. */
    static final class TemplatePool implements AutoCloseable {
        private final Supplier<PostgreSQLContainer<?>> factory;
        private final Consumer<PostgreSQLContainer<?>> migration;
        private final Set<ScopedDatabase> leases = new HashSet<>();
        private PostgreSQLContainer<?> template;
        private boolean closed;
        private int migrations;

        TemplatePool(Supplier<PostgreSQLContainer<?>> factory, Consumer<PostgreSQLContainer<?>> migration) {
            this.factory = factory;
            this.migration = migration;
        }

        synchronized ScopedDatabase open(String label) throws SQLException {
            validateLabel(label);
            if (closed) throw new IllegalStateException("Migrated template pool is closed");
            if (template == null) {
                PostgreSQLContainer<?> candidate = factory.get();
                try {
                    candidate.start();
                    migration.accept(candidate);
                    migrations++;
                    template = candidate;
                } catch (RuntimeException | Error failure) {
                    stopAfterFailure(candidate, failure);
                    throw failure;
                }
            }
            // Serialize template copies; consumers cannot hold template connections.
            String name = label + "_" + UUID.randomUUID().toString().replace("-", "");
            createClone(template, name);
            ScopedDatabase lease = new ScopedDatabase(this, template, name);
            leases.add(lease);
            return lease;
        }

        private void requireOpen(ScopedDatabase lease) {
            if (closed || lease.closed) throw new IllegalStateException("Migrated database lease is closed");
        }

        private synchronized void release(ScopedDatabase lease) throws SQLException {
            if (lease.closed) return;
            dropClone(template, lease.name);
            lease.closed = true;
            leases.remove(lease);
        }

        synchronized int migrationCount() { return migrations; }

        @Override
        public synchronized void close() {
            if (closed) return;
            closed = true;
            leases.forEach(lease -> lease.closed = true);
            leases.clear();
            if (template != null) template.stop();
        }
    }

    private static void validateLabel(String label) {
        // 30 + '_' + 32 hex chars stays within PostgreSQL's 63-byte identifier limit.
        if (label == null || !label.matches("[a-z][a-z0-9_]{0,29}")) {
            throw new IllegalArgumentException("Database label must contain 1-30 lowercase identifier characters");
        }
    }

    private static void validateDatabaseName(String name) {
        if (name == null || !name.matches("[a-z][a-z0-9_]{0,62}")) {
            throw new IllegalArgumentException("Invalid fixture database name");
        }
    }

    private static void migrate(PostgreSQLContainer<?> postgres) {
        Flyway.configure()
                .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    /** Compatibility API: the caller owns this dedicated container and must stop it. */
    public static PostgreSQLContainer<?> startMigratedContainer(String databaseName) {
        validateDatabaseName(databaseName);
        PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName(databaseName).withReuse(false);
        try {
            postgres.start();
            migrate(postgres);
            return postgres;
        } catch (RuntimeException | Error failure) {
            stopAfterFailure(postgres, failure);
            throw failure;
        }
    }

    /** Compatibility API for migration-specific templates; the caller owns the container/clones. */
    public static Connection cloneConnection(
            PostgreSQLContainer<?> template, String cloneDatabaseName) throws SQLException {
        createClone(template, cloneDatabaseName);
        try {
            return DriverManager.getConnection(jdbcUrlFor(template, cloneDatabaseName),
                    template.getUsername(), template.getPassword());
        } catch (SQLException failure) {
            try {
                dropClone(template, cloneDatabaseName);
            } catch (SQLException cleanupFailure) {
                failure.addSuppressed(cleanupFailure);
            }
            throw failure;
        }
    }

    private static void createClone(PostgreSQLContainer<?> template, String name) throws SQLException {
        validateDatabaseName(name);
        if (name.equals(template.getDatabaseName())) throw new IllegalArgumentException("Cannot clone over the template");
        execute(template, "createdb", "-U", template.getUsername(), "-T", template.getDatabaseName(), name);
    }

    private static void dropClone(PostgreSQLContainer<?> template, String name) throws SQLException {
        execute(template, "dropdb", "-U", template.getUsername(), "--if-exists", "--force", name);
    }

    private static void execute(PostgreSQLContainer<?> template, String... command) throws SQLException {
        try {
            var result = template.execInContainer(command);
            if (result.getExitCode() != 0) {
                throw new SQLException(command[0] + " failed (exit " + result.getExitCode() + "): " + result.getStderr());
            }
        } catch (InterruptedException failure) {
            Thread.currentThread().interrupt();
            throw new SQLException("Fixture database operation interrupted", failure);
        } catch (IOException failure) {
            throw new SQLException("Fixture database operation failed", failure);
        }
    }

    private static void stopAfterFailure(PostgreSQLContainer<?> postgres, Throwable failure) {
        try {
            postgres.stop();
        } catch (RuntimeException | Error cleanupFailure) {
            failure.addSuppressed(cleanupFailure);
        }
    }

    /** Same server and JDBC parameters, with a different database name. */
    public static String jdbcUrlFor(PostgreSQLContainer<?> container, String databaseName) {
        validateDatabaseName(databaseName);
        String url = container.getJdbcUrl();
        int queryStart = url.indexOf('?');
        String baseUrl = queryStart < 0 ? url : url.substring(0, queryStart);
        int lastSlash = baseUrl.lastIndexOf('/');
        String rebuiltUrl = baseUrl.substring(0, lastSlash + 1) + databaseName;
        return queryStart < 0 ? rebuiltUrl : rebuiltUrl + url.substring(queryStart);
    }
}
