package com.uten.imp.security;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** The once-per-statement workshop resolution keeps the exact per-row recursive department verdict. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionWorkshopAssignmentScopePostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;

    /** The pre-V1121-era per-row walk, kept verbatim as the reference verdict. */
    private static final String REFERENCE = """
            EXISTS (
                WITH RECURSIVE workshop_tree(id) AS (
                    SELECT t.workshop_department_id WHERE t.workshop_department_id IS NOT NULL
                    UNION ALL
                    SELECT child.id FROM departments child JOIN workshop_tree parent ON child.parent_id=parent.id
                    WHERE child.is_deleted=FALSE
                )
                SELECT 1 FROM employees employee
                LEFT JOIN employee_secondary_departments secondary ON secondary.employee_id=employee.id
                WHERE employee.id=:employeeId AND employee.is_deleted=FALSE
                  AND employee.status IN ('active','probation','onLeave')
                  AND (t.responsible_employee_id=employee.id
                       OR employee.department_id IN (SELECT id FROM workshop_tree)
                       OR secondary.department_id IN (SELECT id FROM workshop_tree)
                       OR EXISTS (SELECT 1 FROM departments managed WHERE managed.id IN (SELECT id FROM workshop_tree)
                                  AND managed.manager_id=employee.id AND managed.is_deleted=FALSE))
            )
            """;

    @BeforeAll static void start() {
        PG.start();
        TestFlyway.configure().dataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()).load().migrate();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
    }

    @AfterAll static void stop() { PG.stop(); }

    @Test void everyEmployeeAndWorkshopKeepTheRecursiveSubtreeVerdict() {
        Map<String, UUID> d = new LinkedHashMap<>();
        department(d, "root", null, false);
        department(d, "a", "root", false);
        department(d, "a1", "a", false);
        department(d, "a1Deleted", "a1", true);
        department(d, "underDeleted", "a1Deleted", false);
        department(d, "bDeleted", "root", true);
        department(d, "b1", "bDeleted", false);
        department(d, "standalone", null, false);
        Map<String, UUID> e = new LinkedHashMap<>();
        employee(e, "primaryA1", d.get("a1"), "active", false);
        employee(e, "secondaryDeleted", d.get("standalone"), "probation", false);
        employee(e, "managerB1", d.get("standalone"), "onLeave", false);
        employee(e, "underDeletedPrimary", d.get("underDeleted"), "active", false);
        employee(e, "resigned", d.get("a1"), "resigned", false);
        employee(e, "deletedEmployee", d.get("a1"), "active", true);
        employee(e, "managesDeleted", d.get("standalone"), "active", false);
        employee(e, "secondaryRoot", d.get("standalone"), "active", false);
        db.update("INSERT INTO employee_secondary_departments(employee_id,department_id) VALUES (?,?),(?,?)",
                e.get("secondaryDeleted"), d.get("a1Deleted"), e.get("secondaryRoot"), d.get("root"));
        db.update("UPDATE departments SET manager_id=? WHERE id=?", e.get("managerB1"), d.get("b1"));
        db.update("UPDATE departments SET manager_id=? WHERE id=?", e.get("managesDeleted"), d.get("a1Deleted"));

        List<UUID> workshops = new ArrayList<>(d.values());
        workshops.add(null);
        List<UUID> responsible = new ArrayList<>(List.of(e.get("primaryA1"), e.get("resigned"), e.get("deletedEmployee")));
        responsible.add(null);
        StringBuilder tasks = new StringBuilder();
        int index = 0;
        for (UUID workshop : workshops) for (UUID owner : responsible) {
            if (!tasks.isEmpty()) tasks.append(',');
            tasks.append("(").append(index++).append(',').append(literal(workshop)).append(',').append(literal(owner)).append(')');
        }
        String sql = "SELECT t.idx, (" + REFERENCE + ") AS reference, (" + ProductionWorkshopAssignmentScope.predicate("t")
                + ") AS resolved FROM (VALUES " + tasks + ") t(idx,workshop_department_id,responsible_employee_id) ORDER BY t.idx";
        var named = new NamedParameterJdbcTemplate(db);
        List<UUID> subjects = new ArrayList<>(e.values());
        subjects.add(UUID.randomUUID());
        int assigned = 0;
        for (UUID subject : subjects) {
            var rows = named.queryForList(sql, Map.of("employeeId", subject));
            assertThat(rows).hasSize(index);
            for (var row : rows) {
                assertThat(row.get("resolved")).as("never NULL for %s task %s", subject, row.get("idx")).isNotNull();
                assertThat(row.get("resolved")).as("employee %s task %s", subject, row.get("idx")).isEqualTo(row.get("reference"));
                if (Boolean.TRUE.equals(row.get("resolved"))) assigned++;
            }
        }
        assertThat(assigned).as("the fixture exercises positive assignments").isGreaterThan(10);
        // An unbound subject never qualifies, in a filter or as a projected flag.
        var unbound = new java.util.HashMap<String, Object>();
        unbound.put("employeeId", null);
        for (var row : named.queryForList(sql, unbound)) {
            assertThat(row.get("reference")).isEqualTo(false);
            assertThat(row.get("resolved")).isEqualTo(false);
        }
    }

    private static void department(Map<String, UUID> d, String name, String parent, boolean deleted) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,level,parent_id,is_deleted) VALUES (?,?,?,'一级部门',?,?)",
                id, "WS-" + id, "workshop " + name, parent == null ? null : d.get(parent), deleted);
        d.put(name, id);
    }

    private static void employee(Map<String, UUID> e, String name, UUID department, String status, boolean deleted) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type,is_deleted)
                VALUES (?,?,?,'其他',?,CURRENT_DATE,?,'regular',?)
                """, id, "WS-" + id, "workshop " + name, department, status, deleted);
        e.put(name, id);
    }

    private static String literal(UUID id) { return id == null ? "NULL::uuid" : "'" + id + "'::uuid"; }
}
