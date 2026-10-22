package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real context-owned clones: old negative data stays real and never enters a new context. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AuthSessionContextDatabaseIsolationPostgresTest {
    @Test
    void newContextNeverInheritsAnUncheckedUnreadableIdentityAndClosesPoolsBeforeItsLease() {
        var firstCloses = new ArrayList<String>();
        var secondCloses = new ArrayList<String>();
        MigratedSchemaBaseline.ScopedDatabase firstLease;
        MigratedSchemaBaseline.ScopedDatabase secondLease;
        try (var first = context(firstCloses)) {
            firstLease = first.getBean(AuthSessionPostgresTestSupport.DATABASE_LEASE_BEAN,
                    MigratedSchemaBaseline.ScopedDatabase.class);
            var firstDb = new JdbcTemplate(first.getBean("dataSource", HikariDataSource.class));
            var evidence = new JdbcTemplate(first.getBean("evidenceDataSource", HikariDataSource.class));
            assertEquals(firstDb.queryForObject("SELECT current_database()", String.class),
                    evidence.queryForObject("SELECT current_database()", String.class));
            UUID employee = UUID.randomUUID();
            firstDb.update("""
                    INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,confirmed_at,status,employment_type)
                    SELECT ?,?,'Synthetic identity isolation','身份证',id,DATE '2025-01-02',DATE '2025-04-02','active','regular'
                    FROM departments WHERE code='DEPT_ENG' AND NOT is_deleted
                    """, employee, "SYN-AUTH-" + employee.toString().substring(0, 8));
            String corrupt = "v1:bm90IGEgcGdwIG1lc3NhZ2U=";
            firstDb.update("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check) VALUES(?,?,'unchecked')",
                    employee, corrupt);
            try (var second = context(secondCloses)) {
                secondLease = second.getBean(AuthSessionPostgresTestSupport.DATABASE_LEASE_BEAN,
                        MigratedSchemaBaseline.ScopedDatabase.class);
                var secondDb = new JdbcTemplate(second.getBean("dataSource", HikariDataSource.class));
                assertNotEquals(firstDb.queryForObject("SELECT current_database()", String.class),
                        secondDb.queryForObject("SELECT current_database()", String.class));
                assertEquals(0, secondDb.queryForObject("SELECT count(*) FROM employee_sensitive WHERE employee_id=?", Integer.class, employee));
                assertEquals(0, secondDb.queryForObject("SELECT count(*) FROM employee_sensitive WHERE id_card_check='unchecked'", Integer.class));
                assertEquals(corrupt, firstDb.queryForObject("SELECT id_card_enc FROM employee_sensitive WHERE employee_id=?", String.class, employee));
                assertEquals("unchecked", firstDb.queryForObject("SELECT id_card_check FROM employee_sensitive WHERE employee_id=?", String.class, employee));
                // Open the secondary pool too: cleanup must close real holders,
                // rather than make dropdb --force kill an otherwise live pool.
                assertEquals(1, new JdbcTemplate(second.getBean("evidenceDataSource", HikariDataSource.class))
                        .queryForObject("SELECT 1", Integer.class));
            }
            assertEquals(List.of("evidenceDataSource", "dataSource"), secondCloses);
            assertThrows(IllegalStateException.class, secondLease::getJdbcUrl);
            assertEquals(1, firstDb.queryForObject("SELECT count(*) FROM employee_sensitive WHERE employee_id=?", Integer.class, employee));
        }
        assertEquals(List.of("evidenceDataSource", "dataSource"), firstCloses);
        assertThrows(IllegalStateException.class, firstLease::getJdbcUrl);
    }

    private static GenericApplicationContext context(List<String> closeOrder) {
        var context = new GenericApplicationContext();
        new AuthSessionPostgresTestSupport.DatabaseInitializer().initialize(context);
        context.registerBean("dataSource", HikariDataSource.class, () -> pool(context, closeOrder, "dataSource"),
                definition -> definition.setDestroyMethodName("close"));
        context.registerBean("evidenceDataSource", HikariDataSource.class, () -> pool(context, closeOrder, "evidenceDataSource"),
                definition -> {
                    definition.setDependsOn("dataSource");
                    definition.setDestroyMethodName("close");
                });
        context.refresh();
        return context;
    }

    private static HikariDataSource pool(GenericApplicationContext context, List<String> closeOrder, String name) {
        var lease = context.getBean(AuthSessionPostgresTestSupport.DATABASE_LEASE_BEAN, MigratedSchemaBaseline.ScopedDatabase.class);
        var source = new HikariDataSource() {
            @Override public void close() {
                assertDoesNotThrow(lease::getJdbcUrl, "the lease must remain open while a dependent pool closes");
                closeOrder.add(name);
                super.close();
            }
        };
        source.setJdbcUrl(lease.getJdbcUrl());
        source.setUsername(lease.getUsername());
        source.setPassword(lease.getPassword());
        source.setMaximumPoolSize(1);
        source.setMinimumIdle(0);
        return source;
    }
}
