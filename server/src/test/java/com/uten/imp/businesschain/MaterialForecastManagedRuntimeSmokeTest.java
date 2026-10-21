package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.UtenImpApplication;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Opt-in acceptance against an actual offline runtime, public SHFE, full HTTP security,
 * and an independently restored PostgreSQL database. Ordinary CI uses deterministic
 * process/source tests; this test deliberately needs an operator supplied payload.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_MARKET_RUNTIME_SMOKE", matches = "(?i)true")
class MaterialForecastManagedRuntimeSmokeTest {
    private final List<ProcessHandle> crashTestChildren = new ArrayList<>();
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String LOGIN = "market-runtime-smoke";
    private static final String INITIAL_PASSWORD = "MarketSmokeInitial-1!";
    private static final String PASSWORD = "MarketSmokeChanged-2!";
    private static final String SETTINGS = "/api/admin/system-settings";
    private static final String SERIES = "shfe_cu_main_daily";
    private static final HttpClient HTTP = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();

    @Test
    @Timeout(value = 20, unit = TimeUnit.MINUTES)
    void oneBindingAndPortablePolicyWorkAfterRealCollectionRestartAndDatabaseRestore() throws Exception {
        Path payload = requiredPath("uten.market.test.payload");
        Path cache = requiredPath("uten.market.test.cache");
        Path python = requiredPath("uten.market.test.python");
        Path project = Path.of("").toAbsolutePath().normalize().getParent();
        Path evidenceRoot = project.resolve(".local-artifacts/material-managed");
        Files.createDirectories(evidenceRoot);
        Path work = Files.createTempDirectory(evidenceRoot, "runtime-acceptance-");
        Path firstHost = work.resolve("first-host");
        Path nextHost = work.resolve("restored-host");
        Map<String, Object> evidence = new LinkedHashMap<>();
        evidence.put("startedAt", Instant.now().toString());
        UUID goods;
        String firstRun;
        String revision;
        try (PostgreSQLContainer postgres = new PostgreSQLContainer("postgres:16-alpine")
                .withDatabaseName("uten_imp").withUsername("uten").withPassword("uten")) {
            postgres.start();
            try (ConfigurableApplicationContext context = start(postgres.getJdbcUrl(), firstHost, payload, cache, python)) {
                String base = base(context);
                String token = login(base, true);
                save(base, token, Map.of("material_forecast.interval_minutes", "16",
                        "material_forecast.history_days", "1200", "material_forecast.backfill_budget", "0"));
                goods = goods(context);
                String market = "/api/master/goods/" + goods + "/price-analysis/market";
                JsonNode binding = request(base, "PUT", market,
                        Map.of("seriesId", SERIES, "expectedVersion", 0), token, null);
                assertEquals(1, binding.path("bindingVersion").asInt());
                JsonNode collected = await("real SHFE publication", () -> {
                    JsonNode status = request(base, "GET", SETTINGS + "/material-forecast-status", null, token, null);
                    JSON.writerWithDefaultPrettyPrinter().writeValue(work.resolve("last-status.json").toFile(), status);
                    JsonNode read = request(base, "GET", market, null, token, null);
                    return status.path("runtime").path("configurationApplied").asBoolean()
                            && read.path("current").path("latestPrice").asDouble() > 0 ? status : null;
                });
                evidence.put("firstCollection", collected);
                assertEquals(1, request(base, "GET", market, null, token, null).path("bindingVersion").asInt());
                Path firstState = firstHost.resolve("media/material-forecast");
                firstRun = health(firstState).path("runId").asText();
                revision = collected.path("configuration").path("revision").asText();
                assertTrue(firstRun.matches("[0-9a-f-]{36}"));
                assertEquals(revision, health(firstState).path("configRevision").asText());

                // Destroy only the worker that this test's JVM owns for this private state directory.
                ProcessHandle child = ProcessHandle.current().children().filter(process -> {
                    String[] arguments = process.info().arguments().orElse(new String[0]);
                    return List.of(arguments).contains(firstState.toString()) && List.of(arguments).contains("--auto");
                }).findFirst().orElseThrow(() -> new AssertionError("Owned market worker missing"));
                crashTestChildren.addAll(child.descendants().toList());
                child.destroyForcibly();
                String beforeCrash = firstRun;
                await("worker crash recovery", () -> {
                    JsonNode status = request(base, "GET", SETTINGS + "/material-forecast-status", null, token, null);
                    JSON.writerWithDefaultPrettyPrinter().writeValue(work.resolve("last-status.json").toFile(), status);
                    return status.path("runtime").path("configurationApplied").asBoolean()
                            && !beforeCrash.equals(health(firstState).path("runId").asText()) ? status : null;
                });
                evidence.put("crashRecovered", true);
                save(base, token, Map.of("material_forecast.enabled", "false"));
                await("disabled acknowledgement", () -> {
                    JsonNode status = request(base, "GET", SETTINGS + "/material-forecast-status", null, token, null);
                    return "DISABLED".equals(status.path("runtime").path("state").asText())
                            && status.path("runtime").path("configurationApplied").asBoolean()
                            && !status.path("runtime").path("processRunning").asBoolean() ? status : null;
                });
                save(base, token, Map.of("material_forecast.enabled", "true"));
                await("enabled acknowledgement", () -> {
                    JsonNode status = request(base, "GET", SETTINGS + "/material-forecast-status", null, token, null);
                    return status.path("runtime").path("configurationApplied").asBoolean() ? status : null;
                });
                evidence.put("disableAndEnableApplied", true);
                firstRun = health(firstState).path("runId").asText();
                // Export while the collector is alive: the helper and writer share a short OS barrier.
                evidence.put("marketBackup", helper(project, python, "export", firstState, work.resolve("market-backup")));
                check(postgres.execInContainer("pg_dump", "-U", "uten", "-Fc", "-d", "uten_imp", "-f", "/tmp/market-smoke.dump"));
            }
            check(postgres.execInContainer("createdb", "-U", "uten", "restored_market"));
            check(postgres.execInContainer("pg_restore", "-U", "uten", "-d", "restored_market", "/tmp/market-smoke.dump"));
            Files.createDirectories(nextHost.resolve("media"));
            evidence.put("marketRestore", helper(project, python, "restore", work.resolve("market-backup"),
                    nextHost.resolve("media/material-forecast")));
            JsonNode offline = health(nextHost.resolve("media/material-forecast"));
            assertFalse(offline.path("autoUpdateEnabled").asBoolean());
            assertFalse(offline.has("runId"));
            assertFalse(offline.has("configRevision"));
            String restoredUrl = postgres.getJdbcUrl().replace("/uten_imp", "/restored_market");
            try (ConfigurableApplicationContext context = start(restoredUrl, nextHost, payload, cache, python)) {
                String base = base(context);
                String token = login(base, false);
                String oldRun = firstRun;
                JsonNode restored = await("restored host automatic acknowledgement", () -> {
                    JsonNode status = request(base, "GET", SETTINGS + "/material-forecast-status", null, token, null);
                    JSON.writerWithDefaultPrettyPrinter().writeValue(work.resolve("last-status.json").toFile(), status);
                    return status.path("runtime").path("configurationApplied").asBoolean()
                            && !oldRun.equals(health(nextHost.resolve("media/material-forecast")).path("runId").asText()) ? status : null;
                });
                assertEquals(revision, restored.path("configuration").path("revision").asText());
                assertEquals(16, restored.path("configuration").path("intervalMinutes").asInt());
                assertEquals(0, restored.path("configuration").path("backfillBudget").asInt());
                JsonNode read = request(base, "GET", "/api/master/goods/" + goods + "/price-analysis/market", null, token, null);
                assertEquals(1, read.path("bindingVersion").asInt());
                assertEquals(SERIES, read.path("benchmark").path("seriesId").asText());
                assertTrue(read.path("current").path("latestPrice").asDouble() > 0);
                evidence.put("restoredCollection", restored);
                evidence.put("restoredBindingVersion", read.path("bindingVersion").asInt());
                evidence.put("restoredPolicyRevisionUnchanged", true);
                evidence.put("migrationCount", context.getBean(JdbcTemplate.class).queryForObject(
                        "SELECT count(*) FROM flyway_schema_history WHERE success", Long.class));
            }
        }
        evidence.put("completedAt", Instant.now().toString());
        JSON.writerWithDefaultPrettyPrinter().writeValue(work.resolve("evidence.json").toFile(), evidence);
        System.out.println("Managed market acceptance evidence: " + work.resolve("evidence.json"));
    }

