package com.uten.imp.features.notice.outbox;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.uten.imp.application.concurrency.FulfillmentSourceConflictException;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;
import org.springframework.test.util.ReflectionTestUtils;

import java.sql.SQLException;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class BusinessOutboxDeliveryDiagnosticsTest {
    @Test
    void onlyTheActualLockSqlStateOrExplicitPreWriteReasonCanBeOrdinaryContention() {
        var busy = new SQLException("bounded source row wait", "55P03");
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(busy).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.LOCK_BUSY);
        FulfillmentSourceConflictException wrapped = ReflectionTestUtils.invokeMethod(
                FulfillmentSourceConflictException.class, "lockBusy", "known timeout", "public busy message", busy);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(wrapped).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.LOCK_BUSY);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(wrapped).persistedDescription()).contains("55P03", "known timeout");
        var unknown = new FulfillmentSourceConflictException("unclassified wrapper", true);
        unknown.initCause(busy);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(unknown).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.UNEXPECTED);
        var structural = new FulfillmentSourceConflictException("coverage gap", false);
        structural.initCause(busy);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(structural).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.UNEXPECTED);
        var generic = new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT);
        generic.initCause(busy);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(generic).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.UNEXPECTED);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(new FulfillmentSourceConflictException("unknown", true)).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.UNEXPECTED);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(new FulfillmentSourceConflictException("coverage gap", false)).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.UNEXPECTED);
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(new SQLException("deadlock", "40P01")).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.UNEXPECTED);
        busy.setNextException(new SQLException("chained deadlock", "40P01"));
        assertThat(BusinessOutboxDeliveryDiagnostics.describe(wrapped).kind())
                .isEqualTo(BusinessOutboxDeliveryDiagnostics.Kind.UNEXPECTED);
    }

    @Test
    void noRecordedRowCannotClaimThatAnyDurableRetryWasScheduled() {
        checkRecordedState(Optional.empty(), BusinessOutboxDeliveryDiagnostics.Outcome.NOT_RECORDED, Level.WARN);
    }

    @Test
    void aPendingRowWithoutFutureEligibilityIsNotReportedAsDeferred() {
        Instant now = Instant.now();
        checkRecordedState(Optional.of(new BusinessOutboxFailureRecorder.RecordedFailure(0, 1, now, now)),
                BusinessOutboxDeliveryDiagnostics.Outcome.FAILED, Level.WARN);
    }

    @Test
    void exhaustedContentionStillRaisesAnErrorAndAnExplicitMetric() {
        Instant now = Instant.now();
        checkRecordedState(Optional.of(new BusinessOutboxFailureRecorder.RecordedFailure(2, 8, now, now)),
                BusinessOutboxDeliveryDiagnostics.Outcome.EXHAUSTED, Level.ERROR);
    }

    private static void checkRecordedState(Optional<BusinessOutboxFailureRecorder.RecordedFailure> state,
                                           BusinessOutboxDeliveryDiagnostics.Outcome outcome, Level level) {
        var processor = mock(BusinessOutboxProcessor.class);
        var recorder = mock(BusinessOutboxFailureRecorder.class);
        var failure = new OutboxDeliveryException(UUID.randomUUID(), new SQLException("busy", "55P03"));
        when(processor.processNext()).thenThrow(failure).thenReturn(false);
        when(recorder.record(any(), any())).thenReturn(state);
        var executor = new ManualOutboxExecutor();
        Logger logger = (Logger) LoggerFactory.getLogger(BusinessOutboxScheduler.class);
        var logs = new ListAppender<ILoggingEvent>();
        logs.start(); logger.addAppender(logs);
        var meters = new SimpleMeterRegistry();
        try (var scheduler = new BusinessOutboxScheduler(processor, recorder, OutboxWarnThrottler.withDefaults(),
                     executor, new BusinessOutboxDeliveryDiagnostics(meters))) {
            scheduler.drain(); executor.runOne();
            assertThat(logs.list).anySatisfy(event -> assertThat(event.getLevel()).isEqualTo(level));
            assertThat(logs.list).noneSatisfy(event -> assertThat(event.getFormattedMessage()).contains("contention deferred"));
            assertThat(meters.get("uten.business.outbox.delivery").tags("outcome", outcome.name(), "kind", "LOCK_BUSY")
                    .counter().count()).isEqualTo(1);
            assertThat(meters.find("uten.business.outbox.delivery").tag("outcome", "DEFERRED").counter()).isNull();
        } finally { logger.detachAppender(logs); logs.stop(); meters.close(); }
    }
}
