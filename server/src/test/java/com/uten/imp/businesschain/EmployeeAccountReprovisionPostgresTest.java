package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** Ordinary account provisioning reuses retained identity without reviving removed authority. */
class EmployeeAccountReprovisionPostgresTest extends AuthSessionPostgresTestSupport {

    @org.springframework.beans.factory.annotation.Autowired
    com.uten.imp.features.org.employee.EmployeeOnboardingService onboarding;

    @Test
    void unrelatedEmployeeEditWithUnchangedPrimaryPhonePreservesAnAllowedCustomLoginAndSession() throws Exception {
        String admin = adminToken();
        CustomLogin custom = customLoginEmployee(admin);
        Employee employee = custom.employee();
        String before = accountHash(UUID.fromString(employee.userId()));
        var saved = mvc.perform(json(put("/api/org/employees/" + employee.employeeId()),
                Map.of("phone", "+86 " + custom.primaryPhone(), "seatNo", "phone-sync-regression"), admin)).andReturn();
        assertEquals(200, saved.getResponse().getStatus(), body(saved));
        assertEquals(employee.loginAccount(), jdbc.queryForObject("SELECT login_account FROM users WHERE id=?",
                String.class, UUID.fromString(employee.userId())));
        assertEquals(before, accountHash(UUID.fromString(employee.userId())));
        assertEquals(200, me(employee.accessToken()).getResponse().getStatus());
    }

    @Test
    void approvalOfAnUnchangedPrimaryPhonePreservesAnAllowedCustomLoginAndSession() throws Exception {
        String admin = adminToken();
        CustomLogin custom = customLoginEmployee(admin);
        Employee employee = custom.employee();
        String before = accountHash(UUID.fromString(employee.userId()));
        var submitted = mvc.perform(json(post("/api/profile/me/changes"), Map.of(
                "changes", java.util.List.of(Map.of("fieldCode", "phone", "fieldLabel", "Phone",
                        "newValue", custom.primaryPhone())), "idemKey", "same-phone-" + UUID.randomUUID()),
                employee.accessToken()).header("X-Uten-Step-Up", stepUp(employee.accessToken(), EMPLOYEE_PASSWORD)))
                .andReturn();
        assertEquals(200, submitted.getResponse().getStatus(), body(submitted));
        UUID batch = UUID.fromString(json(submitted).path("batchId").asText());
        var reviewed = mvc.perform(json(post("/api/hr/profile-changes/" + batch + "/review"),
                Map.of("action", "approve"), admin)).andReturn();
        assertEquals(200, reviewed.getResponse().getStatus(), body(reviewed));
        assertEquals(employee.loginAccount(), jdbc.queryForObject("SELECT login_account FROM users WHERE id=?",
                String.class, UUID.fromString(employee.userId())));
        assertEquals(before, accountHash(UUID.fromString(employee.userId())));
        assertEquals("applied", jdbc.queryForObject("SELECT status FROM profile_change_requests WHERE batch_id=?",
                String.class, batch));
        assertEquals(200, me(employee.accessToken()).getResponse().getStatus());
    }

    @Test
    void dedicatedCommandWithUnchangedPrimaryPhoneAlsoPreservesTheCustomLogin() throws Exception {
        String admin = adminToken();
        CustomLogin custom = customLoginEmployee(admin);
        Employee employee = custom.employee();
        String before = accountHash(UUID.fromString(employee.userId()));
        var unchanged = mvc.perform(json(post("/api/org/employees/" + employee.employeeId() + "/change-phone"),
                Map.of("newPhone", custom.primaryPhone()), admin)).andReturn();
        assertEquals(200, unchanged.getResponse().getStatus(), body(unchanged));
        assertEquals(before, accountHash(UUID.fromString(employee.userId())));
        assertEquals(200, me(employee.accessToken()).getResponse().getStatus());
    }