    @AfterEach
    void cleanUpOnlyRecordedPrivateWorkerDescendants() {
        for (ProcessHandle process : crashTestChildren) {
            if (process.isAlive()) {
                process.destroyForcibly();
            }
        }
    }

    private static ConfigurableApplicationContext start(String database, Path host, Path payload, Path cache, Path python) {
        return new SpringApplicationBuilder(UtenImpApplication.class).web(WebApplicationType.SERVLET).run(
                "--spring.profiles.active=dev", "--server.port=0", "--spring.datasource.url=" + database,
                "--spring.datasource.username=uten", "--spring.datasource.password=uten",
                "--uten.jwt.secret=market-runtime-jwt-secret-0123456789-test-only",
                "--uten.crypto.pgp-master-key=market-runtime-pgp-key-0123456789-test-only",
                "--uten.crypto.hmac-key=market-runtime-hmac-key-0123456789-test-only",
                "--uten.bootstrap.admin-login=" + LOGIN, "--uten.bootstrap.admin-password=" + INITIAL_PASSWORD,
                "--uten.material-forecast.manage-runtime=true", "--uten.material-forecast.payload-directory=" + payload,
                "--uten.material-forecast.cache-directory=" + cache, "--uten.material-forecast.base-python-executable=" + python,
                "--uten.storage.provider=local", "--uten.storage.local-dir=" + host.resolve("media"),
                "--uten.audit.retention.enabled=false", "--uten.reporting.materialized-view-refresh.enabled=false",
                "--logging.file.name=" + host.resolve("application.log"), "--logging.level.com.uten.imp=WARN");
    }

