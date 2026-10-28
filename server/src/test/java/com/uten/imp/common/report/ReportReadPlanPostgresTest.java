package com.uten.imp.common.report;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import javax.xml.parsers.SAXParserFactory;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.stream.IntStream;
import java.util.zip.ZipFile;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

/**
 * Actual PostgreSQL execution for all six shared executors and a bounded export/read competition
 * probe. Domain-specific projection and authorization suites remain separate required evidence.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReportReadPlanPostgresTest {
    private static final int ROWS = 100_000;
    private static final BigDecimal QUANTITY = new BigDecimal("1234567890123.123456789");
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("b1_report_read_probe").withReuse(false)
            .withCommand("postgres", "-c", "max_connections=12", "-c", "shared_buffers=64MB", "-c", "work_mem=4MB")
            .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig()
                    .withMemory(768L * 1024 * 1024).withNanoCPUs(1_000_000_000L));
    private static final String SELECT = "SELECT o.id AS \"rowId\",o.qty AS \"qty\",o.kind AS \"kind\"";
    private static final String FROM = "FROM b1_report_facts o";
    private static final Path EVIDENCE = Path.of("target-b1-report-probe");
    private static Connection reportConnection;
    private static NamedParameterJdbcTemplate named;
    private static JdbcTemplate ordinary;
    private static EntityManager em;
    private static org.hibernate.SessionFactory sessions;
    private static org.hibernate.Session session;
    private static final AtomicInteger statements = new AtomicInteger();
    private static final List<Map<String, Object>> metrics = new ArrayList<>();

    @BeforeAll static void start() throws Exception {
        PG.start();
        var dataSource = new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        ordinary = new JdbcTemplate(dataSource);
        ordinary.execute("CREATE TABLE b1_report_facts(id bigint PRIMARY KEY,qty numeric(30,9) NOT NULL,kind text NOT NULL,owner_key text NOT NULL)");
        ordinary.update("INSERT INTO b1_report_facts SELECT n,?::numeric,'类别-'||(n%3),'A' FROM generate_series(1,?) n", QUANTITY, ROWS);
        ordinary.execute("INSERT INTO b1_report_facts SELECT n,9999999999999,'不可见','OTHER' FROM generate_series(100001,100010) n");
        ordinary.execute("CREATE INDEX b1_report_facts_scope_qty_id ON b1_report_facts(owner_key,qty DESC,id ASC)");
        ordinary.execute("ANALYZE b1_report_facts");
        // All report pages in this test use one actual, stable, read-only PostgreSQL snapshot.
        reportConnection = DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        reportConnection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
        reportConnection.setReadOnly(true);
        reportConnection.setAutoCommit(false);
        named = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(reportConnection, true));
        var configuration = new org.hibernate.cfg.Configuration()
                .setProperty("hibernate.hbm2ddl.auto", "none")
                .setProperty("hibernate.show_sql", "false")
                .setProperty("hibernate.connection.provider_disables_autocommit", "true");
        configuration.getProperties().put("hibernate.connection.datasource", new SingleConnectionDataSource(reportConnection, true));
        configuration.setStatementInspector(sql -> { statements.incrementAndGet();return sql; });
        sessions = configuration.buildSessionFactory();session = sessions.openSession();
        session.setDefaultReadOnly(true);session.beginTransaction();em = session;
        Files.createDirectories(EVIDENCE);
        Path previous = EVIDENCE.resolve("metrics.json");
        if (Files.exists(previous)) Files.copy(previous,
                EVIDENCE.resolve("metrics-previous-" + System.currentTimeMillis() + ".json"));
    }

    @AfterAll static void stop() throws Exception {
        try {
            Files.createDirectories(EVIDENCE);
            new ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(EVIDENCE.resolve("metrics.json").toFile(), metrics);
        } finally {
            if (session != null) { if (session.getTransaction().isActive()) {session.getTransaction().rollback();} session.close(); }
            if (sessions != null) sessions.close();
            if (reportConnection != null) { reportConnection.rollback(); reportConnection.close(); }
            PG.stop();
        }
    }

    @AfterEach void clearSnapshotFlags() { TransactionSynchronizationManager.clear();Thread.interrupted(); }

    private static void actualSnapshotContext() throws Exception {
        assertThat(reportConnection.getAutoCommit()).isFalse();
        assertThat(reportConnection.getTransactionIsolation()).isEqualTo(Connection.TRANSACTION_REPEATABLE_READ);
        assertThat(named.queryForObject("SHOW transaction_read_only", Map.of(), String.class)).isEqualTo("on");
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);
    }

    private static long portals() {
        return Objects.requireNonNull(named.queryForObject(
                "SELECT count(*) FROM pg_cursors WHERE name LIKE 'C_%' AND statement LIKE '%b1_report_facts%'", Map.of(), Long.class));
    }

    private record Domain(Object service, Method execute, Object where, List<?> columns) {
        Object read(int page, int size) throws Exception {
            var facet = new ReportQueryKit.FacetSpec("kind", "o.kind AS v,o.kind AS lbl", "o.kind", "o.kind", "text");
            return execute.invoke(service, columns, SELECT, FROM, where, "o.id", List.of(facet), Map.of(), page, size, "qty", "desc");
        }
    }

    private static Domain domain(String name) throws Exception {
        String prefix = "com.uten.imp.features." + name + ".report.";
        Class<?> type = Class.forName(prefix + Character.toUpperCase(name.charAt(0)) + name.substring(1) + "ReportService");
        Constructor<?> constructor = type.getConstructors()[0];
        Object service = constructor.newInstance(Arrays.stream(constructor.getParameterTypes())
                .map(parameter -> parameter == EntityManager.class ? em : mock(parameter)).toArray());
        Method execute = Arrays.stream(type.getDeclaredMethods()).filter(method -> method.getName().equals("execute"))
                .filter(method -> method.getParameterCount() == 11)
                .findFirst().orElseThrow();
        execute.setAccessible(true);
        Class<?> whereType = execute.getParameterTypes()[3];
        Constructor<?> createWhere = whereType.getDeclaredConstructor(String.class);
        createWhere.setAccessible(true);
        Object where = createWhere.newInstance("WHERE o.owner_key=:owner");
        Method add = whereType.getMethod("add", String.class, String.class, Object.class);
        add.setAccessible(true);
        add.invoke(where, "1=1", "owner", "A");
        Class<?> column = Class.forName(prefix + "ReportColumn");
        Object id = column.getMethod("number", String.class, String.class).invoke(null, "rowId", "行号");
        Object quantity = column.getMethod("number", String.class, String.class).invoke(null, "qty", "数量");
        quantity = column.getMethod("totaled", String.class).invoke(quantity, "合计数量");
        Object kind = column.getMethod("text", String.class, String.class).invoke(null, "kind", "类别");
        return new Domain(service, execute, where, List.of(id, quantity, kind));
    }

    @SuppressWarnings("unchecked") private static List<Map<String, Object>> rows(Object response) {
        try { return (List<Map<String, Object>>) response.getClass().getMethod("rows").invoke(response); }
        catch (ReflectiveOperationException error) { throw new IllegalStateException(error); }
    }
    private static long total(Object response) {
        try { return ((Number) response.getClass().getMethod("total").invoke(response)).longValue(); }
        catch (ReflectiveOperationException error) { throw new IllegalStateException(error); }
    }

    @Test void realSqlHonorsAllIndependentMetadataPlansAcrossEveryDomainAndStableSameValuePages() throws Exception {
        for (String name : List.of("sales", "purchase", "subcontract", "production", "stock", "finance")) {
            Domain domain = domain(name);
            for (int bits = 0; bits < 8; bits++) {
                var plan = new ReportReadPlan((bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0);
                int before = statements.get();
                Object response;
                try (var ignored = ReportReadPlan.open(plan)) { response = domain.read(2, 7); }
                assertThat(statements.get() - before).as("%s plan %s actual SQL work", name, bits)
                        .isEqualTo(1 + (plan.includeCount() ? 1 : 0) + (plan.includeFacets() ? 1 : 0) + (plan.includeTotals() ? 1 : 0));
                assertThat(total(response)).isEqualTo(plan.includeCount() ? ROWS : -1);
                assertThat(rows(response)).extracting(row -> ((Number) row.get("rowId")).longValue())
                        .containsExactly(8L, 9L, 10L, 11L, 12L, 13L, 14L);
                assertThat(rows(response)).allSatisfy(row -> assertThat(row).containsEntry("qty", QUANTITY)
                        .containsEntry("qtyExact", QUANTITY.toPlainString()));
                Map<?, ?> facets = (Map<?, ?>) response.getClass().getMethod("facets").invoke(response);
                assertThat(facets.size()).isEqualTo(plan.includeFacets() ? 1 : 0);
                @SuppressWarnings("unchecked") List<ReportTotal> totals =
                        (List<ReportTotal>) response.getClass().getMethod("totals").invoke(response);
                if (plan.includeTotals()) assertThat(totals.getFirst().groups().getFirst().value())
                        .isEqualByComparingTo(QUANTITY.multiply(BigDecimal.valueOf(ROWS)));
                else assertThat(totals).isEmpty();
            }
            List<Long> ids = new ArrayList<>();
            try (var ignored = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
                for (int page = 1; page <= 20; page++) for (var row : rows(domain.read(page, 7)))
                    ids.add(((Number) row.get("rowId")).longValue());
                assertThat(rows(domain.read(Integer.MAX_VALUE, 500))).isEmpty();
            }
            assertThat(ids).containsExactlyElementsOf(IntStream.rangeClosed(1, 140).mapToObj(value -> (long) value).toList());
        }
    }

    @Test void cursorClosesItsRealPostgresPortalOnEarlyExitCriteriaDriftAndCancellation() throws Exception {
        assertThat(portals()).isZero();actualSnapshotContext();Domain domain = domain("sales");
        try (var plan = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY);var cursor = ReportExportCursor.open()) {
            assertThat(rows(domain.read(1, 7))).hasSize(7);
            assertThat(portals()).isEqualTo(1);
            assertThat(((Number) em.createNativeQuery("SELECT COUNT(*) FROM b1_report_facts WHERE id>1")
                    .getSingleResult()).longValue()).isEqualTo(100_009);
            assertThat(rows(domain.read(2, 7))).extracting(row -> row.get("rowId"))
                    .containsExactly(8L,9L,10L,11L,12L,13L,14L);
            assertThat(portals()).isEqualTo(1);
        }
        assertThat(portals()).isZero();
        try (var plan = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY);var cursor = ReportExportCursor.open()) {
            domain.read(1, 7);
            Domain changed = domain("sales");
            ((ReportQueryKit.WhereBuilder) changed.where()).add("o.id>:minimum", "minimum", 1L);
            assertThatThrownBy(() -> changed.read(2, 7)).hasRootCauseInstanceOf(IllegalStateException.class);
            assertThat(portals()).isZero();
        }
        try (var plan = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY);var cursor = ReportExportCursor.open()) {
            domain.read(1, 7);Thread.currentThread().interrupt();
            try {
                assertThatThrownBy(() -> domain.read(2, 7)).hasRootCauseInstanceOf(CancellationException.class);
            } finally { Thread.interrupted(); }
        }
        assertThat(portals()).isZero();
    }

    @ParameterizedTest @ValueSource(booleans = {false, true})
    void oneHundredThousandRowsStreamWithOrdinaryIndexedReadsAndInspectableResourceEvidence(boolean useCursor) throws Exception {
        Domain domain = domain("sales");
        List<Double> baseline = ordinaryReads(150, null);
        AtomicBoolean exporting = new AtomicBoolean(true);
        AtomicLong peakHeap = new AtomicLong(heap());
        AtomicLong peakTemp = new AtomicLong();
        AtomicInteger maxBatch = new AtomicInteger();
        AtomicInteger batches = new AtomicInteger();
        Path directory = Files.createTempDirectory(EVIDENCE, "stream-");
        Path file = directory.resolve("data.xlsx");
        var executor = Executors.newFixedThreadPool(2);
        var sampler = Executors.newSingleThreadScheduledExecutor();
        long heapBefore = heap();
        long start = System.nanoTime();
        long cpuBefore = ProcessHandle.current().info().totalCpuDuration().orElseThrow().toNanos();
        int sqlBefore = statements.get();
        Future<List<Double>> competing = executor.submit(() -> ordinaryReads(150, exporting));
        sampler.scheduleAtFixedRate(() -> {
            peakHeap.accumulateAndGet(heap(), Math::max);
            try (var paths = Files.list(directory)) {
                long size = paths.mapToLong(path -> { try { return Files.size(path); } catch (Exception missing) { return 0; } }).sum();
                peakTemp.accumulateAndGet(size, Math::max);
            } catch (Exception ignored) { }
        }, 0, 20, TimeUnit.MILLISECONDS);
        List<Double> exportPages = new ArrayList<>();
        ExportPayload exported;
        actualSnapshotContext();
        try (var cursor = useCursor ? ReportExportCursor.open() : null;
             var writer = new XlsxExportService().openStream(null, null, directory);
             var sink = ExportPageSink.open(page -> {
                 batches.incrementAndGet();maxBatch.accumulateAndGet(page.rows().size(), Math::max);writer.accept(page);
             })) {
            exported = ReportQueryKit.paginateAll(ROWS, (page, size) -> {
                long pageStart = System.nanoTime();
                try { return domain.read(page, size); }
                catch (Exception failure) { throw new IllegalStateException(failure); }
                finally { exportPages.add((System.nanoTime() - pageStart) / 1_000_000.0); }
            }, ReportReadPlanPostgresTest::total,
                    response -> List.of(new ExportColumn("rowId", "行号", "number"),
                            new ExportColumn("qty", "数量", "number"), new ExportColumn("kind", "类别", "text")),
                    ReportReadPlanPostgresTest::rows);
            try (var output = Files.newOutputStream(file)) { writer.finish(output); }
            assertThat(writer.rowCount()).isEqualTo(ROWS);
        } finally {
            exporting.set(false);sampler.shutdownNow();executor.shutdown();TransactionSynchronizationManager.clear();
        }
        List<Double> mixed = competing.get(60, TimeUnit.SECONDS);
        assertThat(exported.total()).isEqualTo(ROWS);
        assertThat(exported.rows()).isEmpty();
        assertThat(maxBatch).hasValue(500);
        assertThat(batches).hasValue(201); // The final empty page proves completion when count was omitted.
        assertThat(statements.get() - sqlBefore).isEqualTo(useCursor ? 1 : 201);
        verifyWorkbook(file);
        var evidence = new LinkedHashMap<String, Object>();
        evidence.put("at", Instant.now().toString());
        evidence.put("scope", "Actual six-domain shared SQL executor microbenchmark; domain workflows and browser/API SLA are separate gates");
        evidence.put("readMode", useCursor ? "hibernate-jdbc-cursor" : "offset-pages");
        evidence.put("rows", ROWS);evidence.put("postgresImage", "postgres:16-alpine");
        evidence.put("postgresVersion", ordinary.queryForObject("SELECT version()", String.class));
        evidence.put("containerMemoryBytes", 768L * 1024 * 1024);evidence.put("containerCpuCores", 1);
        evidence.put("jvmVersion", System.getProperty("java.version"));evidence.put("jvmMaxHeapBytes", Runtime.getRuntime().maxMemory());
        evidence.put("jvmProcessors", Runtime.getRuntime().availableProcessors());
        evidence.put("baselineIndexedRead", distribution(baseline));evidence.put("competingIndexedRead", distribution(mixed));
        evidence.put("exportPageSql", distribution(exportPages));
        evidence.put("pageTimingDefinition", "Native SQL read plus existing domain mapping/masking; workbook writing and API/browser latency are separate");
        evidence.put("exportElapsedMs", (System.nanoTime() - start) / 1_000_000.0);
        evidence.put("jvmCpuMs", (ProcessHandle.current().info().totalCpuDuration().orElseThrow().toNanos() - cpuBefore) / 1_000_000.0);
        evidence.put("heapBeforeBytes", heapBefore);evidence.put("peakHeapBytes", peakHeap.get());
        evidence.put("peakTemporaryDirectoryBytes", peakTemp.get());evidence.put("xlsxBytes", Files.size(file));
        evidence.put("actualExportSqlStatements", statements.get() - sqlBefore);evidence.put("maxRetainedInputBatchRows", maxBatch.get());
        evidence.put("snapshot", named.queryForObject("SELECT txid_current_snapshot()::text", Map.of(), String.class));
        evidence.put("firstPagePlan", explain(0));evidence.put("lastPagePlan", explain(99_500));
        if (useCursor) evidence.put("singleCursorScanPlan", explain(-1));
        evidence.put("sharedEnvironmentNote", "No shared database accessed; unrelated host work is not stopped. Timings include host contention and this JVM's preceding tests; no quiet production baseline is claimed.");
        var runtimeClasses = new TreeMap<String, String>();
        for (String name : List.of("common.report.ReportReadPlan", "common.report.ReportSort", "common.report.ReportQueryKit", "common.report.ReportExportCursor",
                "common.export.XlsxExportService", "features.sales.report.SalesReportService",
                "features.purchase.report.PurchaseReportService", "features.subcontract.report.SubcontractReportService",
                "features.production.report.ProductionReportService", "features.stock.report.StockReportService",
                "features.finance.report.FinanceReportService")) {
            String resource = "/com/uten/imp/" + name.replace('.', '/') + ".class";
            try (var bytes = ReportReadPlanPostgresTest.class.getResourceAsStream(resource)) {
                var digest = java.security.MessageDigest.getInstance("SHA-256");
                try(var hashing=new java.security.DigestOutputStream(java.io.OutputStream.nullOutputStream(), digest)) { Objects.requireNonNull(bytes).transferTo(hashing); }
                runtimeClasses.put(name, HexFormat.of().formatHex(digest.digest()));
            }
        }
        evidence.put("executedClassSha256", runtimeClasses);
        metrics.add(evidence);
        new ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(EVIDENCE.resolve("metrics.json").toFile(), metrics);
        System.out.println("B1_REPORT_PROBE mode=" + evidence.get("readMode") + " rows=" + ROWS + " sql=" + (statements.get() - sqlBefore)
                + " indexedMixed=" + distribution(mixed) + " peakHeap=" + peakHeap.get());
        // This is the frozen microbenchmark budget, not a claim about API or browser latency.
        assertThat(((Number) distribution(mixed).get("p95Ms")).doubleValue()).isLessThanOrEqualTo(500);
        assertThat(Files.size(file)).isLessThanOrEqualTo(256L * 1024 * 1024);
        Files.delete(file);Files.delete(directory);
    }

    private static List<Double> ordinaryReads(int minimum, AtomicBoolean exporting) throws Exception {
        List<Double> times = new ArrayList<>();
        int index = 0;
        while (index < minimum || (exporting != null && exporting.get())) {
            long start = System.nanoTime();
            BigDecimal value = ordinary.queryForObject("SELECT qty FROM b1_report_facts WHERE id=? AND owner_key='A'",
                    BigDecimal.class, 1L + (index++ * 7919L) % ROWS);
            assertThat(value).isEqualByComparingTo(QUANTITY);
            times.add((System.nanoTime() - start) / 1_000_000.0);
            if (exporting != null) Thread.sleep(2);
        }
        return times;
    }
    private static Map<String, Object> distribution(List<Double> values) {
        var sorted = values.stream().sorted().toList();
        return Map.of("samples", sorted.size(), "p95Ms", sorted.get((int) Math.ceil(sorted.size() * .95) - 1),
                "p99Ms", sorted.get((int) Math.ceil(sorted.size() * .99) - 1), "maxMs", sorted.getLast());
    }
    private static long heap() { return Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory(); }
    private static Object explain(int offset) throws Exception {
        String plan = named.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) " + SELECT + " " + FROM
                + " WHERE o.owner_key=:owner ORDER BY \"qty\" DESC,o.id" + (offset < 0 ? "" : " LIMIT :limit OFFSET :offset"),
                Map.of("owner", "A", "limit", 500, "offset", offset), (rs, number) -> rs.getString(1));
        return new ObjectMapper().readTree(plan);
    }
    private static void verifyWorkbook(Path file) throws Exception {
        AtomicInteger count = new AtomicInteger();
        AtomicInteger verifiedIds = new AtomicInteger();
        AtomicInteger verifiedQuantities = new AtomicInteger();
        AtomicInteger verifiedKinds = new AtomicInteger();
        var parser = SAXParserFactory.newInstance();
        parser.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        try (var archive = new ZipFile(file.toFile()); var sheet = archive.getInputStream(archive.getEntry("xl/worksheets/sheet1.xml"))) {
            parser.newSAXParser().parse(sheet, new org.xml.sax.helpers.DefaultHandler() {
                int row;String cell;String valueElement;StringBuilder value;
                @Override public void startElement(String uri, String local, String name, org.xml.sax.Attributes attributes) throws org.xml.sax.SAXException {
                    if (name.equals("row")) {
                        try { row = Integer.parseInt(attributes.getValue("r")); }
                        catch(NumberFormatException invalid) { throw new org.xml.sax.SAXException("Worksheet row identity is invalid",invalid); }
                        if (row > 1) count.incrementAndGet();
                    }
                    if (name.equals("c")) cell = attributes.getValue("r");
                    if (name.equals("v") || name.equals("t")) { value = new StringBuilder();valueElement = name; }
                }
                @Override public void characters(char[] chars, int start, int length) { if (value != null) value.append(chars, start, length); }
                @Override public void endElement(String uri, String local, String name) {
                    if (name.equals(valueElement) && row > 1) {
                        if (cell.equals("A" + row)) {
                            assertThat(new BigDecimal(value.toString()).longValueExact()).isEqualTo(row - 1L);verifiedIds.incrementAndGet();
                        }
                        if (cell.equals("B" + row)) {
                            assertThat(value.toString()).isEqualTo(QUANTITY.toPlainString());verifiedQuantities.incrementAndGet();
                        }
                        if (cell.equals("C" + row)) {
                            assertThat(value.toString()).isEqualTo("类别-" + ((row - 1) % 3));verifiedKinds.incrementAndGet();
                        }
                    }
                    if (name.equals(valueElement)) { value = null;valueElement = null; }
                }
            });
        }
        assertThat(count).hasValue(ROWS);assertThat(verifiedIds).hasValue(ROWS);assertThat(verifiedQuantities).hasValue(ROWS);
        assertThat(verifiedKinds).hasValue(ROWS);
    }
}
