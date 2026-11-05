package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.callback.Callback;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** Real Flyway lifecycle, original resources/checksums and preserved nonempty event/audit history. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ExpensePaymentReversalUpgradePostgresTest {
    private static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("expense_reversal_pre1000").withUsername("upgrade_fixture").withPassword("anonymous-upgrade-only")
            .withCommand("postgres","-c","max_locks_per_transaction=512");
    private static String currentHead;
    @TempDir Path altered;
    @BeforeAll static void baseline(){
        DB.start();flyway(DB.getDatabaseName(),"999.13",true,null).migrate();
        currentHead=java.util.Arrays.stream(flyway(DB.getDatabaseName(),null,true,null).info().all())
                .map(org.flywaydb.core.api.MigrationInfo::getVersion).filter(java.util.Objects::nonNull)
                .max(java.util.Comparator.naturalOrder()).orElseThrow().getVersion();
    }
    @AfterAll static void stop(){DB.stop();}

    @Test void preservedPre1000ReversalFailsOriginallyThenUpgradesThroughTheActualTwoScriptsToCurrentHead()throws Exception {
        String database=cloneDatabase("historical");Snapshot before;
        try(var connection=connection(database)){seed(connection,true);before=snapshot(connection,"999.13");}
        var red=catchThrowable(()->flyway(database,"1000",false,null).migrate());
        assertThat(red).isInstanceOf(FlywayException.class);assertThat(sqlState(red)).isEqualTo("23514");
        try(var connection=connection(database)){assertPreserved(connection,before,"999.13",false);assertThat(head(connection)).isEqualTo("999.13");}
        flyway(database,null,true,null).migrate();
        try(var connection=connection(database)) {
            assertPreserved(connection,before,"999.13",true);assertCurrent(connection);assertOriginalChecksums(connection);
            assertThat(scalar(connection,"SELECT count(*) FROM expense_claim_events WHERE event_type='PAYMENT_REVERSED'")).isEqualTo("1");
            assertNativeTrailAndInvalidKindRejected(connection);
        }
        assertThat(flyway(database,null,true,null).migrate().migrationsExecuted).isZero();
    }

    @ParameterizedTest @ValueSource(strings={"1000","1002"})
    void alreadyAppliedOriginalMigrationHistoryIsNotReexecutedOrRepaired(String installed)throws Exception {
        String database=cloneDatabase("installed_"+installed);
        // No reversal exists yet: this reproduces an installation that legitimately
        // passed the original restrictive CHECK before the forward V1051 repair.
        flyway(database,installed,false,null).migrate();Snapshot before;
        try(var connection=connection(database)){seed(connection,false);before=snapshot(connection,installed);}
        flyway(database,null,true,null).migrate();
        try(var connection=connection(database)) {
            assertPreserved(connection,before,installed,true);assertCurrent(connection);assertOriginalChecksums(connection);
            assertNativeTrailAndInvalidKindRejected(connection);
        }
    }

    @ParameterizedTest @ValueSource(strings={"1000","1002"})
    void laterFailureRollsBackTheRealReplacementDdlEventsAuditAndFlywayHistory(String failedVersion)throws Exception {
        String database=cloneDatabase("rollback_"+failedVersion);
        try(var connection=connection(database)){seed(connection,true);}
        String installed="999.13";
        if(failedVersion.equals("1002")){flyway(database,"1001",true,null).migrate();installed="1001";}
        Snapshot before;String constraintBefore;
        try(var connection=connection(database)){before=snapshot(connection,installed);constraintBefore=constraint(connection);}
        var failure=catchThrowable(()->flyway(database,failedVersion,true,new FailAfterMigration(failedVersion)).migrate());
        assertThat(failure).isInstanceOf(FlywayException.class).hasMessageContaining("expense-compat-rollback-proof");
        try(var connection=connection(database)) {
            assertPreserved(connection,before,installed,failedVersion.equals("1002"));
            assertThat(head(connection)).isEqualTo(installed);assertThat(constraint(connection)).isEqualTo(constraintBefore);
            assertThat(scalar(connection,"SELECT current_setting('uten.compat_expense_event_check',true)")).isIn(null,"");
            assertThat(scalar(connection,failedVersion.equals("1000")
                    ?"SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='expense_claim_events' AND column_name='approval_stage'"
                    :"SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='department_approval_policies'")).isEqualTo("0");
        }
        flyway(database,null,true,null).migrate();
        try(var connection=connection(database)){assertPreserved(connection,before,installed,true);assertCurrent(connection);}
    }

    @ParameterizedTest @ValueSource(strings={"checksum","sha_only"})
    void changedPendingScriptIsRejectedBeforeItsDdlAndNeverRecordedAsTheReviewedMigration(String change)throws Exception {
        String database=cloneDatabase("changed_"+change);Snapshot before;
        try(var connection=connection(database)){seed(connection,true);before=snapshot(connection,"999.13");}
        for(var info:flyway(database,null,true,null).info().all()) {
            if(!info.getScript().endsWith(".sql"))continue;
            try(var input=getClass().getClassLoader().getResourceAsStream("db/migration/"+info.getScript())) {
                assertThat(input).isNotNull();Files.write(altered.resolve(info.getScript()),input.readAllBytes());
            }
        }
        Path changed=altered.resolve(ExpenseEventMigrationCompatibility.plan("1000").script());
        if(change.equals("checksum"))Files.writeString(changed,
                "\n-- unreviewed private negative fixture\n",StandardCharsets.UTF_8,java.nio.file.StandardOpenOption.APPEND);
        else Files.writeString(changed,Files.readString(changed,StandardCharsets.UTF_8).replace("\n","\r\n"),StandardCharsets.UTF_8);
        var configuration=configuration(database,"1000",true,null).locations("filesystem:"+altered);
        assertThatThrownBy(()->configuration.load().migrate()).isInstanceOf(FlywayException.class)
                .hasMessageContaining(change.equals("checksum")?"exact reviewed immutable SQL identity":"reviewed SHA-256");
        try(var connection=connection(database)){assertPreserved(connection,before,"999.13",false);assertThat(head(connection)).isEqualTo("999.13");}
    }

    @Test void emptyDatabaseInstallsToCurrentHeadWithOriginalSqlHistoryAndValidatedEvents()throws Exception {
        String database="expense_fresh_"+UUID.randomUUID().toString().replace("-","");
        try(var connection=connection("postgres")){execute(connection,"CREATE DATABASE \""+database+"\"");}
        flyway(database,null,true,null).migrate();
        try(var connection=connection(database)){assertCurrent(connection);assertOriginalChecksums(connection);assertThat(scalar(connection,"SELECT count(*) FROM expense_claim_events")).isEqualTo("0");}
        flyway(database,null,true,null).validate();
    }

    private record Snapshot(String events,String audit,String history,String triggers) { }
    private static Snapshot snapshot(Connection connection,String through)throws SQLException {
        return new Snapshot(events(connection),scalar(connection,"SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY id),'[]')::text FROM audit_log a WHERE target_type IN('expense_claim_events','expense_claims')"),history(connection,through),triggers(connection));
    }
    private static void assertPreserved(Connection connection,Snapshot before,String through,boolean stageColumns)throws SQLException {
        assertThat(events(connection)).isEqualTo(before.events());
        // Legitimate parent workflow migrations may append a new claim audit.
        // Every audit already present must retain exactly its original bytes.
        assertThat(scalar(connection,"SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY id),'[]')::text FROM audit_log a WHERE id IN(SELECT (value->>'id')::bigint FROM jsonb_array_elements(?::jsonb))",before.audit())).isEqualTo(before.audit());
        assertThat(history(connection,through)).isEqualTo(before.history());assertThat(triggers(connection)).isEqualTo(before.triggers());
        if(stageColumns)assertThat(scalar(connection,"SELECT count(*) FROM expense_claim_events WHERE approval_stage IS NOT NULL OR approval_round IS NOT NULL")).isEqualTo("0");
    }
    private static String events(Connection connection)throws SQLException {
        return scalar(connection,"SELECT COALESCE(jsonb_agg(to_jsonb(e)-ARRAY['approval_stage','approval_round'] ORDER BY id),'[]')::text FROM expense_claim_events e");
    }
    private static void seed(Connection connection,boolean reversal)throws SQLException {
        UUID employee=UUID.randomUUID(),approver=UUID.randomUUID(),claim=UUID.randomUUID();
        String applicantName="匿名申请人-"+employee,approverName="匿名办理人-"+approver;
        for(UUID person:List.of(employee,approver))execute(connection,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN' AND NOT is_deleted),DATE '2026-01-01','active','regular')",person,"UPGRADE-"+person,person.equals(employee)?applicantName:approverName);
        execute(connection,"INSERT INTO expense_claims(id,applicant_id,applicant_name_snapshot,title,total_amount,claim_no,status,approved_by,approved_at) VALUES(?,?,?,'匿名历史付款反审',100,'BX20260923000001','APPROVED',?,TIMESTAMPTZ '2026-09-23 01:00:00+00')",claim,employee,applicantName,approver);
        for(String kind:reversal?List.of("CREATED","APPROVED","PAID","PAYMENT_REVERSED"):List.of("CREATED","APPROVED"))
            execute(connection,"INSERT INTO expense_claim_events(claim_id,event_type,actor_employee_id,actor_name_snapshot,remark,created_at) VALUES(?,?,?,?,'原历史依据保全',TIMESTAMPTZ '2026-09-23 02:00:00+00')",claim,kind,kind.equals("CREATED")?employee:approver,kind.equals("CREATED")?applicantName:approverName);
    }
    private static void assertNativeTrailAndInvalidKindRejected(Connection connection)throws SQLException {
        int before=Integer.parseInt(scalar(connection,"SELECT count(*) FROM expense_claim_events"));
        String auditBefore=scalar(connection,"SELECT count(*) FROM audit_log WHERE target_type='expense_claim_events'");
        execute(connection,"INSERT INTO expense_claim_events(claim_id,event_type,actor_employee_id,actor_name_snapshot) SELECT id,'PAYMENT_REVERSED',approved_by,'匿名后续办理人' FROM expense_claims LIMIT 1");
        assertThat(scalar(connection,"SELECT count(*) FROM expense_claim_events")).isEqualTo(Integer.toString(before+1));
        assertThat(scalar(connection,"SELECT count(*) FROM expense_claim_events WHERE event_type='PAYMENT_REVERSED' AND actor_name_snapshot='匿名后续办理人' AND actor_employee_id IS NOT NULL AND created_at IS NOT NULL AND claim_id IS NOT NULL")).isEqualTo("1");
        // ADR-105's owning NONE/ledger contract keeps this native event trail
        // instead of copying its payload again into the general audit log.
        assertThat(auditBefore).isEqualTo("0");
        assertThat(scalar(connection,"SELECT count(*) FROM audit_log WHERE target_type='expense_claim_events'")).isEqualTo(auditBefore);
        assertThatThrownBy(()->execute(connection,"INSERT INTO expense_claim_events(claim_id,event_type,actor_name_snapshot) SELECT id,'UNKNOWN_EVENT','匿名负例' FROM expense_claims LIMIT 1")).isInstanceOf(SQLException.class).satisfies(error->assertThat(((SQLException)error).getSQLState()).isEqualTo("23514"));
    }
    private static void assertCurrent(Connection connection)throws SQLException {
        assertThat(head(connection)).isEqualTo(currentHead);
        assertThat(constraint(connection)).contains("PAYMENT_REVERSED","STAGE_APPROVED","ABANDONED");
        assertThat(scalar(connection,"SELECT convalidated::text FROM pg_constraint WHERE conrelid='expense_claim_events'::regclass AND conname='expense_claim_events_type_chk'")).isEqualTo("true");
        assertThat(scalar(connection,"SELECT count(*) FROM pg_trigger WHERE tgrelid='expense_claim_events'::regclass AND tgfoid='fn_audit()'::regprocedure")).isEqualTo("0");
        assertThat(scalar(connection,"SELECT count(*) FROM pg_trigger WHERE tgrelid='expense_claim_events'::regclass AND tgname IN('trg_retain_business_record','trg_retain_business_truncate','trg_bind_business_record_parent','trg_guard_business_record_parent') AND tgenabled='A'")).isEqualTo("4");
        assertThat(scalar(connection,"SELECT count(*) FROM pg_trigger WHERE tgrelid='expense_claims'::regclass AND tgfoid='fn_audit()'::regprocedure AND tgenabled='A'")).isNotEqualTo("0");
    }
    private static void assertOriginalChecksums(Connection connection)throws SQLException {
        for(String version:new String[]{"1000","1002"}) {
            var plan=ExpenseEventMigrationCompatibility.plan(version);
            assertThat(scalar(connection,"SELECT checksum::text||':'||type||':'||script||':'||success::text FROM flyway_schema_history WHERE version=?",version))
                    .isEqualTo(plan.checksum()+":SQL:"+plan.script()+":true");
        }
    }
    private static String history(Connection connection,String through)throws SQLException {
        return scalar(connection,"SELECT md5(COALESCE(string_agg(to_jsonb(h)::text,E'\\n' ORDER BY installed_rank),'')) FROM flyway_schema_history h WHERE success AND string_to_array(version,'.')::int[]<=string_to_array(?,'.')::int[]",through);
    }
    private static String triggers(Connection connection)throws SQLException {
        return scalar(connection,"SELECT COALESCE(string_agg(pg_get_triggerdef(oid)||':'||tgenabled::text,E'\\n' ORDER BY tgrelid::regclass::text,tgname),'') FROM pg_trigger WHERE NOT tgisinternal AND (tgrelid='expense_claim_events'::regclass OR tgrelid='expense_claims'::regclass AND tgfoid='fn_audit()'::regprocedure)");
    }
    private static String constraint(Connection connection)throws SQLException{return scalar(connection,"SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='expense_claim_events'::regclass AND conname='expense_claim_events_type_chk'");}
    private static String head(Connection connection)throws SQLException{return scalar(connection,"SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1");}
    private static Flyway flyway(String database,String target,boolean compatible,Callback extra){return configuration(database,target,compatible,extra).load();}
    private static org.flywaydb.core.api.configuration.FluentConfiguration configuration(String database,String target,boolean compatible,Callback extra) {
        var config=com.uten.imp.testsupport.TestFlyway.configure().dataSource(url(database),DB.getUsername(),DB.getPassword()).locations("classpath:db/migration").cleanDisabled(true);
        if(target!=null)config.target(target);var callbacks=new ArrayList<Callback>();
        if(compatible)callbacks.add(new AppliedMigrationCompatibilityCallback());else callbacks.add(new WithoutExpenseCompatibility());
        callbacks.add(new AuditFreshStartGuardCallback());if(extra!=null)callbacks.add(extra);return config.callbacks(callbacks.toArray(Callback[]::new));
    }
    private static final class WithoutExpenseCompatibility implements Callback {
        private final AppliedMigrationCompatibilityCallback delegate=new AppliedMigrationCompatibilityCallback();
        public boolean supports(Event event,Context context){return !ExpenseEventMigrationCompatibility.supports(event,context)&&delegate.supports(event,context);}
        public boolean canHandleInTransaction(Event event,Context context){return delegate.canHandleInTransaction(event,context);}
        public void handle(Event event,Context context){delegate.handle(event,context);}
        public String getCallbackName(){return "original-compatibility-without-expense-fix";}
    }
    private record FailAfterMigration(String version) implements Callback {
        public boolean supports(Event event,Context context){return event==Event.AFTER_EACH_MIGRATE&&context.getMigrationInfo()!=null&&context.getMigrationInfo().getVersion().getVersion().equals(version);}
        public boolean canHandleInTransaction(Event event,Context context){return true;}
        public void handle(Event event,Context context){throw new FlywayException("expense-compat-rollback-proof");}
        public String getCallbackName(){return "zz-expense-compat-rollback-proof";}
    }
    private static String cloneDatabase(String label)throws SQLException {
        String database="expense_"+label+"_"+UUID.randomUUID().toString().replace("-","");
        try(var connection=connection("postgres")){execute(connection,"CREATE DATABASE \""+database+"\" TEMPLATE \""+DB.getDatabaseName()+"\"");}return database;
    }
    private static String url(String database){return DB.getJdbcUrl().replace("/"+DB.getDatabaseName(),"/"+database);}
    private static Connection connection(String database)throws SQLException{return DriverManager.getConnection(url(database),DB.getUsername(),DB.getPassword());}
    private static void execute(Connection connection,String sql,Object...args)throws SQLException {
        try(var statement=connection.prepareStatement(sql)){for(int index=0;index<args.length;index++)statement.setObject(index+1,args[index]);statement.execute();}
    }
    private static String scalar(Connection connection,String sql,Object...args)throws SQLException {
        try(var statement=connection.prepareStatement(sql)){for(int index=0;index<args.length;index++)statement.setObject(index+1,args[index]);try(var rows=statement.executeQuery()){assertThat(rows.next()).isTrue();return rows.getString(1);}}
    }
    private static String sqlState(Throwable failure){for(Throwable next=failure;next!=null;next=next.getCause())if(next instanceof SQLException sql)return sql.getSQLState();return null;}
}
