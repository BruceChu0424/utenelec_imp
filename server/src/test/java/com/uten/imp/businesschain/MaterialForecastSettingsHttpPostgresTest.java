package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** Real HTTP/security/PG persistence: policy save and one goods binding survive changing prices. */
class MaterialForecastSettingsHttpPostgresTest extends AuthSessionPostgresTestSupport {
    private static final String SETTINGS = "/api/admin/system-settings";
    private static final String ENABLED = "material_forecast.enabled";
    private static final String MINUTES = "material_forecast.interval_minutes";
    private static final String HISTORY = "material_forecast.history_days";
    private static final String BUDGET = "material_forecast.backfill_budget";
    private static final String SERIES = "shfe_cu_main_daily";
    private static final Path SNAPSHOTS = temporaryDirectory();

    private static Path temporaryDirectory() {
        try {
            Path path = Files.createTempDirectory("uten-market-http-");
            path.toFile().deleteOnExit();
            return path;
        } catch (Exception error) {
            throw new ExceptionInInitializerError(error);
        }
    }

    @DynamicPropertySource
    static void marketProperties(DynamicPropertyRegistry registry) {
        registry.add("uten.material-forecast.snapshot-directory", () -> SNAPSHOTS.toString());
        registry.add("uten.material-forecast.manage-runtime", () -> "false");
    }

    @Test
    void portablePolicyUsesStepUpAndCasAndOneBindingReadsSubsequentMarketUpdates() throws Exception {
        String admin = adminToken();
        Map<String, JsonNode> before = settings(admin);
        assertEquals("true", before.get(ENABLED).path("value").asText());
        assertEquals("15", before.get(MINUTES).path("value").asText());
        assertEquals("material_market", before.get(MINUTES).path("category").asText());
        assertEquals(15, before.get(MINUTES).path("minValue").asInt());
        assertEquals(60, before.get(MINUTES).path("maxValue").asInt());

        Map<String, String> desired = new LinkedHashMap<>();
        desired.put(ENABLED, "false");
        desired.put(MINUTES, "16");
        desired.put(HISTORY, "1200");
        desired.put(BUDGET, "0");
        Object command = changes(before, desired);
        MvcResult noStepUp = mvc.perform(json(put(SETTINGS), command, admin)).andReturn();
        assertEquals(403, noStepUp.getResponse().getStatus(), body(noStepUp));
        assertEquals("REAUTH_REQUIRED", json(noStepUp).path("code").asText());
        assertEquals("true", settingValue(ENABLED));

        MvcResult saved = save(admin, command);
        assertEquals(200, saved.getResponse().getStatus(), body(saved));
        for (JsonNode item : json(saved)) {
            assertEquals("NEXT_SCHEDULED_RUN", item.path("applyMode").asText());
        }
        desired.forEach((key, value) -> assertEquals(value, settingValue(key)));

        // A stale page cannot replace the persisted sixteen-minute policy.
        MvcResult stale = save(admin, Map.of("changes", List.of(
                Map.of("key", MINUTES, "value", "17", "expectedValue", "15"))));
        assertEquals(409, stale.getResponse().getStatus(), body(stale));
        assertEquals("16", settingValue(MINUTES));

        // One invalid field rejects the whole batch, including a valid enabled change.
        MvcResult invalid = save(admin, Map.of("changes", List.of(
                Map.of("key", ENABLED, "value", "true", "expectedValue", "false"),
                Map.of("key", MINUTES, "value", "1", "expectedValue", "16"))));
        assertEquals(422, invalid.getResponse().getStatus(), body(invalid));
        assertEquals("false", settingValue(ENABLED));

        MvcResult enabled = save(admin, changes(settings(admin), Map.of(ENABLED, "true")));
        assertEquals(200, enabled.getResponse().getStatus(), body(enabled));
        JsonNode runtime = read(admin, SETTINGS + "/material-forecast-status");
        assertTrue(runtime.path("configuration").path("enabled").asBoolean());
        assertEquals(16, runtime.path("configuration").path("intervalMinutes").asInt());
        assertTrue(runtime.path("configuration").path("revision").asText().matches("[0-9a-f]{64}"));
        assertFalse(runtime.path("runtime").path("processRunning").asBoolean());
        assertFalse(runtime.toString().contains("pythonExecutable"));
        assertFalse(runtime.toString().contains("snapshotDirectory"));

        UUID goods = goodsFixture();
        String market = "/api/master/goods/" + goods + "/price-analysis/market";
        assertTrue(read(admin, market + "/catalog").size() >= 3);
        MvcResult linked = mvc.perform(json(put(market),
                Map.of("seriesId", SERIES, "expectedVersion", 0), admin)).andReturn();
        assertEquals(200, linked.getResponse().getStatus(), body(linked));
        assertEquals(1, json(linked).path("bindingVersion").asLong());
        assertEquals(SERIES, json(linked).path("benchmark").path("seriesId").asText());

        // Simulate completed collector publications; no second binding command occurs.
        publish("80000", "a");
        JsonNode first = read(admin, market);
        assertEquals("BASELINE_ONLY", first.path("status").asText());
        assertEquals("80000", first.path("current").path("latestPrice").asText());
        publish("81000", "b");
        JsonNode second = read(admin, market);
        assertEquals("81000", second.path("current").path("latestPrice").asText());
        assertEquals(1, second.path("bindingVersion").asLong());
        assertEquals(SERIES, second.path("seriesId").asText());
        assertEquals(1L, jdbc.queryForObject(
                "SELECT version FROM goods_market_reference_bindings WHERE goods_id=?", Long.class, goods));
        assertEquals("16", settingValue(MINUTES));
        assertEquals("true", settingValue(ENABLED));
    }