    @Test
    void dedicatedRealPhoneChangeStillMovesTheLoginRevokesOldSessionAndAdvancesEmployeeVersion() throws Exception {
        String admin = adminToken();
        CustomLogin custom = customLoginEmployee(admin);
        Employee employee = custom.employee();
        UUID staff = UUID.fromString(employee.employeeId());
        int version = jdbc.queryForObject("SELECT version FROM employees WHERE id=?", Integer.class, staff);
        String next = unusedPhone();
        var changed = mvc.perform(json(post("/api/org/employees/" + staff + "/change-phone"),
                Map.of("newPhone", "+86-" + next), admin)).andReturn();
        assertEquals(200, changed.getResponse().getStatus(), body(changed));
        assertEquals(next, jdbc.queryForObject("SELECT login_account FROM users WHERE id=?",
                String.class, UUID.fromString(employee.userId())));
        assertEquals(version + 1, jdbc.queryForObject("SELECT version FROM employees WHERE id=?", Integer.class, staff));
        assertEquals(401, me(employee.accessToken()).getResponse().getStatus());
        login(next, EMPLOYEE_PASSWORD);
    }

    @Test
    void realPhoneChangeToAnotherCustomLoginRollsBackPiiAccountAndEmployeeVersion() throws Exception {
        String admin = adminToken();
        CustomLogin target = customLoginEmployee(admin), owner = customLoginEmployee(admin);
        Employee employee = target.employee();
        UUID staff = UUID.fromString(employee.employeeId());
        String accountBefore = accountHash(UUID.fromString(employee.userId()));
        String sensitiveBefore = jdbc.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",
                String.class, staff);
        int version = jdbc.queryForObject("SELECT version FROM employees WHERE id=?", Integer.class, staff);
        var refused = mvc.perform(json(post("/api/org/employees/" + staff + "/change-phone"),
                Map.of("newPhone", owner.employee().loginAccount()), admin)).andReturn();
        assertEquals(409, refused.getResponse().getStatus(), body(refused));
        assertEquals(accountBefore, accountHash(UUID.fromString(employee.userId())));
        assertEquals(sensitiveBefore, jdbc.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",
                String.class, staff));
        assertEquals(version, jdbc.queryForObject("SELECT version FROM employees WHERE id=?", Integer.class, staff));
        assertEquals(200, me(employee.accessToken()).getResponse().getStatus());
    }

    private record CustomLogin(Employee employee, String primaryPhone) {}

    private CustomLogin customLoginEmployee(String admin) throws Exception {
        String primary = unusedPhone(), login;
        do { login = unusedPhone(); } while (primary.equals(login));
        UUID department = jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_ENG' AND NOT is_deleted", UUID.class);
        String hired = java.time.LocalDate.now().minusDays(1).toString();
        var request = Map.of("profile", Map.of("fullName", "Synthetic custom login " + UUID.randomUUID(),
                        "idType", "其他", "idNumber", "CUSTOM-" + UUID.randomUUID(), "phone", primary),
                "employment", Map.of("departmentId", department, "hireDate", hired, "confirmedAt", hired,
                        "employmentType", "regular", "status", "active"),
                "emergencyContacts", java.util.List.of(), "certificates", java.util.List.of(),
                "educations", java.util.List.of(), "account", Map.of("loginAccount", login));
        var created = mvc.perform(json(post("/api/org/employees"), request, admin)).andReturn();
        assertEquals(200, created.getResponse().getStatus(), body(created));
        String temporary = json(created).path("temporaryPassword").asText();
        var initial = login(login, temporary);
        var permanent = changePassword(initial.path("accessToken").asText(), temporary, EMPLOYEE_PASSWORD);
        String user = jdbc.queryForObject("SELECT id::text FROM users WHERE login_account=?", String.class, login);
        return new CustomLogin(new Employee(login, user, json(created).path("employee").path("id").asText(),
                temporary, permanent.path("accessToken").asText(), permanent.path("refreshToken").asText()), primary);
    }

    @Test
    void editingPrimaryPhoneDoesNotReclaimAnArchivedLoginBeforeExplicitProvisioning() throws Exception {
        String admin=adminToken();Employee employee=newEmployee(admin,"DEPT_ENG");
        retire(employee);admin=adminToken();
        UUID staff=UUID.fromString(employee.employeeId()),user=UUID.fromString(employee.userId());
        String before=accountHash(user),phone=unusedPhone();
        MvcResult updated=mvc.perform(json(put("/api/org/employees/"+staff),Map.of("phone",phone),admin)).andReturn();
        assertEquals(200,updated.getResponse().getStatus(),body(updated));
        assertEquals(before,accountHash(user),"unopened identity keeps the archived login and original credentials");
        admin=adminToken();
        MvcResult opened=provision(admin,staff,stepUp(admin,ADMIN_PASSWORD));
        assertEquals(200,opened.getResponse().getStatus(),body(opened));
        assertEquals(phone,json(opened).path("loginAccount").asText());
        assertEquals(user,jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?",UUID.class,staff));
    }

    @Test
    void genericEmployeePutCannotBypassPrimaryPhoneIdentityChecksWhenNoLoginExists() throws Exception {
        String admin=adminToken();Employee existing=newEmployee(admin,"DEPT_ENG");
        UUID target=profileWithoutAccount();
        MvcResult duplicate=mvc.perform(json(put("/api/org/employees/"+target),
                Map.of("phone",existing.loginAccount()),admin)).andReturn();
        assertEquals(409,duplicate.getResponse().getStatus(),body(duplicate));
        assertEquals(0L,jdbc.queryForObject("SELECT count(*) FROM employee_sensitive WHERE employee_id=?",Long.class,target));
        assertEquals(0L,jdbc.queryForObject("SELECT count(*) FROM users WHERE employee_id=?",Long.class,target));
        MvcResult updated=mvc.perform(json(put("/api/org/employees/"+target),Map.of("phone",unusedPhone()),admin)).andReturn();
        assertEquals(200,updated.getResponse().getStatus(),body(updated));
        assertEquals(1L,jdbc.queryForObject("SELECT count(*) FROM employee_sensitive WHERE employee_id=?",Long.class,target));
    }

    @Test
    void concurrentUnopenedProfilesCanClaimOnePrimaryPhoneOnlyOnce() throws Exception {
        String admin=adminToken(),phone=unusedPhone();UUID a=profileWithoutAccount(),b=profileWithoutAccount();
        CountDownLatch start=new CountDownLatch(1);
        try(var executor=Executors.newFixedThreadPool(2)) {
            var first=executor.submit(()->putPhone(admin,a,phone,start));
            var second=executor.submit(()->putPhone(admin,b,phone,start));start.countDown();
            assertThat(java.util.List.of(first.get(30,TimeUnit.SECONDS),second.get(30,TimeUnit.SECONDS)))
                    .containsExactlyInAnyOrder(200,409);
        }
        assertEquals(1L,jdbc.queryForObject("SELECT count(*) FROM employee_sensitive WHERE employee_id IN (?,?) AND phone_hash IS NOT NULL",Long.class,a,b));
    }

    @Test
    void approvedPhoneChangeCannotClaimAnotherPrimaryPhoneAndEntireDecisionRollsBack() throws Exception {
        String admin = adminToken();
        Employee owner = newEmployee(admin, "DEPT_ENG");
        Employee applicant = newEmployee(admin, "DEPT_ENG");
        String before = accountHash(UUID.fromString(applicant.userId()));
        String sensitiveBefore = jdbc.queryForObject(
                "SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",
                String.class, UUID.fromString(applicant.employeeId()));
        var submitted = mvc.perform(json(post("/api/profile/me/changes"), Map.of(
                "changes", java.util.List.of(Map.of("fieldCode", "phone", "fieldLabel", "Phone",
                        "newValue", owner.loginAccount())), "idemKey", "phone-identity-" + UUID.randomUUID()),
                applicant.accessToken()).header("X-Uten-Step-Up", stepUp(applicant.accessToken(), EMPLOYEE_PASSWORD)))
                .andReturn();
        assertEquals(200, submitted.getResponse().getStatus(), body(submitted));
        UUID batch = UUID.fromString(json(submitted).path("batchId").asText());
        var decision = mvc.perform(json(post("/api/hr/profile-changes/" + batch + "/review"),
                Map.of("action", "approve"), admin)).andReturn();
        assertEquals(409, decision.getResponse().getStatus(), body(decision));
        assertEquals(before, accountHash(UUID.fromString(applicant.userId())));
        assertEquals(sensitiveBefore, jdbc.queryForObject(
                "SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",
                String.class, UUID.fromString(applicant.employeeId())));
        assertEquals("pending", jdbc.queryForObject(
                "SELECT status FROM profile_change_requests WHERE batch_id=?", String.class, batch));
    }

    private int putPhone(String admin,UUID employee,String phone,CountDownLatch start) throws Exception {
        start.await();return mvc.perform(json(put("/api/org/employees/"+employee),Map.of("phone",phone),admin))
                .andReturn().getResponse().getStatus();
    }

    private UUID profileWithoutAccount() {
        UUID employee=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,?,'其他',department_id,CURRENT_DATE,'probation','regular'
                FROM employees WHERE id=(SELECT employee_id FROM users WHERE login_account=?)
                """,employee,"PHONE-CLAIM-"+employee.toString().substring(0,8),
                com.uten.imp.support.SyntheticEmployeeIdentity.name("Synthetic unopened phone profile",employee),ADMIN_LOGIN);
        return employee;
    }

    private String unusedPhone() {
        String phone;
        do {phone="137"+String.format(java.util.Locale.ROOT,"%08d",Math.floorMod(System.nanoTime(),100_000_000L));}
        while(jdbc.queryForObject("SELECT count(*) FROM users WHERE login_account=?",Long.class,phone)>0);
        return phone;
    }

    @Test
    void unopenedRetainedIdentityUsesNormalStepUpAndPreservesHistoricalOwnership() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin, "DEPT_ENG");
        UUID user = UUID.fromString(employee.userId());
        UUID staff = UUID.fromString(employee.employeeId());
        Employee other = newEmployee(admin, "DEPT_ENG");
        admin = grantScope(admin, employee.userId(), other.employeeId());
        admin = grantScope(admin, other.userId(), employee.employeeId());
        String otherScopes = scopeHash(UUID.fromString(other.userId()));
        jdbc.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect,active,authority_source)
                SELECT ?,id,CASE WHEN code='profile:edit:self' THEN 'revoke' ELSE 'grant' END,
                    code<>'employee:create','SUPER_ADMIN_CONFIRMED'
                FROM permissions WHERE code IN ('account:support','profile:edit:self','employee:create')
                """, user);
        String inactiveOverride = jdbc.queryForObject(
                "SELECT to_jsonb(o)::text FROM user_permission_overrides o WHERE user_id=? AND NOT active",
                String.class, user);
        long auditBefore = jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE actor_id=?", Long.class, user);
        retire(employee);
        // V324 deliberately invalidates every permission snapshot on permanent
        // lifecycle changes. Renew the real actor session after arranging that fixture.
        admin = adminToken();
        long version = number("version", user);
        long auth = number("auth_version", user);
        long generation = number("permission_delegation_generation", user);

        MvcResult detail = mvc.perform(get("/api/org/employees/" + staff)
                .header("Authorization", "Bearer " + admin)).andReturn();
        assertEquals(200, detail.getResponse().getStatus());
        assertThat(json(detail).path("accountStatus").isNull()
                || json(detail).path("accountStatus").isMissingNode()).isTrue();
        MvcResult candidates = mvc.perform(get("/api/admin/users/provision-candidates")
                .param("search", code(staff)).header("Authorization", "Bearer " + admin)).andReturn();
        assertEquals(200, candidates.getResponse().getStatus());
        assertThat(json(candidates).findValuesAsText("employeeId")).contains(staff.toString());

        String before = accountHash(user);
        MvcResult noStepUp = mvc.perform(json(post(account(staff)), Map.of(), admin)).andReturn();
        assertEquals(403, noStepUp.getResponse().getStatus());
        assertEquals("REAUTH_REQUIRED", json(noStepUp).path("code").asText());
        assertEquals(before, accountHash(user));

        MvcResult opened = provision(admin, staff, stepUp(admin, ADMIN_PASSWORD));
        assertEquals(200, opened.getResponse().getStatus(), body(opened));
        JsonNode issued = json(opened);
        assertEquals(employee.loginAccount(), issued.path("loginAccount").asText());
        assertEquals("active", issued.path("employee").path("accountStatus").asText());
        assertEquals(user, jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?", UUID.class, staff));
        assertThat(jdbc.queryForObject("""
                SELECT NOT is_deleted AND deleted_at IS NULL AND status='active'
                    AND NOT remote_access AND must_change_password AND failed_attempts=0
                    AND locked_until IS NULL AND temp_password_expires_at>now()
                FROM users WHERE id=?
                """, Boolean.class, user)).isTrue();
        assertEquals(version + 1, number("version", user));
        assertThat(number("auth_version", user)).isGreaterThan(auth);
        assertThat(number("permission_delegation_generation", user)).isGreaterThan(generation);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE user_id=? AND active",
                Long.class, user)).isZero();
        assertEquals(2L, jdbc.queryForObject("""
                SELECT count(*) FROM user_permission_overrides WHERE user_id=? AND NOT active AND row_version=2
                """, Long.class, user));
        assertEquals(inactiveOverride, jdbc.queryForObject(
                "SELECT to_jsonb(o)::text FROM user_permission_overrides o WHERE user_id=? AND row_version=1",
                String.class, user));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM user_data_scopes WHERE user_id=?", Long.class, user));
        assertEquals(otherScopes, scopeHash(UUID.fromString(other.userId())));
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM audit_log WHERE target_type='user_data_scopes' AND action='delete'
                    AND "before"->>'user_id'=? AND actor_id=(SELECT id FROM users WHERE login_account=?)
                """, Long.class, user.toString(), ADMIN_LOGIN)).isGreaterThanOrEqualTo(1L);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM auth_sessions WHERE user_id=? AND revoked_at IS NULL",
                Long.class, user)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM refresh_tokens WHERE user_id=? AND revoked_at IS NULL",
                Long.class, user)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE actor_id=?", Long.class, user))
                .isGreaterThanOrEqualTo(auditBefore);
        assertThat(me(employee.accessToken()).getResponse().getStatus()).isEqualTo(401);

        String after = accountHash(user);
        admin = adminToken();
        MvcResult repeated = provision(admin, staff, stepUp(admin, ADMIN_PASSWORD));
        assertEquals(409, repeated.getResponse().getStatus());
        assertEquals(after, accountHash(user));
        JsonNode firstLogin = login(employee.loginAccount(), issued.path("temporaryPassword").asText());
        assertThat(firstLogin.path("mustChangePassword").asBoolean()).isTrue();
        String newToken = changePassword(firstLogin.path("accessToken").asText(),
                issued.path("temporaryPassword").asText(), "ReopenedOwn-4!").path("accessToken").asText();
        MvcResult current = me(newToken);
        assertEquals(200, current.getResponse().getStatus());
        assertThat(json(current).path("permissions").toString()).doesNotContain("account:support");
        assertThat(json(current).path("permissions").toString()).contains("profile:edit:self");
    }

    @Test
    void concurrentProvisioningHasOneWinnerAndNeverReissuesItsCredential() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin, "DEPT_ENG");
        retire(employee);
        UUID staff = UUID.fromString(employee.employeeId());
        UUID user = UUID.fromString(employee.userId());
        long version = number("version", user);
        UUID actorId = jdbc.queryForObject("SELECT id FROM users WHERE login_account=?", UUID.class, ADMIN_LOGIN);
        UUID actorEmployee = jdbc.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, actorId);
        var actor = new com.uten.imp.security.AuthUser(actorId, actorEmployee, ADMIN_LOGIN,
                java.util.Set.of("account:support", "employee:view"), false, true, true);
        CountDownLatch start = new CountDownLatch(1);
        try (var executor = Executors.newFixedThreadPool(2)) {
            // Exercise the transactional boundary after authentication. The HTTP
            // step-up contract is tested above; a request reaching JWT validation
            // after the winning commit must instead reauthenticate under V324.
            var first = executor.submit(() -> concurrentProvision(actor, staff, start));
            var second = executor.submit(() -> concurrentProvision(actor, staff, start));
            start.countDown();
            int a = first.get(30, TimeUnit.SECONDS);
            int b = second.get(30, TimeUnit.SECONDS);
            assertThat(java.util.List.of(a, b))
                    .containsExactlyInAnyOrder(200, 409);
        }
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM users WHERE employee_id=?", Long.class, staff));
        assertEquals(user, jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?", UUID.class, staff));
        assertEquals(version + 1, number("version", user));
    }

    @Test
    void supportCannotReopenHighRiskTargetAndFailureRollsBackAllAccountChanges() throws Exception {
        String admin = adminToken();
        Employee support = newEmployee(admin, "DEPT_ENG");
        MvcResult granted = mvc.perform(json(put("/api/admin/users/" + support.userId() + "/permission-overrides"),
                Map.of("grants", java.util.List.of("account:support"), "revokes", java.util.List.of()), admin)
                .header("X-Uten-Step-Up", stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, granted.getResponse().getStatus(), body(granted));
        admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_HR");
        admin = grantScope(admin, target.userId(), support.employeeId());
        retire(target);
        String supportToken = login(support.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        UUID user = UUID.fromString(target.userId());
        String before = accountHash(user);
        String scopesBefore = scopeHash(user);
        MvcResult refused = provision(supportToken, UUID.fromString(target.employeeId()),
                stepUp(supportToken, EMPLOYEE_PASSWORD));
        assertEquals(403, refused.getResponse().getStatus());
        assertThat(json(refused).path("message").asText()).contains("高危权限");
        assertEquals(before, accountHash(user));
        assertEquals(scopesBefore, scopeHash(user));
    }

    private String grantScope(String admin, String recipient, String owner) throws Exception {
        MvcResult saved = mvc.perform(json(put("/api/admin/users/" + recipient + "/data-scopes").param("scope", "client"),
                Map.of("ownerEmployeeIds", java.util.List.of(owner), "expectedOwnerEmployeeIds", java.util.List.of()), admin)
                .header("X-Uten-Step-Up", stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, saved.getResponse().getStatus(), body(saved));
        return adminToken();
    }

    private String scopeHash(UUID user) {
        return jdbc.queryForObject("""
                SELECT encode(digest(COALESCE(jsonb_agg(to_jsonb(s) ORDER BY scope,owner_employee_id)::text,'[]'),
                    'sha256'),'hex') FROM user_data_scopes s WHERE user_id=?
                """, String.class, user);
    }

    private void retire(Employee employee) {
        jdbc.update("""
                UPDATE users SET login_account='offboarded-'||login_account,status='disabled',is_deleted=true,
                    remote_access=true,must_change_password=true,temp_password_expires_at=now()-interval '1 day',
                    failed_attempts=7,locked_until=now()+interval '1 day',deleted_at=NULL
                WHERE id=?
                """, UUID.fromString(employee.userId()));
    }

    private int concurrentProvision(com.uten.imp.security.AuthUser actor, UUID staff, CountDownLatch start)
            throws InterruptedException {
        var context = org.springframework.security.core.context.SecurityContextHolder.createEmptyContext();
        context.setAuthentication(new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(
                actor, null, actor.getAuthorities()));
        org.springframework.security.core.context.SecurityContextHolder.setContext(context);
        try {
            start.await();
            onboarding.provisionAccount(staff);
            return 200;
        } catch (com.uten.imp.common.web.ApiException refused) {
            assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT, refused.getCode());
            return 409;
        } finally {
            org.springframework.security.core.context.SecurityContextHolder.clearContext();
        }
    }

    private MvcResult provision(String token, UUID employee, String proof) throws Exception {
        return mvc.perform(json(post(account(employee)), Map.of(), token)
                .header("X-Uten-Step-Up", proof)).andReturn();
    }

    private static String account(UUID staff) { return "/api/org/employees/" + staff + "/account"; }
    private String code(UUID staff) { return jdbc.queryForObject("SELECT code FROM employees WHERE id=?", String.class, staff); }
    private long number(String column, UUID user) {
        if (!java.util.Set.of("version", "auth_version", "permission_delegation_generation").contains(column)) {
            throw new IllegalArgumentException("Unsupported test projection");
        }
        return jdbc.queryForObject("SELECT " + column + " FROM users WHERE id=?", Long.class, user);
    }
    private String accountHash(UUID user) {
        return jdbc.queryForObject("SELECT encode(digest(to_jsonb(u)::text,'sha256'),'hex') FROM users u WHERE id=?", String.class, user);
    }
}
