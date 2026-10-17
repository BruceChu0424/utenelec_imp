package com.uten.imp.features.workbench.badge;

import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.slf4j.Logger;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalArgumentException;
import static org.mockito.Mockito.*;

class WorkbenchBadgeSourceDiagnosticsTest {
    private static final String WARNING = "工作台徽章来源 {} 本次未算出: {}";
    private static final String RECOVERY = "工作台徽章来源 {} 已恢复，前次原因: {}";
    private static final String SOURCE = "serverOperations";
    private static final ErrorCode UNAVAILABLE = ErrorCode.SERVER_OPERATIONS_UNAVAILABLE;

    private final AtomicLong now = new AtomicLong();
    private final Logger log = mock(Logger.class);
    private WorkbenchBadgeSourceDiagnostics diagnostics;

    @BeforeEach
    void setUp() {
        diagnostics = new WorkbenchBadgeSourceDiagnostics(Set.of(SOURCE, "productionSchedule"), now::get, log);
    }

    @Test
    void sameFailureWarnsImmediatelyThenOnlyAtEachTenMinuteBoundary() {
        diagnostics.failed(SOURCE, UNAVAILABLE);
        diagnostics.failed(SOURCE, UNAVAILABLE);
        now.set(WorkbenchBadgeSourceDiagnostics.WARNING_INTERVAL_NANOS - 1);
        diagnostics.failed(SOURCE, UNAVAILABLE);
        verify(log).warn(WARNING, SOURCE, UNAVAILABLE.name());

        now.incrementAndGet();
        diagnostics.failed(SOURCE, UNAVAILABLE);
        diagnostics.failed(SOURCE, UNAVAILABLE);
        now.addAndGet(WorkbenchBadgeSourceDiagnostics.WARNING_INTERVAL_NANOS);
        diagnostics.failed(SOURCE, UNAVAILABLE);

        verify(log, times(3)).warn(WARNING, SOURCE, UNAVAILABLE.name());
        verifyNoMoreInteractions(log);
    }

    @Test
    void changedErrorCodeOrExceptionTypeWarnsImmediatelyAndStartsANewReminderInterval() {
        diagnostics.failed(SOURCE, UNAVAILABLE);
        now.set(WorkbenchBadgeSourceDiagnostics.WARNING_INTERVAL_NANOS - 1);
        diagnostics.failed(SOURCE, ErrorCode.CONFLICT);
        now.incrementAndGet();
        diagnostics.failed(SOURCE, ErrorCode.CONFLICT);
        diagnostics.failed(SOURCE, IllegalStateException.class);
        diagnostics.failed(SOURCE, IllegalArgumentException.class);
        diagnostics.failed(SOURCE, IllegalArgumentException.class);

        verify(log).warn(WARNING, SOURCE, UNAVAILABLE.name());
        verify(log).warn(WARNING, SOURCE, ErrorCode.CONFLICT.name());
        verify(log).warn(WARNING, SOURCE, IllegalStateException.class.getName());
        verify(log).warn(WARNING, SOURCE, IllegalArgumentException.class.getName());
        verifyNoMoreInteractions(log);
    }

    @Test
    void successfulReadLogsOneRecoveryAndTheNextFailureWarnsImmediately() {
        diagnostics.recovered(SOURCE);
        diagnostics.failed(SOURCE, UNAVAILABLE);
        diagnostics.recovered(SOURCE);
        diagnostics.recovered(SOURCE);
        diagnostics.failed(SOURCE, UNAVAILABLE);

        verify(log, times(2)).warn(WARNING, SOURCE, UNAVAILABLE.name());
        verify(log).info(RECOVERY, SOURCE, UNAVAILABLE.name());
        verifyNoMoreInteractions(log);
    }

    @Test
    void sourceFailuresAndRecoveriesDoNotChangeAnotherSourceState() {
        diagnostics.failed(SOURCE, UNAVAILABLE);
        diagnostics.failed("productionSchedule", UNAVAILABLE);
        diagnostics.recovered("productionSchedule");
        diagnostics.failed(SOURCE, UNAVAILABLE);
        diagnostics.failed("productionSchedule", UNAVAILABLE);

        verify(log).warn(WARNING, SOURCE, UNAVAILABLE.name());
        verify(log, times(2)).warn(WARNING, "productionSchedule", UNAVAILABLE.name());
        verify(log).info(RECOVERY, "productionSchedule", UNAVAILABLE.name());
        verifyNoMoreInteractions(log);
    }

    @Test
    void concurrentPollsLogOnlyOneWarningAndOneRecoveryPerSource() throws Exception {
        var executor = Executors.newFixedThreadPool(8);
        var ready = new CountDownLatch(8);
        var start = new CountDownLatch(1);
        try {
            List<Future<?>> failures = new ArrayList<>();
            for (int i = 0; i < 8; i++) {
                failures.add(executor.submit(() -> {
                    ready.countDown();
                    if (!start.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("未能同步启动轮询");
                    for (int poll = 0; poll < 50; poll++) diagnostics.failed(SOURCE, UNAVAILABLE);
                    return null;
                }));
            }
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            for (Future<?> failure : failures) failure.get(5, TimeUnit.SECONDS);

            List<Future<?>> recoveries = new ArrayList<>();
            for (int i = 0; i < 8; i++) recoveries.add(executor.submit(() -> diagnostics.recovered(SOURCE)));
            for (Future<?> recovery : recoveries) recovery.get(5, TimeUnit.SECONDS);

            verify(log).warn(WARNING, SOURCE, UNAVAILABLE.name());
            verify(log).info(RECOVERY, SOURCE, UNAVAILABLE.name());
            verifyNoMoreInteractions(log);
        } finally {
            start.countDown();
            executor.shutdownNow();
        }
    }

    @Test
    void reminderUsesElapsedMonotonicTimeEvenAcrossNanoTimeWraparound() {
        now.set(Long.MAX_VALUE - 1);
        diagnostics.failed(SOURCE, UNAVAILABLE);
        now.addAndGet(WorkbenchBadgeSourceDiagnostics.WARNING_INTERVAL_NANOS);
        diagnostics.failed(SOURCE, UNAVAILABLE);

        verify(log, times(2)).warn(WARNING, SOURCE, UNAVAILABLE.name());
        verifyNoMoreInteractions(log);
    }

    @Test
    void unregisteredSourcesCannotGrowTheDiagnosticRegistry() {
        assertThatIllegalArgumentException().isThrownBy(() -> diagnostics.failed("unregistered", UNAVAILABLE));
        assertThatIllegalArgumentException().isThrownBy(() -> diagnostics.recovered("unregistered"));
        verifyNoInteractions(log);
    }
}
