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
            long originalRows=count(db,table);
            String originalProof=proofSnapshot(run,id);
            ObjectNode forged=payload.deepCopy();forged.put("id",UUID.randomUUID().toString());
            rejectedWithReason(()->insert(db,table,forged),"legacy receipt row has no exact source proof in this transaction");
            ObjectNode changed=payload.deepCopy();changed.put("qty",99);
            rejectedWithReason(()->insert(db,table,changed),"legacy receipt does not match its original source projection");
            ObjectNode changedWeight=payload.deepCopy();changedWeight.put("weight",999);
            rejectedWithReason(()->insert(db,table,changedWeight),"legacy receipt does not match its original source projection");
            ObjectNode invented=payload.deepCopy();invented.put(family.equals("PURCHASE")?"charged_base_qty":"adopted_base_qty",1);
            rejectedWithReason(()->insert(db,table,invented),"verified historical quantities cannot carry new adoption, gift or precision facts");
            ObjectNode policy=payload.deepCopy();policy.put("quantity_adoption_version",1);
            rejectedWithReason(()->insert(db,table,policy),"verified historical receipts require initial version two and adopted weight version one");
            ObjectNode missingVersion=payload.deepCopy();missingVersion.putNull("quantity_adoption_version");
            rejectedWithReason(()->insert(db,table,missingVersion),"verified historical receipts require initial version two and adopted weight version one");
            ObjectNode newPolicy=payload.deepCopy();newPolicy.putObject("quantity_precision_policy");
            rejectedWithReason(()->insert(db,table,newPolicy),"verified historical quantities cannot carry new adoption, gift or precision facts");
            assertEquals(originalRows,count(db,table),"Every rejected insert must leave the full item inventory unchanged");
            assertEquals(originalProof,proofSnapshot(run,id),"The complete original source-proof row must stay byte-exact");
        }
    }

    @Test void aSourceProofCannotBeReusedAfterItsActualImportTransaction() throws Exception {
        var db=current.db;UUID run=context(db);
        importRow(db,run,"PURCHASE_HEADER",source(db,"PURCHASE_HEADER"));
        ObjectNode original=source(db,"PURCHASE_ITEM");UUID id=register(db,run,"PURCHASE_ITEM",original);
        ObjectNode payload=projection(db,"PURCHASE_ITEM",original);payload.put("id",id.toString());payload.put("legacy_import_run_id",run.toString());
        String originalProof=proofSnapshot(run,id);
        Long issued=db.queryForObject("SELECT issued_txid FROM legacy_procurement_receipt_import_sources WHERE run_id=? AND target_id=?",Long.class,run,id);
        db.execute("SET CONSTRAINTS ALL IMMEDIATE");current.connection.commit();
        assertNotEquals(issued,db.queryForObject("SELECT txid_current()",Long.class));
        rejectedWithReason(()->insert(db,"purchase_receipt_items",payload),"legacy source evidence requires the active bootstrap lock, run and source file");
        assertEquals(0,db.queryForObject("SELECT count(*) FROM purchase_receipt_items WHERE id=?",Integer.class,id));
        // Use the actual fixture capability entrance to reacquire the legitimate
        // dedicated-role/bootstrap lock and reviewed metadata, without issuing a new row proof.
        UUID freshContext=context(db);
        assertNotEquals(run,freshContext);
        db.queryForObject("SELECT set_config('uten.bootstrap_run_id',?,true)",String.class,run.toString());
        assertDoesNotThrow(()->db.queryForList("SELECT fn_require_legacy_bootstrap(?,?)",run,"purchase_receipt_items.csv"));
        assertEquals(originalProof,proofSnapshot(run,id));
        // Authorization is now valid; this must fail specifically because the
        // original proof/target belongs to the already committed transaction.
        rejectedWithReason(()->insert(db,"purchase_receipt_items",payload),"legacy receipt row has no exact source proof in this transaction");
        assertEquals(0,db.queryForObject("SELECT count(*) FROM purchase_receipt_items WHERE id=?",Integer.class,id));
        assertEquals(originalProof,proofSnapshot(run,id),"Re-entering a legal bootstrap context cannot reissue or rewrite the old proof");
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

    private void rejectedWithReason(Runnable operation,String exactReason) throws Exception {
        var rejected=rejected(current,operation);
        var cause=assertInstanceOf(org.postgresql.util.PSQLException.class,rejected.getMostSpecificCause());
        assertEquals("23514",cause.getSQLState(),cause::getMessage);
        assertNotNull(cause.getServerErrorMessage());
        assertEquals(exactReason,cause.getServerErrorMessage().getMessage());
    }

    private String proofSnapshot(UUID run,UUID target) {
        return current.db.queryForObject("SELECT to_jsonb(proof)::text FROM legacy_procurement_receipt_import_sources proof WHERE run_id=? AND target_id=?",String.class,run,target);
    }
}
