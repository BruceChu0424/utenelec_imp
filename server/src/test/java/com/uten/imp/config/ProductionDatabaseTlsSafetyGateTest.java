package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.mock.env.MockEnvironment;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProductionDatabaseTlsSafetyGateTest {

    private static final String TRUSTED_REMOTE_URL =
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp"
                    + "?sslmode=verify-full"
                    + "&sslrootcert=/etc/uten-imp/tls/company-root-ca.crt";

    @ParameterizedTest
    @ValueSource(strings = {
            "jdbc:postgresql://localhost:5432/uten_imp",
            "jdbc:postgresql://localhost.:5432/uten_imp",
            "jdbc:postgresql://127.0.0.1:5432/uten_imp",
            "jdbc:postgresql://127.42.1.9:5432/uten_imp",
            "jdbc:postgresql://[::1]:5432/uten_imp"
    })
    void productionAllowsExplicitLoopbackWithoutTls(String url) {
        assertDoesNotThrow(() -> gate("prod", url).validate());
    }

    @Test
    void productionAllowsRemotePostgresWithVerifyFullAndExplicitRootCertificate() {
        assertDoesNotThrow(() -> gate("prod", TRUSTED_REMOTE_URL).validate());
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=require"
                    + "&sslrootcert=/etc/uten-imp/tls/company-root-ca.crt",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full"
                    + "&sslrootcert=company-root-ca.crt",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full"
                    + "&sslrootcert=/etc/CHANGE_ME.crt",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full"
                    + "&sslrootcert=%20/etc/root.crt",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=require"
                    + "&sslmode=verify-full&sslrootcert=/etc/root.crt",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full"
                    + "&sslrootcert=/etc/root.crt"
                    + "&sslfactory=org.postgresql.ssl.NonValidatingFactory",
            "jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full"
                    + "&sslrootcert=/etc/root.crt"
                    + "&sslhostnameverifier=com.example.AcceptAllVerifier"
    })
    void productionRejectsRemotePostgresWithoutAuthenticatedTls(String url) {
        assertThrows(IllegalStateException.class, () -> gate("prod", url).validate());
    }

    @Test
    void oneRemoteHostInMultiHostUrlRequiresAuthenticatedTls() {
        String url = "jdbc:postgresql://127.0.0.1:5432,pg-primary.imp.internal:5432/uten_imp";

        assertThrows(IllegalStateException.class, () -> gate("prod", url).validate());
    }

    @ParameterizedTest
    @ValueSource(strings = {"dev", "test", "local", "internal-test"})
    void nonProductionProfilesRemainUnrestricted(String profile) {
        assertDoesNotThrow(() -> gate(
                profile,
                "jdbc:postgresql://database.example.test:5432/uten_imp").validate());
    }

    @Test
    void productionProfileAmongMultipleProfilesEnablesGate() {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles("dev", "prod");
        environment.setProperty("spring.datasource.url",
                "jdbc:postgresql://database.example.test:5432/uten_imp");

        assertThrows(IllegalStateException.class,
                () -> new ProductionDatabaseTlsSafetyGate(environment).validate());
    }

    @Test
    void cloudRequiresAuthenticatedTlsForBothExplicitPools() {
        MockEnvironment environment = cloudEnvironment();
        environment.setProperty("app.cloud.db.replica.url",
                "jdbc:postgresql://127.0.0.1:5432/uten_imp");

        assertThrows(IllegalStateException.class,
                () -> new ProductionDatabaseTlsSafetyGate(environment).validate());
    }

    @Test
    void cloudAcceptsBothPoolsWithVerifyFullAndExplicitRootCertificate() {
        MockEnvironment environment = cloudEnvironment();

        assertDoesNotThrow(
                () -> new ProductionDatabaseTlsSafetyGate(environment).validate());
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "",
            "jdbc:mysql://database.example.test:3306/uten_imp",
            "jdbc:postgresql://",
            "jdbc:postgresql://localhost:/uten_imp"
    })
    void productionRejectsMissingOrMalformedPostgresUrl(String url) {
        assertThrows(IllegalStateException.class, () -> gate("prod", url).validate());
    }

    private static ProductionDatabaseTlsSafetyGate gate(String profile, String url) {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles(profile);
        environment.setProperty("spring.datasource.url", url);
        return new ProductionDatabaseTlsSafetyGate(environment);
    }

    private static MockEnvironment cloudEnvironment() {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles("cloud");
        environment.setProperty("spring.datasource.url",
                "jdbc:postgresql://localhost:5432/uten_imp");
        environment.setProperty("app.cloud.db.primary.url", TRUSTED_REMOTE_URL);
        environment.setProperty("app.cloud.db.replica.url",
                TRUSTED_REMOTE_URL.replace("pg-primary", "pg-standby"));
        return environment;
    }
}
