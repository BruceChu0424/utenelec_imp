package com.uten.imp.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.support.LegacyFinanceImportFixture;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.UUID;
import java.util.concurrent.Executors;

import static org.junit.jupiter.api.Assertions.*;

/** Synthetic only: full Flyway, original V626 entry, every native guard enabled. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyAccountFlowBatchMonthlyPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate admin;

    @BeforeAll static void start() {
        PG.start();
        admin=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        admin.execute("CREATE ROLE uten LOGIN NOSUPERUSER; CREATE ROLE uten_migrator LOGIN NOSUPERUSER");
        TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).load().migrate();
        LegacyFinanceImportFixture.seed(admin);
        admin.execute("GRANT USAGE ON SCHEMA public TO uten; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten;"
                +"GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO uten; REVOKE ALL ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC,uten");
    }
    @AfterAll static void stop(){PG.stop();}

    static final class Tx implements AutoCloseable {
        final Connection connection; final JdbcTemplate db; final UUID run;
        Tx() throws Exception {
            connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
            connection.setAutoCommit(false);db=new JdbcTemplate(new SingleConnectionDataSource(connection,true));
            run=LegacyFinanceImportFixture.context(db);
            db.update("UPDATE legacy_migration_runs SET mapping_version='bootstrap-v19' WHERE run_id=?",run);
            db.execute("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v19'");
        }
        void flow(int id,String incoming) throws Exception {
            ObjectNode source=new ObjectMapper().createObjectNode();
            db.queryForList("SELECT unnest(source_keys) FROM fn_legacy_finance_kind('ACCOUNT_FLOW')",String.class).forEach(source::putNull);
            source.put("legacy_id",id);source.put("bill_no","SYNTHETIC-FLOW-"+id);source.put("acc_id",906001);
            source.put("bill_date","2025-01-02T00:00:00Z");source.put("b_style",20);source.put("bill_id",id);
            source.put("in_total",new BigDecimal(incoming));source.put("out_total",BigDecimal.ZERO);
            db.queryForObject("SELECT fn_import_legacy_finance_source(?,'ACCOUNT_FLOW',?::jsonb)",UUID.class,run,source.toString());
        }
        void rebuild(){db.execute("SELECT fn_rebuild_account_flow_monthly_summaries(NULL);SELECT fn_assert_account_flow_monthly_integrity(NULL)");}
        void success(){db.update("UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='PASSED',exit_code=0,finished_at=now() WHERE run_id=?",run);}
        void flush(){db.execute("SET CONSTRAINTS ALL IMMEDIATE");}
        @Override public void close() throws Exception {connection.rollback();connection.close();}
    }

    @Test void signedNegativePrefixRebuildsOnlyTheFinalNativeMonth() throws Exception {
        try(Tx tx=new Tx()) {
            tx.flow(990001,"-2");tx.flow(990002,"5");
            assertEquals(0,tx.db.queryForObject("SELECT count(*) FROM account_flow_monthly_summaries WHERE month_start='2025-01-01'",Integer.class));
            tx.rebuild();tx.success();tx.flush();
            assertEquals(0,new BigDecimal("3").compareTo(tx.db.queryForObject("SELECT in_amount FROM account_flow_monthly_summaries WHERE month_start='2025-01-01'",BigDecimal.class)));
            assertEquals(1,tx.db.queryForObject("SELECT count(*) FROM legacy_migration_runs WHERE legacy_account_flow_import_txid=txid_current()",Integer.class));
        }
    }

    @Test void missingRebuildAndLateCacheDamageBothFailActualCommit() throws Exception {
        for(boolean damage:new boolean[]{false,true})try(Tx tx=new Tx()) {
            tx.flow(990010,"5");
            if(damage){tx.rebuild();tx.db.execute("UPDATE account_flow_monthly_summaries SET in_amount=in_amount+1");}
            tx.success();assertThrows(java.sql.SQLException.class,tx.connection::commit);
        }
    }

    @Test void noSuccessOrAnActuallyNegativeFinalMonthCannotComplete() throws Exception {
        try(Tx tx=new Tx()){tx.flow(990020,"5");tx.rebuild();assertThrows(java.sql.SQLException.class,tx.connection::commit);}
        try(Tx tx=new Tx()){tx.flow(990021,"-2");assertThrows(DataAccessException.class,tx::rebuild);}
    }

    @Test void earlyFlushDoesNotPermitUpdateDeleteTruncateOrStatusDowngrade() throws Exception {
        for(String change:new String[]{"UPDATE account_flow_monthly_summaries SET in_amount=in_amount+1",
                "DELETE FROM account_flow_monthly_summaries","TRUNCATE account_flow_monthly_summaries",
                "UPDATE legacy_migration_runs SET status='RUNNING' WHERE legacy_account_flow_import_txid=txid_current()"})try(Tx tx=new Tx()) {
            tx.flow(990030,"5");tx.rebuild();tx.success();tx.flush();
            tx.db.execute("SELECT set_config('uten.bootstrap_run_id','',true)");
            assertThrows(DataAccessException.class,()->tx.db.execute(change));
        }
    }

    @Test void exactCoordinatorFinalizationAndAuditRunAfterPrivateSuccess() throws Exception {
        try(Tx tx=new Tx()) {
            tx.flow(990040,"5");tx.rebuild();tx.success();
            // The coordinator emits psql; these two modules contain ordinary
            // SQL except audit's single run-id parameter, bound here directly.
            tx.db.execute(Files.readString(Path.of("legacy_migration/migrate_finalize_checks.sql")));
            tx.db.execute(Files.readString(Path.of("legacy_migration/migrate_audit_summary.sql"))
                    .replace(":'run_id'","'"+tx.run+"'"));
            assertEquals(1,tx.db.queryForObject("SELECT count(*) FROM audit_log WHERE target_id=? AND action='legacy_migration_run'",Integer.class,tx.run.toString()));
        }
    }

    @Test void originAndProofCannotBeCleared() throws Exception {
        try(Tx tx=new Tx()) {
            tx.flow(990050,"5");
            var save=tx.connection.setSavepoint();
            assertThrows(DataAccessException.class,()->tx.db.update("UPDATE legacy_migration_runs SET legacy_account_flow_import_txid=NULL,legacy_account_flow_origin_system_identifier=NULL,legacy_account_flow_origin_database_oid=NULL WHERE run_id=?",tx.run));
            tx.connection.rollback(save);
            assertThrows(DataAccessException.class,()->tx.db.update("UPDATE legacy_finance_import_sources SET target_fields=ARRAY['id'] WHERE run_id=?",tx.run));
        }
    }

    static void modern(Connection connection,String id) {
        new JdbcTemplate(new SingleConnectionDataSource(connection,true)).update("""
                INSERT INTO finance_reconciliations(bill_no,bill_date,source_doc_type,source_doc_id,
                  account_id,account_currency_id,in_amount,out_amount,entry_kind,amount_local)
                SELECT ?,'2025-02-01','BALANCE_ADJUSTMENT',gen_random_uuid(),id,currency_id,1,0,'POSTING',1
                FROM accounts WHERE legacy_id=906001
                """,id);
    }
    @Test void ordinaryRuntimePostingNeedsNoClusterPrivilegeAndConcurrentTotalsStayCorrect() throws Exception {
        // Set role on an authenticated owner connection models actual runtime
        // current_user while keeping Testcontainers' ephemeral random password.
        try(var executor=Executors.newFixedThreadPool(2)) {
            var futures=new java.util.ArrayList<java.util.concurrent.Future<?>>();
            for(int i=0;i<2;i++){final int index=i;futures.add(executor.submit(()->{
                try(Connection c=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())) {
                    c.setAutoCommit(false);c.createStatement().execute("SET LOCAL ROLE uten");modern(c,"SYN-CONCURRENT-"+index);c.commit();
                }catch(Exception error){throw new IllegalStateException(error);}
            }));}
            for(var future:futures)future.get();
        }
        admin.execute("SELECT fn_assert_account_flow_monthly_integrity(NULL)");
        assertEquals(2,admin.queryForObject("SELECT sum(flow_count)::integer FROM account_flow_monthly_summaries WHERE month_start='2025-02-01'",Integer.class));
    }
}
