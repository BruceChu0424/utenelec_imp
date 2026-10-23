package com.uten.imp.features.notice.outbox;

import com.uten.imp.application.concurrency.FulfillmentSourceConflictException;
import com.uten.imp.common.web.ApiException;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.stereotype.Component;

import java.sql.SQLException;
import java.util.ArrayList;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;

/** Bounded outcome labels; event ids and exception text never become metric tags. */
@Component
public class BusinessOutboxDeliveryDiagnostics {
    public enum Kind { NONE, SOURCE_CHANGED, LOCK_BUSY, UNEXPECTED }
    public enum Outcome { DELIVERED, ALREADY_DELIVERED, DEFERRED, FAILED, EXHAUSTED, NOT_RECORDED }

    public record Failure(Kind kind, String sqlState, String detail) {
        boolean deferrable() { return kind == Kind.SOURCE_CHANGED || kind == Kind.LOCK_BUSY; }
        String persistedDescription() {
            String value = "kind=" + kind + "; sqlState=" + (sqlState == null ? "-" : sqlState) + "; " + detail;
            return value.substring(0, Math.min(value.length(), 1000));
        }
    }

    private final MeterRegistry meters;

    public BusinessOutboxDeliveryDiagnostics(MeterRegistry meters) { this.meters = meters; }

    void count(Outcome outcome, Kind kind) {
        if (meters != null) {
            meters.counter("uten.business.outbox.delivery", "outcome", outcome.name(), "kind", kind.name()).increment();
        }
    }

    static Failure describe(Throwable error) {
        List<Throwable> causes = causes(error);
        List<SQLException> sqlFailures = causes.stream().filter(SQLException.class::isInstance)
                .map(SQLException.class::cast).toList();
        SQLException sql = sqlFailures.stream().filter(value -> !"55P03".equals(value.getSQLState()))
                .findFirst().orElse(sqlFailures.isEmpty() ? null : sqlFailures.getFirst());
        // An unexpected SQL failure (especially a deadlock) must never be hidden by an outer conflict.
        boolean onlyLockBusy = causes.size() < 32 && sql != null && causes.stream().filter(SQLException.class::isInstance)
                .map(SQLException.class::cast).allMatch(value -> "55P03".equals(value.getSQLState()));
        FulfillmentSourceConflictException conflict = causes.stream()
                .filter(FulfillmentSourceConflictException.class::isInstance)
                .map(FulfillmentSourceConflictException.class::cast).findFirst().orElse(null);
        ApiException business = causes.stream().filter(ApiException.class::isInstance)
                .map(ApiException.class::cast).findFirst().orElse(null);
        boolean knownLockWrapper = business == null || conflict != null && business == conflict && conflict.retryable()
                && conflict.reason() == FulfillmentSourceConflictException.Reason.LOCK_BUSY;
        Kind kind = onlyLockBusy && knownLockWrapper ? Kind.LOCK_BUSY
                : causes.size() < 32 && sql == null && conflict != null && business == conflict && conflict.retryable()
                    && conflict.reason() == FulfillmentSourceConflictException.Reason.PRE_WRITE_SOURCE_CHANGED
                    ? Kind.SOURCE_CHANGED : Kind.UNEXPECTED;
        Throwable root = causes.isEmpty() ? error : causes.getLast();
        String detail = conflict == null
                ? root.getClass().getSimpleName() + ": " + root.getMessage()
                : conflict.getClass().getSimpleName() + ": " + conflict.internalReason()
                    + (root == conflict ? "" : "; cause=" + root.getClass().getSimpleName() + ": " + root.getMessage());
        return new Failure(kind, sql == null ? null : sql.getSQLState(), detail);
    }

    private static List<Throwable> causes(Throwable error) {
        Set<Throwable> visited = Collections.newSetFromMap(new IdentityHashMap<>());
        List<Throwable> result = new ArrayList<>();
        var pending = new ArrayDeque<Throwable>();
        pending.add(java.util.Objects.requireNonNull(error));
        while (!pending.isEmpty() && result.size() < 32) {
            Throwable next = pending.removeFirst();
            if (!visited.add(next)) { continue; }
            result.add(next);
            if (next.getCause() != null) { pending.addLast(next.getCause()); }
            if (next instanceof SQLException sql && sql.getNextException() != null) { pending.addLast(sql.getNextException()); }
        }
        return result;
    }
}
