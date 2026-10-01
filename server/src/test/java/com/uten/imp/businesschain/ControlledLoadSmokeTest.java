package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.features.admin.serverstatus.ServerStatusService;
import com.uten.imp.features.ai.job.AiJobWorker;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchResult;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchResponse;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseTrigger;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.beans.factory.config.BeanFactoryPostProcessor;
import org.springframework.beans.factory.support.DefaultListableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.config.TaskManagementConfigUtils;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;

import java.lang.management.ManagementFactory;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** One context, one execution per real input, inside verified cgroups. Not an HTTP or percentile test. */
@EnabledIfEnvironmentVariable(named = "UTEN_CONTROLLED_LOAD", matches = "true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "spring.datasource.hikari.maximum-pool-size=8", "spring.datasource.hikari.minimum-idle=1",
        "uten.jwt.secret=controlled-load-isolated-fixture-only-0123456789",
        "uten.crypto.pgp-master-key=controlled-load-isolated-fixture-only-0123456789",
        "uten.crypto.hmac-key=controlled-load-isolated-fixture-only-0123456789",
        "uten.bootstrap.admin-login=controlled-load-test-only",
        "uten.bootstrap.admin-password=ControlledLoadTestOnly-1!"})
@Import({ControlledLoadSmokeTest.DiagnosticConfiguration.class,
        ProductionJdbcMeasurement.Configuration.class, ControlledLoadConnectionMetrics.Configuration.class})
class ControlledLoadSmokeTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        String url = required("UTEN_LOAD_DB_URL");
        if (!url.matches("jdbc:postgresql://uten-load-[a-z0-9-]+:5432/uten_load")) {
            throw new IllegalStateException("Controlled load requires its private named container/database");
        }
        properties.add("spring.datasource.url", () -> url);
        properties.add("spring.datasource.username", () -> required("UTEN_LOAD_DB_USER"));
        properties.add("spring.datasource.password", () -> required("UTEN_LOAD_DB_PASSWORD"));
        properties.add("uten.storage.local-dir", () -> "/tmp/uten-controlled-load-attachments");
    }

    /** Diagnostic profile only: keep real domain services, stop timer/async competition explicitly. */
    @TestConfiguration(proxyBeanMethods = false)
    static class DiagnosticConfiguration {
        @Bean static BeanFactoryPostProcessor disableAutomaticTimersForDiagnostic() {
            return factory -> {
                var definitions = (DefaultListableBeanFactory) factory;
                String name = TaskManagementConfigUtils.SCHEDULED_ANNOTATION_PROCESSOR_BEAN_NAME;
                if (definitions.containsBeanDefinition(name)) definitions.removeBeanDefinition(name);
            };
        }
    }

    @MockitoBean BusinessOutboxScheduler outboxWakeups;
    @MockitoBean AiJobWorker aiWakeups;
    @MockitoBean ServerStatusService statusSampler;
    @MockitoBean WorkshopMaterialCloseTrigger materialCloseWakeups;
    @MockitoSpyBean MaterialAnalysisService analyses;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ApplicationContext context;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired StockDocService stock;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired InventoryValueWorkService valueWork;
    @Autowired InventoryValuationPort values;

    @Test void oneControlledSmokePerFrozenInput() throws Exception {
        Path output = Path.of(required("UTEN_LOAD_OUTPUT"));
        Files.createDirectories(output);
        var manifest = new LinkedHashMap<String, Object>();
        var samples = new ArrayList<Map<String, Object>>();
        manifest.put("schema", "uten-controlled-load-smoke-v1");
        manifest.put("startedAt", Instant.now().toString());
        manifest.put("backgroundProfile", "DIAGNOSTIC_QUIET_SINGLE_CONTEXT");
        manifest.put("notCovered", List.of("HTTP/authentication/queueing", "Flutter rendering", "normal background load",
                "CPU/IO competition", "p95/p99", "long-run throughput", "company deployment"));
        manifest.put("disabledTimers", "all @Scheduled registrations removed in test context only");
        manifest.put("disabledIndependentWakeups", List.of("BusinessOutboxScheduler", "AiJobWorker", "ServerStatusService", "WorkshopMaterialCloseTrigger"));
        manifest.put("inventorySettlement", "real service explicitly drained outside measured command; pending costs may remain legally PENDING");
        manifest.put("samples", samples);
        try {
            assertFalse(context.containsBean(TaskManagementConfigUtils.SCHEDULED_ANNOTATION_PROCESSOR_BEAN_NAME));
            for (Object worker : List.of(outboxWakeups, aiWakeups, statusSampler, materialCloseWakeups)) {
                assertTrue(mockingDetails(worker).isMock());
            }
            manifest.put("applicationCgroup", verifiedCgroup());
            manifest.put("javaVersion", System.getProperty("java.version"));
            manifest.put("postgresVersion", db.queryForObject("SELECT version()", String.class));
            manifest.put("database", db.queryForObject("SELECT current_database()", String.class));
            assertEquals("uten_load", manifest.get("database"));
            manifest.put("migrations", db.queryForMap("SELECT count(*) AS count,max(version::int) AS head FROM flyway_schema_history WHERE success AND type='SQL'"));
            manifest.put("hikari", Map.of("maximumPoolSize", 8, "minimumIdle", 1));
            for (int size : List.of(1, 3, 11)) {
                var prepared = ControlledDailyReportInputs.prepare(beans, db, size, "load-" + UUID.randomUUID());
                execute(output, samples, new Input("daily-report-" + size, prepared.goodsIds(), prepared.command(),
                        prepared.verify(), prepared.metadata(), null, -1));
            }
            for (String mode : List.of("plain", "prestock", "mixed")) execute(output, samples, fqc(mode));
            for (int size : List.of(1, 3, 10)) execute(output, samples, draw(size));
            assertEquals(9, samples.size());
            manifest.put("outcome", "PASSED");
        } catch (Throwable failure) {
            manifest.put("outcome", "FAILED");
            manifest.put("failureType", failure.getClass().getName());
            manifest.put("failureMessage", failure.getMessage());
            throw failure;
        } finally {
            manifest.put("finishedAt", Instant.now().toString());
            manifest.put("applicationCgroupAfter", cgroupSnapshot());
            json.writerWithDefaultPrettyPrinter().writeValue(output.resolve("smoke-summary.json").toFile(), manifest);
            SecurityContextHolder.clearContext();
        }
    }

    private record Input(String name, Set<UUID> goods, Supplier<?> command, Runnable verify,
                         Map<String, Object> metadata, UUID analysisObserver, int expectedRefreshes) { }

    private void execute(Path output, List<Map<String, Object>> samples, Input input) throws Exception {
        var sample = new LinkedHashMap<String, Object>();
        sample.put("scenario", input.name()); sample.put("input", input.metadata());
        samples.add(sample);
        long preparation = System.nanoTime();
        InventoryValueWorkTestSupport.drain(valueWork, db, List.copyOf(input.goods()));
        sample.put("beforeFacts", ControlledLoadFacts.verify(db, values, input.goods()));
        sample.put("settlementAndBeforeVerificationMillis", elapsed(preparation));
        Object analysisTarget = AopTestUtils.getUltimateTargetObject(analyses);
        clearInvocations(analysisTarget);
        var jdbc = ProductionJdbcMeasurement.begin();
        var borrow = ControlledLoadConnectionMetrics.begin();
        long cpuBefore = cpuNanos(), started = System.nanoTime();
        sample.put("cgroupBefore", cgroupSnapshot());
        sample.put("startedAt", Instant.now().toString());
        try {
            Object result = input.command().get();
            sample.put("resultType", result == null ? "void" : result.getClass().getSimpleName());
            sample.put("outcome", "COMMITTED");
        } catch (Throwable failure) {
            sample.put("outcome", "FAILED"); sample.put("failureType", failure.getClass().getName());
            throw failure;
        } finally {
            sample.put("commandWallMillis", elapsed(started));
            sample.put("requestThreadCpuMillis", (cpuNanos() - cpuBefore) / 1_000_000.0);
            ControlledLoadConnectionMetrics.end(); ProductionJdbcMeasurement.end();
            sample.put("jdbc", jdbc.result()); sample.put("connectionAcquisition", borrow.result());
            sample.put("cgroupAfterCommand", cgroupSnapshot());
            json.writerWithDefaultPrettyPrinter().writeValue(output.resolve(input.name() + ".json").toFile(), sample);
        }
        assertEquals(1, jdbc.commits, input.name() + " must commit its real business command exactly once");
        assertEquals(0, jdbc.rollbacks);
        if (input.analysisObserver() != null) {
            long refreshes = mockingDetails(analysisTarget).getInvocations().stream()
                    .filter(call -> call.getMethod().getName().equals("refreshLocked") && call.getArguments().length == 1
                            && input.analysisObserver().equals(call.getArgument(0))).count();
            sample.put("analysisObserverRefreshes", refreshes);
            assertEquals(input.expectedRefreshes(), refreshes, "the FQC fixture must really observe the intended analysis refresh");
        }
        input.verify().run();
        long settlement = System.nanoTime();
        InventoryValueWorkTestSupport.drain(valueWork, db, List.copyOf(input.goods()));
        sample.put("settlementAfterMillis", elapsed(settlement));
        sample.put("afterFacts", ControlledLoadFacts.verify(db, values, input.goods()));
        sample.put("invariants", "PASSED");
        json.writerWithDefaultPrettyPrinter().writeValue(output.resolve(input.name() + ".json").toFile(), sample);
    }

    private Input fqc(String mode) {
        var fixture = new ProductionFqcPreStockBatchEndToEndTest();
        for (var entry : Map.<String, Object>of("beans", beans, "db", db, "analyses", analyses,
                "commands", analysisCommands, "stock", stock, "arrivals", arrivals).entrySet()) {
            ReflectionTestUtils.setField(fixture, entry.getKey(), entry.getValue());
        }
        Object scenario = ReflectionTestUtils.invokeMethod(fixture, "prepare", 20, mode);
        FullChainEndToEndTest.World world = ReflectionTestUtils.invokeMethod(scenario, "world");
        UUID report = ReflectionTestUtils.invokeMethod(scenario, "reportId");
        UUID watcher = ReflectionTestUtils.invokeMethod(scenario, "watcherAnalysis");
        List<UUID> inspections = ReflectionTestUtils.invokeMethod(scenario, "inspections");
        Integer prestock = ReflectionTestUtils.invokeMethod(scenario, "preStocked");
        assertNotNull(world); assertNotNull(report); assertNotNull(inspections); assertNotNull(prestock);
        var command = new PassAllBatchRequest(inspections, "controlled-fqc-" + report);
        Authentication actor = SecurityContextHolder.getContext().getAuthentication();
        return new Input("fqc-20-" + mode, goods(world), withActor(actor, () -> {
            PassAllBatchResult result = quality.passAll(command);
            assertFalse(result.replay()); assertEquals(20, result.items().size()); return result;
        }), () -> ReflectionTestUtils.invokeMethod(fixture, "assertFacts", scenario),
                Map.of("rows", 20, "route", mode, "preStockedRows", prestock, "reportId", report.toString(),
                        "source", "real priced OTHER_IN -> DRAW -> report -> arrival -> quality"), watcher, prestock == 0 ? 0 : 1);
    }

    private Input draw(int size) {
        var fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture);
        var world = fixture.seedWorld("load-draw-" + UUID.randomUUID());
        fixture.loginAs(world.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", world, Integer.toString(size * 10));
        List<UUID> documents = new ArrayList<>();
        for (int i = 0; i < size; i++) documents.add(ReflectionTestUtils.invokeMethod(fixture,
                "generateSingleWarehouseDraw", world, "load-draw-plan-" + UUID.randomUUID()));
        fixture.requestWorkshopDraws("load-draw-" + UUID.randomUUID(), documents);
        var command = new StockDocIssueBatchRequest();
        command.setIdempotencyKey("controlled-draw-" + UUID.randomUUID()); command.setDocIds(documents);
        Authentication actor = SecurityContextHolder.getContext().getAuthentication();
        return new Input("draw-" + size, goods(world), withActor(actor, () -> {
            StockDocIssueBatchResponse response = stock.issueFullBatch(command);
            assertEquals(size, response.issuedCount()); assertFalse(response.replayed()); return response;
        }), () -> {
            for (UUID id : documents) {
                assertEquals(1, db.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, id));
                assertEquals(0, db.queryForObject("SELECT count(*) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted AND issued_qty<>fn_production_draw_item_requested_qty(id)", Integer.class, id));
                assertEquals(1, db.queryForObject("SELECT count(*) FROM production_material_stock_events WHERE stock_document_id=? AND event_type='ISSUE'", Integer.class, id));
            }
            assertEquals(1, db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE idempotency_key=?", Integer.class, command.getIdempotencyKey()));
        }, Map.of("documents", size, "lines", size * 2, "outputPerPlan", 10,
                "source", "priced OTHER_IN B20+E10 per A10 plan, no direct balance insert"), null, -1);
    }

    private static Set<UUID> goods(FullChainEndToEndTest.World world) {
        return Set.of(world.goodsA(), world.goodsB(), world.goodsC(), world.goodsD(), world.goodsE());
    }
    private static Supplier<?> withActor(Authentication actor, Supplier<?> action) {
        return () -> {
            var prior = SecurityContextHolder.getContext(); var selected = SecurityContextHolder.createEmptyContext();
            selected.setAuthentication(actor); SecurityContextHolder.setContext(selected);
            try { return action.get(); } finally { SecurityContextHolder.setContext(prior); }
        };
    }
    private static String required(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) throw new IllegalStateException("Missing controlled test environment " + name);
        return value;
    }
    private static Map<String, String> verifiedCgroup() throws Exception {
        var snapshot = cgroupSnapshot();
        String[] cpu = snapshot.get("cpu.max").split("\\s+");
        assertNotEquals("max", cpu[0], "a JVM processor hint is not a cgroup quota");
        assertTrue(Double.parseDouble(cpu[0]) / Double.parseDouble(cpu[1]) <= 1.25);
        assertTrue(Long.parseLong(snapshot.get("memory.max")) <= 4L * 1024 * 1024 * 1024);
        return snapshot;
    }
    private static Map<String, String> cgroupSnapshot() throws Exception {
        var result = new LinkedHashMap<String, String>();
        for (String name : List.of("cpu.max", "cpu.stat", "memory.max", "memory.current", "memory.peak", "memory.events", "io.stat")) {
            Path file = Path.of("/sys/fs/cgroup", name);
            if (Files.exists(file)) result.put(name, Files.readString(file).strip());
        }
        return result;
    }
    private static long cpuNanos() { return ManagementFactory.getThreadMXBean().getCurrentThreadCpuTime(); }
    private static double elapsed(long start) { return (System.nanoTime() - start) / 1_000_000.0; }
}