    private static String base(ConfigurableApplicationContext context) {
        return "http://127.0.0.1:" + ((WebServerApplicationContext) context).getWebServer().getPort();
    }

    private static String login(String base, boolean initial) throws Exception {
        JsonNode result = request(base, "POST", "/api/auth/login",
                Map.of("loginAccount", LOGIN, "password", initial ? INITIAL_PASSWORD : PASSWORD), null, null);
        String token = result.path("accessToken").asText();
        if (initial) {
            token = request(base, "POST", "/api/auth/change-password", Map.of("oldPassword", INITIAL_PASSWORD,
                    "newPassword", PASSWORD), token, null).path("accessToken").asText();
        }
        assertFalse(token.isBlank());
        return token;
    }

    private static void save(String base, String token, Map<String, String> values) throws Exception {
        JsonNode settings = request(base, "GET", SETTINGS, null, token, null);
        List<Map<String, Object>> changes = new ArrayList<>();
        for (JsonNode row : settings) {
            String key = row.path("key").asText();
            if (values.containsKey(key)) {
                changes.add(Map.of("key", key, "value", values.get(key), "expectedValue", row.path("value").asText()));
            }
        }
        assertEquals(values.size(), changes.size());
        String stepUp = request(base, "POST", "/api/auth/step-up", Map.of("password", PASSWORD), token, null)
                .path("stepUpToken").asText();
        request(base, "PUT", SETTINGS, Map.of("changes", changes), token, stepUp);
    }

    private static UUID goods(ConfigurableApplicationContext context) {
        JdbcTemplate jdbc = context.getBean(JdbcTemplate.class);
        UUID id = UUID.randomUUID();
        UUID actor = jdbc.queryForObject("SELECT id FROM users WHERE login_account=?", UUID.class, LOGIN);
        new TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource())).executeWithoutResult(status -> {
            jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)", String.class, actor.toString());
            jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'market runtime acceptance',"
                    + "(SELECT coalesce(max(code_sequence),0)+1 FROM goods))", id, "MRUNTIME-" + id);
        });
        return id;
    }

    private static JsonNode request(String base, String method, String path, Object body, String token, String stepUp) throws Exception {
        var builder = HttpRequest.newBuilder(URI.create(base + path)).timeout(Duration.ofSeconds(30))
                .header("Content-Type", "application/json");
        if (token != null) {
            builder.header("Authorization", "Bearer " + token);
        }
        if (stepUp != null) {
            builder.header("X-Uten-Step-Up", stepUp);
        }
        builder.method(method, body == null ? HttpRequest.BodyPublishers.noBody()
                : HttpRequest.BodyPublishers.ofByteArray(JSON.writeValueAsBytes(body)));
        var response = HTTP.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray());
        assertEquals(200, response.statusCode(), method + " " + path + " => " + new String(response.body(), java.nio.charset.StandardCharsets.UTF_8));
        return JSON.readTree(response.body());
    }

    private static JsonNode await(String description, Callable<JsonNode> probe) throws Exception {
        long deadline = System.nanoTime() + Duration.ofMinutes(5).toNanos();
        while (System.nanoTime() < deadline) {
            JsonNode value = probe.call();
            if (value != null) {
                return value;
            }
            Thread.sleep(1000);
        }
        throw new AssertionError("Timed out: " + description);
    }

    private static JsonNode health(Path state) throws Exception {
        Path file = state.resolve("auto-feed-health.json");
        return Files.isRegularFile(file) ? JSON.readTree(file.toFile()) : JSON.createObjectNode();
    }

    private static Path requiredPath(String property) {
        String value = System.getProperty(property);
        assertNotNull(value, "Missing opt-in test property " + property);
        Path path = Path.of(value).toAbsolutePath().normalize();
        assertTrue(Files.exists(path), "Missing opt-in test path " + property);
        return path;
    }

    private static JsonNode helper(Path project, Path python, String action, Path source, Path target) throws Exception {
        Process process = new ProcessBuilder(python.toString(), "-I", project.resolve("deploy/postgres/backup/market_state_backup.py").toString(),
                action, source.toString(), target.toString()).redirectError(ProcessBuilder.Redirect.INHERIT).start();
        byte[] output = process.getInputStream().readNBytes(65537);
        assertTrue(process.waitFor(60, TimeUnit.SECONDS));
        assertEquals(0, process.exitValue(), "Market-state helper failed");
        assertTrue(output.length < 65537);
        return JSON.readTree(output);
    }

    private static void check(org.testcontainers.containers.Container.ExecResult result) {
        assertEquals(0, result.getExitCode(), result.getStderr());
    }
}
