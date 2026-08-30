package com.uten.imp.migration;

import org.flywaydb.core.Flyway;

import java.io.PrintStream;
import java.util.Map;
import java.util.Objects;
import java.util.regex.Pattern;

/**
 * Standalone, migration-only process entry point.
 *
 * <p>This class deliberately does not use Spring Boot. It accepts no command-line
 * overrides, always connects to the same-host {@code uten_imp} database as the
 * {@code uten_migrator} role, validates the immutable migration history, applies
 * pending migrations, and exits. The only accepted secret is supplied by the
 * dedicated systemd environment file.</p>
 */
public final class UtenImpMigrator {

    static final String DATABASE_URL = "jdbc:postgresql://127.0.0.1:5432/uten_imp";
    static final String DATABASE_USER = "uten_migrator";
    static final String PASSWORD_ENV = "UTEN_MIGRATOR_DB_PASSWORD";
    static final String MIGRATION_LOCATION = "classpath:db/migration";

    private static final Pattern REVIEWED_PASSWORD_FORMAT =
            Pattern.compile("[A-Za-z0-9]{20,512}");
    private static final int EXIT_CONFIGURATION = 64;
    private static final int EXIT_MIGRATION_FAILURE = 1;

    private UtenImpMigrator() {
    }

    public static void main(String[] args) {
        int exitCode = run(
                args,
                System.getenv(),
                System.out,
                System.err,
                UtenImpMigrator::newMigrationActions);
        if (exitCode != 0) {
            System.exit(exitCode);
        }
    }

    static int run(
            String[] args,
            Map<String, String> environment,
            PrintStream standardOut,
            PrintStream standardError,
            MigrationActionsFactory actionsFactory) {
        Objects.requireNonNull(args, "args");
        Objects.requireNonNull(environment, "environment");
        Objects.requireNonNull(standardOut, "standardOut");
        Objects.requireNonNull(standardError, "standardError");
        Objects.requireNonNull(actionsFactory, "actionsFactory");

        if (args.length != 0) {
            standardError.println("UTEN_MIGRATION_CONFIGURATION_INVALID: command-line arguments are not supported");
            return EXIT_CONFIGURATION;
        }

        String password = environment.get(PASSWORD_ENV);
        if (password == null || !REVIEWED_PASSWORD_FORMAT.matcher(password).matches()) {
            standardError.println("UTEN_MIGRATION_CONFIGURATION_INVALID: dedicated database credential is missing or invalid");
            return EXIT_CONFIGURATION;
        }

        try {
            MigrationActions actions = actionsFactory.create(password);
            actions.validate();
            standardOut.println("UTEN_MIGRATION_VALIDATE_OK");
            int migrationsExecuted = actions.migrate();
            standardOut.printf("UTEN_MIGRATION_OK migrations_executed=%d%n", migrationsExecuted);
            return 0;
        } catch (Exception | LinkageError exception) {
            // Flyway/JDBC exception text is intentionally not emitted. A driver or
            // wrapper may echo connection properties supplied by its caller.
            standardError.println("UTEN_MIGRATION_FAILED");
            return EXIT_MIGRATION_FAILURE;
        } finally {
            password = null;
        }
    }

    static Flyway configuredFlyway(String password) {
        if (password == null || !REVIEWED_PASSWORD_FORMAT.matcher(password).matches()) {
            throw new IllegalArgumentException("invalid dedicated database credential");
        }
        return Flyway.configure(UtenImpMigrator.class.getClassLoader())
                .dataSource(DATABASE_URL, DATABASE_USER, password)
                .locations(MIGRATION_LOCATION)
                .baselineOnMigrate(false)
                .cleanDisabled(true)
                .outOfOrder(false)
                // The explicit pre-migration validation must permit migrations
                // that this release is about to apply, but it must not inherit
                // Flyway's *:future default. An older release therefore still
                // fails against a database containing newer applied history.
                .ignoreMigrationPatterns("*:pending")
                .validateMigrationNaming(true)
                .callbacks(
                        new AppliedMigrationCompatibilityCallback(),
                        new AuditFreshStartGuardCallback())
                // The explicit validate() call gives operators a distinct gate;
                // keep Flyway's in-migrate validation too so a classpath/history
                // change between both phases still fails closed.
                .validateOnMigrate(true)
                .failOnMissingLocations(true)
                .connectRetries(3)
                .connectRetriesInterval(5)
                .load();
    }

    private static MigrationActions newMigrationActions(String password) {
        Flyway flyway = configuredFlyway(password);
        return new MigrationActions() {
            @Override
            public void validate() {
                flyway.validate();
            }

            @Override
            public int migrate() {
                var result = flyway.migrate();
                if (!result.success) {
                    throw new IllegalStateException("Flyway returned an unsuccessful migration result");
                }
                return result.migrationsExecuted;
            }
        };
    }

    @FunctionalInterface
    interface MigrationActionsFactory {
        MigrationActions create(String password) throws Exception;
    }

    interface MigrationActions {
        void validate() throws Exception;

        int migrate() throws Exception;
    }
}
