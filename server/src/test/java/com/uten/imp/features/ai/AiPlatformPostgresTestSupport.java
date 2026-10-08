package com.uten.imp.features.ai;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 公共 AI 平台的真库测试底座(ADR-133): 真实 PostgreSQL + 全部迁移 + 完整安全过滤链 + 真实后台线程,
 * AI 服务商是 {@link FakeAiProviderServer}(本机部署 http://127.0.0.1)。子类共享同一个 Spring 上下文。
 *
 * <p>测试用任务处理器 {@code PLATFORM_TEST}: 参数 mode = echo(默认, ai=1 时调用一次 AI) / sleep(一直报进度直到
 * 被取消) / fail(抛出业务异常); 提交时 mode=deny 拒绝; 结果里的 secretField 在读取时被过滤掉。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev",
        "uten.storage.malware-scan.provider=test-only",
        "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.jwt.secret=ai-platform-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=ai-platform-pgp-key-0123456789-test-only",
        "uten.crypto.hmac-key=ai-platform-hmac-key-0123456789-test-only",
        "uten.bootstrap.admin-login=ai-platform-admin",
        "uten.bootstrap.admin-password=AiPlatformBoot-1!",
        "uten.ai.job-poll-initial-delay-ms=3600000",
        "uten.ai.housekeeping-initial-delay-ms=3600000",
        "uten.ai.max-jobs-per-user-per-day=500"
})
@AutoConfigureMockMvc
@Import(AiPlatformPostgresTestSupport.TestHandlers.class)
public abstract class AiPlatformPostgresTestSupport {

    public static final String KIND = "PLATFORM_TEST";
    protected static final String STEP_UP_HEADER = "X-Uten-Step-Up";
    protected static final String ADMIN_LOGIN = "ai-platform-admin";
    protected static final String ADMIN_INITIAL_PASSWORD = "AiPlatformBoot-1!";
    protected static final String ADMIN_PASSWORD = "AiPlatformAdmin-2!";
    protected static final String EMPLOYEE_PASSWORD = "AiPlatformStaff-3!";
    protected static final String PROVIDER_KEY = "sk-fake-provider-0123456789abcdefWXYZ";

    private static final AtomicInteger EMPLOYEE_SEQUENCE = new AtomicInteger();

    protected static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_imp")
            .withUsername("uten")
            .withPassword("uten");
    protected static final FakeAiProviderServer FAKE = FakeAiProviderServer.start();

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    /** 测试任务处理器。 */
    @TestConfiguration(proxyBeanMethods = false)
    public static class TestHandlers {
        @Bean
        AiJobHandler platformTestHandler() {
            return new PlatformTestHandler();
        }
    }

    static final class PlatformTestHandler implements AiJobHandler {
        @Override
        public String kind() {
            return KIND;
        }

        @Override
        public void authorizeSubmit(Map<String, String> params) {
            if ("deny".equals(params.get("mode"))) {
                throw new ApiException(ErrorCode.FORBIDDEN, "测试处理器拒绝提交");
            }
        }

