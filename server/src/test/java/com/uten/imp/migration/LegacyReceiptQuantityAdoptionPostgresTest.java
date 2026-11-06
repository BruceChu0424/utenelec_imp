package com.uten.imp.migration;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.support.LegacyFinanceImportFixture;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.migration.LegacyReceiptConsiderationProvenancePostgresTest.*;
import static org.junit.jupiter.api.Assertions.*;

/** Current source-authorized import, without synthesizing modern adoption or inventory facts. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyReceiptQuantityAdoptionPostgresTest {
    private MigratedSchemaBaseline.ScopedDatabase database;
    private LegacyReceiptConsiderationProvenancePostgresTest.Tx current;

    @BeforeEach void setup() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("legacy_receipt_adoption");
        var connection=database.openConnection();connection.setAutoCommit(false);
        current=new LegacyReceiptConsiderationProvenancePostgresTest.Tx(connection);
        LegacyFinanceImportFixture.seed(current.db);
        current.db.update("INSERT INTO units(legacy_id,code,name) VALUES(900301,'ADOPTION-OLD-U','原始历史单位')");
        current.db.update("INSERT INTO warehouses(legacy_id,code,name) VALUES(900201,'ADOPTION-OLD-W','历史仓库')");
        for(int legacy:List.of(900101,900102))current.db.update("INSERT INTO goods(legacy_id,code,name,unit_id,code_sequence) SELECT ?,?,'历史来源货品',id,(SELECT coalesce(max(code_sequence),0)+1 FROM goods) FROM units WHERE legacy_id=900301",legacy,"ADOPTION-OLD-G-"+legacy);
    }
    @AfterEach void close() throws Exception {
        if(current!=null)current.close();
        if(database!=null)database.close();
    }

    @Test void bothVerifiedSourceFamiliesRetainOriginalFactsAndUnknownDerivedValues() throws Exception {
        var db=current.db;UUID run=context(db);
        long movements=count(db,"stock_movements"),payables=count(db,"ar_ap_ledger"),parts=count(db,"procurement_receipt_consideration_parts");
        for(String family:List.of("PURCHASE","SUBCONTRACT")) {
            importRow(db,run,family+"_HEADER",source(db,family+"_HEADER"));
            ObjectNode original=source(db,family+"_ITEM");
            UUID id=importRow(db,run,family+"_ITEM",original);
            String table=family.toLowerCase()+"_receipt_items";
            var row=db.queryForMap("SELECT qty,unit_id,unit_rate,quantity_adoption_version,quantity_precision_policy,to_jsonb(item) body FROM "+table+" item WHERE id=?",id);
            assertEquals(0,new BigDecimal(original.get("qty").asText()).compareTo((BigDecimal)row.get("qty")));
            assertEquals(0,new BigDecimal(original.get("unit_rate").asText()).compareTo((BigDecimal)row.get("unit_rate")));
            assertNotNull(row.get("unit_id"));assertEquals(1,((Number)row.get("quantity_adoption_version")).intValue());assertNull(row.get("quantity_precision_policy"));
            if(family.equals("PURCHASE")) {
                assertNull(db.queryForObject("SELECT charged_base_qty FROM purchase_receipt_items WHERE id=?",Object.class,id));
                assertNull(db.queryForObject("SELECT gift_base_qty FROM purchase_receipt_items WHERE id=?",Object.class,id));
                assertEquals("LEGACY_RECORDED",db.queryForObject("SELECT quantity_semantics FROM purchase_receipt_items WHERE id=?",String.class,id));
            }else assertNull(db.queryForObject("SELECT adopted_base_qty FROM subcontract_receipt_items WHERE id=?",Object.class,id));
            String before=db.queryForObject("SELECT to_jsonb(item)::text FROM "+table+" item WHERE id=?",String.class,id);
            rejected(current,()->db.update("UPDATE "+table+" SET qty=qty+1 WHERE id=?",id));
            assertEquals(before,db.queryForObject("SELECT to_jsonb(item)::text FROM "+table+" item WHERE id=?",String.class,id));
        }
        db.execute("SET CONSTRAINTS ALL IMMEDIATE");
        assertEquals(movements,count(db,"stock_movements"));assertEquals(payables,count(db,"ar_ap_ledger"));assertEquals(parts,count(db,"procurement_receipt_consideration_parts"));
    }

    @Test void historicalUnknownOriginalUnitAndRateStayUnknownRatherThanBeingAdopted() throws Exception {
        var db=current.db;UUID run=context(db);
        for(String family:List.of("PURCHASE","SUBCONTRACT")) {
            importRow(db,run,family+"_HEADER",source(db,family+"_HEADER"));
            ObjectNode original=source(db,family+"_ITEM");original.putNull("unit_legacy_id");original.putNull("unit_rate");
            UUID id=importRow(db,run,family+"_ITEM",original);String table=family.toLowerCase()+"_receipt_items";
            assertNull(db.queryForObject("SELECT unit_id FROM "+table+" WHERE id=?",Object.class,id));
            assertNull(db.queryForObject("SELECT unit_rate FROM "+table+" WHERE id=?",Object.class,id));
            assertEquals((short)1,db.queryForObject("SELECT quantity_adoption_version FROM "+table+" WHERE id=?",Short.class,id));
        }
        db.execute("SET CONSTRAINTS ALL IMMEDIATE");
    }

    @Test void markersChangedFactsAndInventedDerivationsNeverGrantTheHistoricalLane() throws Exception {
        var db=current.db;UUID run=context(db);
        for(String family:List.of("PURCHASE","SUBCONTRACT")) {
            importRow(db,run,family+"_HEADER",source(db,family+"_HEADER"));
            ObjectNode original=source(db,family+"_ITEM");UUID id=register(db,run,family+"_ITEM",original);
            ObjectNode payload=projection(db,family+"_ITEM",original);payload.put("id",id.toString());payload.put("legacy_import_run_id",run.toString());
            String table=family.toLowerCase()+"_receipt_items";
            ObjectNode forged=payload.deepCopy();forged.put("id",UUID.randomUUID().toString());
            assertTrue(rejected(current,()->insert(db,table,forged)).getMessage().contains("exact source proof in this transaction"));
            ObjectNode changed=payload.deepCopy();changed.put("qty",99);
            assertTrue(rejected(current,()->insert(db,table,changed)).getMessage().contains("original source projection"));
            ObjectNode changedWeight=payload.deepCopy();changedWeight.put("weight",999);
            assertTrue(rejected(current,()->insert(db,table,changedWeight)).getMessage().contains("original source projection"));
            ObjectNode invented=payload.deepCopy();invented.put(family.equals("PURCHASE")?"charged_base_qty":"adopted_base_qty",1);
            assertTrue(rejected(current,()->insert(db,table,invented)).getMessage().contains("invented derived values"));
            ObjectNode policy=payload.deepCopy();policy.put("quantity_adoption_version",1);
            assertTrue(rejected(current,()->insert(db,table,policy)).getMessage().contains("invented derived values"));
            ObjectNode missingVersion=payload.deepCopy();missingVersion.putNull("quantity_adoption_version");
            assertTrue(rejected(current,()->insert(db,table,missingVersion)).getMessage().contains("invented derived values"));
        }
    }

    @Test void aSourceProofCannotBeReusedAfterItsActualImportTransaction() throws Exception {
        var db=current.db;UUID run=context(db);
        importRow(db,run,"PURCHASE_HEADER",source(db,"PURCHASE_HEADER"));
        ObjectNode original=source(db,"PURCHASE_ITEM");UUID id=register(db,run,"PURCHASE_ITEM",original);
        ObjectNode payload=projection(db,"PURCHASE_ITEM",original);payload.put("id",id.toString());payload.put("legacy_import_run_id",run.toString());
        db.execute("SET CONSTRAINTS ALL IMMEDIATE");current.connection.commit();
        assertTrue(rejected(current,()->insert(db,"purchase_receipt_items",payload)).getMessage().contains("exact source proof in this transaction"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM purchase_receipt_items WHERE id=?",Integer.class,id));
    }

    @Test void nativeQuantityStillNeedsItsRealUnitAndCurrentExactChoice() throws Exception {
        var db=current.db;UUID receipt=UUID.randomUUID();
        UUID goods=db.queryForObject("SELECT id FROM goods WHERE legacy_id=900102",UUID.class);
        UUID unit=db.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,goods);
        db.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,status) VALUES(?,'CJ20250102800001','2025-01-02',0)",receipt);
        String sql="INSERT INTO purchase_receipt_items(id,receipt_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,charged_base_qty,gift_base_qty,price,amount_original,amount_local,goods_snapshot_source) VALUES(?,?,'CJ20250102800001','2025-01-02',?,?,?,?,?,0,0,0,0,'MASTER_AT_SAVE')";
        BigDecimal exact=new BigDecimal("1.123456789012345678901234");UUID id=UUID.randomUUID();
        db.update(sql,id,receipt,goods,unit,BigDecimal.ONE,exact,exact);
        assertEquals((short)2,db.queryForObject("SELECT quantity_adoption_version FROM purchase_receipt_items WHERE id=?",Short.class,id));
        assertEquals(unit,db.queryForObject("SELECT unit_id FROM purchase_receipt_items WHERE id=?",UUID.class,id));
        assertEquals(exact,db.queryForObject("SELECT qty FROM purchase_receipt_items WHERE id=?",BigDecimal.class,id));
        assertNotNull(db.queryForObject("SELECT quantity_precision_policy FROM purchase_receipt_items WHERE id=?",Object.class,id));
        BigDecimal fullCapacity=new BigDecimal("9999999999999999999999999999999999999999.000000000000000000000001");
        UUID large=UUID.randomUUID();db.update(sql,large,receipt,goods,unit,BigDecimal.ONE,fullCapacity,fullCapacity);
        assertEquals(fullCapacity,db.queryForObject("SELECT qty FROM purchase_receipt_items WHERE id=?",BigDecimal.class,large));
        assertNotNull(rejected(current,()->{
            db.update("UPDATE purchase_receipt_items SET weight=0.5 WHERE id=?",id);
            db.execute("SET CONSTRAINTS purchase_receipt_weight_adoption IMMEDIATE");
        }),"native weighing still requires its real current-transaction input evidence");
        assertTrue(rejected(current,()->db.update(sql,UUID.randomUUID(),receipt,goods,null,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE)).getMessage().contains("actual positive unit rate and original unit"));
        BigDecimal tooFine=new BigDecimal("0.0000000000000000000000001");
        assertNotNull(rejected(current,()->db.update(sql,UUID.randomUUID(),receipt,goods,unit,BigDecimal.ONE,tooFine,tooFine)));
        BigDecimal operands=new BigDecimal("1.000000000000000000000001"),adopted=new BigDecimal("1.000000000000000000000002");
        assertNotNull(rejected(current,()->db.update(sql,UUID.randomUUID(),receipt,goods,unit,operands,operands,adopted)));
        db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)",String.class,"{\"version\":1,\"choices\":{\"quantity.to-base\":{\"scale\":24,\"rounding\":\"DOWN\"}}}");
        UUID chosen=UUID.randomUUID();db.update(sql,chosen,receipt,goods,unit,operands,operands,adopted);
        assertEquals(adopted,db.queryForObject("SELECT charged_base_qty FROM purchase_receipt_items WHERE id=?",BigDecimal.class,chosen));
        assertEquals(24,db.queryForObject("SELECT (quantity_precision_policy->'choices'->'quantity.to-base'->>'scale')::integer FROM purchase_receipt_items WHERE id=?",Integer.class,chosen));
    }
}
