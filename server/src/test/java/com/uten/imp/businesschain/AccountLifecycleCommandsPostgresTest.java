package com.uten.imp.businesschain;

import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.test.web.servlet.MvcResult;

import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Private PostgreSQL + real roles/HTTP; no production accounts or credentials. */
class AccountLifecycleCommandsPostgresTest extends AuthSessionPostgresTestSupport {
    private static final AtomicInteger PHONES = new AtomicInteger();
    @org.springframework.beans.factory.annotation.Autowired
    com.uten.imp.security.TxSessionVars encryption;

    @Test
    void newCustomLoginTrimsUiWhitespaceAndWorksWithTheReturnedCanonicalIdentifier() throws Exception {
        String admin = adminToken(), login = "custom-" + UUID.randomUUID();
        var created = create(admin, "DEPT_ENG", "probation", true, " \u00a0" + login + "\u00a0 ", null);
        assertEquals(200, created.getResponse().getStatus(), body(created));
        assertEquals(login, json(created).path("loginAccount").asText());
        assertTrue(login(login, json(created).path("temporaryPassword").asText()).path("mustChangePassword").asBoolean());
    }

    @ParameterizedTest
    @org.junit.jupiter.params.provider.MethodSource("invalidNewLogins")
    void invalidNewLoginFailsBeforeCreatingAnyProfileOrAccount(String invalid) throws Exception {
        String admin = adminToken();
        long employees = employeeCount(), users = userCount();
        var rejected = create(admin, "DEPT_ENG", "probation", true, invalid, null);
        assertEquals(ErrorCode.VALIDATION_FAILED.getHttpStatus(), rejected.getResponse().getStatus(), body(rejected));
        assertEquals(employees, employeeCount()); assertEquals(users, userCount());
    }

    static java.util.stream.Stream<String> invalidNewLogins() {
        return java.util.stream.Stream.of("x".repeat(129), "custom login", "custom\tlogin", "custom\u0000login", "custom\u200blogin");
    }

    @Test
    void defaultLoginUsesTheCanonicalPrimaryMobile() throws Exception {
        String canonical = "136" + String.format("%08d", PHONES.incrementAndGet());
        var created = create(adminToken(), "DEPT_ENG", "probation", true, null, "+86 " + canonical);
        assertEquals(200, created.getResponse().getStatus(), body(created));
        assertEquals(canonical, json(created).path("loginAccount").asText());
    }

    @Test
    void provisioningRejectsAnInvalidLegacyPrimaryMobileWithoutCreatingACredential() throws Exception {
        String admin = adminToken();
        var created = create(admin, "DEPT_ENG", "probation", false);
        assertEquals(200, created.getResponse().getStatus(), body(created));
        UUID employee = UUID.fromString(json(created).path("employee").path("id").asText());
        jdbc.update("UPDATE employee_sensitive SET phone_enc=? WHERE employee_id=?", encryption.encrypt("not a mobile"), employee);
        long users = userCount();
        var rejected = mvc.perform(json(post("/api/org/employees/" + employee + "/account"), Map.of(), admin)
                .header("X-Uten-Step-Up", stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(ErrorCode.VALIDATION_FAILED.getHttpStatus(), rejected.getResponse().getStatus(), body(rejected));
        assertEquals(users, userCount());
    }

    @ParameterizedTest
    @ValueSource(strings = {"admin-unlock", "employee-unlock", "admin-lock", "employee-lock"})
    void disabledAccountCannotBeReenabledThroughLockRecovery(String route) throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        var disabled = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/disable"), Map.of(), admin)).andReturn();
        assertEquals(200, disabled.getResponse().getStatus(), body(disabled));
        admin = adminToken();
        String before = userSnapshot(target);
        String action = route.endsWith("unlock") ? "unlock" : "lock";
        String path = route.startsWith("admin")
                ? "/api/admin/users/" + target.userId() + "/" + action
                : "/api/org/employees/" + target.employeeId() + "/account/" + action;
        var denied = mvc.perform(json(post(path), Map.of(), admin)).andReturn();
        assertEquals(409, denied.getResponse().getStatus(), body(denied));
        assertEquals(before, userSnapshot(target));
    }

    @Test
    void aDeletedEmployeeBindingCanBeQuarantinedButNeverEnabled() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        jdbc.update("UPDATE employees SET is_deleted=true,deleted_at=now() WHERE id=?", UUID.fromString(target.employeeId()));
        admin = adminToken();
        String password = jdbc.queryForObject("SELECT password_hash FROM users WHERE id=?", String.class, UUID.fromString(target.userId()));
        var disabled = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/disable"), Map.of(), admin)).andReturn();
        assertEquals(200, disabled.getResponse().getStatus(), body(disabled));
        assertEquals("disabled", status(target));
        assertEquals(password, jdbc.queryForObject("SELECT password_hash FROM users WHERE id=?", String.class, UUID.fromString(target.userId())));
        admin = adminToken();
        var enable = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/enable"), Map.of(), admin)).andReturn();
        assertEquals(409, enable.getResponse().getStatus(), body(enable));
        assertEquals("disabled", status(target));
    }

