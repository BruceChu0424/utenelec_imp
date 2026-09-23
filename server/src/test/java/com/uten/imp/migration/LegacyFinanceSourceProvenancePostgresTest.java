package com.uten.imp.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.support.LegacyFinanceImportFixture;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Source evidence is a database capability, not an app supplied legacy flag. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyFinanceSourceProvenancePostgresTest {
    static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    static final String PASSWORD=UUID.randomUUID().toString();
    static JdbcTemplate admin;

    @BeforeAll static void start() {
        PG.start();
        admin=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        admin.execute("CREATE ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '"+PASSWORD+"'; "
                +"CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '"+PASSWORD+"'");
        Flyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).load().migrate();
        LegacyFinanceImportFixture.seed(admin);
        admin.update("""
                INSERT INTO users(employee_id,login_account,password_hash,status)
                SELECT id,'synthetic-finance-reviewer','test-only-unused-password','active'
                FROM employees WHERE legacy_id=900701
                """);
        // Model direct runtime DML and a non-owner migration login, never role membership.
        admin.execute("GRANT USAGE ON SCHEMA public TO uten,uten_migrator; "
                +"GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten,uten_migrator; "
                +"GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO uten,uten_migrator; "
                +"REVOKE INSERT,UPDATE,DELETE ON legacy_finance_import_sources FROM uten; "
                +"REVOKE ALL ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC,uten,uten_migrator");
    }
    @AfterAll static void stop(){PG.stop();}

    @Test void originalCashAndProvenanceCannotBeChangedBorrowedOrRebound() throws Exception {
        try(Tx tx=tx()) {
            UUID run=LegacyFinanceImportFixture.context(tx.db);
            UUID id=importRow(tx.db,run,"RECEIPT",source("m_get.csv"));
            for(String assignment:new String[]{"amount_local=9","legacy_id=999","legacy_import_run_id=NULL",
                    "receipt_kind='CUSTOMER_PREPAYMENT'","status=0","is_closed=true"}) {
                rejected(tx,()->tx.db.update("UPDATE finance_receipts SET "+assignment+" WHERE id=?",id));
            }
            rejected(tx,()->tx.db.update("DELETE FROM finance_receipts WHERE id=?",id));
            rejected(tx,()->tx.db.update("UPDATE legacy_finance_import_sources SET initial_state='{}' WHERE target_id=?",id));
            rejected(tx,()->tx.db.update("DELETE FROM legacy_finance_import_sources WHERE target_id=?",id));
            rejected(tx,()->tx.db.update("INSERT INTO finance_receipt_lines(id,receipt_id,line_no,amount_original) VALUES(?,?,1,1)",UUID.randomUUID(),id));
            rejected(tx,()->tx.db.update("INSERT INTO finance_receipts(id,bill_no,bill_date,legacy_id,legacy_import_run_id,receipt_kind) VALUES(?,'forged','2025-02-02',906002,?,'LEGACY_UNCLASSIFIED')",UUID.randomUUID(),run));
            assertEquals("LEGACY_UNCLASSIFIED",tx.db.queryForObject("SELECT receipt_kind FROM finance_receipts WHERE id=?",String.class,id));
        }
    }

    @Test void candidateSourceShapeAndExecutionTransactionAreRequired() throws Exception {
        try(Tx tx=tx()) {
            UUID run=LegacyFinanceImportFixture.context(tx.db);
            ObjectNode source=source("m_get.csv");
            source.put("legacy_id",990003);source.put("bill_no","SYN-CANDIDATE-TX");
            ObjectNode incomplete=source.deepCopy();incomplete.remove("remark");
            rejected(tx,()->importRow(tx.db,run,"RECEIPT",incomplete));
            rejected(tx,()->importRow(tx.db,run,"UNREGISTERED",source));
            for(String setting:new String[]{"uten.bootstrap_run_id","uten.bootstrap_mapping_version",
                    "uten.bootstrap_repository_commit","uten.bootstrap_manifest_sha"}) {
                rejected(tx,()->{tx.db.queryForObject("SELECT set_config(?,'forged',true)",String.class,setting);importRow(tx.db,run,"RECEIPT",source);});
            }
            for(String change:new String[]{"status='SUCCESS'","target='--finance'","migration_mode='DRY_RUN'",
                    "reconciliation_summary=reconciliation_summary||'{\"targetDatabase\":\"another_database\"}'"}) {
                rejected(tx,()->{tx.db.update("UPDATE legacy_migration_runs SET "+change+" WHERE run_id=?",run);importRow(tx.db,run,"RECEIPT",source);});
            }
            UUID id=importRow(tx.db,run,"RECEIPT",source);
            String row=tx.db.queryForObject("SELECT to_jsonb(r)::text FROM finance_receipts r WHERE id=?",String.class,id);
            tx.connection.commit();
            rejected(tx,()->tx.db.queryForObject("SELECT fn_assert_legacy_finance_import('finance_receipts',?::jsonb)",Object.class,row));
        }
    }

    @Test void realRuntimeWithForgedSettingsAndTemporaryCatalogsCannotMintProof() throws Exception {
        // Deliberately grant the private entry to simulate a mistaken blanket function grant.
        admin.execute("GRANT EXECUTE ON FUNCTION fn_import_legacy_finance_source(uuid,text,jsonb,integer) TO uten");
        try(Tx tx=tx("uten",PASSWORD)) {
            tx.db.execute("CREATE TEMP TABLE pg_roles(rolname name,rolsuper boolean,rolcanlogin boolean); "
                    +"INSERT INTO pg_roles VALUES('uten',true,true)");
            UUID fake=UUID.randomUUID();
            tx.db.queryForObject("SELECT set_config('uten.bootstrap_run_id',?,true)",String.class,fake.toString());
            tx.db.execute("SELECT pg_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:'||current_database(),0))");
            DataAccessException error=rejected(tx,()->importRow(tx.db,fake,"RECEIPT",uncheckedSource("m_get.csv")));
            assertTrue(error.getMessage().contains("dedicated migration identity"));
        } finally {admin.execute("REVOKE EXECUTE ON FUNCTION fn_import_legacy_finance_source(uuid,text,jsonb,integer) FROM uten");}
    }

    @Test void nonSuperMigrationLoginNeedsOnlyTheExplicitClusterIdentityReadPrivilege() throws Exception {
        assertFalse(admin.queryForObject("SELECT pg_has_role('uten_migrator',?,'MEMBER')",Boolean.class,PG.getUsername()));
        try(Tx tx=tx("uten_migrator",PASSWORD)) {
            assertFalse(tx.db.queryForObject("SELECT rolsuper FROM pg_roles WHERE rolname=current_user",Boolean.class));
            rejected(tx,()->tx.db.queryForObject("SELECT system_identifier FROM pg_catalog.pg_control_system()",String.class));
        }
        admin.execute("GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");
        try(Tx tx=tx("uten_migrator",PASSWORD)) {
            UUID run=LegacyFinanceImportFixture.context(tx.db);
            ObjectNode s=source("m_get.csv");s.put("legacy_id",990002);s.put("bill_no","SYN-NON-SUPER");
            UUID id=importRow(tx.db,run,"RECEIPT",s);
            assertEquals("8",tx.db.queryForObject("SELECT trim_scale(amount_local)::text FROM finance_receipts WHERE id=?",String.class,id));
            assertFalse(tx.db.queryForObject("SELECT has_schema_privilege(current_user,'public','CREATE')",Boolean.class));
        } finally {admin.execute("REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM uten_migrator");}
    }

    @Test void openingsPreserveZeroNegativeAndUnknownCurrencyWithoutCreatingCashAuthority() throws Exception {
        try(Tx tx=tx()) {
            UUID run=LegacyFinanceImportFixture.context(tx.db);
            UUID ar=importRow(tx.db,run,"AR_OPENING",source("m_in.csv"));
            assertEquals("12",tx.db.queryForObject("SELECT trim_scale(amount_balance)::text FROM ar_ap_ledger WHERE id=?",String.class,ar));
            assertEquals("8",tx.db.queryForObject("SELECT trim_scale((initial_state->>'amount_settled')::numeric)::text FROM legacy_finance_import_sources WHERE target_id=?",String.class,ar));
            assertFalse(tx.db.queryForObject("SELECT fn_is_verified_legacy_opening_ar(?)",Boolean.class,ar));
            tx.db.update("UPDATE legacy_migration_runs SET status='SUCCESS' WHERE run_id=?",run);
            assertTrue(tx.db.queryForObject("SELECT fn_is_verified_legacy_opening_ar(?)",Boolean.class,ar));
            rejected(tx,()->tx.db.update("UPDATE ar_ap_ledger SET amount_original=99 WHERE id=?",ar));
            tx.db.update("UPDATE legacy_migration_runs SET status='RUNNING' WHERE run_id=?",run);
            ObjectNode ap=source("m_out.csv");ap.put("legacy_id",991003);ap.put("total",-8);ap.put("settled",0);ap.put("balance",-8);
            UUID negative=importRow(tx.db,run,"AP_OPENING",ap);
            assertEquals("LEGACY_UNVERIFIED",tx.db.queryForObject("SELECT open_item_kind FROM ar_ap_ledger WHERE id=?",String.class,negative));
            ObjectNode unknown=source("m_out.csv");unknown.put("legacy_id",991004);unknown.put("bill_no","SYN-UNKNOWN-FX");unknown.put("exchange_rate",0);
            UUID foreign=importRow(tx.db,run,"AP_OPENING",unknown);
            assertNull(tx.db.queryForObject("SELECT amount_original FROM ar_ap_ledger WHERE id=?",Object.class,foreign));
            assertEquals("0",tx.db.queryForObject("SELECT trim_scale(exchange_rate)::text FROM ar_ap_ledger WHERE id=?",String.class,foreign));
            assertEquals(0L,tx.db.queryForObject("SELECT count(*) FROM finance_receipts WHERE legacy_import_run_id=?",Long.class,run));
        }
    }

    @Test void financialProofAuditOmitsTheOriginalMonetaryPayload() throws Exception {
        try(Tx tx=tx()) {
            UUID run=LegacyFinanceImportFixture.context(tx.db);
            ObjectNode s=source("m_get.csv");s.put("legacy_id",992002);s.put("bill_no","SYN-AUDIT-CANARY");
            UUID id=importRow(tx.db,run,"RECEIPT",s);
            assertTrue(tx.db.queryForObject("SELECT jsonb_exists(initial_state,'amount_local') FROM legacy_finance_import_sources WHERE target_id=?",Boolean.class,id));
            assertFalse(tx.db.queryForObject("SELECT jsonb_exists(fn_audit_redact_row('legacy_finance_import_sources',to_jsonb(p)),'initial_state') FROM legacy_finance_import_sources p WHERE target_id=?",Boolean.class,id));
            // ADR-105: 老系统导入来源证明是只读遗留数据(NONE), 由导入对账核对, 不再逐行复制进审计;
            // 金额原始载荷因此根本不会进入审计。
            assertEquals(0L,tx.db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='legacy_finance_import_sources'::regclass AND tgfoid='public.fn_audit()'::regprocedure",Long.class));
            assertEquals(0L,tx.db.queryForObject("""
                    SELECT count(*) FROM audit_log audit JOIN legacy_finance_import_sources proof
                      ON audit.target_id=proof.id::text AND audit.target_type='legacy_finance_import_sources'
                    WHERE proof.target_id=?
                    """,Long.class,id));
        }
    }

    @Test void onlyActualNativeOffsetEventsAdvanceHistoricalTargetAndCanBeReversed() throws Exception {
        try(Tx tx=tx()) {
            UUID run=LegacyFinanceImportFixture.context(tx.db);
            ObjectNode s=source("m_out.csv");s.put("legacy_id",993003);s.put("bill_no","SYN-OFFSET-TARGET");
            s.put("total",25);s.put("settled",8);s.put("balance",17);
            UUID target=importRow(tx.db,run,"AP_OPENING",s);
            tx.db.update("UPDATE legacy_migration_runs SET status='SUCCESS' WHERE run_id=?",run);
            UUID supplier=tx.db.queryForObject("SELECT supplier_id FROM ar_ap_ledger WHERE id=?",UUID.class,target);
            UUID currency=tx.db.queryForObject("SELECT currency_id FROM ar_ap_ledger WHERE id=?",UUID.class,target);
            UUID credit=UUID.randomUUID(),event=UUID.randomUUID();
            tx.db.update("""
                    INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,
                        supplier_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_settled,
                        amount_balance,amount_received_original,amount_received_local,amount_write_off_original,
                        amount_write_off_local,amount_balance_original,status)
                    VALUES(?,'AP','PURCHASE_RETURN',gen_random_uuid(),'SYN-CREDIT','SYN-CREDIT','2025-02-02',?,?,1,
                        -4,-4,0,-4,0,0,0,0,-4,1)
                    """,credit,supplier,currency);
            rejected(tx,()->{
                tx.db.update("UPDATE ar_ap_ledger SET amount_offset_original=4,amount_offset_local=4,amount_balance=13,amount_balance_original=13 WHERE id=?",target);
                tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE");
            });
            tx.db.update("UPDATE ar_ap_ledger SET amount_offset_original=4,amount_offset_local=4,amount_balance=13,amount_balance_original=13 WHERE id=?",target);
            tx.db.update("UPDATE ar_ap_ledger SET amount_offset_original=-4,amount_offset_local=-4,amount_balance=0,amount_balance_original=0,is_settled=true,settled_date='2025-02-02' WHERE id=?",credit);
            tx.db.update("""
                    INSERT INTO supplier_open_item_offsets(id,supplier_id,currency_id,source_ledger_id,target_ledger_id,
                        offset_batch_id,line_sequence,amount_original,source_amount_local,target_amount_local,
                        source_balance_before_original,source_balance_after_original,target_balance_before_original,
                        target_balance_after_original,effective_date,status,reason,source_rate,target_rate)
                    VALUES(?,?,?,?,?,gen_random_uuid(),1,4,4,4,-4,0,17,13,'2025-02-02','APPLIED','Synthetic native credit',1,1)
                    """,event,supplier,currency,credit,target);
            tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED");
            assertEquals("13",tx.db.queryForObject("SELECT trim_scale(amount_balance)::text FROM ar_ap_ledger WHERE id=?",String.class,target));
            rejected(tx,()->tx.db.update("UPDATE supplier_open_item_offsets SET amount_original=3 WHERE id=?",event));
            rejected(tx,()->tx.db.update("DELETE FROM supplier_open_item_offsets WHERE id=?",event));
            tx.db.update("UPDATE ar_ap_ledger SET amount_offset_original=0,amount_offset_local=0,amount_balance=17,amount_balance_original=17 WHERE id=?",target);
            tx.db.update("UPDATE ar_ap_ledger SET amount_offset_original=0,amount_offset_local=0,amount_balance=-4,amount_balance_original=-4,is_settled=false,settled_date=NULL WHERE id=?",credit);
            tx.db.update("""
                    UPDATE supplier_open_item_offsets SET status='REVERSED',row_version=1,reversed_at=now(),
                        reversed_by=(SELECT id FROM users ORDER BY id LIMIT 1),reverse_reason='Synthetic reversal' WHERE id=?
                    """,event);
            tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE");
            assertEquals("17",tx.db.queryForObject("SELECT trim_scale(amount_balance)::text FROM ar_ap_ledger WHERE id=?",String.class,target));
            rejected(tx,()->tx.db.update("UPDATE supplier_open_item_offsets SET status='APPLIED',row_version=2,reversed_by=NULL,reversed_at=NULL WHERE id=?",event));
        }
    }

    @Test void temporaryFinanceRelationsCannotHideRealConservationOrOffsetIdentityFailures() throws Exception {
        try(Tx tx=tx()) {
            LegacyFinanceImportFixture.context(tx.db);
            UUID receipt=UUID.randomUUID(),line=UUID.randomUUID();
            tx.db.update("""
                    INSERT INTO public.finance_receipts(id,bill_no,bill_date,client_id,currency_id,status,receipt_kind,
                        amount_original,amount_local,settlement_authority_version)
                    SELECT ?,'SYN-NATIVE-GUARD','2025-02-02',client.id,currency.id,0,'AR_SETTLEMENT',1,1,0
                    FROM public.clients client CROSS JOIN public.currencies currency
                    WHERE client.legacy_id=900501 AND currency.legacy_id=1
                    """,receipt);
            tx.db.update("""
                    INSERT INTO public.finance_receipt_lines(id,receipt_id,bill_no,bill_date,amount_original,amount_local,
                        applied_amount_local,write_off_amount,client_id,currency_id)
                    SELECT ?,id,bill_no,bill_date,1,1,1,0,client_id,currency_id FROM public.finance_receipts WHERE id=?
                    """,line,receipt);
            tx.db.update("UPDATE public.finance_receipts SET status=1 WHERE id=?",receipt);
            tx.db.execute("CREATE TEMP TABLE finance_receipts(fake text); CREATE TEMP TABLE finance_receipt_lines(fake text); "
                    +"CREATE TEMP TABLE ar_ap_ledger(fake text); CREATE TEMP TABLE customer_open_item_offset_batches(fake text)");
            tx.db.queryForObject("SELECT public.fn_assert_receipt_source_conservation(?)",Object.class,UUID.randomUUID());
            DataAccessException realFailure=rejected(tx,()->tx.db.queryForObject("SELECT public.fn_assert_receipt_source_conservation(?)",Object.class,line));
            assertTrue(realFailure.getMessage().contains("do not conserve the approved line snapshots"),realFailure::getMessage);
            // The independent existing actual-book source trigger runs first;
            // isolate this guard's batch identity relation from that older reader.
            tx.db.execute("DROP TABLE pg_temp.finance_receipts,pg_temp.finance_receipt_lines,pg_temp.ar_ap_ledger");
            DataAccessException identityFailure=rejected(tx,()->tx.db.update("""
                    INSERT INTO public.customer_open_item_offsets(id,offset_batch_id,source_ledger_id,target_ledger_id,
                        target_source_ref_id,sales_order_id,client_id,currency_id,effective_date)
                    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
                        gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),'2025-02-02')
                    """));
            assertTrue(identityFailure.getMostSpecificCause().getMessage().contains("crosses active client, currency, order, rate, or AR identities"),()->identityFailure.getMostSpecificCause().getMessage());
        }
    }

    static ObjectNode source(String file) throws Exception{return (ObjectNode)new ObjectMapper().readTree(LegacyFinanceImportFixture.source(file));}
    static ObjectNode uncheckedSource(String file){try{return source(file);}catch(Exception e){throw new IllegalStateException(e);}}
    static UUID importRow(JdbcTemplate db,UUID run,String kind,ObjectNode source){return db.queryForObject("SELECT fn_import_legacy_finance_source(?,?,?::jsonb)",UUID.class,run,kind,source.toString());}
    static Tx tx() throws Exception{return tx(PG.getUsername(),PG.getPassword());}
    static Tx tx(String user,String password) throws Exception {Connection c=DriverManager.getConnection(PG.getJdbcUrl(),user,password);c.setAutoCommit(false);return new Tx(c);}
    static final class Tx implements AutoCloseable {
        final Connection connection;final JdbcTemplate db;
        Tx(Connection c){connection=c;db=new JdbcTemplate(new SingleConnectionDataSource(c,true));}
        @Override public void close() throws Exception{connection.rollback();connection.close();}
    }
    static DataAccessException rejected(Tx tx,Runnable action) throws Exception {
        var sp=tx.connection.setSavepoint();
        try{return assertThrows(DataAccessException.class,action::run);}finally{tx.connection.rollback(sp);}
    }
}
