package com.uten.imp.businesschain;

import com.uten.imp.config.props.BootstrapProperties;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.security.JwtService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import static org.assertj.core.api.Assertions.assertThat;

/** Two full contexts intentionally disagree in their annotations but reuse one database. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.bootstrap.admin-login=shared-context-first-test", "uten.bootstrap.admin-password=FirstFixturePass-1!",
        "uten.jwt.secret=first-context-isolated-jwt-key-test-only-0123456789", // gitleaks:allow deliberately conflicting synthetic Testcontainers JWT fixture.
        "uten.crypto.pgp-master-key=first-context-isolated-pgp-key-test-only", // gitleaks:allow deliberately conflicting synthetic Testcontainers encryption fixture.
        "uten.crypto.hmac-key=first-context-isolated-hmac-key-test-only"})
class SharedFullChainDatabaseConfigurationEndToEndTest extends SharedFullChainConfigurationAssertions {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Test void firstContextUsesTheDatabaseIdentityAndKeys() { assertSharedConfiguration(); }
}

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.bootstrap.admin-login=shared-context-restart-test", "uten.bootstrap.admin-password=RestartFixturePass-1!",
        "uten.jwt.secret=restart-context-isolated-jwt-key-test-only-0123456789", // gitleaks:allow deliberately conflicting synthetic Testcontainers JWT fixture.
        "uten.crypto.pgp-master-key=restart-context-isolated-pgp-key-test-only", // gitleaks:allow deliberately conflicting synthetic Testcontainers encryption fixture.
        "uten.crypto.hmac-key=restart-context-isolated-hmac-key-test-only"})
class SharedFullChainDatabaseRestartEndToEndTest extends SharedFullChainConfigurationAssertions {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Test void restartedContextReusesIdentityPasswordAndPreviouslyEncryptedData() { assertSharedConfiguration(); }
}

abstract class SharedFullChainConfigurationAssertions {
    private static final ConcurrentHashMap<String, SharedProof> PROOFS = new ConcurrentHashMap<>();
    private static final String PLAINTEXT = "synthetic shared-context encryption fixture";
    @Autowired private JdbcTemplate db;
    @Autowired private BootstrapProperties bootstrap;
    @Autowired private JwtProperties jwt;
    @Autowired private CryptoProperties crypto;
    @Autowired private JwtService jwtService;
    @Autowired private PasswordEncoder passwords;

    final void assertSharedConfiguration() {
        assertThat(bootstrap.getAdminLogin()).isEqualTo(FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        assertThat(bootstrap.getAdminPassword()).isEqualTo(FullChainEndToEndTest.SHARED_ADMIN_PASSWORD);
        assertThat(jwt.getSecret()).isEqualTo(FullChainEndToEndTest.SHARED_JWT_SECRET);
        assertThat(crypto.getPgpMasterKey()).isEqualTo(FullChainEndToEndTest.SHARED_PGP_KEY);
        assertThat(crypto.getHmacKey()).isEqualTo(FullChainEndToEndTest.SHARED_HMAC_KEY);
        var admin = db.queryForMap("""
                SELECT u.id, u.password_hash FROM users u JOIN employees e ON e.id=u.employee_id
                WHERE e.code='ADMIN'
                """);
        UUID adminId = (UUID) admin.get("id");
        String passwordHash = (String) admin.get("password_hash");
        assertThat(passwords.matches(FullChainEndToEndTest.SHARED_ADMIN_PASSWORD, passwordHash)).isTrue();
        assertThat(db.queryForObject("SELECT login_account FROM users WHERE id=?", String.class, adminId))
                .isEqualTo(FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        String database = db.queryForObject("SELECT current_database() || ':' || inet_server_addr() || ':' || inet_server_port()", String.class);
        SharedProof proof = PROOFS.computeIfAbsent(database, ignored -> new SharedProof(adminId, passwordHash,
                db.queryForObject("SELECT pgp_sym_encrypt(?, ?)", byte[].class, PLAINTEXT, crypto.getPgpMasterKey()),
                db.queryForObject("SELECT encode(hmac(?::text, ?::text, 'sha256'), 'hex')", String.class, PLAINTEXT, crypto.getHmacKey()),
                jwtService.issueModeToken(adminId, UUID.randomUUID(), Instant.now().plusSeconds(600))));
        assertThat(adminId).isEqualTo(proof.adminId());
        assertThat(passwordHash).isEqualTo(proof.passwordHash());
        assertThat(db.queryForObject("SELECT pgp_sym_decrypt(?::bytea, ?)", String.class, proof.ciphertext(), crypto.getPgpMasterKey()))
                .isEqualTo(PLAINTEXT);
        assertThat(db.queryForObject("SELECT encode(hmac(?::text, ?::text, 'sha256'), 'hex')", String.class, PLAINTEXT, crypto.getHmacKey()))
                .isEqualTo(proof.hmac());
        assertThat(jwtService.parse(proof.token()).getSubject()).isEqualTo(adminId.toString());
    }

    private record SharedProof(UUID adminId, String passwordHash, byte[] ciphertext, String hmac, String token) { }
}
