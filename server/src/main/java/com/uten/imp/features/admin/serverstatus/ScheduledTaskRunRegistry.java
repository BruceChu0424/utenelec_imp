package com.uten.imp.features.admin.serverstatus;

import org.springframework.scheduling.support.ScheduledMethodRunnable;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * In-memory record of the last run of every {@code @Scheduled} method.
 *
 * <p>Populated by {@code DrainAwareTaskScheduler} around each execution; nothing is
 * persisted and the registry restarts empty with the JVM. Names are derived from the
 * declaring class and method only (no arguments, messages, SQL or paths).</p>
 *
 * <p>Spring 6.2 hands the scheduler a package-private {@code Task$OutcomeTrackingRunnable}
 * wrapper whose {@code toString()} delegates to the wrapped
 * {@link ScheduledMethodRunnable} ({@code "<fqcn>.<method>"}); {@link #nameOf(Runnable)}
 * therefore accepts both the runnable itself and that wrapper, and ignores plain lambdas
 * (verified against spring-context 6.2.19 bytecode, 2026-09-10).</p>
 */
@Component
public class ScheduledTaskRunRegistry {

    /** Immutable snapshot of one task; {@code lastEnd} is null while the first run is in progress. */
    public record Run(String name, Duration period, Instant lastStart, Instant lastEnd,
                      Long lastDurationMs, String lastErrorType, int consecutiveFailures, long runs) {
        boolean running() { return lastStart != null && (lastEnd == null || lastEnd.isBefore(lastStart)); }
    }

    private static final Pattern SCHEDULED_METHOD =
            Pattern.compile("^(?:[A-Za-z_$][\\w$]*\\.)*([A-Z][\\w$]*)\\.([a-z_$][\\w$]*)$");

    private final Map<String, Run> runs = new ConcurrentHashMap<>();

    /** Registers the task if it is a scheduled method; returns its name or null for lambdas. */
    public String register(Runnable task, Duration period) {
        String name = nameOf(task);
        if (name == null) return null;
        runs.compute(name, (key, previous) -> previous == null
                ? new Run(name, period, null, null, null, null, 0, 0)
                : new Run(name, period == null ? previous.period() : period, previous.lastStart(),
                        previous.lastEnd(), previous.lastDurationMs(), previous.lastErrorType(),
                        previous.consecutiveFailures(), previous.runs()));
        return name;
    }

    public void started(String name, Instant at) {
        if (name == null) return;
        runs.compute(name, (key, previous) -> previous == null
                ? new Run(name, null, at, null, null, null, 0, 0)
                : new Run(name, previous.period(), at, previous.lastEnd(), null,
                        previous.lastErrorType(), previous.consecutiveFailures(), previous.runs()));
    }

    public void finished(String name, Instant at, Throwable failure) {
        if (name == null) return;
        runs.compute(name, (key, previous) -> {
            Run base = previous == null ? new Run(name, null, at, null, null, null, 0, 0) : previous;
            Long duration = base.lastStart() == null ? null
                    : Math.max(0, Duration.between(base.lastStart(), at).toMillis());
            String errorType = failure == null ? null : failure.getClass().getSimpleName();
            int failures = failure == null ? 0 : base.consecutiveFailures() + 1;
            return new Run(name, base.period(), base.lastStart(), at, duration, errorType,
                    failures, base.runs() + 1);
        });
    }

    /** Stable, name-sorted copy for the status page. */
    public List<Run> snapshot() {
        return runs.values().stream().sorted(Comparator.comparing(Run::name)).toList();
    }

    static String nameOf(Runnable task) {
        if (task == null) return null;
        if (task instanceof ScheduledMethodRunnable scheduled) {
            var method = scheduled.getMethod();
            return method.getDeclaringClass().getSimpleName() + "." + method.getName();
        }
        String text = String.valueOf(task);
        var matcher = SCHEDULED_METHOD.matcher(text);
        if (!matcher.matches()) return null;
        return matcher.group(1) + "." + matcher.group(2);
    }
}