    @Test
    void ordinaryEmployeeCannotReadRuntimeOrWritePortablePolicy() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        MvcResult status = mvc.perform(get(SETTINGS + "/material-forecast-status")
                .header("Authorization", "Bearer " + employee.accessToken())).andReturn();
        assertEquals(403, status.getResponse().getStatus(), body(status));
        String current = settingValue(MINUTES);
        MvcResult write = mvc.perform(json(put(SETTINGS), Map.of("changes", List.of(
                        Map.of("key", MINUTES, "value", "30", "expectedValue", current))), employee.accessToken())
                .header("X-Uten-Step-Up", stepUp(employee.accessToken(), EMPLOYEE_PASSWORD))).andReturn();
        assertEquals(403, write.getResponse().getStatus(), body(write));
        assertEquals(current, settingValue(MINUTES));
    }

    private Map<String, JsonNode> settings(String token) throws Exception {
        Map<String, JsonNode> result = new LinkedHashMap<>();
        for (JsonNode item : read(token, SETTINGS)) {
            result.put(item.path("key").asText(), item);
        }
        assertTrue(result.keySet().containsAll(List.of(ENABLED, MINUTES, HISTORY, BUDGET)));
        return result;
    }

    private Object changes(Map<String, JsonNode> before, Map<String, String> requested) {
        List<Map<String, String>> items = new ArrayList<>();
        requested.forEach((key, value) -> items.add(Map.of(
                "key", key, "value", value, "expectedValue", before.get(key).path("value").asText())));
        return Map.of("changes", items);
    }

    private MvcResult save(String token, Object command) throws Exception {
        return mvc.perform(json(put(SETTINGS), command, token)
                .header("X-Uten-Step-Up", stepUp(token, ADMIN_PASSWORD))).andReturn();
    }

    private JsonNode read(String token, String path) throws Exception {
        MvcResult result = mvc.perform(get(path).header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private String settingValue(String key) {
        return jdbc.queryForObject("SELECT value FROM system_settings WHERE key=?", String.class, key);
    }

    private UUID goodsFixture() {
        UUID id = UUID.randomUUID();
        UUID actor = jdbc.queryForObject("SELECT id FROM users WHERE login_account=?", UUID.class, ADMIN_LOGIN);
        new TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource())).executeWithoutResult(status -> {
            jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)", String.class, actor.toString());
            jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'market HTTP fixture',"
                    + "(SELECT coalesce(max(code_sequence),0)+1 FROM goods))", id, "MHTTP-" + id);
        });
        return id;
    }

    private void publish(String amount, String digestCharacter) throws Exception {
        JsonNode catalog;
        try (var input = getClass().getResourceAsStream("/pricing/material-benchmarks.json")) {
            assertNotNull(input);
            catalog = objectMapper.readTree(input);
        }
        JsonNode definition = catalog.get(0);
        assertEquals(SERIES, definition.path("seriesId").asText());
        ObjectNode snapshot = objectMapper.createObjectNode();
        for (String key : List.of("seriesId", "name", "commodity", "market", "grade", "region",
                "currency", "unit", "priceBasis", "sourceName", "sourceUrl", "rollPolicy")) {
            snapshot.set(key, definition.get(key));
        }
        Instant now = Instant.now().minusMillis(50);
        snapshot.put("schemaVersion", 2).put("authorized", true)
                .put("dataAsOf", LocalDate.ofInstant(now, ZoneId.of("Asia/Shanghai")).toString())
                .put("generatedAt", now.toString()).put("sourceFetchedAt", now.toString())
                .put("latestPrice", amount).put("status", "BASELINE_ONLY")
                .put("modelVersion", "Naive/http-contract").put("libraryVersion", "2.1.1")
                .put("datasetDigest", digestCharacter.repeat(64))
                .put("validationBasis", "LATEST_HISTORY_REPLAY")
                .put("modelPriceBasis", "CHAIN_LINKED_CURRENT_ANCHOR")
                .put("quoteContract", "cu2611").put("historyRecordCount", 4)
                .put("procurementSignal", "INSUFFICIENT");
        snapshot.putArray("reasonCodes").add("INSUFFICIENT_BACKTEST_FOLDS").add("LATEST_HISTORY_REPLAY");
        ObjectNode validation = snapshot.putObject("validation");
        validation.put("passed", false).put("folds", 0);
        for (String key : List.of("baselineMAE", "modelMAE", "coverage80", "backtestStart", "backtestEnd")) {
            validation.putNull(key);
        }
        var forecasts = snapshot.putArray("forecasts");
        BigDecimal value = new BigDecimal(amount);
        for (int horizon : List.of(1, 5, 20)) {
            forecasts.addObject().put("horizon", horizon).put("price", amount)
                    .put("lower80", value.subtract(BigDecimal.valueOf(100)).toPlainString())
                    .put("upper80", value.add(BigDecimal.valueOf(100)).toPlainString())
                    .put("direction", "UNCERTAIN");
        }
        Path target = SNAPSHOTS.resolve(SERIES + ".json");
        target.toFile().deleteOnExit();
        objectMapper.writeValue(target.toFile(), snapshot);
    }
}
