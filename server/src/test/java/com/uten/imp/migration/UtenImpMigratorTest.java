package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.Location;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.assertThat;

class UtenImpMigratorTest {

    private static final String TEST_PASSWORD = "a".repeat(64);

    @Test
    void flywayConfigurationIsFixedAndFailClosed() {
        Flyway flyway = UtenImpMigrator.configuredFlyway(TEST_PASSWORD);
        var configuration = flyway.getConfiguration();

        assertThat(configuration.getUrl()).isEqualTo("jdbc:postgresql://127.0.0.1:5432/uten_imp");
        assertThat(configuration.getUser()).isEqualTo("uten_migrator");
        assertThat(configuration.getPassword()).isEqualTo(TEST_PASSWORD);
        assertThat(configuration.getLocations())
                .extracting(Location::getDescriptor)
                .containsExactly("classpath:db/migration");
        assertThat(configuration.isBaselineOnMigrate()).isFalse();
        assertThat(configuration.isCleanDisabled()).isTrue();
        assertThat(configuration.isOutOfOrder()).isFalse();
        assertThat(configuration.getIgnoreMigrationPatterns())
                .extracting(Object::toString)
                .containsExactly("*:pending");
        assertThat(configuration.isValidateMigrationNaming()).isTrue();
        assertThat(configuration.getCallbacks())
                .hasSize(1)
                .allMatch(AppliedMigrationCompatibilityCallback.class::isInstance);
        assertThat(configuration.isValidateOnMigrate()).isTrue();
        assertThat(configuration.isFailOnMissingLocations()).isTrue();
        assertThat(configuration.getConnectRetries()).isEqualTo(3);
        assertThat(configuration.getConnectRetriesInterval()).isEqualTo(5);
    }

    @Test
    void argumentsAreRejectedBeforeTheCredentialOrFactoryIsUsed() {
        CapturedOutput output = new CapturedOutput();
        AtomicBoolean factoryCalled = new AtomicBoolean();

        int exitCode = UtenImpMigrator.run(
                new String[]{"-url=jdbc:postgresql://attacker.invalid/other"},
                Map.of(UtenImpMigrator.PASSWORD_ENV, TEST_PASSWORD),
                output.standardOut(),
                output.standardError(),
                ignored -> {
                    factoryCalled.set(true);
                    throw new AssertionError("factory must not run");
                });

        assertThat(exitCode).isEqualTo(64);
        assertThat(factoryCalled).isFalse();
        assertThat(output.outText()).isEmpty();
        assertThat(output.errText()).contains("command-line arguments are not supported");
        assertThat(output.errText()).doesNotContain(TEST_PASSWORD);
    }

    @Test
    void missingOrUnreviewedCredentialIsRejectedWithoutDisclosure() {
        CapturedOutput missingOutput = new CapturedOutput();
        int missingExitCode = UtenImpMigrator.run(
                new String[0],
                Map.of(),
                missingOutput.standardOut(),
                missingOutput.standardError(),
                ignored -> {
                    throw new AssertionError("factory must not run");
                });
        assertThat(missingExitCode).isEqualTo(64);
        assertThat(missingOutput.outText()).isEmpty();
        assertThat(missingOutput.errText()).contains("credential is missing or invalid");

        for (String candidate : List.of("", "short", "contains-a-dash", "contains whitespace")) {
            CapturedOutput output = new CapturedOutput();
            AtomicBoolean factoryCalled = new AtomicBoolean();

            int exitCode = UtenImpMigrator.run(
                    new String[0],
                    Map.of(UtenImpMigrator.PASSWORD_ENV, candidate),
                    output.standardOut(),
                    output.standardError(),
                    ignored -> {
                        factoryCalled.set(true);
                        throw new AssertionError("factory must not run");
                    });

            assertThat(exitCode).isEqualTo(64);
            assertThat(factoryCalled).isFalse();
            assertThat(output.outText()).isEmpty();
            if (!candidate.isEmpty()) {
                assertThat(output.errText()).doesNotContain(candidate);
            }
        }
    }

