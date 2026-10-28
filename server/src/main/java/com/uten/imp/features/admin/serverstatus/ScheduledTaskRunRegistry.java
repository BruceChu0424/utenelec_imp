package com.uten.imp.features.admin.serverstatus;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
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
 * <p>Populated by {@code ObservedTaskScheduler} around each execution; nothing is
 * persisted by default and the registry restarts empty with the JVM — except for
 * the governance tasks listed in {@link ScheduledTaskCatalog#durableEvidenceTasks()},
 * whose completed runs are also appended to {@code scheduled_task_runs} (V954) so
 * the status page keeps its evidence across restarts. A persistence failure is
 * logged and never propagates into the observed task. Names are derived from the
 * declaring class and method only (no arguments, messages, SQL or paths).</p>
 *
 * <p>Spring 6.2 hands the scheduler a package-private {@code Task$OutcomeTrackingRunnable}
 * wrapper whose {@code toString()} delegates to the wrapped
 * {@link ScheduledMethodRunnable} ({@code "<fqcn>.<method>"}); {@link #nameOf(Runnable)}
 * therefore accepts both the runnable itself and that wrapper, and ignores plain lambdas
 * (verified against spring-context 6.2.19 bytecode, 2026-09-10).</p>
 */
@Slf4j
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

    /** 治理任务完成回执的持久层; 直接 new 本类的测试保持纯内存语义。 */
    @Autowired(required = false)
    private transient ScheduledTaskRunStore runStore;

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
        Run completed = runs.compute(name, (key, previous) -> {
            Run base = previous == null ? new Run(name, null, at, null, null, null, 0, 0) : previous;
            Long duration = base.lastStart() == null ? null
                    : Math.max(0, Duration.between(base.lastStart(), at).toMillis());
            String errorType = failure == null ? null : failure.getClass().getSimpleName();
            int failures = failure == null ? 0 : base.consecutiveFailures() + 1;
            return new Run(name, base.period(), base.lastStart(), at, duration, errorType,
                    failures, base.runs() + 1);
        });
        persistDurableEvidence(completed, failure);
    }

    /** 治理类低频任务的完成回执写穿到 scheduled_task_runs; 失败绝不影响任务本身。 */
    private void persistDurableEvidence(Run completed, Throwable failure) {
        if (runStore == null
                || !ScheduledTaskCatalog.durableEvidenceTasks().contains(completed.name())
                || completed.lastStart() == null) {
            return;
        }
        try {
            runStore.append(
                    completed.name(),
                    completed.lastStart(),
                    completed.lastEnd(),
                    completed.lastDurationMs(),
                    failure == null ? null : failure.getClass().getSimpleName());
        } catch (RuntimeException persistenceFailure) {
            log.warn("后台任务完成回执写入失败(不影响任务执行): {}", persistenceFailure.toString());
        }
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
