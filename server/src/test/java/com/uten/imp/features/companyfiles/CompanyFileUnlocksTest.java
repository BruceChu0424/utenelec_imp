package com.uten.imp.features.companyfiles;

import static org.assertj.core.api.Assertions.*;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;

import org.junit.jupiter.api.Test;

import java.time.*;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.*;

class CompanyFileUnlocksTest {
    @Test
    void extensionChangesCannotTurnScannedTextIntoExecutableOrShortcutDownloads() {
        for (String renamed :
                java.util.List.of(
                        "template.cmd",
                        "template.bat",
                        "template.url",
                        "template",
                        "template.txt.exe",
                        ".cmd"))
            assertCode(
                    ErrorCode.VALIDATION_FAILED,
                    () -> CompanyFileService.requireSameFileExtension("source.txt", renamed));
        assertCode(
                ErrorCode.VALIDATION_FAILED,
                () -> CompanyFileService.requireSameFileExtension("source.txt", "reserved.exe"));
        assertThatCode(
                        () ->
                                CompanyFileService.requireSameFileExtension(
                                        "source.txt", "renamed.TXT"))
                .doesNotThrowAnyException();
        assertThatCode(() -> CompanyFileService.requireSameFileExtension(".txt", "visible.txt"))
                .doesNotThrowAnyException();
    }

    @Test
    void passwordCreationHasTheSameMinimumAndUtf8BoundaryAsTheEditor() {
        CompanyFileUnlocks unlocks = new CompanyFileUnlocks();
        assertThat(unlocks.hash(null)).isNull();
        for (String password :
                java.util.List.of("", " ".repeat(8), "1234567", "密码太短", "😀".repeat(7)))
            assertCode(ErrorCode.VALIDATION_FAILED, () -> unlocks.hash(password));
        assertThat(unlocks.hash("12345678")).startsWith("$2a$");
        assertThat(unlocks.hash("中".repeat(24))).startsWith("$2a$");
        assertCode(ErrorCode.VALIDATION_FAILED, () -> unlocks.hash("中".repeat(25)));
        assertThat(unlocks.hash("😀".repeat(18))).startsWith("$2a$");
        assertCode(ErrorCode.VALIDATION_FAILED, () -> unlocks.hash("😀".repeat(19)));
    }

    @Test
    void capabilityBindsUserSessionRevisionAndFifteenMinuteExpiry() {
        MutableClock clock = new MutableClock();
        CompanyFileUnlocks unlocks = new CompanyFileUnlocks(clock);
        UUID id = UUID.randomUUID();
        AuthUser user = user(UUID.randomUUID(), UUID.randomUUID());
        String hash = unlocks.hash("公司资料库访问密码");
        assertThat(hash).startsWith("$2a$").doesNotContain("公司资料库访问密码");
        Instant expires = unlocks.unlock(id, 7, hash, "公司资料库访问密码", user);
        assertThat(expires).isEqualTo(clock.instant().plusSeconds(900));
        assertThat(unlocks.isUnlocked(id, 7, user)).isTrue();
        assertThat(unlocks.isUnlocked(id, 8, user)).isFalse();
        unlocks.unlock(id, 7, hash, "公司资料库访问密码", user);
        assertThat(unlocks.isUnlocked(id, 7, user(user.getId(), UUID.randomUUID()))).isFalse();
        assertThat(unlocks.isUnlocked(id, 7, user(UUID.randomUUID(), user.getSessionId())))
                .isFalse();
        clock.now = expires;
        assertThat(unlocks.isUnlocked(id, 7, user)).isFalse();
    }

    @Test
    void fifthFailureIsCountedAndNextAttemptIsRateLimitedAcrossSessions() {
        MutableClock clock = new MutableClock();
        CompanyFileUnlocks unlocks = new CompanyFileUnlocks(clock);
        UUID id = UUID.randomUUID();
        AuthUser actor = user(UUID.randomUUID(), UUID.randomUUID());
        String hash = unlocks.hash("correct1");
        for (int i = 0; i < 5; i++)
            assertCode(
                    ErrorCode.VALIDATION_FAILED, () -> unlocks.unlock(id, 0, hash, "wrong", actor));
        assertCode(
                ErrorCode.RATE_LIMITED,
                () ->
                        unlocks.unlock(
                                id, 0, hash, "correct1", user(actor.getId(), UUID.randomUUID())));
        clock.now = clock.now.plusSeconds(901);
        assertThat(unlocks.unlock(id, 0, hash, "correct1", actor)).isAfter(clock.instant());
    }

