package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Statement;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ControlledLoadWindowMetricsTest {
    @Test void anExceptionAfterCommitDoesNotBecomeAFakeRollback() {
        var facts = new ControlledLoadWindowMetrics.Counters(); facts.commitAttempts.increment(); facts.commitConfirmed.increment();
        assertEquals(ControlledLoadWindowMetrics.Outcome.COMMIT_CONFIRMED_CALL_FAILED, ControlledLoadWindowMetrics.outcome(false, facts));
    }
    @Test void failedCommitAcknowledgementRemainsUnknownEvenIfRollbackWasLaterAttempted() {
        var facts = new ControlledLoadWindowMetrics.Counters(); facts.commitAttempts.increment(); facts.commitUncertain.increment(); facts.rollbackConfirmed.increment();
        assertEquals(ControlledLoadWindowMetrics.Outcome.OUTCOME_UNKNOWN, ControlledLoadWindowMetrics.outcome(false, facts));
    }
    @Test void knownRollbackAndOrdinaryReturnAreDifferentEvidence() {
        var facts = new ControlledLoadWindowMetrics.Counters(); facts.rollbackConfirmed.increment();
        assertEquals(ControlledLoadWindowMetrics.Outcome.ROLLBACK_CONFIRMED, ControlledLoadWindowMetrics.outcome(false, facts));
        assertEquals(ControlledLoadWindowMetrics.Outcome.OUTCOME_UNKNOWN, ControlledLoadWindowMetrics.outcome(true, facts));
    }
    @Test void independentBackgroundSqlIsCountedGloballyWithoutEnteringTheRequestSpan() throws Exception {
        DataSource source = mock(DataSource.class); Connection connection = mock(Connection.class); Statement statement = mock(Statement.class);
        when(source.getConnection()).thenReturn(connection); when(connection.createStatement()).thenReturn(statement);
        var measured = (DataSource) ControlledLoadWindowMetrics.Configuration.controlledWindowJdbcMetrics().postProcessAfterInitialization(source, "dataSource");
        ControlledLoadWindowMetrics.beginWindow();
        try (var command = ControlledLoadWindowMetrics.span(ControlledLoadWindowMetrics.Phase.COMMAND)) {
            measured.getConnection().createStatement().execute("select 1");
            var failure = new java.util.concurrent.atomic.AtomicReference<Throwable>();
            Thread worker = new Thread(() -> {
                try { measured.getConnection().createStatement().execute("select 2"); }
                catch (Throwable error) { failure.set(error); }
            }, "business-outbox-test");
            worker.start(); worker.join(5000); assertFalse(worker.isAlive()); assertNull(failure.get());
            assertEquals(1, command.counters.sql.sum());
            var all = ControlledLoadWindowMetrics.allThreads();
            assertEquals(1L, ((java.util.Map<?, ?>) all.get("COMMAND")).get("sqlStatements"));
            assertEquals(1L, ((java.util.Map<?, ?>) all.get("BACKGROUND")).get("sqlStatements"));
        }
    }
}
