package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.time.Duration;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/**
 * 敏感操作再认证的 HTTP 契约 (ADR-110; security-04/05/06/02/01), 真库 + 完整安全过滤链:
 * 每个点名端点不带凭证一律 403 REAUTH_REQUIRED; 凭证 5 分钟、绑定本人本会话、只能用一次;
 * 连续输错 5 次暂停 15 分钟并踢掉当前会话; 改密原密码共享同一份计数。
 */
class StepUpHttpContractPostgresTest extends AuthSessionPostgresTestSupport {

    private static final String STEP_UP_HEADER = "X-Uten-Step-Up";

    @Test
    void everyNamedEndpointRejectsCallsWithoutAFreshStepUp() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin);
        String departmentId = jdbc.queryForObject(
                "SELECT id::text FROM departments WHERE code = 'DEPT_HR' AND NOT is_deleted", String.class);
        String users = "/api/admin/users/" + target.userId();
        List<MockHttpServletRequestBuilder> calls = List.of(
                json(put(users + "/super-admin"), Map.of("superAdmin", true), admin),
                json(put(users + "/remote-access"), Map.of("remoteAccess", true), admin),
                json(put(users + "/permission-overrides"), Map.of("grants", List.of(), "revokes", List.of()), admin),
                json(put(users + "/data-scopes").param("scope", "goods"),
                        Map.of("ownerEmployeeIds", List.of(), "expectedOwnerEmployeeIds", List.of()), admin),
                json(put("/api/admin/departments/" + departmentId + "/permissions"),
                        Map.of("permissions", List.of()), admin),
                json(post(users + "/reset-password"), Map.of(), admin),
                json(post("/api/admin/impersonation/enter"), Map.of(), admin),
                json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                        Map.of("key", "lockout_minutes", "value", "16", "expectedValue", "15"))), admin),
                json(post("/api/system-test/business-data/reset"), Map.of("confirm", "清空业务数据"), admin),
                json(post("/api/system-test/business-data/attachments/prepare"),
                        Map.of("confirm", "清理测试业务附件", "database", "x", "fingerprint", "x"), admin),
                // 补开账号同样把明文临时密码交给操作人 (评审补例): 不在 /api/admin 前缀下也要再认证
                json(post("/api/org/employees/" + target.employeeId() + "/account"), Map.of(), admin),
                // 个人资料改手机号 (即登录账号): 服务端按提交内容要求再认证, 不再只靠前端先问密码
                json(post("/api/profile/me/changes"), Map.of(
                        "idemKey", "step-up-contract-" + target.userId(),
                        "changes", List.of(Map.of("fieldCode", "phone", "fieldLabel", "手机号",
                                "newValue", "13911112222"))), target.accessToken()));
        for (MockHttpServletRequestBuilder call : calls) {
            MvcResult result = mvc.perform(call).andReturn();
            assertEquals(403, result.getResponse().getStatus(), body(result));
            assertEquals("REAUTH_REQUIRED", json(result).path("code").asText(), body(result));
        }
        // 什么都没发生: 设置未改、目标不是超管、清库没跑
        assertEquals("15", jdbc.queryForObject(
                "SELECT value FROM system_settings WHERE key = 'lockout_minutes'", String.class));
        assertEquals(Boolean.FALSE, jdbc.queryForObject(
                "SELECT is_super_admin FROM users WHERE id = ?::uuid", Boolean.class, target.userId()));
    }

    @Test
    void stepUpTokenIsOneTimeAndBoundToTheIssuingSession() throws Exception {
        String admin = adminToken();
        String token = stepUp(admin, ADMIN_PASSWORD);
        MockHttpServletRequestBuilder save = json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                Map.of("key", "lockout_minutes", "value", "16", "expectedValue", "15"))), admin)
                .header(STEP_UP_HEADER, token);
        MvcResult saved = mvc.perform(save).andReturn();
        assertEquals(200, saved.getResponse().getStatus(), body(saved));
        assertEquals("16", jdbc.queryForObject(
                "SELECT value FROM system_settings WHERE key = 'lockout_minutes'", String.class));

        // 同一凭证第二次使用: 已核销
        MvcResult reused = mvc.perform(json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                Map.of("key", "lockout_minutes", "value", "15", "expectedValue", "16"))), admin)
                .header(STEP_UP_HEADER, token)).andReturn();
        assertEquals(403, reused.getResponse().getStatus());
        assertEquals("REAUTH_REQUIRED", json(reused).path("code").asText());

        // 换一个会话 (重新登录) 拿别的会话签发的凭证: 不认
        String otherSessionToken = stepUp(admin, ADMIN_PASSWORD);
        String secondSession = login(ADMIN_LOGIN, ADMIN_PASSWORD).path("accessToken").asText();
        MvcResult crossSession = mvc.perform(json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                Map.of("key", "lockout_minutes", "value", "15", "expectedValue", "16"))), secondSession)
                .header(STEP_UP_HEADER, otherSessionToken)).andReturn();
        assertEquals(403, crossSession.getResponse().getStatus());

        // 同一会话里签发的凭证, 5 分钟后过期
        String expiring = stepUp(secondSession, ADMIN_PASSWORD);
        clock.advance(Duration.ofMinutes(5).plusSeconds(1));
        MvcResult expired = mvc.perform(json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                Map.of("key", "lockout_minutes", "value", "15", "expectedValue", "16"))), secondSession)
                .header(STEP_UP_HEADER, expiring)).andReturn();
        assertEquals(403, expired.getResponse().getStatus());

        String fresh = stepUp(secondSession, ADMIN_PASSWORD);
        MvcResult restored = mvc.perform(json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                Map.of("key", "lockout_minutes", "value", "15", "expectedValue", "16"))), secondSession)
                .header(STEP_UP_HEADER, fresh)).andReturn();
        assertEquals(200, restored.getResponse().getStatus(), body(restored));
    }

    @Test
    void fiveWrongPasswordsPauseStepUpAndRevokeTheCurrentSession() throws Exception {
        Employee employee = newEmployee(adminToken());
        // 改密输错原密码与再认证共享同一份计数
        MvcResult wrongOld = mvc.perform(json(post("/api/auth/change-password"),
                Map.of("oldPassword", "not-my-password-1", "newPassword", "Another-Pass-9"),
                employee.accessToken())).andReturn();
        assertEquals(422, wrongOld.getResponse().getStatus(), "输错不用 401, 前端不会当登录过期去重放");
        assertEquals("REAUTH_FAILED", json(wrongOld).path("code").asText());
        for (int attempt = 2; attempt <= 4; attempt++) {
            MvcResult wrong = stepUpResult(employee.accessToken(), "wrong-password-" + attempt);
            assertEquals(422, wrong.getResponse().getStatus(), body(wrong));
        }
        MvcResult fifth = stepUpResult(employee.accessToken(), "wrong-password-5");
        assertEquals(429, fifth.getResponse().getStatus(), body(fifth));
        assertEquals("REAUTH_LOCKED", json(fifth).path("code").asText());
        // 被盗的会话不能继续高速试密码: 当前会话已被吊销
        assertEquals(401, me(employee.accessToken()).getResponse().getStatus());

        String relogin = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        MvcResult stillPaused = stepUpResult(relogin, EMPLOYEE_PASSWORD);
        assertEquals(429, stillPaused.getResponse().getStatus(), "暂停期内连正确密码也不验");

        clock.advance(Duration.ofMinutes(16));
        String afterPause = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        assertEquals(200, stepUpResult(afterPause, EMPLOYEE_PASSWORD).getResponse().getStatus());
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM auth_step_up_states WHERE user_id = ?::uuid",
                Integer.class, employee.userId()), "成功一次即清零");
    }

    @Test
    void resetIssuesOneTimeRandomPasswordNotifiesTheHolderAndEndsTheirSessions() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin);
        assertTrue(target.issuedTemporaryPassword().length() >= 20, "开号的初始密码是随机高熵临时密码");

        String token = stepUp(admin, ADMIN_PASSWORD);
        MvcResult reset = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/reset-password"),
                Map.of(), admin).header(STEP_UP_HEADER, token)).andReturn();
        assertEquals(200, reset.getResponse().getStatus(), body(reset));
        String temporary = json(reset).path("temporaryPassword").asText();
        assertTrue(temporary.length() >= 20);

        assertEquals(401, me(target.accessToken()).getResponse().getStatus(), "目标的旧会话全部失效");
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*) FROM notices WHERE audience_user_id = ?::uuid AND title = '你的登录密码已被重置'
                """, Integer.class, target.userId()));
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*) FROM audit_log WHERE action = 'password_temporary_reset' AND target_id = ?
                """, Integer.class, target.userId()));
        JsonNode relogin = login(target.loginAccount(), temporary);
        assertTrue(relogin.path("mustChangePassword").asBoolean());

        // 自定临时密码的旧请求体被忽略: 仍然只能拿到系统生成的密码
        String again = stepUp(admin, ADMIN_PASSWORD);
        MvcResult custom = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/reset-password"),
                Map.of("temporaryPassword", "Chosen-By-Admin-1"), admin).header(STEP_UP_HEADER, again)).andReturn();
        assertEquals(200, custom.getResponse().getStatus(), body(custom));
        assertNotEquals("Chosen-By-Admin-1", json(custom).path("temporaryPassword").asText());
    }

    @Test
    void stepUpIsConsumedOnlyAfterValidationAndAuthorizationPass() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        try {
            // 没有权限的人: 直接拒绝, 不会先被要求输入密码 (再认证排在方法级权限判定之后)
            MvcResult forbidden = mvc.perform(json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                    Map.of("key", "lockout_minutes", "value", "16", "expectedValue", "15"))),
                    employee.accessToken())).andReturn();
            assertEquals(403, forbidden.getResponse().getStatus(), body(forbidden));
            assertNotEquals("REAUTH_REQUIRED", json(forbidden).path("code").asText(), body(forbidden));

            // 请求体不合法: 参数校验先拒绝 (422), 凭证不被消耗; 改正后同一张凭证仍然可用
            String token = stepUp(admin, ADMIN_PASSWORD);
            MvcResult invalid = mvc.perform(json(put("/api/admin/system-settings"),
                    Map.of("changes", List.of()), admin).header(STEP_UP_HEADER, token)).andReturn();
            assertEquals(422, invalid.getResponse().getStatus(), body(invalid));
            assertEquals("VALIDATION_FAILED", json(invalid).path("code").asText(), body(invalid));
            MvcResult saved = mvc.perform(json(put("/api/admin/system-settings"), Map.of("changes", List.of(
                    Map.of("key", "lockout_minutes", "value", "16", "expectedValue", "15"))), admin)
                    .header(STEP_UP_HEADER, token)).andReturn();
            assertEquals(200, saved.getResponse().getStatus(), body(saved));
        } finally {
            jdbc.update("UPDATE system_settings SET value = '15' WHERE key = 'lockout_minutes'");
        }
    }

    @Test
    void onlySuperAdministratorsIssueCredentialsForHighRiskHolders() throws Exception {
        String admin = adminToken();
        // 工程研发部的部门授权里没有任何高危权限; 付款审批只靠个人点名授予
        Employee support = newEmployee(admin, "DEPT_ENG");
        Employee payer = newEmployee(admin, "DEPT_ENG");
        Employee ordinary = newEmployee(admin, "DEPT_ENG");
        // 行政与人力资源部的部门授权含工资审核/发布: 同样只有超管能重置
        Employee payrollClerk = newEmployee(admin, "DEPT_HR");
        grantPersonally(support.userId(), "account:support");
        grantPersonally(payer.userId(), "finance_payment:approve");
        String supportToken = login(support.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();

        // 付款审批人: 账号支持人员不能重置 (拿到明文临时密码就能冒充他付款)
        MvcResult refused = mvc.perform(json(post("/api/admin/users/" + payer.userId() + "/reset-password"),
                Map.of(), supportToken).header(STEP_UP_HEADER, stepUp(supportToken, EMPLOYEE_PASSWORD))).andReturn();
        assertEquals(403, refused.getResponse().getStatus(), body(refused));
        assertEquals("FORBIDDEN", json(refused).path("code").asText(), body(refused));
        String payerAccess = login(payer.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        assertEquals(200, me(payerAccess).getResponse().getStatus(), "被拒的重置什么都没改");
        MvcResult payrollRefused = mvc.perform(json(post("/api/admin/users/" + payrollClerk.userId()
                        + "/reset-password"), Map.of(), supportToken)
                .header(STEP_UP_HEADER, stepUp(supportToken, EMPLOYEE_PASSWORD))).andReturn();
        assertEquals(403, payrollRefused.getResponse().getStatus(), "部门授予的高危权限同样算");

        // 普通员工: 账号支持可以重置; 其他超管同时收到提醒
        MvcResult reset = mvc.perform(json(post("/api/admin/users/" + ordinary.userId() + "/reset-password"),
                Map.of(), supportToken).header(STEP_UP_HEADER, stepUp(supportToken, EMPLOYEE_PASSWORD))).andReturn();
        assertEquals(200, reset.getResponse().getStatus(), body(reset));
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*) FROM notices n JOIN users u ON u.id = n.audience_user_id
                WHERE u.login_account = ? AND n.title = '有员工的登录密码被重置'
                """, Integer.class, ADMIN_LOGIN));

        // 目标本人的账号安全提醒不能删除 (冒充登录的人删不掉它)
        String temporary = json(reset).path("temporaryPassword").asText();
        JsonNode first = login(ordinary.loginAccount(), temporary);
        String ordinaryToken = changePassword(first.path("accessToken").asText(), temporary, "OrdinaryNew-4!")
                .path("accessToken").asText();
        String noticeId = jdbc.queryForObject("""
                SELECT id::text FROM notices WHERE audience_user_id = ?::uuid AND title = '你的登录密码已被重置'
                """, String.class, ordinary.userId());
        MvcResult deleted = mvc.perform(json(post("/api/notices/batch-delete"),
                Map.of("ids", List.of(noticeId)), ordinaryToken)).andReturn();
        assertEquals(200, deleted.getResponse().getStatus(), body(deleted));
        assertEquals(0, json(deleted).path("deleted").asInt());
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM notice_user_states WHERE notice_id = ?::uuid AND deleted_at IS NOT NULL
                """, Integer.class, noticeId));
    }

    @Test
    void temporaryCredentialsCanNeverBePermanentAndHighRiskFlagsLiveInTheCatalog() throws Exception {
        // 任何写路径都造不出「必须改密却永不过期」的非超管凭据 (离职冻结/复职曾经这样写):
        // 写空即按已过期落库, 这张临时凭据立即不可用
        String userId = newEmployee(adminToken(), "DEPT_ENG").userId();
        jdbc.update("""
                UPDATE users SET must_change_password = TRUE, temp_password_expires_at = NULL
                WHERE id = ?::uuid
                """, userId);
        assertEquals(Boolean.TRUE, jdbc.queryForObject("""
                SELECT temp_password_expires_at IS NOT NULL AND temp_password_expires_at <= now()
                FROM users WHERE id = ?::uuid
                """, Boolean.class, userId));
        // 验收口径 (security-01): 库里不存在「必须改密却没有过期时间」的非超管账号
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM users
                WHERE must_change_password AND NOT is_super_admin AND temp_password_expires_at IS NULL
                """, Integer.class));
        // 高危清单在权限目录上集中维护: 资金审批/付款/过账与工资发布都在内, 日常权限不在
        for (String code : List.of("finance_payment:approve", "finance_receipt:approve",
                "finance_bank_transfer:approve", "finance_expense:approve", "finance_other_income:approve",
                "expense:approve", "expense:pay", "payroll:review", "payroll:publish", "account:support",
                "audit_log:view", "authorization:manage", "stock:balance:adjust")) {
            assertEquals(Boolean.TRUE, highRisk(code), code);
        }
        assertEquals(Boolean.FALSE, highRisk("notice:read"));
        assertEquals(Boolean.FALSE, highRisk("sales_order:view"));
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM permissions
                WHERE active AND NOT high_risk
                  AND module = '财税管理' AND action_type IN ('APPROVE', 'EXECUTE')
                """, Integer.class), "财税模块的审批/执行类权限必须全部标记为高危");
    }

    private Boolean highRisk(String code) {
        return jdbc.queryForObject("SELECT high_risk FROM permissions WHERE code = ?", Boolean.class, code);
    }

    /** 授权变更会让全部访问令牌失效 (授权戳), 每次都用新登录的超管令牌。 */
    private void grantPersonally(String userId, String code) throws Exception {
        String admin = adminToken();
        MvcResult granted = mvc.perform(json(put("/api/admin/users/" + userId + "/permission-overrides"),
                Map.of("grants", List.of(code), "revokes", List.of()), admin)
                .header(STEP_UP_HEADER, stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, granted.getResponse().getStatus(), body(granted));
    }

    @Test
    void lockedAccountAnswersCorrectAndWrongPasswordsIdentically() throws Exception {
        Employee employee = newEmployee(adminToken());
        for (int attempt = 1; attempt <= 5; attempt++) {
            MvcResult wrong = loginResult(employee.loginAccount(), "wrong-password-" + attempt);
            assertEquals(401, wrong.getResponse().getStatus());
        }
        MvcResult correct = loginResult(employee.loginAccount(), EMPLOYEE_PASSWORD);
        MvcResult wrong = loginResult(employee.loginAccount(), "wrong-password-6");

        assertEquals(401, correct.getResponse().getStatus());
        assertEquals(json(wrong).path("code").asText(), json(correct).path("code").asText());
        assertEquals(json(wrong).path("message").asText(), json(correct).path("message").asText());
        assertEquals("BAD_CREDENTIALS", json(correct).path("code").asText());
    }

    @Test
    void retiredPasswordAndSettingsWritePathsAreGone() throws Exception {
        String admin = adminToken();
        MvcResult verify = mvc.perform(json(post("/api/auth/verify-password"),
                Map.of("password", ADMIN_PASSWORD), admin)).andReturn();
        assertTrue(verify.getResponse().getStatus() == 404 || verify.getResponse().getStatus() == 405,
                body(verify));
        MvcResult singleSetting = mvc.perform(json(put("/api/admin/system-settings/lockout_minutes"),
                Map.of("value", "20", "password", ADMIN_PASSWORD), admin)).andReturn();
        assertTrue(singleSetting.getResponse().getStatus() == 404
                || singleSetting.getResponse().getStatus() == 405, body(singleSetting));
        MvcResult celebration = mvc.perform(json(put("/api/notices/celebration/settings"),
                Map.of("autoEnabled", true, "password", ADMIN_PASSWORD), admin)).andReturn();
        assertTrue(celebration.getResponse().getStatus() == 404
                || celebration.getResponse().getStatus() == 405, body(celebration));
        // 公开设置下发前端需要的限制值
        MvcResult publicSettings = mvc.perform(get("/api/settings/public")
                .header("Authorization", "Bearer " + admin)).andReturn();
        JsonNode values = json(publicSettings);
        assertEquals(8, values.path("passwordMinLength").asInt());
        assertEquals(60, values.path("badgePollSeconds").asInt());
        assertTrue(values.path("attachmentMaxBytes").asLong() > 0);
    }
}
