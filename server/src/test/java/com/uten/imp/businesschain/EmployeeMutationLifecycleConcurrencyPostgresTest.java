package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;

import java.sql.Connection;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Delays a real INSERT after employee loading, without replacing any business rule. */
class EmployeeMutationLifecycleConcurrencyPostgresTest extends AuthSessionPostgresTestSupport {
    @Test
    void contractRenewalAndOffboardingCannotResurrectTheDepartedEmployee() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin, "DEPT_ENG");
        jdbc.execute("""
                CREATE FUNCTION fn_test_contract_lifecycle_gate() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(1431586126,45202); RETURN NEW; END $$;
                CREATE TRIGGER trg_test_contract_lifecycle_gate BEFORE INSERT ON employee_contracts
                FOR EACH ROW EXECUTE FUNCTION fn_test_contract_lifecycle_gate();
                """);
        try (Connection gate = jdbc.getDataSource().getConnection(); var executor = Executors.newFixedThreadPool(2)) {
            gate(gate, true);
            boolean held = true;
            try {
                var renewal = executor.submit(() -> mvc.perform(json(post("/api/org/employees/" + employee.employeeId() + "/contracts"),
                        Map.of("contractType", "fixed", "startDate", LocalDate.now().toString()), admin)).andReturn());
                awaitWaiter();
                var departure = executor.submit(() -> mvc.perform(json(post("/api/org/employees/" + employee.employeeId() + "/offboard"),
                        Map.of("resignType", "VOLUNTARY", "effectiveDate", LocalDate.now().toString(), "reason", "Concurrent lifecycle proof",
                                "requestId", UUID.randomUUID(), "confirmedChecklistCodes", List.of("ACCESS_CARD_RETURNED",
                                        "COMPANY_ASSETS_ACCOUNTED", "ACCOUNT_DISABLE_ACKNOWLEDGED", "SOCIAL_BENEFITS_ARRANGED")), admin)).andReturn());
                try { departure.get(5, TimeUnit.SECONDS); } catch (TimeoutException expectedSerialization) { /* release either ordering below */ }
                gate(gate, false);
                held = false;
                var renewed = renewal.get(30, TimeUnit.SECONDS);
                var departed = departure.get(30, TimeUnit.SECONDS);
                assertEquals(200, renewed.getResponse().getStatus(), body(renewed));
                assertTrue(List.of(200, 409).contains(departed.getResponse().getStatus()), body(departed));
                if (departed.getResponse().getStatus() == 200) {
                    assertEquals("resigned", jdbc.queryForObject("SELECT status FROM employees WHERE id=?", String.class,
                            UUID.fromString(employee.employeeId())), "a stale contract save must not undo committed offboarding");
                }
            } finally {
                if (held) gate(gate, false);
            }
        } finally {
            jdbc.execute("DROP TRIGGER trg_test_contract_lifecycle_gate ON employee_contracts; DROP FUNCTION fn_test_contract_lifecycle_gate()");
        }
    }

    private static void gate(Connection connection, boolean acquire) throws java.sql.SQLException {
        try (var statement = connection.prepareStatement(acquire
                ? "SELECT pg_advisory_lock(?,?)" : "SELECT pg_advisory_unlock(?,?)")) {
            statement.setInt(1, 1431586126); statement.setInt(2, 45202); statement.execute();
        }
    }

    private void awaitWaiter() throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        while (System.nanoTime() < deadline) {
            if (jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=1431586126 AND objid=45202 AND NOT granted)", Boolean.class)) return;
            Thread.sleep(20);
        }
        fail("contract INSERT did not reach the private concurrency gate");
    }
}
