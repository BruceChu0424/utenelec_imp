package com.uten.imp.features.stock;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.sql.*;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

/** Real V924 catalog + the exact V928 upgrade SQL, on a new test-owned server only. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockMeasurementOperabilityPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("measurement_upgrade").withUsername("fixture_admin").withPassword("owned-fixture-only");
    private static final UUID UNKNOWN=UUID.randomUUID(), ZERO_AMOUNT=UUID.randomUUID(), KNOWN=UUID.randomUUID();
    private static final UUID UNIT=UUID.randomUUID();
    private static UUID warehouse,reviewer;
    private Connection db;

    @BeforeAll static void upgrade() throws Exception {
        PG.start();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())
                .locations("classpath:db/migration").target("924").load().migrate();
        try(var c=connection()) {
            exec(c,"CREATE ROLE uten LOGIN NOSUPERUSER PASSWORD 'runtime-measurement-fixture'");
            exec(c,"INSERT INTO units(id,code,name) VALUES('"+UNIT+"','MEASURE-FIXTURE','测试计量单位')");
            try(var s=c.createStatement();var rs=s.executeQuery("SELECT fn_warehouse_root_id()")) { rs.next();warehouse=rs.getObject(1,UUID.class); }
            if(warehouse==null) {
                warehouse=UUID.randomUUID();
                exec(c,"INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES('"+warehouse+"','001','测试主仓','使用',true)");
            }
            UUID leaf=UUID.randomUUID();
            exec(c,"INSERT INTO warehouses(id,code,name,status,is_accountable,parent_id) VALUES('"+leaf+"','MEASURE-LEAF','测试计量仓','使用',true,'"+warehouse+"')");
            warehouse=leaf;
            exec(c,"INSERT INTO goods(id,code,name,code_sequence,unit_id) VALUES('"+UNKNOWN+"','MEASURE-UNKNOWN','待核原账',900001,NULL),"
                    +"('"+ZERO_AMOUNT+"','MEASURE-ZERO-AMOUNT','零量有金额原账',900002,NULL),"
                    +"('"+KNOWN+"','MEASURE-KNOWN','已知单位正常库存',900003,'"+UNIT+"')");
            exec(c,"INSERT INTO stock_balances(warehouse_id,goods_id,qty,amount_local,weight,weight_estimated) VALUES"
                    +"('"+warehouse+"','"+UNKNOWN+"',9,-90,18,true),('"+warehouse+"','"+ZERO_AMOUNT+"',0,75,0,false),"
                    +"('"+warehouse+"','"+KNOWN+"',100,1000,200,false)");
            exec(c,reservation(UNKNOWN,warehouse)); // A real pre-upgrade commitment remains auditable and releasable.
            reviewer=UUID.randomUUID();
            exec(c,"INSERT INTO users(id,employee_id,login_account,password_hash) SELECT '"+reviewer+"',id,'measurement-fixture-reviewer','fixture-only' FROM employees WHERE code='ADMIN'");
            try(var source=StockMeasurementOperabilityPostgresTest.class.getResourceAsStream("/db/migration/V928__stock_unresolved_unit_operability.sql")) {
                exec(c,new String(source.readAllBytes(),StandardCharsets.UTF_8));
            }
            // Deliberately generous application ACLs prove row/session guards,
            // including accidental later grants, independently of plain REVOKE.
            exec(c,"GRANT USAGE ON SCHEMA public TO uten; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten; GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO uten; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO uten");
        }
    }
    @AfterAll static void stop() { PG.stop(); }
    @BeforeEach void open() throws Exception { db=connection();db.setAutoCommit(false); }
    @AfterEach void rollback() throws Exception { if(db!=null){db.rollback();db.close();} }
    private static Connection connection() throws SQLException { return DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()); }

    @Test void capturePreservesEveryBookFieldIncludingZeroQuantityAmountAndIsIdempotent() throws Exception {
        assertThat(scalar("SELECT count(*) FROM stock_measurement_holds")).isEqualTo("2");
        assertThat(scalar("SELECT fn_capture_stock_measurement_holds()")).isEqualTo("0");
        assertThat(scalar("SELECT qty||'|'||amount_local||'|'||weight||'|'||weight_estimated FROM stock_balances WHERE goods_id='"+UNKNOWN+"'"))
                .isEqualTo("9.0000|-90|18.0000|true");
        assertThat(scalar("SELECT qty||'|'||amount_local FROM stock_balances WHERE goods_id='"+ZERO_AMOUNT+"'"))
                .isEqualTo("0.0000|75");
        assertThat(scalar("SELECT count(*) FROM v_stock_usable WHERE goods_id='"+UNKNOWN+"'")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM v_stock_available WHERE goods_id='"+UNKNOWN+"'")).isEqualTo("0");
        assertThat(scalar("SELECT fn_stock_global_usable('"+UNKNOWN+"',NULL)")).isEqualTo("0");
    }
    @Test void ordinaryUnitEditIsAlreadyRejectedAndEvenControlledMasterCompletionNeverReleasesOldNumbers() throws Exception {
        reject("UPDATE goods SET unit_id='"+UNIT+"' WHERE id='"+UNKNOWN+"'","历史基本单位尚未核对");
        completeFixtureMasterOnly();
        assertThat(scalar("SELECT fn_stock_has_resolved_base_unit('"+UNKNOWN+"')")).isEqualTo("t");
        assertThat(scalar("SELECT fn_stock_measurement_usable('"+warehouse+"','"+UNKNOWN+"',NULL)")).isEqualTo("f");
        assertThat(scalar("SELECT count(*) FROM v_stock_usable WHERE goods_id='"+UNKNOWN+"'")).isEqualTo("0");
        reject(movement(UNKNOWN,1),"计量待核");reject(movement(UNKNOWN,-1),"计量待核");
        reject("UPDATE stock_balances SET qty=qty+1 WHERE goods_id='"+UNKNOWN+"'","计量待核");
        reject("UPDATE stock_balances SET amount_local=0 WHERE goods_id='"+UNKNOWN+"'","计量待核");
        reject("UPDATE stock_balances SET weight=0 WHERE goods_id='"+UNKNOWN+"'","计量待核");
    }
    @Test void unknownStockCannotBeReservedGloballyOrLocallyAndNativeKnownStockKeepsWorking() throws Exception {
        completeFixtureMasterOnly();
        reject(reservation(UNKNOWN,warehouse),"计量待核");reject(reservation(UNKNOWN,null),"计量待核");
        reject("UPDATE stock_reservations SET consumed_qty=qty,status=1,is_deleted=true WHERE goods_id='"+UNKNOWN+"'","计量待核");
        exec(db,"UPDATE stock_reservations SET released_qty=qty,status=1 WHERE goods_id='"+UNKNOWN+"'");
        assertThat(scalar("SELECT fn_stock_global_usable('"+KNOWN+"',NULL)")).isEqualTo("100.0000");
        exec(db,movement(KNOWN,1));exec(db,movement(KNOWN,-1));
        exec(db,"UPDATE stock_balances SET qty=qty+1 WHERE goods_id='"+KNOWN+"'");
        exec(db,reservation(KNOWN,warehouse));
        assertThat(scalar("SELECT on_hand_qty FROM v_stock_usable WHERE goods_id='"+KNOWN+"'")).isEqualTo("101.0000");
        assertThat(scalar("SELECT qty FROM stock_balances WHERE goods_id='"+UNKNOWN+"'")).isEqualTo("9.0000");
    }
    @Test void trustedOriginalBasisVerificationNeedsEvidenceAndLeavesBookAndMovementFactsUnchanged() throws Exception {
        completeFixtureMasterOnly();
        String hold=scalar("SELECT id FROM stock_measurement_holds WHERE goods_id='"+UNKNOWN+"'");
        reject(verification(hold,UNIT,"","bad","too short"),"Require verified");
        String before=scalar("SELECT row_to_json(b)::text FROM stock_balances b WHERE goods_id='"+UNKNOWN+"'");
        String movements=scalar("SELECT count(*) FROM stock_movements");
        exec(db,verification(hold,UNIT,"fixture://reviewed-original-unit","a".repeat(64),"Fixture reviewer confirmed this exact original quantity already used the documented base unit, without conversion."));
        assertThat(scalar("SELECT fn_stock_measurement_usable('"+warehouse+"','"+UNKNOWN+"',NULL)")).isEqualTo("t");
        assertThat(scalar("SELECT row_to_json(b)::text FROM stock_balances b WHERE goods_id='"+UNKNOWN+"'")).isEqualTo(before);
        assertThat(scalar("SELECT count(*) FROM stock_movements")).isEqualTo(movements);
        assertThat(scalar("SELECT count(*) FROM stock_measurement_holds WHERE released_at IS NOT NULL")).isEqualTo("1");
        reject(verification(hold,UNIT,"fixture://repeat","b".repeat(64),"This cannot replace prior reviewed evidence."),"already been verified");
    }
    @Test void changedOriginalSnapshotCannotBeVerifiedAsAnUnchangedBasis() throws Exception {
        completeFixtureMasterOnly();
        exec(db,"ALTER TABLE stock_balances DISABLE TRIGGER trg_stock_balance_measurement_operability");
        exec(db,"UPDATE stock_balances SET qty=10 WHERE goods_id='"+UNKNOWN+"'");
        exec(db,"SET CONSTRAINTS ALL IMMEDIATE");
        exec(db,"ALTER TABLE stock_balances ENABLE ALWAYS TRIGGER trg_stock_balance_measurement_operability");
        String hold=scalar("SELECT id FROM stock_measurement_holds WHERE goods_id='"+UNKNOWN+"'");
        reject(verification(hold,UNIT,"fixture://stale","a".repeat(64),"This purported unchanged-unit evidence no longer matches the captured book snapshot."),"Original balance changed");
    }
    @Test void runtimeCannotReleaseCaptureRewriteDeleteOrTruncateEvidenceEvenThroughSecurityDefiner() throws Exception {
        String hold=scalar("SELECT id FROM stock_measurement_holds WHERE goods_id='"+UNKNOWN+"'");
        exec(db,"CREATE FUNCTION measurement_fixture_attempt_release() RETURNS void SECURITY DEFINER LANGUAGE plpgsql AS $$ BEGIN PERFORM fn_verify_stock_original_measurement_basis('"+hold+"','"+UNIT+"','"+reviewer+"','fixture://forged','"+"a".repeat(64)+"','runtime is not a trusted measurement reviewer'); END $$");
        db.commit(); // Separate LOGIN must see the deliberately vulnerable wrapper.
        try(var runtime=DriverManager.getConnection(PG.getJdbcUrl(),"uten","runtime-measurement-fixture")) {
            runtime.setAutoCommit(false);
            reject(runtime,"SELECT measurement_fixture_attempt_release()","requires reviewed schema maintenance");
            reject(runtime,"SELECT fn_capture_stock_measurement_holds()","Only schema maintenance");
            reject(runtime,"UPDATE stock_measurement_holds SET captured_qty=0 WHERE id='"+hold+"'","maintenance-only");
            reject(runtime,"DELETE FROM stock_measurement_holds WHERE id='"+hold+"'","cannot be deleted");
            reject(runtime,"TRUNCATE stock_measurement_holds","permission denied");
            runtime.rollback();
        } finally { exec(db,"DROP FUNCTION measurement_fixture_attempt_release()"); }
    }
    private void completeFixtureMasterOnly() throws SQLException {
        // Owned-fixture setup deliberately bypasses the OLD V675 master guard;
        // this is not a supported production unit repair or a release action.
        exec(db,"ALTER TABLE goods DISABLE TRIGGER trg_goods_quantity_unit_immutable");
        exec(db,"UPDATE goods SET unit_id='"+UNIT+"' WHERE id='"+UNKNOWN+"'");
        exec(db,"ALTER TABLE goods ENABLE TRIGGER trg_goods_quantity_unit_immutable");
    }
    private String scalar(String sql) throws SQLException { try(var s=db.createStatement();var r=s.executeQuery(sql)){r.next();return r.getString(1);} }
    private void reject(String sql,String message) throws Exception { reject(db,sql,message); }
    private static void reject(Connection c,String sql,String message) throws Exception {
        Savepoint save=c.setSavepoint();try { assertThatThrownBy(()->exec(c,sql)).hasMessageContaining(message); }
        finally { c.rollback(save);c.releaseSavepoint(save); }
    }
    private static void exec(Connection c,String sql) throws SQLException { try(var s=c.createStatement()){s.execute(sql);} }
    private static String movement(UUID goods,int direction) {
        return "INSERT INTO stock_movements(transaction_date,movement_type,source_doc_type,source_doc_id,goods_id,warehouse_id,direction,qty) VALUES(now(),11,'STOCK_DOC','"
                +UUID.randomUUID()+"','"+goods+"','"+warehouse+"',"+direction+",1)";
    }
    private static String reservation(UUID goods,UUID wh) {
        UUID order=UUID.randomUUID();
        return "INSERT INTO stock_reservations(order_item_id,owner_type,owner_id,purpose,goods_id,warehouse_id,qty) VALUES('"+order+"','SALES_ORDER_ITEM','"+order+"','SALES_FULFILLMENT','"+goods+"',"+(wh==null?"NULL":"'"+wh+"'")+",1)";
    }
    private static String verification(String hold,UUID unit,String ref,String sha,String note) {
        return "SELECT fn_verify_stock_original_measurement_basis('"+hold+"','"+unit+"','"+reviewer+"','"+ref+"','"+sha+"','"+note+"')";
    }
}
