package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.TokenIssuer;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.aopalliance.intercept.MethodInterceptor;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.aop.framework.Advised;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.time.Duration;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Callable;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** Full Spring/JPA/PostgreSQL transactions: no substituted repository locks or service results. */
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@Import(RemoteMfaConcurrencyPostgresTest.LockProbeConfiguration.class)
class RemoteMfaConcurrencyPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired TokenIssuer tokens;

    @Test
    void disableAndRefreshUseCompatibleLockOrderAndRevokeEveryIssuedCredential() throws Exception {
        FactorFixture fixture = factor(true);
        Race outcome = raceWithCredential(fixture, action(fixture, Action.DISABLE), false);
        assertEquals(200, outcome.action().getResponse().getStatus(), body(outcome.action()));
        assertAllCredentialsRevoked(fixture.employee(), outcome.replacement());
        assertFalse(enabled(fixture));
    }

    @Test
    void administratorResetAndRefreshRevokeEvenCredentialsIssuedDuringTheWait() throws Exception {
        FactorFixture fixture = factor(true);
        Race outcome = raceWithCredential(fixture, action(fixture, Action.RESET), false);
        assertEquals(200, outcome.action().getResponse().getStatus(), body(outcome.action()));
        assertAllCredentialsRevoked(fixture.employee(), outcome.replacement());
        assertFalse(enabled(fixture));
    }

    @Test
    void logoutWinningDuringDisableWaitRejectsTheStaleSessionAndRollsBackOtpConsumption() throws Exception {
        FactorFixture fixture = factor(true);
        long before = acceptedStep(fixture);
        Race outcome = raceWithCredential(fixture, action(fixture, Action.DISABLE), true);
        assertEquals(401, outcome.action().getResponse().getStatus(), body(outcome.action()));
        assertTrue(enabled(fixture), "A session ended by logout cannot remove the factor");
        assertEquals(before, acceptedStep(fixture), "Failed final session validation must roll back the consumed OTP");
        assertEquals(401, me(fixture.employee().accessToken()).getResponse().getStatus());
    }

    @Test
    void confirmationWaitingForRefreshUsesTheSameSessionAndCannotReplayTheCode() throws Exception {
        FactorFixture fixture = factor(false);
        Race outcome = raceWithCredential(fixture, action(fixture, Action.CONFIRM), false);
        assertEquals(200, outcome.action().getResponse().getStatus(), body(outcome.action()));
        assertTrue(enabled(fixture));
        assertEquals(200, me(outcome.replacement().accessToken()).getResponse().getStatus());
        var verified = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/auth/mfa")
                .header("Authorization", "Bearer " + outcome.replacement().accessToken())).andReturn();
        assertTrue(json(verified).path("sessionVerified").asBoolean());
        var replay = mvc.perform(json(post("/api/auth/mfa/verify"), Map.of("otpCode", code(fixture.secret())),
                outcome.replacement().accessToken())).andReturn();
        assertEquals(422, replay.getResponse().getStatus(), body(replay));
        assertEquals("MFA_INVALID", json(replay).path("code").asText());
    }

    @Test
    void actualPasswordEntityFlushAndRefreshDoNotInvertUserAndTokenLocks() throws Exception {
        FactorFixture fixture = factor(true);
        var password = json(post("/api/auth/change-password"),
                Map.of("oldPassword", EMPLOYEE_PASSWORD, "newPassword", "ConcurrentOwn-4!"), fixture.employee().accessToken());
        Race outcome = raceWithCredential(fixture, password, false);
        assertEquals(200, outcome.action().getResponse().getStatus(), body(outcome.action()));
        assertTrue(enabled(fixture));
        assertEquals(401, me(outcome.replacement().accessToken()).getResponse().getStatus());
        var expired = mvc.perform(json(post("/api/auth/refresh"),
                Map.of("refreshToken", outcome.replacement().refreshToken()), null)).andReturn();
        assertEquals(401, expired.getResponse().getStatus(), body(expired));
        String changedToken = json(outcome.action()).path("accessToken").asText();
        assertEquals(200, me(changedToken).getResponse().getStatus());
        var verified = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/auth/mfa")
                .header("Authorization", "Bearer " + changedToken)).andReturn();
        assertTrue(json(verified).path("sessionVerified").asBoolean());
    }

    @Test
    void remoteRevocationWaitsForRefreshThenInvalidatesItsNewCredentials() throws Exception {
        FactorFixture fixture = factor(true);
        jdbc.update("UPDATE users SET remote_access=true WHERE id=?::uuid", fixture.employee().userId());
        Race outcome = raceWithCredential(fixture, remoteRevocation(fixture), false);
        assertEquals(200, outcome.action().getResponse().getStatus(), body(outcome.action()));
        assertAllCredentialsRevoked(fixture.employee(), outcome.replacement());
        assertFalse(jdbc.queryForObject("SELECT remote_access FROM users WHERE id=?::uuid", Boolean.class, fixture.employee().userId()));
    }

    @Test
    void accountMutationAheadOfRefreshBlocksBeforeTokenLockAndReadsCommittedRevocation() throws Exception {
        FactorFixture fixture = factor(true);
        jdbc.update("UPDATE users SET remote_access=true WHERE id=?::uuid", fixture.employee().userId());
        var revokeRequest = remoteRevocation(fixture);
        var accountGate = new LockGate("findByIdForUpdate");
        var identityGate = new LockGate("findIdentityByTokenHash");
        try (var pool = Executors.newFixedThreadPool(3)) {
            var revoked = pool.submit(() -> withGate(accountGate, () -> mvc.perform(revokeRequest).andReturn()));
            assertTrue(accountGate.locked.await(10, TimeUnit.SECONDS));
            var refreshed = pool.submit(() -> withGate(identityGate, () -> {
                try { tokens.refresh(fixture.employee().refreshToken()); return null; }
                catch (ApiException denied) { return denied.getCode(); }
            }));
            try {
                assertTrue(identityGate.locked.await(10, TimeUnit.SECONDS));
                identityGate.release.countDown();
                awaitDatabaseBlocker(accountGate.pid.get(), "users");
                // While refresh waits on U, real logout must still acquire T and S and commit.
                // An early token entity/lock in refresh would block this operation or use stale data.
                pool.submit(() -> tokens.logout(fixture.employee().refreshToken())).get(10, TimeUnit.SECONDS);
            } finally {
                identityGate.release.countDown(); accountGate.release.countDown();
            }
            var result = revoked.get(20, TimeUnit.SECONDS);
            assertEquals(200, result.getResponse().getStatus(), body(result));
            assertEquals(ErrorCode.UNAUTHORIZED, refreshed.get(20, TimeUnit.SECONDS));
            assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM auth_sessions WHERE user_id=?::uuid AND revoked_at IS NULL",
                    Integer.class, fixture.employee().userId()));
        } finally { identityGate.release.countDown(); accountGate.release.countDown(); }
    }

    enum Action { DISABLE, RESET, CONFIRM }

    @ParameterizedTest
    @EnumSource(Action.class)
    void passwordChangeSerializesWithFactorManagementWithoutRestoringStaleProof(Action action) throws Exception {
        FactorFixture fixture = factor(action != Action.CONFIRM);
        var actionRequest = action(fixture, action);
        var gate = new LockGate("findByIdForUpdate");
        try (var pool = Executors.newFixedThreadPool(2)) {
            var changed = pool.submit(() -> withGate(gate, () ->
                    changePassword(fixture.employee().accessToken(), EMPLOYEE_PASSWORD, "ConcurrentOwn-4!")));
            assertTrue(gate.locked.await(10, TimeUnit.SECONDS));
            var managed = pool.submit(() -> mvc.perform(actionRequest).andReturn());
            try { awaitDatabaseBlocker(gate.pid.get(), "users"); }
            finally { gate.release.countDown(); }
            var replacement = changed.get(20, TimeUnit.SECONDS);
            var result = managed.get(20, TimeUnit.SECONDS);
            if (action == Action.RESET) {
                assertEquals(200, result.getResponse().getStatus(), body(result));
                assertFalse(enabled(fixture));
                assertEquals(401, me(replacement.path("accessToken").asText()).getResponse().getStatus());
                assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM auth_sessions WHERE user_id=?::uuid AND mfa_verified_at IS NOT NULL",
                        Integer.class, fixture.employee().userId()));
            } else {
                assertEquals(401, result.getResponse().getStatus(), body(result));
                assertEquals(action == Action.DISABLE, enabled(fixture));
                assertEquals(200, me(replacement.path("accessToken").asText()).getResponse().getStatus());
                var status = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/auth/mfa")
                        .header("Authorization", "Bearer " + replacement.path("accessToken").asText())).andReturn();
                assertEquals(action == Action.DISABLE, json(status).path("sessionVerified").asBoolean());
                if (action == Action.CONFIRM) {
                    var stalePending = mvc.perform(json(post("/api/auth/mfa/confirm"), Map.of("otpCode", code(fixture.secret())),
                            replacement.path("accessToken").asText())).andReturn();
                    assertEquals("MFA_ENROLLMENT_EXPIRED", json(stalePending).path("code").asText());
                }
            }
        } finally { gate.release.countDown(); }
    }

    @Test
    void invalidDisableCodeCommitsFailureWithoutRevokingCredentials() throws Exception {
        FactorFixture fixture = factor(true);
        var badCode = json(post("/api/auth/mfa/disable"), Map.of("otpCode", "invalid"), fixture.employee().accessToken())
                .header("X-Uten-Step-Up", stepUp(fixture.employee().accessToken(), EMPLOYEE_PASSWORD));
        var denied = mvc.perform(badCode).andReturn();
        assertEquals(422, denied.getResponse().getStatus(), body(denied));
        assertEquals("MFA_INVALID", json(denied).path("code").asText());
        assertEquals(1, jdbc.queryForObject("SELECT failed_attempts FROM staff_mfa WHERE user_id=?::uuid",
                Integer.class, fixture.employee().userId()));
        assertTrue(enabled(fixture));
        assertEquals(200, me(tokens.refresh(fixture.employee().refreshToken()).accessToken()).getResponse().getStatus());
    }

    private record FactorFixture(Employee employee, String admin, String secret) {}
    private record Race(TokenResponse replacement, MvcResult action) {}

    private FactorFixture factor(boolean confirm) throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        var enrollment = mvc.perform(json(post("/api/auth/mfa/enrollment"), Map.of(), employee.accessToken())
                .header("X-Uten-Step-Up", stepUp(employee.accessToken(), EMPLOYEE_PASSWORD))).andReturn();
        assertEquals(200, enrollment.getResponse().getStatus());
        String secret = json(enrollment).path("secret").asText();
        if (confirm) {
            var result = mvc.perform(json(post("/api/auth/mfa/confirm"), Map.of("otpCode", code(secret)), employee.accessToken())).andReturn();
            assertEquals(200, result.getResponse().getStatus(), body(result));
            clock.advance(Duration.ofSeconds(30));
        }
        return new FactorFixture(employee, admin, secret);
    }

    private MockHttpServletRequestBuilder action(FactorFixture fixture, Action action) throws Exception {
        if (action == Action.RESET) return json(post("/api/auth/mfa/users/" + fixture.employee().userId() + "/reset"),
                Map.of("reason", "Concurrent device recovery"), fixture.admin())
                .header("X-Uten-Step-Up", stepUp(fixture.admin(), ADMIN_PASSWORD));
        var request = json(post("/api/auth/mfa/" + (action == Action.DISABLE ? "disable" : "confirm")),
                Map.of("otpCode", code(fixture.secret())), fixture.employee().accessToken());
        if (action == Action.DISABLE) request.header("X-Uten-Step-Up", stepUp(fixture.employee().accessToken(), EMPLOYEE_PASSWORD));
        return request;
    }

    private MockHttpServletRequestBuilder remoteRevocation(FactorFixture fixture) throws Exception {
        return json(put("/api/admin/users/" + fixture.employee().userId() + "/remote-access"),
                Map.of("remoteAccess", false), fixture.admin())
                .header("X-Uten-Step-Up", stepUp(fixture.admin(), ADMIN_PASSWORD));
    }

    private Race raceWithCredential(FactorFixture fixture, MockHttpServletRequestBuilder action,
                                    boolean logout) throws Exception {
        var gate = new LockGate("findAndLockByTokenHash");
        try (var pool = Executors.newFixedThreadPool(2)) {
            var credential = pool.submit(() -> withGate(gate, () -> {
                if (logout) { tokens.logout(fixture.employee().refreshToken()); return null; }
                return tokens.refresh(fixture.employee().refreshToken());
            }));
            assertTrue(gate.locked.await(10, TimeUnit.SECONDS));
            var managed = pool.submit(() -> mvc.perform(action).andReturn());
            // Old refresh held only T here; corrected refresh has already acquired U then T.
            // Observe the actual wait; the fixture never pre-acquires either production lock.
            try { awaitDatabaseBlocker(gate.pid.get(), logout ? "refresh_tokens" : "users|refresh_tokens"); }
            finally { gate.release.countDown(); }
            return new Race(credential.get(20, TimeUnit.SECONDS), managed.get(20, TimeUnit.SECONDS));
        } finally { gate.release.countDown(); }
    }

    private boolean enabled(FactorFixture fixture) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT enabled_at IS NOT NULL FROM staff_mfa WHERE user_id=?::uuid",
                Boolean.class, fixture.employee().userId()));
    }

    private long acceptedStep(FactorFixture fixture) {
        return jdbc.queryForObject("SELECT last_accepted_step FROM staff_mfa WHERE user_id=?::uuid", Long.class, fixture.employee().userId());
    }

    private void assertAllCredentialsRevoked(Employee employee, TokenResponse replacement) throws Exception {
        assertEquals(401, me(employee.accessToken()).getResponse().getStatus());
        assertEquals(401, me(replacement.accessToken()).getResponse().getStatus());
        var expired = mvc.perform(json(post("/api/auth/refresh"), Map.of("refreshToken", replacement.refreshToken()), null)).andReturn();
        assertEquals(401, expired.getResponse().getStatus(), body(expired));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM auth_sessions WHERE user_id=?::uuid AND revoked_at IS NULL",
                Integer.class, employee.userId()));
    }

    private void awaitDatabaseBlocker(int blocker, String relation) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        while (System.nanoTime() < deadline) {
            if (Boolean.TRUE.equals(jdbc.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM pg_stat_activity
                    WHERE ? = ANY(pg_blocking_pids(pid)) AND lower(query) ~ ?)
                    """, Boolean.class, blocker, relation))) return;
            Thread.sleep(20);
        }
        fail("The real competing transaction never waited on " + relation + " owned by backend " + blocker);
    }

    private static void await(CountDownLatch latch) {
        try { if (!latch.await(15, TimeUnit.SECONDS)) throw new IllegalStateException("Concurrency fixture timed out"); }
        catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IllegalStateException(failure); }
    }

    private static final ThreadLocal<LockGate> CURRENT_GATE = new ThreadLocal<>();

    private static final class LockGate {
        final String method;
        final CountDownLatch locked = new CountDownLatch(1), release = new CountDownLatch(1);
        final AtomicInteger pid = new AtomicInteger();
        final AtomicBoolean used = new AtomicBoolean();
        LockGate(String method) { this.method = method; }
    }

    private static <T> T withGate(LockGate gate, Callable<T> action) throws Exception {
        CURRENT_GATE.set(gate);
        try { return action.call(); }
        finally { CURRENT_GATE.remove(); }
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class LockProbeConfiguration {
        @Bean
        static BeanPostProcessor actualRepositoryLockProbe(ObjectProvider<JdbcTemplate> jdbc) {
            return new BeanPostProcessor() {
                @Override public Object postProcessAfterInitialization(Object bean, String name) {
                    if ((bean instanceof RefreshTokenRepository || bean instanceof UserAccountRepository) && bean instanceof Advised proxy) {
                        proxy.addAdvice(0, (MethodInterceptor) invocation -> {
                            Object result = invocation.proceed(); // Real Spring transaction + Hibernate SQL + real lock.
                            LockGate gate = CURRENT_GATE.get();
                            if (gate != null && gate.method.equals(invocation.getMethod().getName()) && gate.used.compareAndSet(false, true)) {
                                assertTrue(org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive());
                                gate.pid.set(jdbc.getObject().queryForObject("SELECT pg_backend_pid()", Integer.class));
                                gate.locked.countDown();
                                await(gate.release);
                            }
                            return result;
                        });
                    }
                    return bean;
                }
            };
        }
    }

    private String code(String secret) throws Exception {
        var decoded = new java.io.ByteArrayOutputStream();
        int bits = 0, buffer = 0;
        for (char character : secret.toCharArray()) {
            int digit = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".indexOf(character);
            if (digit < 0) throw new IllegalArgumentException("Invalid fixture secret");
            buffer = (buffer << 5) | digit; bits += 5;
            if (bits >= 8) { bits -= 8; decoded.write((buffer >> bits) & 255); }
        }
        var mac = javax.crypto.Mac.getInstance("HmacSHA1");
        mac.init(new javax.crypto.spec.SecretKeySpec(decoded.toByteArray(), "HmacSHA1"));
        byte[] digest = mac.doFinal(java.nio.ByteBuffer.allocate(8).putLong(clock.instant().getEpochSecond() / 30).array());
        int offset = digest[digest.length - 1] & 15;
        int binary = ((digest[offset] & 127) << 24) | ((digest[offset + 1] & 255) << 16)
                | ((digest[offset + 2] & 255) << 8) | (digest[offset + 3] & 255);
        return String.format(java.util.Locale.ROOT, "%06d", binary % 1_000_000);
    }
}
