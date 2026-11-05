package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** A nonempty upgrade keeps original sources/history/guards while narrowing future audit payloads. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FinancialSubversionAuditPolicyForwardPostgresTest {
    private static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID ORIGINAL = UUID.randomUUID();
    private static final UUID PARTY = UUID.randomUUID();
    private static JdbcTemplate db;
    private static UUID actor;
    private static Map<String, String> rowsBefore;
    private static Map<String, String> rowsAfter;
    private static String auditBefore;
    private static String auditAfter;
    private static String historyBefore;
    private static String historyAfter;
    private static String guardsBefore;
    private static String guardsAfter;

    @BeforeAll
    static void upgradeNonemptyFinancialSources() throws Exception {
        DB.start();
        TestFlyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").target("1058").load().migrate();
        db = new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        actor = createActor();
        source(ORIGINAL, "before-upgrade-private.xlsx");
        db.update("""
                INSERT INTO finance_auxiliary_parties(id,source_system,source_code,source_name,created_by,updated_by)
                VALUES (?,'synthetic-audit-source','SYNTHETIC-PARTY','Before upgrade private party',?,?)
                """, PARTY, actor, actor);
        rowsBefore = financialRows();
        auditBefore = auditHistory();
        historyBefore = migrationHistory();
        guardsBefore = businessGuards();
        var migration = TestFlyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").target("1059").load().migrate();
        assertThat(migration.migrationsExecuted).isEqualTo(1);
        rowsAfter = financialRows();
        auditAfter = auditHistory();
        historyAfter = migrationHistory();
        guardsAfter = businessGuards();
    }

    @AfterAll
    static void stop() { DB.stop(); }

    @Test
    void upgradePreservesEveryFinancialSubversionRowAuditAndBusinessGuard() {
        assertThat(rowsAfter).hasSize(57).isEqualTo(rowsBefore);
        assertThat(auditAfter).isEqualTo(auditBefore);
        assertThat(historyAfter).isEqualTo(historyBefore);
        assertThat(guardsAfter).isEqualTo(guardsBefore)
                .contains("trg_finance_template_source_immutable", "trg_guard_posted_finance_auxiliary_identity");
    }

    @Test
    void futureInsertAndUpdateKeepOneMetadataTrailWithoutPrivateNamesOrSourceContent() {
        UUID fresh = UUID.randomUUID();
        source(fresh, "after-upgrade-private.xlsx");
        List<Map<String, Object>> sourceAudit = db.queryForList("""
                SELECT "before"::text AS before_payload,"after"::text AS after_payload
                FROM audit_log WHERE target_type='finance_template_sources' AND target_id=?
                """, fresh.toString());
        assertThat(sourceAudit).hasSize(1);
        assertThat(sourceAudit.getFirst().get("after_payload").toString())
                .contains(fresh.toString(), "source_selection", "sheet=2")
                .doesNotContain("after-upgrade-private.xlsx", "private-preview-marker", "source_name", "preview", "storage_key");

        long before = db.queryForObject("""
                SELECT count(*) FROM audit_log WHERE target_type='finance_auxiliary_parties' AND target_id=?
                """, Long.class, PARTY.toString());
        db.update("""
                UPDATE finance_auxiliary_parties SET source_name='After upgrade private party',row_version=row_version+1
                WHERE id=?
                """, PARTY);
        assertThat(db.queryForObject("""
                SELECT count(*) FROM audit_log WHERE target_type='finance_auxiliary_parties' AND target_id=?
                """, Long.class, PARTY.toString())).isEqualTo(before + 1);
        assertThat(db.queryForObject("""
                SELECT "before"::text||"after"::text FROM audit_log
                WHERE target_type='finance_auxiliary_parties' AND target_id=? AND action='update'
                ORDER BY id DESC LIMIT 1
                """, String.class, PARTY.toString()))
                .contains("_redacted_changes", "source_name")
                .doesNotContain("Before upgrade private party", "After upgrade private party");
        assertThat(db.queryForObject("""
                SELECT jsonb_exists("before",'source_name') OR jsonb_exists("after",'source_name') FROM audit_log
                WHERE target_type='finance_auxiliary_parties' AND target_id=? AND action='update'
                ORDER BY id DESC LIMIT 1
                """, Boolean.class, PARTY.toString())).isFalse();
        assertThat(db.queryForObject("SELECT source_name FROM finance_auxiliary_parties WHERE id=?", String.class, PARTY))
                .isEqualTo("After upgrade private party");
        db.update("""
                UPDATE finance_auxiliary_parties SET source_name='After upgrade private party',row_version=row_version+1
                WHERE id=?
                """, PARTY);
        assertThat(db.queryForObject("""
                SELECT count(*) FROM audit_log WHERE target_type='finance_auxiliary_parties' AND target_id=?
                """, Long.class, PARTY.toString())).isEqualTo(before + 1);
    }

    @Test
    void immutableOriginalStillRejectsOverwriteAfterAuditNormalization() {
        var failure = assertThrows(org.springframework.dao.DataAccessException.class,
                () -> db.update("UPDATE finance_template_sources SET source_name='overwrite' WHERE id=?", ORIGINAL));
        assertThat(failure.getMostSpecificCause()).isInstanceOf(java.sql.SQLException.class);
        assertThat(db.queryForObject("SELECT source_name FROM finance_template_sources WHERE id=?", String.class, ORIGINAL))
                .isEqualTo("before-upgrade-private.xlsx");
    }

    private static void source(UUID id, String name) {
        db.update("""
                INSERT INTO finance_template_sources
                    (id,actor_id,template_key,period,source_name,sha256,storage_provider,storage_key,storage_size,preview,source_selection)
                VALUES (?,?,'SYNTHETIC_AUDIT_POLICY','2026-11',?,?,'local',?,1,
                        '{"private":"private-preview-marker"}'::jsonb,'sheet=2')
                """, id, actor, name, id.toString().replace("-", "").repeat(2), id.toString());
    }

    private static UUID createActor() {
        UUID employee = UUID.randomUUID(), user = UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),DATE '2026-01-01','active','regular')
                """, employee, "SUB-AUDIT-" + employee,
                com.uten.imp.support.SyntheticEmployeeIdentity.name("subversion audit", employee));
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status) VALUES(?,?,?,'test-not-used','active')",
                user, employee, "subversion-audit-" + user);
        return user;
    }

    private static Map<String, String> financialRows() throws Exception {
        Map<String, String> rows = new LinkedHashMap<>();
        for (var migration : AuditTriggerCoverageMigrationContractTest.migrations()) {
            if (!migration.path().getFileName().toString().matches("V999_\\d+__.+")) continue;
            var table = AuditTriggerCoverageMigrationContractTest.CREATE_TABLE.matcher(
                    AuditTriggerCoverageMigrationContractTest.stripSqlComments(migration.sql()));
            while (table.find()) {
                String name = table.group(1);
                assertThat(name).matches("[a-z_][a-z0-9_]*");
                rows.put(name, db.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(row_value)::text,''"
                        + " ORDER BY to_jsonb(row_value)::text),'')) FROM public." + name + " row_value", String.class));
            }
        }
        return rows;
    }

    private static String auditHistory() {
        return db.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(a)::text,'' ORDER BY id,created_at),'')) FROM audit_log a", String.class);
    }

    private static String migrationHistory() {
        return db.queryForObject("SELECT md5(string_agg(to_jsonb(h)::text,'' ORDER BY installed_rank)) FROM flyway_schema_history h WHERE version<>'1059'", String.class);
    }

    private static String businessGuards() {
        return db.queryForObject("""
                SELECT jsonb_agg(jsonb_build_array(t.tgrelid::regclass::text,t.tgname,pg_get_triggerdef(t.oid),t.tgenabled)
                    ORDER BY t.tgrelid,t.tgname)::text FROM pg_trigger t
                JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgfoid<>'public.fn_audit()'::regprocedure
                """, String.class);
    }
}