        @Override
        public void validateInput(Map<String, String> params, AiJobInput input) {
            if (input.size() > 100_000) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "测试文件太大");
            }
        }

        @Override
        public long maxInputBytes() {
            return 1024 * 1024;
        }

        @Override
        public Set<String> acceptedKinds() {
            return Set.of("CSV", "XLSX", "PDF");
        }

        @Override
        public void authorizeRead(Map<String, String> params) {
        }

        @Override
        public Map<String, Object> filterResultForReader(Map<String, Object> result) {
            Map<String, Object> copy = new LinkedHashMap<>(result);
            copy.remove("secretField");
            return copy;
        }

        @Override
        public Map<String, Object> process(AiJobContext ctx) throws Exception {
            String mode = ctx.params().getOrDefault("mode", "echo");
            ctx.progress("READING", 10);
            if ("fail".equals(mode)) {
                throw new ApiException(ErrorCode.BUSINESS, "测试处理器拒绝了这个文件");
            }
            if ("sleep".equals(mode)) {
                for (int i = 0; i < 300 && !ctx.cancelled(); i++) {
                    ctx.progress("MATCHING", Math.min(90, 20 + i));
                    Thread.sleep(100);
                }
                return Map.of("slept", true);
            }
            Map<String, Object> result = new LinkedHashMap<>();
            Object principal = SecurityContextHolder.getContext().getAuthentication().getPrincipal();
            result.put("principal", principal instanceof AuthUser user ? user.getId().toString() : null);
            result.put("employee", String.valueOf(ctx.submittedByEmployee()));
            result.put("fileName", ctx.input().fileName());
            result.put("kind", ctx.input().kind());
            result.put("size", ctx.input().size());
            result.put("aiAllowed", ctx.aiAllowed());
            result.put("secretField", "hidden from readers");
            if ("1".equals(ctx.params().get("ai")) && ctx.aiAllowed()) {
                ctx.progress("EXTRACTING", 50);
                AiCompletionPort.AiCompletionResult reply = ctx.completeJson(new AiCompletionPort.AiCompletionRequest(
                        "PLATFORM_TEST", "Extract the client name.",
                        List.of(new AiCompletionPort.AiText(new String(ctx.input().bytes(), StandardCharsets.UTF_8),
                                true)), null, null, 256, null));
                result.put("ai", new ObjectMapper().readValue(reply.json(), Map.class));
            }
            return result;
        }
    }

    @Autowired
    protected MockMvc mvc;
    @Autowired
    protected ObjectMapper objectMapper;
    @Autowired
    protected JdbcTemplate jdbc;

    @BeforeEach
    void relaxRateLimits() {
        jdbc.update("UPDATE system_settings SET value = '100000' WHERE key = 'login_rate_limit_per_minute'");
        jdbc.update("UPDATE system_settings SET value = '1000000' WHERE key = 'login_ip_rate_limit_per_minute'");
        jdbc.update("DELETE FROM auth_step_up_states");
        FAKE.reset();
    }

    // ------------------------------------------------------------------ 账号

    protected String adminToken() throws Exception {
        MvcResult attempt = loginResult(ADMIN_LOGIN, ADMIN_PASSWORD);
        if (attempt.getResponse().getStatus() == 200) {
            return json(attempt).path("accessToken").asText();
        }
        JsonNode initial = login(ADMIN_LOGIN, ADMIN_INITIAL_PASSWORD);
        return changePassword(initial.path("accessToken").asText(), ADMIN_INITIAL_PASSWORD, ADMIN_PASSWORD)
                .path("accessToken").asText();
    }

    protected String stepUp(String token, String password) throws Exception {
        MvcResult result = mvc.perform(json(post("/api/auth/step-up"), Map.of("password", password), token))
                .andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result).path("stepUpToken").asText();
    }

    /** 员工账号(登录账号、users.id、员工 id、访问令牌)。 */
    protected record Staff(String loginAccount, String userId, String employeeId, String token) {
    }

    /**
     * 在持有 ai:use 的部门开一个员工账号; 没有这样的部门时先给行政人事部授权。授权会推进全局授权纪元,
     * 所以之后一律重新登录拿管理员令牌(调用方此前拿到的令牌可能已失效)。
     */
    protected Staff aiUser() throws Exception {
        String department = departmentWithAiUse();
        return newEmployee(adminToken(), department);
    }

    protected String departmentWithAiUse() {
        List<String> codes = jdbc.queryForList("""
                SELECT d.code FROM departments d
                JOIN department_permissions dp ON dp.department_id = d.id
                JOIN permissions p ON p.id = dp.permission_id
                WHERE p.code = 'ai:use' AND NOT d.is_deleted
                ORDER BY d.code
                """, String.class);
        if (!codes.isEmpty()) {
            return codes.get(0);
        }
        jdbc.update("""
                INSERT INTO department_permissions (department_id, permission_id)
                SELECT d.id, p.id FROM departments d, permissions p
                WHERE d.code = 'DEPT_HR' AND p.code = 'ai:use'
                ON CONFLICT DO NOTHING
                """);
        return "DEPT_HR";
    }

    protected Staff newEmployee(String adminToken, String departmentCode) throws Exception {
        int sequence = EMPLOYEE_SEQUENCE.incrementAndGet();
        String phone = "1370000" + String.format("%04d", sequence);
        String departmentId = jdbc.queryForObject(
                "SELECT id::text FROM departments WHERE code = ? AND NOT is_deleted", String.class, departmentCode);
        ObjectNode root = objectMapper.createObjectNode();
        ObjectNode profile = root.putObject("profile");
        profile.put("fullName", "AI 平台测试员工" + sequence);
        profile.put("idType", "身份证");
        profile.put("idNumber", idNumber(sequence));
        profile.put("phone", phone);
        ObjectNode employment = root.putObject("employment");
        LocalDate hired = LocalDate.now().minusDays(1);
        employment.put("departmentId", departmentId);
        employment.put("hireDate", hired.toString());
        employment.put("employmentType", "regular");
        employment.put("status", "active");
        employment.put("confirmedAt", hired.toString());
        root.putArray("emergencyContacts");
        root.putArray("certificates");
        root.putArray("educations");
        root.putObject("account").putArray("roles").add("employee");
        MvcResult created = mvc.perform(json(post("/api/org/employees"), root, adminToken)).andReturn();
        assertEquals(200, created.getResponse().getStatus(), body(created));
        JsonNode credential = json(created);
        String temporary = credential.path("temporaryPassword").asText();
        JsonNode first = login(phone, temporary);
        JsonNode changed = changePassword(first.path("accessToken").asText(), temporary, EMPLOYEE_PASSWORD);
        String userId = jdbc.queryForObject("SELECT id::text FROM users WHERE login_account = ?", String.class,
                phone);
        return new Staff(phone, userId, credential.path("employee").path("id").asText(),
                changed.path("accessToken").asText());
    }

    protected JsonNode login(String account, String password) throws Exception {
        MvcResult result = loginResult(account, password);
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    protected MvcResult loginResult(String account, String password) throws Exception {
        return mvc.perform(json(post("/api/auth/login"),
                Map.of("loginAccount", account, "password", password), null)).andReturn();
    }

    protected JsonNode changePassword(String token, String oldPassword, String newPassword) throws Exception {
        MvcResult result = mvc.perform(json(post("/api/auth/change-password"),
                Map.of("oldPassword", oldPassword, "newPassword", newPassword), token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    // ------------------------------------------------------------------ AI 服务商

    /** 本机部署的自定义服务商请求体, 指向假服务商。 */
    protected Map<String, Object> fakeProviderRequest(String name, String apiKey, Long version) {
        Map<String, Object> request = new LinkedHashMap<>();
        request.put("name", name);
        request.put("preset", "CUSTOM");
        request.put("region", "LOCAL");
        request.put("protocol", "OPENAI_CHAT");
        request.put("baseUrl", FAKE.openAiBaseUrl());
        request.put("model", "fake-model");
        request.put("apiKey", apiKey);
        request.put("enabled", true);
        request.put("supportsVision", false);
        if (version != null) {
            request.put("version", version);
        }
        return request;
    }

    /** 清空服务商后由超管经接口新建一个默认服务商(指向假服务商), 返回其 id。 */
    protected String resetToFakeDefaultProvider(String adminToken) throws Exception {
        jdbc.update("DELETE FROM ai_providers");
        MvcResult created = mvc.perform(json(post("/api/admin/ai/providers"),
                        fakeProviderRequest("假服务商", PROVIDER_KEY, null), adminToken)
                        .header(STEP_UP_HEADER, stepUp(adminToken, ADMIN_PASSWORD)))
                .andReturn();
        assertEquals(200, created.getResponse().getStatus(), body(created));
        return json(created).path("id").asText();
    }

    // ------------------------------------------------------------------ HTTP 小工具

    protected MockHttpServletRequestBuilder json(MockHttpServletRequestBuilder builder, Object body, String token)
            throws Exception {
        builder.contentType(MediaType.APPLICATION_JSON).content(objectMapper.writeValueAsBytes(body));
        if (token != null) {
            builder.header("Authorization", "Bearer " + token);
        }
        return builder;
    }

    protected MockHttpServletRequestBuilder authed(MockHttpServletRequestBuilder builder, String token) {
        return builder.header("Authorization", "Bearer " + token);
    }

    protected JsonNode getJson(String path, String token) throws Exception {
        MvcResult result = mvc.perform(authed(get(path), token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    protected JsonNode json(MvcResult result) throws Exception {
        return objectMapper.readTree(result.getResponse().getContentAsByteArray());
    }

    protected static String body(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }

    /** 通过校验位的 18 位身份证号。 */
    protected static String idNumber(int sequence) {
        String base = "11010819850101" + String.format("%03d", 100 + sequence % 900);
        int[] weights = {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
        char[] checks = {'1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'};
        int sum = 0;
        for (int i = 0; i < 17; i++) {
            sum += (base.charAt(i) - '0') * weights[i];
        }
        return base + checks[sum % 11];
    }
}
