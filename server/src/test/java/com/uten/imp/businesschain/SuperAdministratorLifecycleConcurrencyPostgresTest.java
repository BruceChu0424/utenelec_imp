package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.test.context.TestPropertySource;

import java.sql.Connection;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** Its own private database: the red case deliberately proves zero administrators. */
@TestPropertySource(properties = "uten.test.superadmin-lifecycle-concurrency=isolated")
@org.junit.jupiter.api.parallel.Execution(org.junit.jupiter.api.parallel.ExecutionMode.SAME_THREAD)
class SuperAdministratorLifecycleConcurrencyPostgresTest extends AuthSessionPostgresTestSupport {
    @org.springframework.beans.factory.annotation.Autowired
    com.uten.imp.features.admin.AccountLifecycleCoordinator coordinator;
    @org.springframework.beans.factory.annotation.Autowired
    org.springframework.transaction.PlatformTransactionManager transactions;

    @ParameterizedTest
    @ValueSource(strings = {"disabled", "locked", "deleted-user", "departed", "deleted-employee", "expired"})
    void unusableAdministratorFlagsCannotServeAsTheLastFallback(String condition) {
        fallback(condition, false);
    }

    @Test
    void anotherCurrentAdministratorWithAValidCredentialRemainsACountedFallback() {
        fallback("valid", true);
    }

