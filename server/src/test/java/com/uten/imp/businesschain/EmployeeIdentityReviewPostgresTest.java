package com.uten.imp.businesschain;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.org.employee.EmployeeIdentityCheckRunner;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.DefaultApplicationArguments;
import org.springframework.boot.availability.AvailabilityChangeEvent;
import org.springframework.boot.availability.ReadinessState;
import org.springframework.context.ApplicationContext;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 证件号问题只提醒、不阻塞开号，并给人事生成「证件核对」任务 (V798) 的全链路：真库 + 完整安全过滤链 +
 * 真实账号切换 (超管 / 人事 / 总经办)。老库导入的坏证件号经启动回填判定后，开号照常成功并带出提醒；
 * 只有能改证件的人看到并计红；人事改对之后任务消失、计数减一。
 */
class EmployeeIdentityReviewPostgresTest extends AuthSessionPostgresTestSupport {

    private static final String STEP_UP_HEADER = "X-Uten-Step-Up";
    private static final String CHECK_DIGIT_REASON =
            "身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对";
    private static final String MISSING_REASON = "档案里没有证件号码";
    private static final String UNREADABLE_REASON = "档案里的证件号码读取不出来，系统无法校验，请人事对照证件重新登记";

    @Autowired
    TxSessionVars tx;
    @Autowired
    PlatformTransactionManager transactionManager;
    @Autowired
    EmployeeIdentityCheckRunner identityCheckRunner;
    @Autowired
    ApplicationContext applicationContext;

    @Test
    void wrongOrMissingIdentityWarnsWithoutBlockingAndOnlyIdentityEditorsGetTheTask() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        Employee gm = newEmployee(admin, "GM");
        assertThat(permissions(hr.accessToken()))
                .contains("employee:view", "employee:pii:view", "employee:pii:edit");
        assertThat(permissions(gm.accessToken()))
                .contains("employee:view").doesNotContain("employee:pii:edit");

        // ---- 准备：照老库人事导入写入两名员工 (坏校验位 / 没有证件号)，都还没校验 ----
        int salt = ThreadLocalRandom.current().nextInt(100, 999);
        String correctId = withChecksum("44200019850615" + salt);
        String wrongId = correctId.substring(0, 17) + wrongCheckDigit(correctId);
        String phoneWrong = "1370000" + String.format("%04d", salt);
        String phoneMissing = "1371000" + String.format("%04d", salt);
        UUID wrongEmployee = legacyEmployee("V798-E2E-WRONG-" + salt, "身份证", wrongId, phoneWrong);
        UUID missingEmployee = legacyEmployee("V798-E2E-MISSING-" + salt, "其他", null, phoneMissing);
        assertEquals("unchecked", check(wrongEmployee));

        try {
            identityCheckRunner.run(new DefaultApplicationArguments());
        } finally {
            AvailabilityChangeEvent.publish(applicationContext, ReadinessState.ACCEPTING_TRAFFIC);
        }
        assertEquals("check_digit", check(wrongEmployee));

        // ---- 超管：开号前就绪检查直接给出具体原因 ----
        JsonNode wrongReadiness = okJson(get(readiness(wrongEmployee)), admin);
        assertTrue(wrongReadiness.path("hasPhone").asBoolean());
        assertEquals("invalid", wrongReadiness.path("idNumberIssue").path("kind").asText());
        assertEquals(CHECK_DIGIT_REASON, wrongReadiness.path("idNumberIssue").path("reason").asText());
        JsonNode missingReadiness = okJson(get(readiness(missingEmployee)), admin);
        assertEquals("missing", missingReadiness.path("idNumberIssue").path("kind").asText());
        assertEquals(MISSING_REASON, missingReadiness.path("idNumberIssue").path("reason").asText());
        assertNoIdentityDigits(wrongReadiness.toString(), wrongId, correctId);

        // ---- 超管：开号不再被证件号拦下 ----
        JsonNode wrongProvisioned = provision(admin, wrongEmployee);
        assertEquals(wrongId.substring(12), wrongProvisioned.path("temporaryPassword").asText(),
                "invalid identity still uses the stored last six");
        assertEquals("invalid", wrongProvisioned.path("employee").path("idNumberIssue").path("kind").asText());
        assertEquals(CHECK_DIGIT_REASON,
                wrongProvisioned.path("employee").path("idNumberIssue").path("reason").asText());
        JsonNode missingProvisioned = provision(admin, missingEmployee);
        String randomPassword = missingProvisioned.path("temporaryPassword").asText();
        assertEquals(20, randomPassword.length(), "missing identity gets a one-time random password");
        assertEquals("missing", missingProvisioned.path("employee").path("idNumberIssue").path("kind").asText());
        assertTrue(login(phoneWrong, wrongId.substring(12)).path("mustChangePassword").asBoolean());
        assertTrue(login(phoneMissing, randomPassword).path("mustChangePassword").asBoolean());