    @Test
    void validateRunsBeforeMigrateAndSuccessOutputIsSecretFree() {
        CapturedOutput output = new CapturedOutput();
        List<String> calls = new ArrayList<>();

        int exitCode = UtenImpMigrator.run(
                new String[0],
                Map.of(UtenImpMigrator.PASSWORD_ENV, TEST_PASSWORD),
                output.standardOut(),
                output.standardError(),
                suppliedPassword -> {
                    assertThat(suppliedPassword).isEqualTo(TEST_PASSWORD);
                    return new UtenImpMigrator.MigrationActions() {
                        @Override
                        public void validate() {
                            calls.add("validate");
                        }

                        @Override
                        public int migrate() {
                            calls.add("migrate");
                            return 2;
                        }
                    };
                });

        assertThat(exitCode).isZero();
        assertThat(calls).containsExactly("validate", "migrate");
        assertThat(output.outText())
                .contains("UTEN_MIGRATION_VALIDATE_OK")
                .contains("UTEN_MIGRATION_OK migrations_executed=2")
                .doesNotContain(TEST_PASSWORD);
        assertThat(output.errText()).isEmpty();
    }

    @Test
    void failureDetailsAreRedactedEvenIfAnExceptionContainsTheCredential() {
        CapturedOutput output = new CapturedOutput();

        int exitCode = UtenImpMigrator.run(
                new String[0],
                Map.of(UtenImpMigrator.PASSWORD_ENV, TEST_PASSWORD),
                output.standardOut(),
                output.standardError(),
                ignored -> new UtenImpMigrator.MigrationActions() {
                    @Override
                    public void validate() {
                        throw new IllegalStateException("driver echoed password=" + TEST_PASSWORD);
                    }

                    @Override
                    public int migrate() {
                        throw new AssertionError("migrate must not run after validation failure");
                    }
                });

        assertThat(exitCode).isEqualTo(1);
        assertThat(output.outText()).isEmpty();
        assertThat(output.errText()).isEqualTo("UTEN_MIGRATION_FAILED" + System.lineSeparator());
        assertThat(output.errText()).doesNotContain(TEST_PASSWORD);
    }

    @Test
    void migrateFailureOccursOnlyAfterValidationAndDoesNotClaimSuccess() {
        CapturedOutput output = new CapturedOutput();
        List<String> calls = new ArrayList<>();

        int exitCode = UtenImpMigrator.run(
                new String[0],
                Map.of(UtenImpMigrator.PASSWORD_ENV, TEST_PASSWORD),
                output.standardOut(),
                output.standardError(),
                ignored -> new UtenImpMigrator.MigrationActions() {
                    @Override
                    public void validate() {
                        calls.add("validate");
                    }

                    @Override
                    public int migrate() {
                        calls.add("migrate");
                        throw new IllegalStateException("secret=" + TEST_PASSWORD);
                    }
                });

        assertThat(exitCode).isEqualTo(1);
        assertThat(calls).containsExactly("validate", "migrate");
        assertThat(output.outText())
                .contains("UTEN_MIGRATION_VALIDATE_OK")
                .doesNotContain("UTEN_MIGRATION_OK")
                .doesNotContain(TEST_PASSWORD);
        assertThat(output.errText())
                .isEqualTo("UTEN_MIGRATION_FAILED" + System.lineSeparator())
                .doesNotContain(TEST_PASSWORD);
    }

    private static final class CapturedOutput {
        private final ByteArrayOutputStream out = new ByteArrayOutputStream();
        private final ByteArrayOutputStream err = new ByteArrayOutputStream();
        private final PrintStream standardOut = new PrintStream(out, true, StandardCharsets.UTF_8);
        private final PrintStream standardError = new PrintStream(err, true, StandardCharsets.UTF_8);

        PrintStream standardOut() {
            return standardOut;
        }

        PrintStream standardError() {
            return standardError;
        }

        String outText() {
            return out.toString(StandardCharsets.UTF_8);
        }

        String errText() {
            return err.toString(StandardCharsets.UTF_8);
        }
    }
}
