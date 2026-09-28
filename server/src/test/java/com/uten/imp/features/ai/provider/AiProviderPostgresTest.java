package com.uten.imp.features.ai.provider;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/**
 * AI 服务设置的真库 + 全安全链测试(ADR-133): 只给超管、写入要再认证、密钥只写不读、
 * 新建/改/删之后审计里没有任何密文或明文密钥、用已保存密钥测试只发往保存的地址。
 */
class AiProviderPostgresTest extends AiPlatformPostgresTestSupport {

    private static final String SECOND_KEY = "sk-fake-rotated-9876543210zyxwvABCD";

    private int auditRowsContaining(String needle) {
        Integer count = jdbc.queryForObject("""
                SELECT count(*) FROM audit_log
                WHERE strpos(concat_ws('|', action, target_type, target_id, result, before::text, after::text,
                                       http_path), ?) > 0
                """, Integer.class, needle);
        return count == null ? 0 : count;
    }

    private String storedSecret(String id) {
        return jdbc.queryForObject("SELECT secret FROM ai_providers WHERE id = ?::uuid", String.class, id);
    }

    @Test
    void onlySuperAdminsCanSeeTheSettings() throws Exception {
        Staff staff = aiUser();
        String admin = adminToken();

        MvcResult denied = mvc.perform(authed(get("/api/admin/ai/providers"), staff.token())).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
        MvcResult presets = mvc.perform(authed(get("/api/admin/ai/presets"), admin)).andReturn();
        assertEquals(200, presets.getResponse().getStatus(), body(presets));
        JsonNode view = json(presets);
        assertThat(view.path("allowOverseas").asBoolean(true)).isFalse();
        assertThat(view.path("presets").size()).isEqualTo(AiProviderPreset.values().length);
    }