        // ---- 人事：任务、计数与徽章 ----
        JsonNode hrSummary = okJson(get("/api/org/hr-tasks/summary"), hr.accessToken());
        assertEquals(CHECK_DIGIT_REASON, identityNote(hrSummary, wrongEmployee));
        assertEquals(MISSING_REASON, identityNote(hrSummary, missingEmployee));
        assertNoIdentityDigits(hrSummary.toString(), wrongId, correctId);
        long hrCount = okJson(get("/api/org/hr-tasks/count"), hr.accessToken()).path("count").asLong();
        long hrIdentityTasks = hrSummary.path("identityReview").size();
        assertThat(hrCount).isGreaterThanOrEqualTo(hrIdentityTasks).isGreaterThanOrEqualTo(2);
        JsonNode hrBadges = okJson(get("/api/workbench/badges"), hr.accessToken());
        assertEquals(hrCount, hrBadges.path("facts").path("hrTask.count").asLong());
        assertEquals(hrCount, hrBadges.path("entries").path("hrTaskCenter").path("todo").asLong());

        // ---- 总经办：只有 employee:view，看不到也不计 ----
        JsonNode gmSummary = okJson(get("/api/org/hr-tasks/summary"), gm.accessToken());
        assertEquals(0, gmSummary.path("identityReview").size());
        long gmCount = okJson(get("/api/org/hr-tasks/count"), gm.accessToken()).path("count").asLong();
        assertEquals(hrCount - hrIdentityTasks, gmCount);

        // ---- 认领：人事可以，总经办不行 ----
        JsonNode claim = okJson(json(post("/api/org/hr-tasks/claims"),
                Map.of("taskType", "identity", "employeeId", wrongEmployee.toString()), hr.accessToken()),
                null);
        assertTrue(claim.path("claimedByMe").asBoolean());
        assertTrue(identityItem(okJson(get("/api/org/hr-tasks/summary"), hr.accessToken()), wrongEmployee)
                .path("claimedByMe").asBoolean());
        MvcResult gmClaim = mvc.perform(json(post("/api/org/hr-tasks/claims"),
                Map.of("taskType", "identity", "employeeId", missingEmployee.toString()),
                gm.accessToken())).andReturn();
        assertEquals(403, gmClaim.getResponse().getStatus(), body(gmClaim));

        // ---- 修改证件信息：总经办 403；人事输错报具体原因；改对后任务消失、计数减一 ----
        MvcResult gmChange = changeIdentity(gm.accessToken(), wrongEmployee, "身份证", correctId);
        assertEquals(403, gmChange.getResponse().getStatus(), body(gmChange));
        MvcResult tooShort = changeIdentity(hr.accessToken(), wrongEmployee, "身份证", correctId.substring(0, 16));
        assertEquals(422, tooShort.getResponse().getStatus(), body(tooShort));
        assertEquals("VALIDATION_FAILED", json(tooShort).path("code").asText());
        assertEquals("身份证号应为18位，当前为16位", json(tooShort).path("message").asText());
        assertEquals("check_digit", check(wrongEmployee), "a rejected correction writes nothing");
        MvcResult fixed = changeIdentity(hr.accessToken(), wrongEmployee, "身份证", correctId);
        assertEquals(200, fixed.getResponse().getStatus(), body(fixed));
        assertEquals("valid", check(wrongEmployee));

