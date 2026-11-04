package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.annotation.EnableTransactionManagement;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.context.request.async.DeferredResult;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SessionWatchServiceTest {
    private final AuthSessionService sessions = mock(AuthSessionService.class);
    private final SessionWatchService watches = new SessionWatchService(sessions);

    private void active() {
        when(sessions.evaluateStaffWatches(anyMap())).thenAnswer(invocation -> {
            Map<UUID, UUID> owners = invocation.getArgument(0);
            Map<UUID, AuthSessionService.RefreshVerdict> verdicts = new HashMap<>();
            owners.keySet().forEach(sid -> verdicts.put(sid, AuthSessionService.RefreshVerdict.active()));
            return verdicts;
        });
    }

    @Test
    void replacementCompletesOnlyCapturedOldSessionsAndDeduplicatesRepeatedDelivery() {
        active();
        UUID owner = UUID.randomUUID();
        UUID oldSid = UUID.randomUUID();
        DeferredResult<SessionWatchService.Response> old = watches.watch(oldSid, owner);
        DeferredResult<SessionWatchService.Response> current = watches.watch(UUID.randomUUID(), owner);
        DeferredResult<SessionWatchService.Response> colleague = watches.watch(UUID.randomUUID(), UUID.randomUUID());

        var event = new AuthSessionService.ReplacedSessions(List.of(oldSid), "Android 客户端");
        for (int repeat = 0; repeat < 100; repeat++) watches.replaced(event);

        assertThat(old.getResult()).isEqualTo(new SessionWatchService.Response(
                "replaced", "SESSION_REPLACED", "账号已在「Android 客户端」登录，本设备已自动下线"));
        assertThat(current.hasResult()).isFalse();
        assertThat(colleague.hasResult()).isFalse();
        assertThat(watches.waitingCount()).isEqualTo(2);
    }

    @Test
    void replacementBetweenAuthenticationAndRegistrationIsReturnedImmediately() {
        UUID sid = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        when(sessions.evaluateStaffWatches(Map.of(sid, owner))).thenReturn(Map.of(sid, replaced()));

        var result = watches.watch(sid, owner);

        assertThat(((SessionWatchService.Response) result.getResult()).code()).isEqualTo("SESSION_REPLACED");
        assertThat(watches.waitingCount()).isZero();
    }

    @Test
    void reconciliationObservesOtherProcessReplacementAndDoesNotPublishUnrelatedSessions() {
        active();
        UUID sid = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        var result = watches.watch(sid, owner);
        UUID keptSid = UUID.randomUUID();
        var kept = watches.watch(keptSid, owner);
        when(sessions.evaluateStaffWatches(anyMap())).thenReturn(Map.of(
                sid, replaced(), keptSid, AuthSessionService.RefreshVerdict.active()));

        watches.reconcile();

        assertThat(((SessionWatchService.Response) result.getResult()).status()).isEqualTo("replaced");
        assertThat(kept.hasResult()).isFalse();
        assertThat(watches.waitingCount()).isEqualTo(1);
    }

    @Test
    void unavailableReconciliationKeepsTheVisibleSessionAndFailedRegistrationDoesNotLeak() {
        active();
        var result = watches.watch(UUID.randomUUID(), UUID.randomUUID());
        when(sessions.evaluateStaffWatches(anyMap())).thenThrow(new IllegalStateException("database unavailable"));

        watches.reconcile();

        assertThat(result.hasResult()).isFalse();
        assertThrows(IllegalStateException.class, () -> watches.watch(UUID.randomUUID(), UUID.randomUUID()));
        assertThat(watches.waitingCount()).isEqualTo(1);
    }

    @Test
    void missingOrExpiredSessionEndsWithoutClaimingAnotherDeviceReplacedIt() {
        when(sessions.evaluateStaffWatches(anyMap())).thenReturn(Map.of());
        var result = watches.watch(UUID.randomUUID(), UUID.randomUUID());
        assertThat(result.getResult()).isEqualTo(new SessionWatchService.Response(
                "expired", "UNAUTHORIZED", "登录已失效，请重新登录"));
        assertThat(watches.waitingCount()).isZero();
    }

    @Test
    void rapidRepeatedWatchRequestsHaveABoundedPerSessionLimit() {
        active();
        UUID sid = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        for (int request = 0; request < SessionWatchService.MAX_PER_SESSION; request++) watches.watch(sid, owner);
        assertThat(assertThrows(ApiException.class, () -> watches.watch(sid, owner)).getCode())
                .isEqualTo(ErrorCode.RATE_LIMITED);
        watches.replaced(new AuthSessionService.ReplacedSessions(List.of(sid), null));
        assertThat(watches.waitingCount()).isZero();
        assertThat(watches.watch(sid, owner).hasResult()).isFalse();
    }

    @Test
    void transactionEventDoesNotKickBeforeCommitOrWhenRolledBack() {
        try (var context = new AnnotationConfigApplicationContext(EventsConfiguration.class)) {
            var service = context.getBean(SessionWatchService.class);
            var store = context.getBean(AuthSessionService.class);
            UUID sid = UUID.randomUUID();
            UUID owner = UUID.randomUUID();
            when(store.evaluateStaffWatches(anyMap())).thenReturn(Map.of(sid, AuthSessionService.RefreshVerdict.active()));
            var result = service.watch(sid, owner);
            try {
                TransactionSynchronizationManager.setActualTransactionActive(true);
                TransactionSynchronizationManager.initSynchronization();
                context.publishEvent(new AuthSessionService.ReplacedSessions(List.of(sid), "新设备"));
                assertThat(result.hasResult()).isFalse();
                for (var synchronization : TransactionSynchronizationManager.getSynchronizations()) {
                    synchronization.afterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK);
                }
                assertThat(result.hasResult()).isFalse();
                TransactionSynchronizationManager.clearSynchronization();
                TransactionSynchronizationManager.initSynchronization();
                context.publishEvent(new AuthSessionService.ReplacedSessions(List.of(sid), "新设备"));
                assertThat(result.hasResult()).isFalse();
                for (var synchronization : TransactionSynchronizationManager.getSynchronizations()) {
                    synchronization.afterCompletion(TransactionSynchronization.STATUS_COMMITTED);
                }
                assertThat(((SessionWatchService.Response) result.getResult()).status()).isEqualTo("replaced");
            } finally {
                TransactionSynchronizationManager.clearSynchronization();
                TransactionSynchronizationManager.setActualTransactionActive(false);
            }
        }
    }

    private static AuthSessionService.RefreshVerdict replaced() {
        return new AuthSessionService.RefreshVerdict(AuthSessionService.Verdict.REVOKED,
                AuthSessionService.REASON_REPLACED_BY_LOGIN, "新设备");
    }

    @Configuration(proxyBeanMethods = false)
    @EnableTransactionManagement
    static class EventsConfiguration {
        @Bean AuthSessionService sessions() { return mock(AuthSessionService.class); }
        @Bean SessionWatchService watches(AuthSessionService sessions) { return new SessionWatchService(sessions); }
    }
}
