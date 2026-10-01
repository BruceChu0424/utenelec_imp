package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.features.admin.serverstatus.ScheduledTaskRunRegistry;
import com.uten.imp.features.admin.serverstatus.ServerStatusService;
import com.uten.imp.features.ai.job.AiJobWorker;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseTrigger;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.beans.factory.config.BeanFactoryPostProcessor;
import org.springframework.beans.factory.support.AbstractBeanDefinition;
import org.springframework.beans.factory.support.DefaultListableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.scheduling.config.TaskManagementConfigUtils;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.BufferedWriter;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.LockSupport;

import static com.uten.imp.businesschain.ControlledLoadWindowMetrics.Phase.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** One context and an independent bounded arrival clock; never launched by the ordinary test suite. */
@EnabledIfEnvironmentVariable(named = "UTEN_CONTROLLED_LOAD_WINDOW", matches = "true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "spring.datasource.hikari.maximum-pool-size=8", "spring.datasource.hikari.minimum-idle=1",
        "uten.jwt.secret=controlled-window-test-only-not-a-production-secret-0123456789",
        "uten.crypto.pgp-master-key=controlled-window-test-only-not-a-production-secret-0123456789",
        "uten.crypto.hmac-key=controlled-window-test-only-not-a-production-secret-0123456789",
        "uten.bootstrap.admin-login=controlled-window-test-only", "uten.bootstrap.admin-password=ControlledWindowTestOnly-1!"})
