package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacySubcontractSettlementProvenancePostgresTest {
    static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    static final String FILE="db/migration/V624__legacy_subcontract_settlement_provenance.sql";
    static final String PASSWORD=UUID.randomUUID().toString();
    static JdbcTemplate admin;
    static String sql;
    UUID existing;

    @BeforeAll static void start() throws Exception {
        PG.start(); admin=db(PG.getUsername(),PG.getPassword());
        admin.execute("CREATE ROLE uten LOGIN PASSWORD '"+PASSWORD+"'");
        sql=new ClassPathResource(FILE).getContentAsString(StandardCharsets.UTF_8);
    }
    @AfterAll static void stop(){ PG.stop(); }
    @BeforeEach void fixture() {
        admin.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT USAGE ON SCHEMA public TO uten; CREATE EXTENSION pgcrypto");
        com.uten.imp.support.MigratedProjectionSchema.createTables(admin,"623",
                "legacy_migration_runs","legacy_migration_run_files","suppliers","currencies",
                "subcontract_orders","subcontract_order_items","subcontract_order_cost_items");
        admin.execute("""
            CREATE FUNCTION fn_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$;
            CREATE FUNCTION business_data_reset() RETURNS bigint LANGUAGE plpgsql AS $$
            DECLARE preserved bigint; BEGIN
                PERFORM * FROM (VALUES ('stock_movements', 'CLEAR')) AS policy(name,mode);
                SELECT count(*) INTO preserved FROM public.legacy_subcontract_order_import_sources;
                RETURN preserved;
            END; $$;
            GRANT SELECT,INSERT,UPDATE,DELETE ON subcontract_orders,subcontract_order_items,subcontract_order_cost_items TO uten;
            """);
        // Model an actual pre-V378 row; NOT VALID keeps that existing unknown.
        existing=UUID.randomUUID();
        admin.update("INSERT INTO subcontract_orders(id,bill_no,status) VALUES(?,'old unknown',1)",existing);
        admin.execute("ALTER TABLE subcontract_orders ADD CONSTRAINT subcontract_orders_approved_settlement_chk CHECK(status<>1 OR settlement_method_id IS NOT NULL) NOT VALID");
        String before=admin.queryForObject("SELECT to_jsonb(h)::text FROM subcontract_orders h WHERE id=?",String.class,existing);
        admin.execute(sql);
        assertEquals(before,admin.queryForObject("SELECT (to_jsonb(h)-'legacy_import_run_id')::text FROM subcontract_orders h WHERE id=?",String.class,existing));
    }

    @Test void exactSourceAllowsUnknownWhileOrdinaryApprovedInsertRemainsRejected() throws Exception {
        try(var tx=transaction()) {
            UUID run=context(tx.db);
            UUID id=register(tx.db,run,101);
            insert(tx.db,run,id,101);
            assertNull(tx.db.queryForObject("SELECT settlement_method_id FROM subcontract_orders WHERE id=?",UUID.class,id));
            assertEquals(1,tx.db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?",Integer.class,id));
            rejected(tx,()->tx.db.update("INSERT INTO subcontract_orders(id,bill_no,status) VALUES(?,'online approved',1)",UUID.randomUUID()));
            assertEquals(1L,tx.db.queryForObject("SELECT count(*) FROM legacy_subcontract_order_import_sources",Long.class));
        }
    }

    @Test void forgedRunCandidateLockSourceAndHeaderAreRejected() throws Exception {
        try(var tx=transaction()) {
            UUID run=context(tx.db),id=register(tx.db,run,201);
            rejected(tx,()->insert(tx.db,run,UUID.randomUUID(),201));
            rejected(tx,()->insert(tx.db,UUID.randomUUID(),id,201));
            rejected(tx,()->insert(tx.db,run,id,202));
            rejected(tx,()->tx.db.queryForObject("SELECT fn_register_legacy_subcontract_order_source(?,?::jsonb-'remark')",UUID.class,run,source(202)));
            rejected(tx,()->tx.db.update("INSERT INTO subcontract_orders(id,legacy_import_run_id,legacy_id,bill_no,status) VALUES(?,?,201,'changed',1)",id,run));
            for(String setting:new String[]{"uten.bootstrap_mapping_version","uten.bootstrap_repository_commit","uten.bootstrap_manifest_sha","uten.bootstrap_run_id"}) {
                rejected(tx,()->{tx.db.queryForObject("SELECT set_config(?, 'forged',true)",String.class,setting);register(tx.db,run,202);});
            }
            for(String change:new String[]{"status='SUCCESS'","target='--subcontract'","migration_mode='DRY_RUN'","migration_repository_commit=NULL",
                    "reconciliation_summary=reconciliation_summary||'{\"targetDatabase\":\"other\"}'::jsonb",
                    "reconciliation_summary=reconciliation_summary||'{\"targetSystemIdentifier\":\"1\"}'::jsonb"}) {
                rejected(tx,()->{tx.db.update("UPDATE legacy_migration_runs SET "+change+" WHERE run_id=?",run);register(tx.db,run,202);});
            }
        }
        try(var tx=transaction()) {
            UUID run=UUID.randomUUID();
            rejected(tx,()->register(tx.db,run,203));
        }
    }

    @Test void committedOrRolledBackProofCannotBeReusedAcrossTransactions() throws Exception {
        UUID run,id;
        try(var tx=transaction()) {run=context(tx.db);id=register(tx.db,run,301);tx.connection.commit();}
        try(var tx=transaction()) {
            settings(tx.db,run);
            rejected(tx,()->insert(tx.db,run,id,301));
        }
        try(var tx=transaction()) {UUID rolled=context(tx.db);insert(tx.db,rolled,register(tx.db,rolled,302),302);}
        assertEquals(0,admin.queryForObject("SELECT count(*) FROM subcontract_orders WHERE legacy_id=302",Integer.class));
        assertEquals(0,admin.queryForObject("SELECT count(*) FROM legacy_subcontract_order_import_sources WHERE source_legacy_id=302",Integer.class));
    }

    @Test void provenanceAndOriginalItemsStayFrozenButReviewedReceiptProgressCanAdvance() throws Exception {
        UUID run,id,item=UUID.randomUUID(),cost=UUID.randomUUID();
        try(var tx=transaction()) {
            run=context(tx.db);id=register(tx.db,run,401);insert(tx.db,run,id,401);
            tx.db.update("INSERT INTO subcontract_order_items(id,order_id,qty,price) VALUES(?,?,10,2)",item,id);
            tx.db.update("INSERT INTO subcontract_order_cost_items(id,order_id,qty,unit_qty) VALUES(?,?,20,1)",cost,id);
            tx.connection.commit();
        }
        try(var tx=transaction()) {
            for(String change:new String[]{"legacy_import_run_id=NULL","legacy_import_run_id=gen_random_uuid()",
                    "legacy_id=402","bill_no='new identity'","total_original=99","status=0"}) {
                rejected(tx,()->tx.db.update("UPDATE subcontract_orders SET "+change+" WHERE id=?",id));
            }
            for(String table:new String[]{"subcontract_order_items","subcontract_order_cost_items"}) {
                rejected(tx,()->tx.db.update("INSERT INTO "+table+"(id,order_id,qty,unit_id) VALUES(?,?,1,NULL)",UUID.randomUUID(),id));
                rejected(tx,()->tx.db.update("UPDATE "+table+" SET qty=99 WHERE order_id=?",id));
                rejected(tx,()->tx.db.update("UPDATE "+table+" SET unit_id=gen_random_uuid() WHERE order_id=?",id));
                rejected(tx,()->tx.db.update("DELETE FROM "+table+" WHERE order_id=?",id));
                assertEquals(1,tx.db.update("UPDATE "+table+" SET issued_qty=1,returned_qty=1 WHERE order_id=?",id));
            }
            assertEquals(1,tx.db.update("UPDATE subcontract_order_items SET received_qty=1,arrival_overage_posted_qty=1 WHERE order_id=?",id));
            assertEquals(1,tx.db.update("UPDATE subcontract_orders SET settlement_method_id=?,is_closed=true,fulfill=true WHERE id=?",UUID.randomUUID(),id));
            rejected(tx,()->tx.db.update("UPDATE subcontract_orders SET settlement_method_id=NULL WHERE id=?",id));
            rejected(tx,()->tx.db.update("UPDATE legacy_subcontract_order_import_sources SET issued_txid=txid_current() WHERE order_id=?",id));
            rejected(tx,()->tx.db.update("DELETE FROM legacy_subcontract_order_import_sources WHERE order_id=?",id));
            rejected(tx,()->tx.db.update("UPDATE subcontract_orders SET legacy_import_run_id=? WHERE id=?",run,existing));
        }
    }

    @Test void realRuntimeLoginCanReadPreservedCountsButCannotMintOrBorrowProvenance() throws Exception {
        UUID run,id;
        try(var tx=transaction()) {run=context(tx.db);id=register(tx.db,run,501);insert(tx.db,run,id,501);tx.connection.commit();}
        var runtime=db("uten",PASSWORD);
        assertEquals(1L,runtime.queryForObject("SELECT business_data_reset()",Long.class),"Invoker permission must permit PRESERVE counting");
        // Even a mistakenly broad grant must not turn GUCs or runtime rows into proof.
        admin.execute("GRANT INSERT,UPDATE,DELETE ON legacy_subcontract_order_import_sources TO uten; GRANT EXECUTE ON FUNCTION fn_register_legacy_subcontract_order_source(uuid,jsonb) TO uten");
        try(var connection=DriverManager.getConnection(PG.getJdbcUrl(),"uten",PASSWORD)) {
            connection.setAutoCommit(false);
            try(var tx=new Tx(connection)) {
                settings(tx.db,run);
                tx.db.execute("CREATE TEMP TABLE bootstrap_source_master_ids(source_legacy_id int); INSERT INTO bootstrap_source_master_ids VALUES(999)");
                tx.db.execute("CREATE TEMP TABLE pg_roles(rolname name,rolsuper boolean,rolcanlogin boolean); INSERT INTO pg_roles VALUES('uten',true,true)");
                tx.db.execute("CREATE TEMP TABLE pg_locks(locktype text,pid integer,granted boolean,mode text,objsubid integer,classid oid,objid oid)");
                assertTrue(rejected(tx,()->register(tx.db,run,502)).getMessage().contains("dedicated migration identity"),
                        "Fake temporary catalog relations must not impersonate the authenticated database role");
                rejected(tx,()->tx.db.update("INSERT INTO legacy_subcontract_order_import_sources(run_id,source_legacy_id,order_id,source_row_sha256,source_file_sha256,expected_header_sha256,issued_txid,created_at) SELECT run_id,502,gen_random_uuid(),source_row_sha256,source_file_sha256,expected_header_sha256,txid_current(),now() FROM legacy_subcontract_order_import_sources"));
                rejected(tx,()->insert(tx.db,run,UUID.randomUUID(),501));
            }
        }
    }

    @Test void officialV623ToV624PreservesHistoricalRowsAndResetDefinition() {
        admin.execute("CREATE DATABASE v624_formal");
        String url=PG.getJdbcUrl().replace("/test?","/v624_formal?");
        var flyway=Flyway.configure().dataSource(url,PG.getUsername(),PG.getPassword()).locations("classpath:db/migration");
        flyway.target("377").load().migrate();
        var db=new JdbcTemplate(new DriverManagerDataSource(url,PG.getUsername(),PG.getPassword()));
        UUID old=UUID.randomUUID();
        db.update("INSERT INTO subcontract_orders(id,bill_no,bill_date,status) VALUES(?,'EO20200102000001','2020-01-02',1)",old);
        flyway.target("623").load().migrate();
        String before=db.queryForObject("SELECT to_jsonb(h)::text FROM subcontract_orders h WHERE id=?",String.class,old);
        assertEquals(1,flyway.target("624").load().migrate().migrationsExecuted);
        assertEquals(before,db.queryForObject("SELECT (to_jsonb(h)-'legacy_import_run_id')::text FROM subcontract_orders h WHERE id=?",String.class,old));
        assertTrue(db.queryForObject("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)",String.class)
                .contains("('legacy_subcontract_order_import_sources', 'PRESERVE')"));
    }

    static JdbcTemplate db(String user,String password){return new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),user,password));}
    static Tx transaction() throws Exception {var c=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());c.setAutoCommit(false);return new Tx(c);}
    static final class Tx implements AutoCloseable {
        final Connection connection;final JdbcTemplate db;
        Tx(Connection c){connection=c;db=new JdbcTemplate(new SingleConnectionDataSource(c,true));}
        @Override public void close() throws Exception {connection.rollback();connection.close();}
    }
    static org.springframework.dao.DataAccessException rejected(Tx tx,Runnable command) throws Exception {
        var savepoint=tx.connection.setSavepoint();
        try {return assertThrows(org.springframework.dao.DataAccessException.class,command::run);} finally {tx.connection.rollback(savepoint);}
    }
    static UUID context(JdbcTemplate db){
        UUID run=UUID.randomUUID();
        db.update("""
            INSERT INTO legacy_migration_runs(run_id,target,status,migration_mode,mapping_version,migration_repository_commit,
                export_manifest_sha256,checksum_manifest_sha256,migration_script_sha256,source_backup_sha256,export_approval_reference,reconciliation_summary)
            VALUES(?,'--bootstrap-all','RUNNING','BOOTSTRAP','bootstrap-v2',repeat('a',40),repeat('b',64),repeat('c',64),repeat('d',64),repeat('e',64),'review-fixture',
                jsonb_build_object('importAtomicity','single-transaction-v1','targetDatabase',current_database(),'targetApprovalReference','fixture-review',
                    'targetSystemIdentifier',(SELECT system_identifier::text FROM pg_control_system())))
            """,run);
        db.update("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,'subcontract_order_m.csv',repeat('f',64),500)",run);
        settings(db,run);return run;
    }
    static void settings(JdbcTemplate db,UUID run){
        db.queryForObject("SELECT set_config('uten.bootstrap_run_id',?,true)",String.class,run.toString());
        db.execute("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v2'; SET LOCAL uten.bootstrap_repository_commit='"+"a".repeat(40)+"'; SET LOCAL uten.bootstrap_manifest_sha='"+"b".repeat(64)+"'");
        db.execute("SELECT pg_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:'||current_database(),0))");
    }
    static UUID register(JdbcTemplate db,UUID run,int source){return db.queryForObject("SELECT fn_register_legacy_subcontract_order_source(?,?::jsonb)",UUID.class,run,source(source));}
    static String source(int id){return """
        {"legacy_id":%d,"bill_no":"SOURCE-%d","bill_date":"2020-01-02","supplier_legacy_id":null,
        "deliver_date":null,"send_legacy":null,"maker_legacy":null,"approver_legacy":null,
        "fulfill_bit":false,"stop_bit":false,"currency_legacy_id":null,"exchange_rate":1,
        "tax_rate":13,"total_original":20,"status":1,"cancel_bit":false,"remark":"history"}
        """.formatted(id,id);}
    static void insert(JdbcTemplate db,UUID run,UUID id,int source){
        db.update("""
            INSERT INTO subcontract_orders(id,legacy_import_run_id,legacy_id,bill_no,bill_date,exchange_rate,tax_rate,
                total_original,total_local,status,fulfill,is_closed,remark)
            VALUES(?,?,?,?,'2020-01-02',1,13,20,20,1,false,false,'history')
            """,id,run,source,"SOURCE-"+source);
    }
}
