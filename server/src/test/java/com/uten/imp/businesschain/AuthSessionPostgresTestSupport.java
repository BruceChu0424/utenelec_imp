package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 服务端会话与再认证的真库测试底座 (ADR-110): 真实 PostgreSQL + 全部迁移 + 完整安全过滤链。
 * 用可控时钟 ({@link MutableClock}) 推进会话时间, 不必真的等待空闲超时; 同一配置的测试类共享
 * 一个 Spring 上下文与一个数据库。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev",
        "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false",
        "uten.jwt.secret=auth-session-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=auth-session-pgp-key-0123456789-test-only",
        "uten.crypto.hmac-key=auth-session-hmac-key-0123456789-test-only",
        "uten.bootstrap.admin-login=auth-session-admin",
        "uten.bootstrap.admin-password=AuthSessionBoot-1!"
})
@AutoConfigureMockMvc
@Import({AuthSessionPostgresTestSupport.ClockOverride.class, ProductionJdbcMeasurement.Configuration.class})
abstract class AuthSessionPostgresTestSupport {

    static final String ADMIN_LOGIN = "auth-session-admin";
    static final String ADMIN_INITIAL_PASSWORD = "AuthSessionBoot-1!";
    static final String ADMIN_PASSWORD = "AuthSessionAdmin-2!";
    static final String EMPLOYEE_PASSWORD = "EmployeeOwn-3!";

    private static final AtomicInteger EMPLOYEE_SEQUENCE = new AtomicInteger();

    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_imp")
            .withUsername("uten")
            .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    /** 只由测试推进的时钟: 服务端会话 (last_seen/绝对期限/再认证有效期) 都按它判定。 */
    static final class MutableClock extends Clock {
        private volatile Instant now = Instant.now();

        void advance(Duration duration) {
            now = now.plus(duration);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return now;
        }
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class ClockOverride {
        @Bean
        @Primary
        MutableClock mutableClock() {
            return new MutableClock();
        }
    }

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper objectMapper;
    @Autowired
    JdbcTemplate jdbc;
    @Autowired
    MutableClock clock;

    /** 本类用到的登录很多: 放宽登录限流, 清掉上一用例留下的再认证计数。 */
    @BeforeEach
    void relaxRateLimitsAndResetStepUpCounters() {
        jdbc.update("UPDATE system_settings SET value = '100000' WHERE key = 'login_rate_limit_per_minute'");
        jdbc.update("UPDATE system_settings SET value = '1000000' WHERE key = 'login_ip_rate_limit_per_minute'");
        jdbc.update("DELETE FROM auth_step_up_states");
    }

    /** 引导管理员: 首次用例负责首登改密, 之后直接登录。 */
    String adminToken() throws Exception {
        MvcResult attempt = loginResult(ADMIN_LOGIN, ADMIN_PASSWORD);
        if (attempt.getResponse().getStatus() == 200) {
            return json(attempt).path("accessToken").asText();
        }
        JsonNode initial = login(ADMIN_LOGIN, ADMIN_INITIAL_PASSWORD);
        return changePassword(initial.path("accessToken").asText(), ADMIN_INITIAL_PASSWORD, ADMIN_PASSWORD)
                .path("accessToken").asText();
    }

    /** 管理员给新员工入职开号 (返回系统随机临时密码), 员工首登改成 {@link #EMPLOYEE_PASSWORD}。 */
    Employee newEmployee(String adminToken) throws Exception {
        return newEmployee(adminToken, "DEPT_HR");
    }

    /**
     * 指定部门入职。注意部门授权决定高危与否: 行政与人力资源部带工资审核/发布 (高危),
     * 工程研发部没有任何高危权限。
     */
    Employee newEmployee(String adminToken, String departmentCode) throws Exception {
        int sequence = EMPLOYEE_SEQUENCE.incrementAndGet();
        String phone = "1390000" + String.format("%04d", sequence);
        String departmentId = jdbc.queryForObject(
                "SELECT id::text FROM departments WHERE code = ? AND NOT is_deleted", String.class,
                departmentCode);
        ObjectNode root = objectMapper.createObjectNode();
        ObjectNode profile = root.putObject("profile");
        profile.put("fullName", "会话测试员工" + sequence);
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
        String userId = jdbc.queryForObject(
                "SELECT id::text FROM users WHERE login_account = ?", String.class, phone);
        return new Employee(phone, userId, credential.path("employee").path("id").asText(), temporary,
                changed.path("accessToken").asText(), changed.path("refreshToken").asText());
    }

    record Employee(String loginAccount, String userId, String employeeId, String issuedTemporaryPassword,
                    String accessToken, String refreshToken) {}

    JsonNode login(String account, String password) throws Exception {
        MvcResult result = loginResult(account, password);
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    MvcResult loginResult(String account, String password) throws Exception {
        return mvc.perform(json(post("/api/auth/login"),
                Map.of("loginAccount", account, "password", password), null)).andReturn();
    }

    JsonNode changePassword(String token, String oldPassword, String newPassword) throws Exception {
        MvcResult result = mvc.perform(json(post("/api/auth/change-password"),
                Map.of("oldPassword", oldPassword, "newPassword", newPassword), token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    MvcResult stepUpResult(String token, String password) throws Exception {
        return mvc.perform(json(post("/api/auth/step-up"), Map.of("password", password), token)).andReturn();
    }

    String stepUp(String token, String password) throws Exception {
        MvcResult result = stepUpResult(token, password);
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result).path("stepUpToken").asText();
    }

    MvcResult me(String token) throws Exception {
        return mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + token)).andReturn();
    }

    MockHttpServletRequestBuilder json(MockHttpServletRequestBuilder builder, Object body, String token)
            throws Exception {
        builder.contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsBytes(body));
        if (token != null) {
            builder.header("Authorization", "Bearer " + token);
        }
        return builder;
    }

    JsonNode json(MvcResult result) throws Exception {
        return objectMapper.readTree(result.getResponse().getContentAsByteArray());
    }

    static String body(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }

    /** 生成通过校验位的 18 位身份证号 (每个测试员工一个, 避免证件号查重冲突)。 */
    static String idNumber(int sequence) {
        String base = "11010519900101" + String.format("%03d", 100 + sequence % 900);
        int[] weights = {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
        char[] checks = {'1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'};
        int sum = 0;
        for (int i = 0; i < 17; i++) {
            sum += (base.charAt(i) - '0') * weights[i];
        }
        return base + checks[sum % 11];
    }
}