    @Test
    void resettingPasswordPreservesAnAdministratorsManualLock() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        var locked = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/lock"), Map.of(), admin)).andReturn();
        assertEquals(200, locked.getResponse().getStatus(), body(locked));
        admin = adminToken();
        String temporary = reset(admin, target);
        assertEquals("locked", status(target));
        assertTrue(jdbc.queryForObject("SELECT locked_until IS NULL AND must_change_password AND temp_password_expires_at>now() FROM users WHERE id=?",
                Boolean.class, UUID.fromString(target.userId())));
        var login = loginResult(target.loginAccount(), temporary);
        assertEquals(ErrorCode.ACCOUNT_LOCKED.getHttpStatus(), login.getResponse().getStatus(), body(login));
    }

    @Test
    void resettingPasswordMayClearATemporaryBruteForceLockWithoutRestoringOldSessions() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        jdbc.update("UPDATE users SET status='locked',locked_until=now()+interval '15 minutes',failed_attempts=5 WHERE id=?",
                UUID.fromString(target.userId()));
        String temporary = reset(admin, target);
        assertEquals("active", status(target));
        assertTrue(jdbc.queryForObject("SELECT locked_until IS NULL AND failed_attempts=0 AND must_change_password FROM users WHERE id=?",
                Boolean.class, UUID.fromString(target.userId())));
        assertEquals(401, me(target.accessToken()).getResponse().getStatus());
        assertTrue(login(target.loginAccount(), temporary).path("mustChangePassword").asBoolean());
    }

    @Test
    void onboardingCannotIssueAnActiveAccountForAResignedEmployee() throws Exception {
        String admin = adminToken();
        long employees = employeeCount(), users = userCount();
        var response = create(admin, "DEPT_ENG", "resigned", null);
        assertEquals(ErrorCode.VALIDATION_FAILED.getHttpStatus(), response.getResponse().getStatus(), body(response));
        assertEquals(employees, employeeCount());
        assertEquals(users, userCount());
    }

    @Test
    void creatingAProfileDoesNotAuthorizeIssuingItsLoginCredentials() throws Exception {
        String admin = adminToken();
        String creator = operator(admin, false);
        long employees = employeeCount(), users = userCount();
        var denied = create(creator, "DEPT_ENG", "probation", true);
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
        assertEquals(employees, employeeCount());
        assertEquals(users, userCount());
    }

    @Test
    void aPiiAuthorizedCreatorCanExplicitlyCreateAProfileWithoutOpeningAnAccount() throws Exception {
        String admin = adminToken();
        String creator = operator(admin, false);
        long users = userCount();
        var created = create(creator, "DEPT_ENG", "probation", false);
        assertEquals(200, created.getResponse().getStatus(), body(created));
        assertTrue(json(created).path("temporaryPassword").isNull());
        assertTrue(json(created).path("loginAccount").isNull());
        assertTrue(json(created).path("employee").path("accountStatus").isNull());
        assertEquals(users, userCount());
    }

    @Test
    void ordinarySupportCannotIssueANewHighRiskDepartmentsCredentials() throws Exception {
        String admin = adminToken();
        String support = operator(admin, true);
        long employees = employeeCount(), users = userCount();
        var denied = create(support, "DEPT_HR", "probation", true);
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
        assertEquals(employees, employeeCount());
        assertEquals(users, userCount());
    }

    @Test
    void ordinarySupportCanIssueALowRiskNewAccountsTemporaryCredential() throws Exception {
        String admin = adminToken();
        String support = operator(admin, true);
        var created = create(support, "DEPT_ENG", "probation", true);
        assertEquals(200, created.getResponse().getStatus(), body(created));
        assertFalse(json(created).path("temporaryPassword").asText().isBlank());
        assertEquals("active", json(created).path("employee").path("accountStatus").asText());
        assertTrue(login(json(created).path("loginAccount").asText(), json(created).path("temporaryPassword").asText())
                .path("mustChangePassword").asBoolean());
    }

    @Test
    void rehireRestoresEmploymentWhileAccountRecoveryRemainsExplicitAndPreservesIdentity() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        String password = jdbc.queryForObject("SELECT password_hash FROM users WHERE id=?", String.class, UUID.fromString(target.userId()));
        var offboarded = mvc.perform(json(post("/api/org/employees/" + target.employeeId() + "/offboard"), Map.of(
                "resignType", "VOLUNTARY", "effectiveDate", LocalDate.now().toString(), "reason", "Private lifecycle regression",
                "requestId", UUID.randomUUID(), "confirmedChecklistCodes", List.of("ACCESS_CARD_RETURNED",
                        "COMPANY_ASSETS_ACCOUNTED", "ACCOUNT_DISABLE_ACKNOWLEDGED", "SOCIAL_BENEFITS_ARRANGED")), admin)).andReturn();
        assertEquals(200, offboarded.getResponse().getStatus(), body(offboarded));
        admin = adminToken();
        var rehired = mvc.perform(json(post("/api/org/employees/" + target.employeeId() + "/rehire"), Map.of(), admin)).andReturn();
        assertEquals(200, rehired.getResponse().getStatus(), body(rehired));
        assertEquals("active", jdbc.queryForObject("SELECT status FROM employees WHERE id=?", String.class, UUID.fromString(target.employeeId())));
        assertEquals("disabled", status(target));
        assertEquals(password, jdbc.queryForObject("SELECT password_hash FROM users WHERE id=?", String.class, UUID.fromString(target.userId())));
        assertTrue(jdbc.queryForObject("SELECT must_change_password AND temp_password_expires_at<=now() AND NOT remote_access FROM users WHERE id=?",
                Boolean.class, UUID.fromString(target.userId())));
        assertEquals(2L, jdbc.queryForObject("SELECT count(*) FROM employment_history WHERE employee_id=? AND event_type IN('resign','rehire')",
                Long.class, UUID.fromString(target.employeeId())));
        assertEquals(401, me(target.accessToken()).getResponse().getStatus());
        admin = adminToken();
        String temporary = reset(admin, target);
        assertEquals("disabled", status(target));
        admin = adminToken();
        var enabled = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/enable"), Map.of(), admin)).andReturn();
        assertEquals(200, enabled.getResponse().getStatus(), body(enabled));
        assertTrue(login(target.loginAccount(), temporary).path("mustChangePassword").asBoolean());
        assertEquals(UUID.fromString(target.employeeId()), jdbc.queryForObject("SELECT employee_id FROM users WHERE id=?",
                UUID.class, UUID.fromString(target.userId())));
    }

    private String operator(String admin, boolean accountSupport) throws Exception {
        Employee operator = newEmployee(admin, "DEPT_ENG");
        var granted = mvc.perform(json(put("/api/admin/users/" + operator.userId() + "/permission-overrides"),
                Map.of("grants", accountSupport ? List.of("employee:create", "employee:pii:edit", "account:support")
                                : List.of("employee:create", "employee:pii:edit"),
                        "revokes", accountSupport ? List.of() : List.of("account:support")), admin)
                .header("X-Uten-Step-Up", stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, granted.getResponse().getStatus(), body(granted));
        return login(operator.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
    }

    private MvcResult create(String actor, String departmentCode, String status, Boolean openAccount) throws Exception {
        return create(actor, departmentCode, status, openAccount, null, null);
    }

    private MvcResult create(String actor, String departmentCode, String status, Boolean openAccount,
                             String login, String primary) throws Exception {
        UUID department = jdbc.queryForObject("SELECT id FROM departments WHERE code=? AND NOT is_deleted", UUID.class, departmentCode);
        var account = new HashMap<String, Object>();
        if (openAccount != null) account.put("openAccount", openAccount);
        if (login != null) account.put("loginAccount", login);
        return mvc.perform(json(post("/api/org/employees"), Map.of(
                "profile", Map.of("fullName", "Lifecycle person " + UUID.randomUUID(), "idType", "其他",
                        "idNumber", "LIFECYCLE-" + UUID.randomUUID(), "phone", primary != null ? primary : "136" + String.format("%08d", PHONES.incrementAndGet())),
                "employment", Map.of("departmentId", department, "hireDate", LocalDate.now().minusDays(2).toString(),
                        "employmentType", "regular", "status", status), "account", account), actor)).andReturn();
    }

    private String reset(String admin, Employee target) throws Exception {
        var response = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/reset-password"), Map.of(), admin)
                .header("X-Uten-Step-Up", stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, response.getResponse().getStatus(), body(response));
        String temporary = json(response).path("temporaryPassword").asText();
        assertFalse(temporary.isBlank());
        return temporary;
    }
    private String userSnapshot(Employee employee) { return jdbc.queryForObject("SELECT to_jsonb(u)::text FROM users u WHERE id=?", String.class, UUID.fromString(employee.userId())); }
    private String status(Employee employee) { return jdbc.queryForObject("SELECT status FROM users WHERE id=?", String.class, UUID.fromString(employee.userId())); }
    private long userCount() { return jdbc.queryForObject("SELECT count(*) FROM users", Long.class); }
    private long employeeCount() { return jdbc.queryForObject("SELECT count(*) FROM employees", Long.class); }
}