    @Test
    void successfulAttemptDoesNotReplaceTheMonitorOfAlreadyWaitingFailures() throws Exception {
        CompanyFileUnlocks unlocks = new CompanyFileUnlocks();
        UUID id = UUID.randomUUID();
        AuthUser actor = user(UUID.randomUUID(), UUID.randomUUID());
        String hash = unlocks.hash("correct1");
        // Success retains the shared user/folder counter; concurrent wrong attempts still stop at
        // five.
        unlocks.unlock(id, 0, hash, "correct1", actor);
        try (ExecutorService pool = Executors.newFixedThreadPool(8)) {
            CountDownLatch start = new CountDownLatch(1);
            var results = new java.util.ArrayList<Future<ErrorCode>>();
            for (int i = 0; i < 8; i++)
                results.add(
                        pool.submit(
                                () -> {
                                    start.await();
                                    try {
                                        unlocks.unlock(id, 0, hash, "wrong", actor);
                                        return null;
                                    } catch (ApiException e) {
                                        return e.getCode();
                                    }
                                }));
            start.countDown();
            int invalid = 0, limited = 0;
            for (Future<ErrorCode> result : results) {
                ErrorCode code = result.get(15, TimeUnit.SECONDS);
                if (code == ErrorCode.VALIDATION_FAILED) invalid++;
                if (code == ErrorCode.RATE_LIMITED) limited++;
            }
            assertThat(invalid).isEqualTo(5);
            assertThat(limited).isEqualTo(3);
        }
    }

    @Test
    void clearAndFolderInvalidationRemoveCapabilitiesAndOversizedUtf8IsRejected() {
        CompanyFileUnlocks unlocks = new CompanyFileUnlocks();
        UUID id = UUID.randomUUID();
        AuthUser actor = user(UUID.randomUUID(), UUID.randomUUID());
        String hash = unlocks.hash("correct1");
        unlocks.unlock(id, 0, hash, "correct1", actor);
        unlocks.lock(id, actor);
        assertThat(unlocks.isUnlocked(id, 0, actor)).isFalse();
        unlocks.unlock(id, 0, hash, "correct1", actor);
        unlocks.invalidate(id);
        assertThat(unlocks.isUnlocked(id, 0, actor)).isFalse();
        assertCode(ErrorCode.VALIDATION_FAILED, () -> unlocks.hash("中".repeat(25)));
        assertCode(
                ErrorCode.UNAUTHORIZED,
                () -> unlocks.unlock(id, 0, hash, "correct1", user(actor.getId(), null)));
    }

    @Test
    void windowsReservedAndTraversalNamesAreRejectedButChineseAndUnicodeNormalizationAreStable() {
        for (String name :
                java.util.List.of(
                        "../a", "..", "a\\b", "CON.txt", "lpt9.docx", "name.", "a\nb", "a:b"))
            assertCode(ErrorCode.VALIDATION_FAILED, () -> CompanyFileService.validName(name));
        assertThat(CompanyFileService.validName("  报销模板.xlsx  ")).isEqualTo("报销模板.xlsx");
        assertThat(CompanyFileService.validName("e\u0301.txt")).isEqualTo("é.txt");
    }

    private static AuthUser user(UUID id, UUID session) {
        return new AuthUser(
                id,
                null,
                "fixture",
                Set.of("company_file:view"),
                false,
                true,
                false,
                false,
                null,
                session);
    }

    private static void assertCode(
            ErrorCode code, org.assertj.core.api.ThrowableAssert.ThrowingCallable operation) {
        assertThatThrownBy(operation)
                .isInstanceOfSatisfying(
                        ApiException.class, e -> assertThat(e.getCode()).isEqualTo(code));
    }

    private static final class MutableClock extends Clock {
        Instant now = Instant.parse("2026-10-25T12:00:00Z");

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return now;
        }
    }
}