    @Test
    void keyIsWriteOnlyStepUpIsRequiredAndAuditNeverHoldsCiphertextOrKey() throws Exception {
        jdbc.update("DELETE FROM ai_providers");
        String admin = adminToken();
        List<String> ciphertexts = new ArrayList<>();

        MvcResult withoutStepUp = mvc.perform(json(post("/api/admin/ai/providers"),
                fakeProviderRequest("审计测试", PROVIDER_KEY, null), admin)).andReturn();
        assertEquals(403, withoutStepUp.getResponse().getStatus(), body(withoutStepUp));
        assertThat(json(withoutStepUp).path("code").asText()).isEqualTo("REAUTH_REQUIRED");

        MvcResult created = mvc.perform(json(post("/api/admin/ai/providers"),
                        fakeProviderRequest("审计测试", PROVIDER_KEY, null), admin)
                        .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD)))
                .andReturn();
        assertEquals(200, created.getResponse().getStatus(), body(created));
        assertThat(body(created)).doesNotContain(PROVIDER_KEY);
        JsonNode provider = json(created);
        String id = provider.path("id").asText();
        assertThat(provider.path("apiKeyMasked").asText()).isEqualTo("••••WXYZ");
        assertThat(provider.path("isDefault").asBoolean()).isTrue();
        String firstSecret = storedSecret(id);
        assertThat(firstSecret).startsWith("gh1:").doesNotContain(PROVIDER_KEY);
        ciphertexts.add(firstSecret);

        MvcResult listed = mvc.perform(authed(get("/api/admin/ai/providers"), admin)).andReturn();
        assertThat(body(listed)).doesNotContain(PROVIDER_KEY).doesNotContain(firstSecret);

        Map<String, Object> modelChange = fakeProviderRequest("审计测试", null, provider.path("version").asLong());
        modelChange.put("model", "fake-model-2");
        MvcResult updated = mvc.perform(json(put("/api/admin/ai/providers/" + id), modelChange, admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, updated.getResponse().getStatus(), body(updated));
        assertThat(storedSecret(id)).isEqualTo(firstSecret);
        Integer modelRows = jdbc.queryForObject("""
                SELECT count(*) FROM audit_log
                WHERE target_type = 'ai_providers' AND action = 'update' AND after::text LIKE '%fake-model-2%'
                """, Integer.class);
        assertThat(modelRows).as("column-scoped row audit records the model change").isGreaterThanOrEqualTo(1);

        Map<String, Object> moved = fakeProviderRequest("审计测试", null, json(updated).path("version").asLong());
        moved.put("baseUrl", FAKE.rootUrl() + "/other/v1");
        MvcResult rejected = mvc.perform(json(put("/api/admin/ai/providers/" + id), moved, admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(422, rejected.getResponse().getStatus(), body(rejected));
        assertThat(json(rejected).path("message").asText()).isEqualTo("接口地址已修改, 请重新填写密钥");

        Map<String, Object> rotated = fakeProviderRequest("审计测试", SECOND_KEY, json(updated).path("version").asLong());
        MvcResult rotation = mvc.perform(json(put("/api/admin/ai/providers/" + id), rotated, admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, rotation.getResponse().getStatus(), body(rotation));
        String secondSecret = storedSecret(id);
        assertThat(secondSecret).isNotEqualTo(firstSecret);
        ciphertexts.add(secondSecret);

        // 删除带页面读到的版本号(查询参数 ?version=, DELETE 没有请求体): 过期版本 409, 当前版本才删。
        long currentVersion = json(rotation).path("version").asLong();
        MvcResult stale = mvc.perform(authed(delete("/api/admin/ai/providers/" + id)
                        .param("version", String.valueOf(currentVersion - 1)), admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(409, stale.getResponse().getStatus(), body(stale));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_providers WHERE id = ?::uuid", Integer.class, id))
                .isEqualTo(1);
        MvcResult deleted = mvc.perform(authed(delete("/api/admin/ai/providers/" + id)
                        .param("version", String.valueOf(currentVersion)), admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, deleted.getResponse().getStatus(), body(deleted));

        for (String ciphertext : ciphertexts) {
            assertThat(auditRowsContaining(ciphertext)).as("ciphertext must never reach audit_log").isZero();
            assertThat(auditRowsContaining(ciphertext.substring(4, 40))).isZero();
        }
        assertThat(auditRowsContaining(PROVIDER_KEY)).isZero();
        assertThat(auditRowsContaining(SECOND_KEY)).isZero();
        List<String> explicit = jdbc.queryForList("""
                SELECT action FROM audit_log WHERE target_type = 'ai_providers' AND target_id = ?
                  AND action LIKE 'ai_provider.%' ORDER BY id
                """, String.class, id);
        assertThat(explicit).containsExactly("ai_provider.create", "ai_provider.update", "ai_provider.update",
                "ai_provider.delete");
        Map<String, Object> rotationRow = jdbc.queryForMap("""
                SELECT result, after::text AS change FROM audit_log
                WHERE target_id = ? AND action = 'ai_provider.update'
                ORDER BY id DESC LIMIT 1
                """, id);
        assertThat(rotationRow.get("result")).isEqualTo("success");
        assertThat(String.valueOf(rotationRow.get("change"))).contains("密钥已更换(尾号 ABCD)").contains("审计测试");
        String risk = jdbc.queryForObject("""
                SELECT risk_level FROM audit_log WHERE target_id = ? AND action = 'ai_provider.create'
                """, String.class, id);
        assertThat(risk).isEqualTo("high");
    }

    @Test
    void typedKeyProbeNeedsNoStepUpButMustCarryAKey() throws Exception {
        String admin = adminToken();
        FAKE.models(List.of("fake-model"));
        Map<String, Object> probe = new LinkedHashMap<>();
        probe.put("preset", "CUSTOM");
        probe.put("region", "LOCAL");
        probe.put("protocol", "OPENAI_CHAT");
        probe.put("baseUrl", FAKE.openAiBaseUrl());
        probe.put("model", "fake-model");
        probe.put("apiKey", "sk-typed-probe-0123456789abcdefgh");

        MvcResult result = mvc.perform(json(post("/api/admin/ai/providers/test"), probe, admin)).andReturn();

        assertEquals(200, result.getResponse().getStatus(), body(result));
        JsonNode test = json(result);
        assertThat(test.path("ok").asBoolean()).isTrue();
        assertThat(test.path("steps").size()).isEqualTo(4);
        assertThat(FAKE.lastChatRequest().header("Authorization")).isEqualTo("Bearer sk-typed-probe-0123456789abcdefgh");
        Integer logged = jdbc.queryForObject(
                "SELECT count(*) FROM ai_call_logs WHERE purpose = 'CONNECTION_TEST' AND provider_id IS NULL AND ok",
                Integer.class);
        assertThat(logged).isGreaterThanOrEqualTo(1);

        Map<String, Object> deepSeekWithoutKey = new LinkedHashMap<>();
        deepSeekWithoutKey.put("preset", "DEEPSEEK");
        deepSeekWithoutKey.put("baseUrl", "https://api.deepseek.com");
        deepSeekWithoutKey.put("model", "deepseek-flash");
        MvcResult missingKey = mvc.perform(json(post("/api/admin/ai/providers/test"), deepSeekWithoutKey, admin))
                .andReturn();
        assertEquals(422, missingKey.getResponse().getStatus(), body(missingKey));

        MvcResult models = mvc.perform(json(post("/api/admin/ai/providers/models"), probe, admin)).andReturn();
        assertEquals(200, models.getResponse().getStatus(), body(models));
        assertThat(json(models).path("models").get(0).asText()).isEqualTo("fake-model");
    }

    @Test
    void storedKeyProbeRequiresStepUpAndOnlyGoesToTheStoredAddress() throws Exception {
        String admin = adminToken();
        String id = resetToFakeDefaultProvider(admin);
        Map<String, Object> sameAddress = Map.of("protocol", "OPENAI_CHAT", "baseUrl", FAKE.openAiBaseUrl() + "/",
                "model", "fake-model");

        MvcResult noStepUp = mvc.perform(json(post("/api/admin/ai/providers/" + id + "/test"), sameAddress, admin))
                .andReturn();
        assertEquals(403, noStepUp.getResponse().getStatus(), body(noStepUp));

        FakeAiProviderServer attacker = FakeAiProviderServer.start();
        try {
            MvcResult redirected = mvc.perform(json(post("/api/admin/ai/providers/" + id + "/test"),
                    Map.of("baseUrl", attacker.openAiBaseUrl()), admin)
                    .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
            assertEquals(422, redirected.getResponse().getStatus(), body(redirected));
            assertThat(attacker.requests()).isEmpty();
        } finally {
            attacker.close();
        }

        MvcResult tested = mvc.perform(json(post("/api/admin/ai/providers/" + id + "/test"), sameAddress, admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, tested.getResponse().getStatus(), body(tested));
        assertThat(json(tested).path("ok").asBoolean()).isTrue();
        assertThat(FAKE.lastChatRequest().header("Authorization")).isEqualTo("Bearer " + PROVIDER_KEY);
        Boolean lastOk = jdbc.queryForObject("SELECT last_test_ok FROM ai_providers WHERE id = ?::uuid",
                Boolean.class, id);
        assertThat(lastOk).isTrue();
    }

    @Test
    void staffStatusShowsAvailabilityAndPermissionWithoutProviderDetails() throws Exception {
        Staff staff = aiUser();
        resetToFakeDefaultProvider(adminToken());

        JsonNode status = getJson("/api/ai/status", staff.token());

        assertThat(status.path("available").asBoolean()).isTrue();
        assertThat(status.path("aiAllowedForMe").asBoolean()).isTrue();
        assertThat(status.has("providerName")).isFalse();
        assertThat(status.toString()).doesNotContain("假服务商").doesNotContain("fake-model");

        jdbc.update("UPDATE ai_providers SET enabled = false");
        assertThat(getJson("/api/ai/status", staff.token()).path("available").asBoolean()).isFalse();
        jdbc.update("UPDATE ai_providers SET enabled = true");
    }
}
