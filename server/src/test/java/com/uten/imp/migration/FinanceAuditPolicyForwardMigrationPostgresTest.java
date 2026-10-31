package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Nonempty V974 -> V975: repair the policy shape without rewriting applied history or business evidence. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FinanceAuditPolicyForwardMigrationPostgresTest {
    private static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");
    private static final List<String> TABLES = List.of("finance_report_line_confirmations", "finance_asset_recognition_reversals");
    private static final UUID REQUEST = UUID.randomUUID();
    private static JdbcTemplate db;
    private static UUID reviewer;
    private static String rowsBefore;
    private static String rowsAfter;
    private static String auditBefore;
    private static String auditAfter;
    private static String historyBefore;
    private static String historyAfter;
    private static String guardsBefore;
    private static String guardsAfter;
    private static Set<Long> legacyAuditTriggerIds;

    @BeforeAll
    static void migrateExistingEvidence() {
        DB.start();
        TestFlyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").target("974").load().migrate();
        db = new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        UUID maker = actor("maker");
        reviewer = actor("reviewer");
        UUID voucher = UUID.randomUUID();
        db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status) VALUES(?,?,'2026-10',?,'MANUAL','MANUAL',1)",
                voucher, "AUDIT-POLICY-" + voucher, LocalDate.of(2026, 10, 31));
        db.update("INSERT INTO finance_report_line_confirmations(line_key,confirmed_zero,updated_by) VALUES('BS_2',false,?)", maker);
        // Synthetic retained evidence tests migration/audit behavior; the actual recognition lifecycle has separate service tests.
        db.update("""
                INSERT INTO finance_asset_recognition_reversals
                    (id,object_type,object_id,original_voucher_id,status,reason,requested_by)
                VALUES (?,'FIXED_ASSET',?,?,'SUBMITTED','审计策略升级前的申请',?)
                """, REQUEST, UUID.randomUUID(), voucher, maker);
        assertThat(db.queryForObject("""
                SELECT count(*) FROM pg_trigger WHERE tgrelid IN
                    ('finance_report_line_confirmations'::regclass,'finance_asset_recognition_reversals'::regclass)
                    AND tgfoid='public.fn_audit()'::regprocedure AND tgtype=29 AND tgnargs=0
                """, Integer.class)).isEqualTo(2);
        legacyAuditTriggerIds = Set.copyOf(db.queryForList("""
                SELECT oid::bigint FROM pg_trigger WHERE tgrelid IN
                    ('finance_report_line_confirmations'::regclass,'finance_asset_recognition_reversals'::regclass)
                    AND tgfoid='public.fn_audit()'::regprocedure
                """, Long.class));
        rowsBefore = businessRows();
        auditBefore = auditRows();
        historyBefore = history();
        guardsBefore = guards();
        var migrated = TestFlyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").target("975").load().migrate();
        assertThat(migrated.migrationsExecuted).isEqualTo(1);
        rowsAfter = businessRows();
        auditAfter = auditRows();
        historyAfter = history();
        guardsAfter = guards();
    }

    @AfterAll
    static void stop() { DB.stop(); }

    @Test
    void forwardRegistrationPreservesRowsHistoricalAuditAndBusinessGuards() {
        assertThat(rowsAfter).isEqualTo(rowsBefore);
        assertThat(auditAfter).isEqualTo(auditBefore);
        assertThat(historyAfter).isEqualTo(historyBefore);
        assertThat(guardsAfter).isEqualTo(guardsBefore).contains("trg_guard_asset_recognition_reversal");
        assertThat(db.queryForObject("SELECT max(version::integer) FROM flyway_schema_history WHERE success", Integer.class)).isEqualTo(975);
        assertThat(db.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE NOT success", Integer.class)).isZero();
    }

    @Test
    void bothTablesUseOnlyTheSharedFullPolicyAndEmitOneChangedFieldAudit() {
        for (String table : TABLES) {
            List<Map<String, Object>> triggers = db.queryForList("""
                    SELECT oid::bigint AS id,tgtype::integer AS type,tgenabled::text AS enabled,
                           tgnargs::integer AS args,encode(tgargs,'hex') AS arguments,pg_get_triggerdef(oid) AS definition
                    FROM pg_trigger WHERE tgrelid=CAST(? AS regclass) AND tgfoid='public.fn_audit()'::regprocedure
                    ORDER BY tgtype
                    """, table);
            assertThat(triggers).hasSize(2);
            assertThat(triggers).extracting(t -> t.get("type")).containsExactly(13, 17);
            assertThat(triggers).allSatisfy(t -> {
                assertThat(legacyAuditTriggerIds).doesNotContain(((Number) t.get("id")).longValue());
                assertThat(t.get("enabled")).isEqualTo("A");
                assertThat(t.get("args")).isEqualTo(2);
                assertThat(t.get("arguments")).isEqualTo("646174615f6368616e676500706c61696e00");
            });
            assertThat(triggers.get(1).get("definition").toString()).contains("IS DISTINCT FROM");
        }
        long before = audits("finance_report_line_confirmations");
        db.update("UPDATE finance_report_line_confirmations SET confirmed_zero=true,updated_at=now() WHERE line_key='BS_2'");
        assertThat(audits("finance_report_line_confirmations")).isEqualTo(before + 1);
        assertThat(db.queryForObject("""
                SELECT event_category || '|' || action || '|' || ("after"->>'confirmed_zero')
                FROM audit_log WHERE target_type='finance_report_line_confirmations' AND action='update'
                ORDER BY id DESC LIMIT 1
                """, String.class)).isEqualTo("data_change|update|true");
        db.update("UPDATE finance_report_line_confirmations SET updated_at=now() WHERE line_key='BS_2'");
        assertThat(audits("finance_report_line_confirmations")).isEqualTo(before + 1);
    }

    @Test
    void reversalApprovalStillAuditsOnceAndItsImmutableEvidenceGuardRemainsActive() {
        long before = audits("finance_asset_recognition_reversals", REQUEST.toString());
        db.update("UPDATE finance_asset_recognition_reversals SET status='APPROVED',approved_by=?,approved_at=now() WHERE id=?", reviewer, REQUEST);
        assertThat(audits("finance_asset_recognition_reversals", REQUEST.toString())).isEqualTo(before + 1);
        assertThat(db.queryForObject("""
                SELECT event_category || '|' || action || '|' || ("before"->>'status') || '|' || ("after"->>'status')
                FROM audit_log WHERE target_type='finance_asset_recognition_reversals' AND target_id=? AND action='update'
                ORDER BY id DESC LIMIT 1
                """, String.class, REQUEST.toString())).isEqualTo("data_change|update|SUBMITTED|APPROVED");
        var failure = assertThrows(org.springframework.dao.DataAccessException.class,
                () -> db.update("UPDATE finance_asset_recognition_reversals SET reason='篡改历史理由' WHERE id=?", REQUEST));
        assertThat(failure.getMostSpecificCause()).isInstanceOf(java.sql.SQLException.class);
        assertThat(((java.sql.SQLException) failure.getMostSpecificCause()).getSQLState()).isEqualTo("55000");
        assertThat(audits("finance_asset_recognition_reversals", REQUEST.toString())).isEqualTo(before + 1);
    }

    private static UUID actor(String label) {
        UUID employee = UUID.randomUUID(), user = UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),DATE '2026-01-01','active','regular')
                """, employee, "AP-" + employee, com.uten.imp.support.SyntheticEmployeeIdentity.name(label, employee));
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status) VALUES(?,?,?,'test-not-used','active')",
                user, employee, "audit-policy-" + user);
        return user;
    }

    private static long audits(String table) {
        return db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type=?", Long.class, table);
    }

    private static long audits(String table, String id) {
        return db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type=? AND target_id=?", Long.class, table, id);
    }

    private static String businessRows() {
        return db.queryForObject("""
                SELECT json_build_object('confirmations',(SELECT json_agg(c ORDER BY line_key) FROM finance_report_line_confirmations c),
                    'reversals',(SELECT json_agg(r ORDER BY id) FROM finance_asset_recognition_reversals r))::text
                """, String.class);
    }

    private static String auditRows() {
        return db.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(a)::text,'' ORDER BY id,created_at),'')) FROM audit_log a", String.class);
    }

    private static String history() {
        return db.queryForObject("SELECT md5(string_agg(to_jsonb(h)::text,'' ORDER BY installed_rank)) FROM flyway_schema_history h WHERE version::integer<=974", String.class);
    }

    private static String guards() {
        return db.queryForObject("""
                SELECT jsonb_agg(jsonb_build_array(tgrelid::regclass::text,tgname,pg_get_triggerdef(oid),tgenabled)
                    ORDER BY tgrelid,tgname)::text FROM pg_trigger
                WHERE tgrelid IN ('finance_report_line_confirmations'::regclass,'finance_asset_recognition_reversals'::regclass)
                    AND NOT tgisinternal AND tgfoid<>'public.fn_audit()'::regprocedure
                """, String.class);
    }
}