        JsonNode afterSummary = okJson(get("/api/org/hr-tasks/summary"), hr.accessToken());
        assertThat(identityIds(afterSummary)).doesNotContain(wrongEmployee.toString())
                .contains(missingEmployee.toString());
        assertEquals(hrCount - 1,
                okJson(get("/api/org/hr-tasks/count"), hr.accessToken()).path("count").asLong());
        JsonNode detail = okJson(get("/api/org/employees/" + wrongEmployee), hr.accessToken());
        assertTrue(detail.path("idNumberIssue").isNull() || detail.path("idNumberIssue").isMissingNode());
        assertEquals(LocalDate.of(1985, 6, 15).toString(), detail.path("birthDate").asText());
        assertEquals(Integer.parseInt(correctId.substring(16, 17)) % 2 == 1 ? "male" : "female",
                detail.path("gender").asText());
        assertEquals("missing", okJson(get("/api/org/employees/" + missingEmployee), hr.accessToken())
                .path("idNumberIssue").path("kind").asText());
    }

    /**
     * 证件号密文解不开 (数据损坏，或换密钥后没配旧密钥) 也不拦开号，而且每个地方说的是同一句原因：
     * 真库里 pgp_sym_decrypt 报错会让整个事务作废，这里证明启动回填在保存点里失败后把这些行存成 unreadable
     * (一条 WARN 汇总、没有 ERROR，下次启动不再重试)；人事任务、开号就绪检查、开号结果和员工详情都说
     * 「读取不出来」；开号照常提交，初始密码改为随机；人事对照证件重新登记后变 valid、任务消失。
     * 存的是 valid、读取时却解不开的号码 (换密钥后没配旧密钥)，会解密的详情和开号结果同样说「读取不出来」。
     */
    @Test
    void unreadableIdentityCipherIsStoredOnceAndEveryViewGivesTheSameReason() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);
        String version = new TransactionTemplate(transactionManager).execute(status -> {
            String sample = tx.encrypt("version-probe");
            return sample.substring(0, sample.indexOf(':'));
        });
        // 当前密钥版本 + 一段不是 PGP 报文的 base64：解密时数据库报「密钥错误或数据损坏」。
        String corrupt = version + ":" + Base64.getEncoder().encodeToString(
                "not a pgp message".getBytes(StandardCharsets.UTF_8));
        // 库里登记的密钥版本已不在密钥环里：不发 SQL，直接按解不开处理。
        String unknownKey = "v-retired:" + Base64.getEncoder().encodeToString(
                "retired key".getBytes(StandardCharsets.UTF_8));
        String phoneCorrupt = "1372000" + String.format("%04d", salt);
        String phoneUnknownKey = "1373000" + String.format("%04d", salt);
        String phoneStale = "1374000" + String.format("%04d", salt);
        UUID corruptEmployee = legacyEmployeeWithCipher(
                "V798-E2E-CORRUPT-" + salt, corrupt, "unchecked", phoneCorrupt);
        UUID unknownKeyEmployee = legacyEmployeeWithCipher(
                "V798-E2E-OLDKEY-" + salt, unknownKey, "unchecked", phoneUnknownKey);
        UUID staleEmployee = legacyEmployeeWithCipher(
                "V798-E2E-STALE-" + salt, corrupt, "valid", phoneStale);

        // ---- 启动回填：解不开的存成 unreadable，一条 WARN 汇总，没有 ERROR ----
        List<ILoggingEvent> firstRun = runIdentityCheckCapturingLogs();
        assertEquals("unreadable", check(corruptEmployee));
        assertEquals("unreadable", check(unknownKeyEmployee));
        assertEquals("valid", check(staleEmployee), "only unchecked rows are backfilled");
        assertThat(firstRun).as("no ERROR from any logger while backfilling")
                .noneMatch(event -> event.getLevel().isGreaterOrEqual(Level.ERROR));
        List<ILoggingEvent> firstSummary = runnerEvents(firstRun);
        assertThat(firstSummary).as("one summary line, no per-row lines").hasSize(1);
        assertEquals(Level.WARN, firstSummary.get(0).getLevel());
        assertThat(firstSummary.get(0).getFormattedMessage()).contains("unreadable=");

        // ---- 下次启动：不再重试，结果不变，没有任何汇总或 ERROR ----
        List<ILoggingEvent> secondRun = runIdentityCheckCapturingLogs();
        assertEquals("unreadable", check(corruptEmployee));
        assertEquals("unreadable", check(unknownKeyEmployee));
        assertThat(secondRun).noneMatch(event -> event.getLevel().isGreaterOrEqual(Level.ERROR));
        assertThat(runnerEvents(secondRun)).as("nothing left to check").isEmpty();

        // ---- 人事任务：同一句原因 ----
        JsonNode hrSummary = okJson(get("/api/org/hr-tasks/summary"), hr.accessToken());
        assertEquals(UNREADABLE_REASON, identityNote(hrSummary, corruptEmployee));
        assertEquals(UNREADABLE_REASON, identityNote(hrSummary, unknownKeyEmployee));
        long hrCountBefore = okJson(get("/api/org/hr-tasks/count"), hr.accessToken()).path("count").asLong();

        // ---- 开号就绪检查：同一句原因 ----
        for (UUID employeeId : List.of(corruptEmployee, unknownKeyEmployee)) {
            JsonNode readiness = okJson(get(readiness(employeeId)), admin);
            assertTrue(readiness.path("hasPhone").asBoolean());
            assertEquals("unchecked", readiness.path("idNumberIssue").path("kind").asText());
            assertEquals(UNREADABLE_REASON, readiness.path("idNumberIssue").path("reason").asText());
        }

        // ---- 开号结果与员工详情：同一句原因；开号照常提交，随机密码能登录 ----
        for (UUID employeeId : List.of(corruptEmployee, unknownKeyEmployee, staleEmployee)) {
            JsonNode provisioned = provision(admin, employeeId);
            String password = provisioned.path("temporaryPassword").asText();
            assertEquals(20, password.length(), "an unreadable identity gets a one-time random password");
            JsonNode issue = provisioned.path("employee").path("idNumberIssue");
            assertEquals("unchecked", issue.path("kind").asText());
            assertEquals(UNREADABLE_REASON, issue.path("reason").asText());
            assertTrue(provisioned.path("employee").path("idNumber").isNull()
                    || provisioned.path("employee").path("idNumber").isMissingNode());
            assertEquals(1, jdbc.queryForObject(
                    "SELECT count(*) FROM users WHERE employee_id = ?", Integer.class, employeeId),
                    "the account is committed, not rolled back with an aborted transaction");
            String loginAccount = provisioned.path("loginAccount").asText();
            assertTrue(login(loginAccount, password).path("mustChangePassword").asBoolean());

            JsonNode detail = okJson(get("/api/org/employees/" + employeeId), hr.accessToken());
            assertEquals("unchecked", detail.path("idNumberIssue").path("kind").asText());
            assertEquals(UNREADABLE_REASON, detail.path("idNumberIssue").path("reason").asText());
        }
        assertEquals(phoneCorrupt, okJson(get("/api/org/employees/" + corruptEmployee), admin)
                .path("phone").asText(), "other encrypted fields still read normally");

        // ---- 人事对照证件重新登记：校验结果随新密文改写为 valid，任务消失、计数减一 ----
        String reentered = withChecksum("44200019850616" + salt);
        MvcResult fixed = changeIdentity(hr.accessToken(), corruptEmployee, "身份证", reentered);
        assertEquals(200, fixed.getResponse().getStatus(), body(fixed));
        assertEquals("valid", check(corruptEmployee));
        JsonNode afterSummary = okJson(get("/api/org/hr-tasks/summary"), hr.accessToken());
        assertThat(identityIds(afterSummary)).doesNotContain(corruptEmployee.toString())
                .contains(unknownKeyEmployee.toString());
        assertEquals(hrCountBefore - 1,
                okJson(get("/api/org/hr-tasks/count"), hr.accessToken()).path("count").asLong());
        JsonNode fixedDetail = okJson(get("/api/org/employees/" + corruptEmployee), hr.accessToken());
        assertTrue(fixedDetail.path("idNumberIssue").isNull() || fixedDetail.path("idNumberIssue").isMissingNode());
        assertNoIdentityDigits(afterSummary.toString(), reentered);
    }

    /** 跑一次启动回填，收集期间所有日志 (根日志器)；跑完恢复就绪状态。 */
    private List<ILoggingEvent> runIdentityCheckCapturingLogs() {
        Logger root = (Logger) LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME);
        ListAppender<ILoggingEvent> appender = new ListAppender<>();
        appender.start();
        root.addAppender(appender);
        try {
            identityCheckRunner.run(new DefaultApplicationArguments());
        } finally {
            root.detachAppender(appender);
            appender.stop();
            AvailabilityChangeEvent.publish(applicationContext, ReadinessState.ACCEPTING_TRAFFIC);
        }
        return List.copyOf(appender.list);
    }

    private static List<ILoggingEvent> runnerEvents(List<ILoggingEvent> events) {
        return events.stream()
                .filter(event -> EmployeeIdentityCheckRunner.class.getName().equals(event.getLoggerName()))
                .toList();
    }

    private UUID legacyEmployeeWithCipher(String code, String identityCipher, String identityCheck, String phone) {
        UUID id = UUID.randomUUID();
        String departmentId = jdbc.queryForObject(
                "SELECT id::text FROM departments WHERE code = 'DEPT_ENG' AND NOT is_deleted", String.class);
        jdbc.update("""
                INSERT INTO employees (id, code, full_name, id_type, department_id, hire_date,
                                       confirmed_at, status, employment_type)
                VALUES (?, ?, ?, '身份证', ?::uuid, DATE '2025-01-02', DATE '2025-04-02', 'active', 'regular')
                """, id, code, "证件读不出" + code.substring(code.length() - 3), departmentId);
        List<String> derived = new TransactionTemplate(transactionManager).execute(status ->
                List.of(tx.encrypt(phone), tx.hmac(phone)));
        jdbc.update("""
                INSERT INTO employee_sensitive (employee_id, id_card_enc, id_card_check, phone_enc, phone_hash)
                VALUES (?, ?, ?, ?, ?)
                """, id, identityCipher, identityCheck, derived.get(0), derived.get(1));
        return id;
    }

    private UUID legacyEmployee(String code, String idType, String identity, String phone) {
        UUID id = UUID.randomUUID();
        String departmentId = jdbc.queryForObject(
                "SELECT id::text FROM departments WHERE code = 'DEPT_ENG' AND NOT is_deleted", String.class);
        jdbc.update("""
                INSERT INTO employees (id, code, full_name, id_type, department_id, hire_date,
                                       confirmed_at, status, employment_type)
                VALUES (?, ?, ?, ?, ?::uuid, DATE '2025-01-02', DATE '2025-04-02', 'active', 'regular')
                """, id, code, "证件核对" + code.substring(code.length() - 3), idType, departmentId);
        List<String> derived = new TransactionTemplate(transactionManager).execute(status -> {
            List<String> values = new ArrayList<>();
            values.add(identity == null ? null : tx.encrypt(identity));
            values.add(identity == null ? null : tx.hmac(identity));
            values.add(tx.encrypt(phone));
            values.add(tx.hmac(phone));
            return values;
        });
        jdbc.update("""
                INSERT INTO employee_sensitive (employee_id, id_card_enc, id_card_last4, id_card_hash,
                                                id_card_check, phone_enc, phone_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, id, derived.get(0), identity == null ? null : identity.substring(14),
                derived.get(1), identity == null ? null : "unchecked", derived.get(2), derived.get(3));
        return id;
    }

    private JsonNode provision(String admin, UUID employeeId) throws Exception {
        MvcResult result = mvc.perform(json(post("/api/org/employees/" + employeeId + "/account"), Map.of(), admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private MvcResult changeIdentity(String token, UUID employeeId, String idType, String idNumber)
            throws Exception {
        return mvc.perform(json(post("/api/org/employees/" + employeeId + "/change-identity"),
                Map.of("idType", idType, "idNumber", idNumber), token)).andReturn();
    }

    private JsonNode okJson(org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder request,
                            String token) throws Exception {
        if (token != null) {
            request.header("Authorization", "Bearer " + token);
        }
        MvcResult result = mvc.perform(request).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private List<String> permissions(String token) throws Exception {
        JsonNode me = json(me(token));
        List<String> values = new ArrayList<>();
        me.path("permissions").forEach(node -> values.add(node.asText()));
        return values;
    }

    private String check(UUID employeeId) {
        return jdbc.queryForObject(
                "SELECT id_card_check FROM employee_sensitive WHERE employee_id = ?", String.class, employeeId);
    }

    private static String readiness(UUID employeeId) {
        return "/api/org/employees/" + employeeId + "/account/readiness";
    }

    private static JsonNode identityItem(JsonNode summary, UUID employeeId) {
        for (JsonNode item : summary.path("identityReview")) {
            if (employeeId.toString().equals(item.path("employeeId").asText())) {
                return item;
            }
        }
        throw new AssertionError("identity task missing for the prepared employee");
    }

    private static String identityNote(JsonNode summary, UUID employeeId) {
        return identityItem(summary, employeeId).path("note").asText();
    }

    private static List<String> identityIds(JsonNode summary) {
        List<String> ids = new ArrayList<>();
        summary.path("identityReview").forEach(item -> ids.add(item.path("employeeId").asText()));
        return ids;
    }

    /** 去掉 UUID 后，响应里不能出现完整号码、前 17 位或后四位。断言消息里不带号码。 */
    private static void assertNoIdentityDigits(String body, String... identities) {
        String withoutIds = body.replaceAll(
                "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<id>");
        for (String identity : identities) {
            assertTrue(!withoutIds.contains(identity.substring(0, 17))
                            && !withoutIds.contains(identity.substring(14)),
                    "response must not carry identity digits");
        }
    }

    private static String withChecksum(String firstSeventeen) {
        int[] weights = {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
        char[] checks = {'1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'};
        int sum = 0;
        for (int i = 0; i < 17; i++) {
            sum += (firstSeventeen.charAt(i) - '0') * weights[i];
        }
        return firstSeventeen + checks[sum % 11];
    }

    private static char wrongCheckDigit(String valid) {
        return valid.charAt(17) == '1' ? '2' : '1';
    }
}