@Import({ControlledLoadWindowTest.BackgroundConfiguration.class, ControlledLoadWindowMetrics.Configuration.class})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
class ControlledLoadWindowTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        String url = required("UTEN_LOAD_DB_URL");
        if (!url.matches("jdbc:postgresql://uten-load-[a-z0-9-]+:5432/uten_load"))
            throw new IllegalStateException("Only the runner's private container/database is allowed");
        ControlledLoadRunPlan plan = ControlledLoadRunPlan.from(System.getenv());
        properties.add("spring.datasource.url", () -> url);
        properties.add("spring.datasource.username", () -> required("UTEN_LOAD_DB_USER"));
        properties.add("spring.datasource.password", () -> required("UTEN_LOAD_DB_PASSWORD"));
        properties.add("uten.storage.local-dir", () -> "/tmp/uten-controlled-window-attachments");
        properties.add("uten.load.window.background", () -> plan.background().name());
        if (plan.background() == ControlledLoadRunPlan.Background.QUIET) {
            properties.add("uten.audit.retention.enabled", () -> false);
            properties.add("uten.reporting.materialized-view-refresh.enabled", () -> false);
        }
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class BackgroundConfiguration {
        @Bean static BeanFactoryPostProcessor quietProfileOnly(Environment environment) {
            return factory -> {
                if (!"QUIET".equals(environment.getRequiredProperty("uten.load.window.background"))) return;
                var definitions = (DefaultListableBeanFactory) factory;
                definitions.removeBeanDefinition(TaskManagementConfigUtils.SCHEDULED_ANNOTATION_PROCESSOR_BEAN_NAME);
                Map<String, Class<?>> workers = Map.of("businessOutboxScheduler", BusinessOutboxScheduler.class,
                        "aiJobWorker", AiJobWorker.class, "serverStatusService", ServerStatusService.class,
                        "workshopMaterialCloseTrigger", WorkshopMaterialCloseTrigger.class);
                workers.forEach((name, type) -> {
                    var definition = (AbstractBeanDefinition) definitions.getBeanDefinition(name);
                    definition.setInstanceSupplier(() -> mock(type));
                });
            };
        }
    }

    @Autowired ApplicationContext context;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired javax.sql.DataSource dataSource;
    @Autowired ObjectMapper json;
    @Autowired InventoryValueWorkService valueWork;
    @Autowired InventoryValuationPort values;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired ScheduledTaskRunRegistry scheduled;

    @Test void sampleWithinExplicitLimitsWithoutHidingBackgroundOrUnknownResults() throws Exception {
        var plan = ControlledLoadRunPlan.from(System.getenv());
        Path directory = Path.of(required("UTEN_LOAD_OUTPUT")); Files.createDirectories(directory);
        var summary = new LinkedHashMap<String, Object>();
        summary.put("format", "uten-controlled-load-window-v1"); summary.put("plan", plan.describe());
        summary.put("startedAt", Instant.now().toString()); summary.put("contextId", context.getId());
        summary.put("notCovered", List.of("HTTP/auth/network/UI", "CPU/IO stress injection", "production-machine SLA",
                "shared-goods foreground contention", "external AI/OCR/backup traffic"));
        summary.put("arrivalContract", "fixed clock; preparation shortages, late clock ticks and bounded admission rejections are explicit");
        summary.put("quietContract", "QUIET disables automatic jobs only; input preparation, verification and explicit value settlement still run and are separately counted");
        summary.put("measurementContract", "all application DataSource threads; phases separated; SQL time includes DB/lock/network; raw DriverManager connections excluded");
        assertNull(context.getParent(), "one standalone Spring context only");
        assertEquals(plan.background() == ControlledLoadRunPlan.Background.MIXED,
                context.containsBean(TaskManagementConfigUtils.SCHEDULED_ANNOTATION_PROCESSOR_BEAN_NAME));
        for (Class<?> type : List.of(BusinessOutboxScheduler.class, AiJobWorker.class, ServerStatusService.class, WorkshopMaterialCloseTrigger.class))
            assertEquals(plan.background() == ControlledLoadRunPlan.Background.QUIET, mockingDetails(context.getBean(type)).isMock());
        summary.put("applicationCgroupBefore", verifiedCgroup());
        summary.put("poolBefore", poolSnapshot());
        summary.put("effectiveTransactionTimeout", context.getEnvironment().getProperty("spring.transaction.default-timeout", "unavailable"));
        summary.put("databaseBefore", db.queryForMap("SELECT current_database() AS name,pg_database_size(current_database()) AS bytes"));
        summary.put("javaVersion", System.getProperty("java.version"));
        summary.put("postgresVersion", db.queryForObject("SELECT version()", String.class));
        summary.put("migrations", db.queryForMap("SELECT count(*) AS count,max(version::int) AS head FROM flyway_schema_history WHERE success AND type='SQL'"));

        AtomicBoolean stop = new AtomicBoolean(), stopObserve = new AtomicBoolean();
        AtomicReference<Throwable> fatal = new AtomicReference<>();
        var ready = new ArrayBlockingQueue<ControlledLoadWindowInputs.Input>(plan.readyCapacity());
        var verification = new ArrayBlockingQueue<Completed>(Math.max(4, plan.maxInFlight() * 2));
        var inFlight = new Semaphore(plan.maxInFlight());
        var verificationSlots = new Semaphore(verification.remainingCapacity());
        var active = new ConcurrentHashMap<UUID, Map<String, Object>>();
        List<Map<String, Object>> results = Collections.synchronizedList(new ArrayList<>());
        var admitted = new AtomicInteger(); var offered = new AtomicInteger(); var prepared = new AtomicInteger();
        var peakInFlight = new AtomicInteger(); var peakReady = new AtomicInteger();
        var reasons = new ConcurrentHashMap<String, AtomicInteger>();
        var producer = Executors.newSingleThreadExecutor(task -> new Thread(task, "controlled-fixtures"));
        var workers = Executors.newFixedThreadPool(plan.maxInFlight(), task -> new Thread(task, "controlled-command"));
        var verifier = Executors.newSingleThreadExecutor(task -> new Thread(task, "controlled-verification"));
        var observer = Executors.newSingleThreadExecutor(task -> new Thread(task, "controlled-observer"));
        var journal = new Journal(directory.resolve("events.jsonl"), json);
        try {
            var inputs = new ControlledLoadWindowInputs(beans, db);
            producer.submit(() -> {
                try (var ignored = ControlledLoadWindowMetrics.span(PREPARATION)) {
                    while (!stop.get() && prepared.get() < plan.maxSamples() + plan.readyCapacity() + plan.maxInFlight()) {
                        if (ready.remainingCapacity() == 0) { LockSupport.parkNanos(50_000_000); continue; }
                        String scenario = plan.scenarios().get(prepared.get() % plan.scenarios().size());
                        long started = System.nanoTime();
                        var input = inputs.prepare(scenario);
                        settleScope(input, plan, "PREPARATION");
                        var facts = ControlledLoadFacts.verify(db, values, input.goods());
                        prepared.incrementAndGet();
                        journal.event("INPUT_PREPARED", Map.of("input", input.metadata(), "elapsedMillis", millis(started), "facts", facts));
                        if (!stop.get()) { ready.put(input); peakReady.accumulateAndGet(ready.size(), Math::max); }
                    }
                } catch (Throwable failure) {
                    if (!(failure instanceof InterruptedException && stop.get())) { fatal.compareAndSet(null, failure); stop.set(true); journal.failure("PREPARATION_FAILED", failure); }
                } finally { SecurityContextHolder.clearContext(); }
            });
            long initialDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(120);
            while (ready.size() < plan.maxInFlight() && fatal.get() == null && System.nanoTime() < initialDeadline) Thread.sleep(50);
            if (ready.isEmpty()) throw new IllegalStateException("No validated input became ready within the bounded preparation period", fatal.get());
            ControlledLoadWindowMetrics.beginWindow();
            var backgroundAtStart = queueSnapshot();
            summary.put("backgroundAtStart", backgroundAtStart); summary.put("scheduledAtStart", scheduled.snapshot());
            verifier.submit(() -> {
                while (!stop.get() || !verification.isEmpty() || !active.isEmpty()) {
                    try {
                        Completed next = verification.poll(200, TimeUnit.MILLISECONDS);
                        if (next == null) continue;
                        try (var ignored = ControlledLoadWindowMetrics.span(VERIFY)) {
                            boolean receipt = next.input().receiptExists().getAsBoolean();
                            next.record().put("immutableReceiptConfirmed", receipt);
                            next.record().put("resolution", receipt ? "IMMUTABLE_RECEIPT_CONFIRMED"
                                    : "ROLLBACK_CONFIRMED".equals(next.record().get("commandOutcome")) ? "ROLLBACK_CONFIRMED" : "OUTCOME_UNKNOWN");
                            if (receipt) next.input().verifyBusinessFacts().run();
                            else if (!"ROLLBACK_CONFIRMED".equals(next.record().get("commandOutcome")))
                                next.record().put("unresolvedOutcome", true);
                            settleScope(next.input(), plan, "POST_COMMAND");
                            next.record().put("afterFacts", ControlledLoadFacts.verify(db, values, next.input().goods()));
                            next.record().put("invariants", "PASSED");
                        } catch (Throwable failure) {
                            next.record().put("invariants", "FAILED"); next.record().put("verificationFailure", failure.getClass().getName());
                            fatal.compareAndSet(null, failure); stop.set(true); journal.failure("VERIFICATION_FAILED", failure);
                        } finally {
                            results.add(next.record()); journal.event("COMMAND_VERIFIED", next.record());
                            verificationSlots.release();
                        }
                    } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                }
            });
            observer.submit(() -> {
                while (!stopObserve.get()) {
                    try (var ignored = ControlledLoadWindowMetrics.span(OBSERVER)) {
                        var queues = queueSnapshot();
                        journal.event("BACKGROUND_SAMPLE", Map.of("queues", queues, "allThreadJdbc", ControlledLoadWindowMetrics.allThreads(),
                                "cgroup", cgroup(), "pool", poolSnapshot(), "scheduled", scheduled.snapshot()));
                        if (((Number) queues.get("database_bytes")).longValue() > (long) plan.databaseLimitMiB() * 1024 * 1024) {
                            fatal.compareAndSet(null, new IllegalStateException("Test database size guard reached")); stop.set(true);
                        }
                    } catch (Throwable failure) { fatal.compareAndSet(null, failure); stop.set(true); journal.failure("OBSERVER_FAILED", failure); }
                    LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(2));
                }
            });
            long start = System.nanoTime(), warmEnd = start + TimeUnit.SECONDS.toNanos(plan.warmupSeconds());
            summary.put("admissionStartedAt", Instant.now().toString());
            long end = warmEnd + TimeUnit.SECONDS.toNanos(plan.durationSeconds());
            long interval = (long) (1_000_000_000d / plan.arrivalsPerSecond()), nextArrival = start;
            while (!stop.get() && System.nanoTime() < end && admitted.get() < plan.maxSamples()) {
                long now = System.nanoTime();
                if (now < nextArrival) { LockSupport.parkNanos(Math.min(nextArrival - now, 50_000_000)); continue; }
                if (now - nextArrival >= interval) {
                    int missed = (int) ((now - nextArrival) / interval); offered.addAndGet(missed);
                    reasons.computeIfAbsent("ARRIVAL_CLOCK_LATE", ignored -> new AtomicInteger()).addAndGet(missed);
                    journal.event("ARRIVALS_NOT_SENT", Map.of("reason", "ARRIVAL_CLOCK_LATE", "count", missed)); nextArrival += missed * interval;
                }
                long planned = nextArrival; nextArrival += interval; offered.incrementAndGet();
                String rejected = null;
                if (!inFlight.tryAcquire()) rejected = "MAX_IN_FLIGHT";
                else if (!verificationSlots.tryAcquire()) { inFlight.release(); rejected = "VERIFICATION_BACKPRESSURE"; }
                if (rejected != null) { reject(reasons, journal, rejected); continue; }
                var input = ready.poll();
                if (input == null) { inFlight.release(); verificationSlots.release(); reject(reasons, journal, "INPUT_NOT_READY"); continue; }
                admitted.incrementAndGet();
                var record = new ConcurrentHashMap<String, Object>();
                record.put("input", input.metadata()); record.put("scenario", input.scenario()); record.put("commandId", input.commandId());
                record.put("warmup", planned < warmEnd); record.put("plannedArrivalOffsetMillis", (planned - start) / 1_000_000d);
                active.put(input.commandId(), record); journal.event("COMMAND_ADMITTED", record);
                peakInFlight.accumulateAndGet(active.size(), Math::max);
                workers.submit(() -> {
                    long commandStart = System.nanoTime(), cpuStart = cpuNanos(); boolean returned = false;
                    record.put("arrivalToStartMillis", (commandStart - planned) / 1_000_000d);
                    var span = ControlledLoadWindowMetrics.span(COMMAND);
                    try { input.command().get(); returned = true; }
                    catch (Throwable failure) { record.put("callFailure", failure.getClass().getName()); }
                    finally {
                        record.put("commandMillis", millis(commandStart)); record.put("arrivalToCompletionMillis", (System.nanoTime() - planned) / 1_000_000d);
                        long cpuEnd = cpuNanos(); record.put("threadCpuSupported", cpuStart >= 0 && cpuEnd >= 0);
                        if (cpuStart >= 0 && cpuEnd >= 0) record.put("threadCpuMillis", (cpuEnd - cpuStart) / 1_000_000d);
                        span.close(); record.put("jdbc", span.counters.snapshot());
                        record.put("callReturned", returned);
                        record.put("commandOutcome", ControlledLoadWindowMetrics.outcome(returned, span.counters).name());
                        try {
                            journal.event("COMMAND_RETURNED", record);
                            verification.add(new Completed(input, record));
                        } catch (Throwable failure) {
                            fatal.compareAndSet(null, failure); stop.set(true); verificationSlots.release();
                            record.put("unresolvedOutcome", true); results.add(record);
                        } finally {
                            active.remove(input.commandId()); inFlight.release(); SecurityContextHolder.clearContext();
                        }
                    }
                });
            }
            summary.put("admissionEndedAt", Instant.now().toString()); summary.put("admissionElapsedMillis", millis(start));
            summary.put("admissionStopReason", stop.get() ? "GUARD_OR_FAILURE" : admitted.get() >= plan.maxSamples() ? "SAMPLE_CAP" : "DURATION_CAP");
            // Finish the currently preparing input; interrupting an ordinary
            // source transaction here would manufacture a cleanup-time failure.
            stop.set(true); producer.shutdown(); workers.shutdown();
            boolean preparationStopped = producer.awaitTermination(60, TimeUnit.SECONDS);
            boolean commandsStopped = workers.awaitTermination(plan.drainSeconds(), TimeUnit.SECONDS);
            verifier.shutdown(); boolean verified = verifier.awaitTermination(plan.drainSeconds(), TimeUnit.SECONDS);
            summary.put("preparationStopped", preparationStopped); summary.put("commandsStopped", commandsStopped); summary.put("verificationStopped", verified);
            summary.put("stillInFlight", active.entrySet().stream().map(entry -> Map.of("commandId", entry.getKey(),
                    "input", entry.getValue().get("input"), "resolution", "OUTCOME_UNKNOWN")).toList());
            var backgroundDrain = preparationStopped && commandsStopped && verified ? drainBackground(plan, journal)
                    : Map.<String, Object>of("settled", false, "reason", "test writers are still in flight");
            summary.put("backgroundDrain", backgroundDrain);
            summary.put("offered", offered.get()); summary.put("admitted", admitted.get()); summary.put("prepared", prepared.get());
            summary.put("peakCommandInFlight", peakInFlight.get()); summary.put("peakReadyInputs", peakReady.get());
            var rejected = new LinkedHashMap<String, Integer>(); reasons.forEach((reason, count) -> rejected.put(reason, count.get())); summary.put("notSent", rejected);
            summary.put("inputStarvationInvalidatesCapacityClaim", rejected.containsKey("INPUT_NOT_READY"));
            List<Map<String, Object>> completed = List.copyOf(results);
            summary.put("results", completed); summary.put("latencyByScenario", distributions(completed, List.copyOf(active.values()), plan.scenarios()));
            long measured = completed.stream().filter(row -> Boolean.FALSE.equals(row.get("warmup"))).count();
            long unknown = completed.stream().filter(row -> Boolean.TRUE.equals(row.get("unresolvedOutcome"))).count() + active.size();
            long callFailures = completed.stream().filter(row -> !Boolean.TRUE.equals(row.get("callReturned"))).count();
            summary.put("measuredSamples", measured); summary.put("unknownOutcomes", unknown); summary.put("callFailures", callFailures);
            summary.put("sampleThresholdMet", measured >= plan.minimumMeasuredSamples());
            summary.put("backgroundAtEnd", queueSnapshot()); summary.put("scheduledAtEnd", scheduled.snapshot());
            summary.put("formalSlaAccepted", false);
            if (!preparationStopped || !commandsStopped || !verified) throw new IllegalStateException("Bounded stop did not quiesce all test writers; in-flight outcomes remain unresolved");
            if (!Boolean.TRUE.equals(backgroundDrain.get("settled"))) throw new IllegalStateException("Background work did not drain inside the observation budget");
            if (fatal.get() != null) throw new IllegalStateException("Controlled run failed a preparation/observation/integrity guard", fatal.get());
            if (unknown > 0 || callFailures > 0) throw new IllegalStateException("Command failures or unknown outcomes remain; inspect immutable receipts");
            if (measured < plan.minimumMeasuredSamples()) throw new IllegalStateException("Insufficient measured samples; do not present this as a percentile pass");
            summary.put("outcome", "DIAGNOSTIC_COMPLETED");
        } catch (Throwable failure) {
            summary.put("outcome", "FAILED_OR_INCOMPLETE"); summary.put("failureType", failure.getClass().getName()); summary.put("failureMessage", failure.getMessage());
            throw failure;
        } finally {
            stop.set(true); stopObserve.set(true); producer.shutdownNow(); workers.shutdownNow(); verifier.shutdownNow(); observer.shutdownNow();
            awaitStop(producer); awaitStop(workers); awaitStop(verifier); awaitStop(observer);
            summary.put("allThreadJdbc", ControlledLoadWindowMetrics.allThreads()); summary.put("applicationCgroupAfter", cgroup());
            summary.put("finishedAt", Instant.now().toString());
            json.writerWithDefaultPrettyPrinter().writeValue(directory.resolve("window-summary.json").toFile(), summary);
            journal.close();
            SecurityContextHolder.clearContext();
        }
    }

    private record Completed(ControlledLoadWindowInputs.Input input, Map<String, Object> record) { }
    private static void reject(ConcurrentHashMap<String, AtomicInteger> reasons, Journal journal, String reason) {
        reasons.computeIfAbsent(reason, ignored -> new AtomicInteger()).incrementAndGet(); journal.event("ARRIVAL_NOT_SENT", Map.of("reason", reason));
    }
    private void settleScope(ControlledLoadWindowInputs.Input input, ControlledLoadRunPlan plan, String phase) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(plan.drainSeconds());
        do {
            if (plan.background() == ControlledLoadRunPlan.Background.QUIET) {
                try (var ignored = ControlledLoadWindowMetrics.span(DRAIN)) { valueWork.runBatch(); }
            }
            Boolean pending = ReflectionTestUtils.invokeMethod(InventoryValueWorkTestSupport.class, "pendingForGoods",
                    new NamedParameterJdbcTemplate(db), List.copyOf(input.goods()));
            if (!Boolean.TRUE.equals(pending)) return;
            Thread.sleep(100);
        } while (System.nanoTime() < deadline);
        throw new IllegalStateException(phase + " inventory value queue failed to settle for " + input.commandId());
    }
    private Map<String, Object> drainBackground(ControlledLoadRunPlan plan, Journal journal) throws Exception {
        long start = System.nanoTime(), deadline = start + TimeUnit.SECONDS.toNanos(plan.drainSeconds()); int idle = 0;
        Map<String, Object> queues;
        try (var ignored = ControlledLoadWindowMetrics.span(DRAIN)) {
            do {
                if (plan.background() == ControlledLoadRunPlan.Background.QUIET) {
                    valueWork.runBatch(); for (int i = 0; i < 20 && outbox.processNext(); i++) { }
                }
                queues = queueSnapshot(); journal.event("DRAIN_SAMPLE", queues);
                boolean scheduledBusy = scheduled.snapshot().stream().anyMatch(run -> run.lastStart() != null
                        && (run.lastEnd() == null || run.lastEnd().isBefore(run.lastStart())));
                boolean empty = ((Number) queues.get("business_pending")).longValue() == 0
                        && ((Number) queues.get("business_dead")).longValue() == 0 && !valueWork.hasPendingWork() && !scheduledBusy;
                idle = empty ? idle + 1 : 0;
                if (idle >= 3) return Map.of("settled", true, "elapsedMillis", millis(start), "queues", queues);
                Thread.sleep(100);
            } while (System.nanoTime() < deadline);
        }
        return Map.of("settled", false, "elapsedMillis", millis(start), "queues", queues);
    }
    private Map<String, Object> queueSnapshot() {
        return db.queryForMap("""
                SELECT (SELECT count(*) FROM business_outbox WHERE status=0) AS business_pending,
                       (SELECT count(*) FROM business_outbox WHERE status=2) AS business_dead,
                       (SELECT COALESCE(EXTRACT(EPOCH FROM now()-min(created_at)),0) FROM business_outbox WHERE status=0) AS oldest_business_seconds,
                       (SELECT count(*) FROM stock_value_tasks WHERE status='PENDING') AS value_tasks,
                       (SELECT count(*) FROM stock_value_jobs WHERE status<>'APPLIED') AS value_jobs,
                       (SELECT count(*) FROM stock_value_production_cost_tasks WHERE status='PENDING') AS production_tasks,
                       (SELECT count(*) FROM stock_value_production_cost_objects WHERE business_refresh_pending) AS business_refresh,
                       (SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock') AS lock_waiters,
                       (SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='active') AS active_connections,
                       pg_database_size(current_database()) AS database_bytes
                """);
    }
    private Map<String, Object> poolSnapshot() throws Exception {
        var source = dataSource.unwrap(com.zaxxer.hikari.HikariDataSource.class);
        var pool = source.getHikariPoolMXBean();
        return Map.of("active", pool.getActiveConnections(), "idle", pool.getIdleConnections(),
                "waiting", pool.getThreadsAwaitingConnection(), "total", pool.getTotalConnections(),
                "maximum", source.getMaximumPoolSize(), "minimumIdle", source.getMinimumIdle(), "acquireTimeoutMillis", source.getConnectionTimeout());
    }
    private static void awaitStop(java.util.concurrent.ExecutorService executor) {
        try { executor.awaitTermination(5, TimeUnit.SECONDS); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
    }
    private static Map<String, Object> distributions(List<Map<String, Object>> rows, List<Map<String, Object>> unfinished, List<String> scenarios) {
        var result = new LinkedHashMap<String, Object>();
        for (String scenario : scenarios) {
            var times = rows.stream().filter(row -> scenario.equals(row.get("scenario")) && Boolean.FALSE.equals(row.get("warmup")))
                    .map(row -> ((Number) row.get("arrivalToCompletionMillis")).doubleValue()).sorted().toList();
            long censored = unfinished.stream().filter(row -> scenario.equals(row.get("scenario")) && Boolean.FALSE.equals(row.get("warmup"))).count();
            var values = new LinkedHashMap<String, Object>(); values.put("completedSamplesIncludingFailures", times.size());
            values.put("inFlightWithoutCompletion", censored);
            values.put("medianMillis", quantile(times, .5)); values.put("p95Millis", times.size() >= 500 && censored == 0 ? quantile(times, .95) : null);
            values.put("p99Millis", times.size() >= 1000 && censored == 0 ? quantile(times, .99) : null);
            values.put("maxMillis", times.isEmpty() ? null : times.getLast()); result.put(scenario, values);
        }
        return result;
    }
    private static Double quantile(List<Double> sorted, double percentile) { return sorted.isEmpty() ? null : sorted.get(Math.max(0, (int) Math.ceil(sorted.size() * percentile) - 1)); }
    private static Map<String, String> verifiedCgroup() throws Exception {
        var data = cgroup(); String[] cpu = data.get("cpu.max").split("\\s+");
        assertNotEquals("max", cpu[0]); assertTrue(Double.parseDouble(cpu[0]) / Double.parseDouble(cpu[1]) <= 1.25);
        assertTrue(Long.parseLong(data.get("memory.max")) <= 4L * 1024 * 1024 * 1024); return data;
    }
    private static Map<String, String> cgroup() throws Exception {
        var result = new LinkedHashMap<String, String>();
        for (String name : List.of("cpu.max", "cpu.stat", "memory.max", "memory.current", "memory.peak", "memory.events", "io.stat")) {
            Path path = Path.of("/sys/fs/cgroup", name); if (Files.exists(path)) result.put(name, Files.readString(path).strip());
        }
        return result;
    }
    private static String required(String key) { String value = System.getenv(key); if (value == null || value.isBlank()) throw new IllegalStateException("Missing " + key); return value; }
    private static long cpuNanos() { return ManagementFactory.getThreadMXBean().getCurrentThreadCpuTime(); }
    private static double millis(long start) { return (System.nanoTime() - start) / 1_000_000d; }
    private static final class Journal implements AutoCloseable {
        private final BufferedWriter writer; private final ObjectMapper json;
        Journal(Path path, ObjectMapper json) throws Exception { this.writer = Files.newBufferedWriter(path); this.json = json; }
        synchronized void event(String type, Object data) {
            try { writer.write(json.writeValueAsString(Map.of("at", Instant.now().toString(), "type", type, "data", data))); writer.newLine(); writer.flush(); }
            catch (Exception failure) { throw new IllegalStateException("Load evidence could not be persisted", failure); }
        }
        void failure(String type, Throwable failure) { event(type, Map.of("failureType", failure.getClass().getName(), "message", String.valueOf(failure.getMessage()))); }
        @Override public synchronized void close() throws Exception { writer.close(); }
    }
}