    private void fallback(String condition, boolean allowed) {
        var transaction = new org.springframework.transaction.support.TransactionTemplate(transactions);
        transaction.executeWithoutResult(status -> {
            try {
                coordinator.lock();
                jdbc.update("UPDATE users SET is_super_admin=(login_account=?)", ADMIN_LOGIN);
                jdbc.update("UPDATE users SET status='active',must_change_password=false,temp_password_expires_at=NULL WHERE login_account=?", ADMIN_LOGIN);
                UUID target = jdbc.queryForObject("SELECT id FROM users WHERE login_account=?", UUID.class, ADMIN_LOGIN);
                UUID employee = UUID.randomUUID();
                jdbc.update("""
                        INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type,is_deleted)
                        SELECT ?,?,'Synthetic administrator eligibility','其他',id,CURRENT_DATE,?,'regular',?
                        FROM departments WHERE code='DEPT_ENG'
                        """, employee, "ADMIN-CHECK-" + employee, "departed".equals(condition) ? "resigned" : "active", "deleted-employee".equals(condition));
                jdbc.update("""
                        INSERT INTO users(employee_id,login_account,password_hash,is_super_admin,status,is_deleted,must_change_password,temp_password_expires_at)
                        SELECT ?,?,password_hash,true,?,?,?,CASE WHEN ? THEN now()-interval '1 second' ELSE NULL END
                        FROM users WHERE login_account=?
                        """, employee, "administrator-eligibility-" + employee,
                        "disabled".equals(condition) ? "disabled" : "locked".equals(condition) ? "locked" : "active",
                        "deleted-user".equals(condition), "expired".equals(condition), "expired".equals(condition), ADMIN_LOGIN);
                if (allowed) assertDoesNotThrow(() -> coordinator.requireAdministratorSurvives(target));
                else assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,
                        assertThrows(com.uten.imp.common.web.ApiException.class, () -> coordinator.requireAdministratorSurvives(target)).getCode());
            } finally {
                status.setRollbackOnly();
            }
        });
    }

    @Test
    void concurrentCrossDemotionsCannotRemoveEveryUsableAdministrator() throws Exception {
        String initial = readyPrivateAdministrator();
        Employee second = newEmployee(initial, "DEPT_ENG");
        var promoted = mvc.perform(json(put("/api/admin/users/" + second.userId() + "/super-admin"), Map.of("superAdmin", true), initial)
                .header("X-Uten-Step-Up", stepUp(initial, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, promoted.getResponse().getStatus(), body(promoted));
        String first = adminToken(), next = login(second.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        String firstProof = stepUp(first, ADMIN_PASSWORD), nextProof = stepUp(next, EMPLOYEE_PASSWORD);
        String firstId = jdbc.queryForObject("SELECT id::text FROM users WHERE login_account=?", String.class, ADMIN_LOGIN);
        jdbc.execute("""
                CREATE FUNCTION fn_test_superadmin_lifecycle_gate() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(1431586126,45203); RETURN NEW; END $$;
                CREATE TRIGGER trg_test_superadmin_lifecycle_gate BEFORE UPDATE OF is_super_admin ON users
                FOR EACH ROW WHEN (OLD.is_super_admin AND NOT NEW.is_super_admin)
                EXECUTE FUNCTION fn_test_superadmin_lifecycle_gate();
                """);
        try (Connection gate = jdbc.getDataSource().getConnection(); var executor = Executors.newFixedThreadPool(2)) {
            gate(gate, true);
            boolean held = true;
            try {
                CountDownLatch start = new CountDownLatch(1);
                var a = executor.submit(() -> { start.await(); return mvc.perform(json(put("/api/admin/users/" + second.userId() + "/super-admin"),
                        Map.of("superAdmin", false), first).header("X-Uten-Step-Up", firstProof)).andReturn(); });
                var b = executor.submit(() -> { start.await(); return mvc.perform(json(put("/api/admin/users/" + firstId + "/super-admin"),
                        Map.of("superAdmin", false), next).header("X-Uten-Step-Up", nextProof)).andReturn(); });
                start.countDown();
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
                while (System.nanoTime() < deadline) {
                    int waiters = jdbc.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=1431586126 AND objid=45203 AND NOT granted", Integer.class);
                    if (waiters == 2) break;
                    Thread.sleep(20);
                }
                gate(gate, false);
                held = false;
                var left = a.get(30, TimeUnit.SECONDS); var right = b.get(30, TimeUnit.SECONDS);
                long usable = jdbc.queryForObject("SELECT count(*) FROM users u JOIN employees e ON e.id=u.employee_id WHERE u.is_super_admin AND NOT u.is_deleted AND u.status='active' AND NOT e.is_deleted AND e.status IN('active','probation','onLeave')", Long.class);
                assertTrue(usable >= 1, "concurrent real-role commands removed every usable administrator");
                assertTrue(java.util.List.of(200, 401, 403, 409).contains(left.getResponse().getStatus()), body(left));
                assertTrue(java.util.List.of(200, 401, 403, 409).contains(right.getResponse().getStatus()), body(right));
                assertEquals(1, (left.getResponse().getStatus() == 200 ? 1 : 0) + (right.getResponse().getStatus() == 200 ? 1 : 0));
            } finally {
                if (held) gate(gate, false);
            }
        } finally {
            jdbc.execute("DROP TRIGGER trg_test_superadmin_lifecycle_gate ON users; DROP FUNCTION fn_test_superadmin_lifecycle_gate()");
        }
    }

    @Test
    void offboardingRechecksSuperAdminAfterTheTargetLocksWithoutBlockingOtherAccountsGlobally() throws Exception {
        String admin = readyPrivateAdministrator();
        Employee target = newEmployee(admin, "DEPT_ENG");
        String proof = stepUp(admin, ADMIN_PASSWORD);
        jdbc.execute("""
                CREATE FUNCTION fn_test_promotion_lifecycle_gate() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(1431586126,45204); RETURN NEW; END $$;
                CREATE TRIGGER trg_test_promotion_lifecycle_gate BEFORE UPDATE OF is_super_admin ON users
                FOR EACH ROW WHEN (NOT OLD.is_super_admin AND NEW.is_super_admin)
                EXECUTE FUNCTION fn_test_promotion_lifecycle_gate();
                """);
        try (Connection gate = jdbc.getDataSource().getConnection(); var executor = Executors.newFixedThreadPool(2)) {
            promotionGate(gate, true);
            boolean held = true;
            try {
                var promotion = executor.submit(() -> mvc.perform(json(put("/api/admin/users/" + target.userId() + "/super-admin"),
                        Map.of("superAdmin", true), admin).header("X-Uten-Step-Up", proof)).andReturn());
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
                boolean waiting = false;
                while (System.nanoTime() < deadline) {
                    waiting = jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=1431586126 AND objid=45204 AND NOT granted)", Boolean.class);
                    if (waiting) break;
                    Thread.sleep(20);
                }
                assertTrue(waiting, "promotion must hold its canonical target locks before departure starts");
                var departure = executor.submit(() -> mvc.perform(json(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post(
                        "/api/org/employees/" + target.employeeId() + "/offboard"), Map.of("resignType", "VOLUNTARY",
                        "effectiveDate", LocalDate.now().toString(), "reason", "Promotion versus departure proof", "requestId", UUID.randomUUID(),
                        "confirmedChecklistCodes", List.of("ACCESS_CARD_RETURNED", "COMPANY_ASSETS_ACCOUNTED",
                                "ACCOUNT_DISABLE_ACKNOWLEDGED", "SOCIAL_BENEFITS_ARRANGED")), admin)).andReturn());
                Thread.sleep(200);
                promotionGate(gate, false); held = false;
                var promoted = promotion.get(30, TimeUnit.SECONDS);
                var rejected = departure.get(30, TimeUnit.SECONDS);
                assertEquals(200, promoted.getResponse().getStatus(), body(promoted));
                assertTrue(List.of(401, 403, 409).contains(rejected.getResponse().getStatus()), body(rejected));
                assertEquals("active", jdbc.queryForObject("SELECT status FROM employees WHERE id=?", String.class, UUID.fromString(target.employeeId())));
                assertTrue(jdbc.queryForObject("SELECT is_super_admin AND status='active' FROM users WHERE id=?", Boolean.class, UUID.fromString(target.userId())));
                assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM employee_offboarding_events WHERE employee_id=?", Long.class, UUID.fromString(target.employeeId())));
            } finally {
                if (held) promotionGate(gate, false);
            }
        } finally {
            jdbc.execute("DROP TRIGGER trg_test_promotion_lifecycle_gate ON users; DROP FUNCTION fn_test_promotion_lifecycle_gate()");
        }
    }

    private String readyPrivateAdministrator() throws Exception {
        adminToken();
        jdbc.update("UPDATE users SET is_super_admin=(login_account=?)", ADMIN_LOGIN);
        return adminToken();
    }

    private static void promotionGate(Connection connection, boolean acquire) throws java.sql.SQLException {
        try (var statement = connection.prepareStatement(acquire
                ? "SELECT pg_advisory_lock(?,?)" : "SELECT pg_advisory_unlock(?,?)")) {
            statement.setInt(1, 1431586126); statement.setInt(2, 45204); statement.execute();
        }
    }

    private static void gate(Connection connection, boolean acquire) throws java.sql.SQLException {
        try (var statement = connection.prepareStatement(acquire
                ? "SELECT pg_advisory_lock(?,?)" : "SELECT pg_advisory_unlock(?,?)")) {
            statement.setInt(1, 1431586126); statement.setInt(2, 45203); statement.execute();
        }
    }
}
