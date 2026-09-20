package com.uten.imp.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.support.LegacyFinanceImportFixture;
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

/** Exact old receipt facts enter the historical lane without inventing modern posting chains. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyReceiptConsiderationProvenancePostgresTest {
    static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    static final String PASSWORD=UUID.randomUUID().toString();
    static final UUID OLD_HEADER=UUID.randomUUID(),OLD_ITEM=UUID.randomUUID(),OLD_MIXED_ITEM=UUID.randomUUID();
    static JdbcTemplate admin;
    static String oldHeader,oldItem,nativeAssertion;

    @BeforeAll static void start() throws Exception {
        PG.start();admin=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        admin.execute("CREATE ROLE uten LOGIN NOSUPERUSER PASSWORD '"+PASSWORD+"'");
        migrate("517");
        try(Tx tx=tx()) {
            tx.db.execute("SET LOCAL uten.legacy_reference_import='legacy-receipt-test'");
            LegacyFinanceImportFixture.seed(tx.db);
            tx.db.update("INSERT INTO units(legacy_id,code,name) VALUES(900301,'SYN-RECEIPT-U','Synthetic receipt unit')");
            tx.db.update("INSERT INTO warehouses(legacy_id,code,name) VALUES(900201,'SYN-RECEIPT-W','Synthetic receipt warehouse')");
            tx.db.update("INSERT INTO goods(legacy_id,code,name,unit_id,code_sequence) SELECT 900102,'SYN-RECEIPT-G','Synthetic receipt goods',id,100101 FROM units WHERE legacy_id=900301");
            tx.db.update("INSERT INTO goods(legacy_id,code,name,unit_id,code_sequence) SELECT 900101,'SYN-RECEIPT-F','Synthetic receipt finished goods',id,100102 FROM units WHERE legacy_id=900301");
            tx.db.update("INSERT INTO purchase_receipts(id,legacy_id,bill_no,bill_date,status) VALUES(?,1001,'OLD-RECEIPT','2020-01-01',1)",OLD_HEADER);
            tx.db.update("""
                    INSERT INTO purchase_receipt_items(id,legacy_id,receipt_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,
                        price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                    SELECT ?,1002,?,'OLD-RECEIPT','2020-01-01',id,unit_id,1,2,3,6,6,code,name,'LEGACY_IMPORT',now()
                    FROM goods WHERE legacy_id=900102
                    """,OLD_ITEM,OLD_HEADER);
            tx.db.update("""
                    INSERT INTO purchase_receipt_items(id,receipt_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,
                        price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                    SELECT ?,receipt_id,bill_no,bill_date,goods_id,unit_id,unit_rate,1,price,3,3,
                        goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at
                    FROM purchase_receipt_items WHERE id=?
                    """,OLD_MIXED_ITEM,OLD_ITEM);
            tx.connection.commit();
        }
        migrate("626");
        oldHeader=snapshot(admin,"purchase_receipts",OLD_HEADER,false);
        oldItem=snapshot(admin,"purchase_receipt_items",OLD_ITEM,false);
        nativeAssertion=admin.queryForObject("SELECT pg_get_functiondef('fn_assert_procurement_consideration_receipt(text,uuid)'::regprocedure)",String.class);
        migrate("627");
        admin.execute("GRANT USAGE ON SCHEMA public TO uten; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten; "
                +"GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO uten; REVOKE INSERT,UPDATE,DELETE ON legacy_procurement_receipt_import_sources FROM uten");
    }
    @AfterAll static void stop(){PG.stop();}

    @Test void nonemptyUpgradeDoesNotRewriteHistoryOrWeakenNativeConservation() {
        assertEquals(oldHeader,snapshot(admin,"purchase_receipts",OLD_HEADER,true));
        assertEquals(oldItem,snapshot(admin,"purchase_receipt_items",OLD_ITEM,true));
        assertFalse(admin.queryForObject("SELECT consideration_required FROM purchase_receipts WHERE id=?",Boolean.class,OLD_HEADER));
        assertEquals(nativeAssertion,admin.queryForObject("SELECT pg_get_functiondef('fn_assert_procurement_consideration_receipt(text,uuid)'::regprocedure)",String.class));
    }

    @Test void bothOriginalReceiptFamiliesPassDeferredChecksWithoutNewStockPayablesOrParts() throws Exception {
        try(Tx tx=tx()) {
            UUID run=context(tx.db);
            long stock=count(tx.db,"stock_movements"),payable=count(tx.db,"ar_ap_ledger"),parts=count(tx.db,"procurement_receipt_consideration_parts");
            UUID purchase=importRow(tx.db,run,"PURCHASE_HEADER",source(tx.db,"PURCHASE_HEADER"));
            importRow(tx.db,run,"PURCHASE_ITEM",source(tx.db,"PURCHASE_ITEM"));
            UUID subcontract=importRow(tx.db,run,"SUBCONTRACT_HEADER",source(tx.db,"SUBCONTRACT_HEADER"));
            importRow(tx.db,run,"SUBCONTRACT_ITEM",source(tx.db,"SUBCONTRACT_ITEM"));
            tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE");
            assertFalse(tx.db.queryForObject("SELECT consideration_required FROM purchase_receipts WHERE id=?",Boolean.class,purchase));
            assertFalse(tx.db.queryForObject("SELECT consideration_required FROM subcontract_receipts WHERE id=?",Boolean.class,subcontract));
            assertEquals(stock,count(tx.db,"stock_movements"));assertEquals(payable,count(tx.db,"ar_ap_ledger"));assertEquals(parts,count(tx.db,"procurement_receipt_consideration_parts"));
            assertEquals(4L,tx.db.queryForObject("SELECT count(*) FROM legacy_procurement_receipt_import_sources WHERE run_id=?",Long.class,run));
        }
    }

    @Test void sourceAmountsAndUnknownUnitsArePreservedInsteadOfDefaulted() throws Exception {
        try(Tx tx=tx()) {
            UUID run=context(tx.db);
            ObjectNode header=source(tx.db,"PURCHASE_HEADER");header.put("exchange_rate",2);header.put("total_original",7);
            UUID id=importRow(tx.db,run,"PURCHASE_HEADER",header);
            assertEquals("14",tx.db.queryForObject("SELECT trim_scale(total_local)::text FROM purchase_receipts WHERE id=?",String.class,id));
            ObjectNode item=source(tx.db,"PURCHASE_ITEM");item.putNull("unit_rate");item.putNull("unit_legacy_id");item.put("amount_original",5);
            UUID detail=importRow(tx.db,run,"PURCHASE_ITEM",item);
            assertNull(tx.db.queryForObject("SELECT unit_rate FROM purchase_receipt_items WHERE id=?",Object.class,detail));
            assertNull(tx.db.queryForObject("SELECT unit_id FROM purchase_receipt_items WHERE id=?",Object.class,detail));
            assertEquals("10",tx.db.queryForObject("SELECT trim_scale(amount_local)::text FROM purchase_receipt_items WHERE id=?",String.class,detail));
            ObjectNode sc=source(tx.db,"SUBCONTRACT_HEADER");sc.put("exchange_rate",0);
            importRow(tx.db,run,"SUBCONTRACT_HEADER",sc);
            ObjectNode scItem=source(tx.db,"SUBCONTRACT_ITEM");scItem.put("amount_local",7);scItem.put("amount_original",999);scItem.put("unit_rate",0);
            UUID scDetail=importRow(tx.db,run,"SUBCONTRACT_ITEM",scItem);
            assertNull(tx.db.queryForObject("SELECT amount_original FROM subcontract_receipt_items WHERE id=?",Object.class,scDetail));
            assertEquals("7",tx.db.queryForObject("SELECT trim_scale(amount_local)::text FROM subcontract_receipt_items WHERE id=?",String.class,scDetail));
            assertEquals("0",tx.db.queryForObject("SELECT trim_scale(unit_rate)::text FROM subcontract_receipt_items WHERE id=?",String.class,scDetail));
            tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE");
        }
    }

    @Test void proofCannotAuthorizeDifferentFactsOrNewChildrenOrAReboundNativeReceipt() throws Exception {
        try(Tx tx=tx()) {
            UUID run=context(tx.db);ObjectNode header=source(tx.db,"PURCHASE_HEADER");
            UUID id=importRow(tx.db,run,"PURCHASE_HEADER",header);
            UUID item=importRow(tx.db,run,"PURCHASE_ITEM",source(tx.db,"PURCHASE_ITEM"));
            for(String change:new String[]{"total_original=99","legacy_import_run_id=NULL","consideration_required=true","status=0"})
                rejected(tx,()->tx.db.update("UPDATE purchase_receipts SET "+change+" WHERE id=?",id));
            rejected(tx,()->tx.db.update("UPDATE purchase_receipt_items SET qty=99 WHERE id=?",item));
            rejected(tx,()->tx.db.update("UPDATE purchase_receipt_items SET receipt_id=? WHERE id=?",OLD_HEADER,item));
            rejected(tx,()->tx.db.update("DELETE FROM legacy_procurement_receipt_import_sources WHERE target_id=?",id));
            rejected(tx,()->tx.db.update("INSERT INTO purchase_receipt_items(id,receipt_id,bill_no,bill_date,goods_id,qty) SELECT gen_random_uuid(),?,'forged','2025-01-02',id,1 FROM goods WHERE legacy_id=900102",id));
            ObjectNode changed=source(tx.db,"SUBCONTRACT_HEADER");
            UUID proof=register(tx.db,run,"SUBCONTRACT_HEADER",changed);
            ObjectNode payload=projection(tx.db,"SUBCONTRACT_HEADER",changed);payload.put("id",proof.toString());payload.put("legacy_import_run_id",run.toString());payload.put("total_original",999);
            rejected(tx,()->insert(tx.db,"subcontract_receipts",payload));
            rejected(tx,()->tx.db.update("UPDATE purchase_receipts SET legacy_import_run_id=? WHERE id=?",run,OLD_HEADER));
            rejected(tx,()->tx.db.update("UPDATE purchase_receipt_items SET qty=9 WHERE id=?",OLD_MIXED_ITEM));
            rejected(tx,()->tx.db.update("DELETE FROM purchase_receipt_items WHERE id=?",OLD_MIXED_ITEM));
            rejected(tx,()->tx.db.update("UPDATE purchase_receipt_items SET receipt_id=? WHERE id=?",id,OLD_MIXED_ITEM));
        }
    }

    @Test void sourceCapabilityCannotBeReusedAfterTheImportTransactionCommits() throws Exception {
        String row;
        try(Tx tx=tx()) {
            UUID run=context(tx.db);ObjectNode header=source(tx.db,"PURCHASE_HEADER");
            header.put("legacy_id",995005);header.put("bill_no","SYN-CROSS-TX-RECEIPT");
            UUID id=importRow(tx.db,run,"PURCHASE_HEADER",header);
            row=tx.db.queryForObject("SELECT to_jsonb(receipt)::text FROM purchase_receipts receipt WHERE id=?",String.class,id);
            tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE");tx.connection.commit();
        }
        try(Tx tx=tx()) {
            String saved=row;
            DataAccessException error=rejected(tx,()->tx.db.queryForObject("SELECT fn_assert_legacy_receipt_import_source('purchase_receipts',?::jsonb)",Object.class,saved));
            assertTrue(error.getMessage().contains("exact source proof in this transaction"));
        }
    }

    @Test void newNativeReceiptCannotGuessCapacityFromAnUnknownHistoricalUnit() throws Exception {
        try(Tx tx=tx()) {
            UUID run=context(tx.db),order=UUID.randomUUID(),orderItem=UUID.randomUUID(),nativeHeader=UUID.randomUUID();
            tx.db.update("""
                    INSERT INTO purchase_orders(id,bill_no,bill_date,supplier_id,currency_id,status)
                    SELECT ?,'SYN-UNIT-ORDER','2025-01-02',supplier.id,currency.id,0
                    FROM suppliers supplier CROSS JOIN currencies currency WHERE supplier.legacy_id=900601 AND currency.legacy_id=1
                    """,order);
            tx.db.update("""
                    INSERT INTO purchase_order_items(id,legacy_id,order_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,price,
                        amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                    SELECT ?,994004,?,'SYN-UNIT-ORDER','2025-01-02',id,unit_id,1,100,2.5,250,250,code,name,'LEGACY_IMPORT'
                    FROM goods WHERE legacy_id=900102
                    """,orderItem,order);
            importRow(tx.db,run,"PURCHASE_HEADER",source(tx.db,"PURCHASE_HEADER"));
            ObjectNode old=source(tx.db,"PURCHASE_ITEM");old.put("order_item_legacy_id",994004);old.putNull("unit_rate");old.putNull("unit_legacy_id");
            importRow(tx.db,run,"PURCHASE_ITEM",old);
            tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED");
            tx.db.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,status) VALUES(?,'SYN-NATIVE-UNIT','2025-02-02',0)",nativeHeader);
            DataAccessException denied=rejected(tx,()->tx.db.update("""
                    INSERT INTO purchase_receipt_items(receipt_id,order_item_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty)
                    SELECT ?,?,'SYN-NATIVE-UNIT','2025-02-02',id,unit_id,1,1 FROM goods WHERE legacy_id=900102
                    """,nativeHeader,orderItem));
            assertTrue(denied.getMostSpecificCause().getMessage().contains("review of the original historical unit conversion"),()->denied.getMostSpecificCause().getMessage());
        }
    }

    @Test void forwardOrderProofPreservesExplicitRateAndUnknownBookAmountsAtCommit() throws Exception {
        int identity=996000;
        for(String rate:new String[]{"2.000000",null,"0.000000"}) {
            try(Tx tx=tx()) {
                UUID run=context(tx.db);
                tx.db.update("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,'subcontract_order_m.csv',repeat('f',64),500)",run);
                ObjectNode source=(ObjectNode)new ObjectMapper().readTree(LegacySubcontractSettlementProvenancePostgresTest.source(++identity));
                source.put("total_original",new java.math.BigDecimal("20.0000"));
                java.math.BigDecimal actualRate=rate==null?null:new java.math.BigDecimal(rate);
                if(actualRate==null)source.putNull("exchange_rate");else source.put("exchange_rate",actualRate);
                UUID id=tx.db.queryForObject("SELECT fn_register_legacy_subcontract_order_source(?,?::jsonb)",UUID.class,run,source.toString());
                tx.db.update("""
                        INSERT INTO subcontract_orders(id,legacy_import_run_id,legacy_id,bill_no,bill_date,exchange_rate,
                            tax_rate,total_original,total_local,status,fulfill,is_closed,remark)
                        VALUES(?,?,?,?,'2020-01-02',?,13,?::numeric,fn_legacy_source_book_amount(?::numeric,?::numeric),1,false,false,'history')
                        """,id,run,identity,"SOURCE-"+identity,actualRate,new java.math.BigDecimal("20.0000"),new java.math.BigDecimal("20.0000"),actualRate);
                java.math.BigDecimal recordedRate=tx.db.queryForObject("SELECT exchange_rate FROM subcontract_orders WHERE id=?",java.math.BigDecimal.class,id);
                if(actualRate==null)assertNull(recordedRate);else assertEquals(0,actualRate.compareTo(recordedRate));
                java.math.BigDecimal book=tx.db.queryForObject("SELECT total_local FROM subcontract_orders WHERE id=?",java.math.BigDecimal.class,id);
                if("2.000000".equals(rate))assertEquals(0,new java.math.BigDecimal("40").compareTo(book));else assertNull(book);
                tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE");tx.connection.commit();
            }
        }
    }

    @Test void ordinaryOnlineReceiptStillRequiresFullModernConsiderationAndRuntimeCannotMintProof() throws Exception {
        try(Tx tx=tx()) {
            context(tx.db);
            ObjectNode header=projection(tx.db,"PURCHASE_HEADER",source(tx.db,"PURCHASE_HEADER"));
            UUID id=UUID.randomUUID();header.put("id",id.toString());header.putNull("legacy_id");header.put("bill_no","NATIVE-RECEIPT");
            insert(tx.db,"purchase_receipts",header);
            assertTrue(tx.db.queryForObject("SELECT consideration_required FROM purchase_receipts WHERE id=?",Boolean.class,id));
            rejected(tx,()->tx.db.update("UPDATE purchase_receipts SET consideration_required=false WHERE id=?",id));
            DataAccessException missingParts=rejected(tx,()->{
                tx.db.update("""
                        INSERT INTO purchase_receipt_items(receipt_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,price,
                            amount_original,amount_local,replacement_intent,goods_code_snapshot,goods_name_snapshot,
                            goods_snapshot_source,goods_snapshot_locked_at)
                        SELECT ?,'NATIVE-RECEIPT','2025-01-02',id,unit_id,1,2,3,6,6,'NORMAL',code,name,'MASTER_AT_APPROVAL',now()
                        FROM goods WHERE legacy_id=900102
                        """,id);
                tx.db.execute("SET CONSTRAINTS ALL IMMEDIATE");
            });
            assertTrue(missingParts.getMostSpecificCause().getMessage().contains("receipt consideration quantity or nominal amount is not conserved"),()->missingParts.getMostSpecificCause().getMessage());
        }
        admin.execute("GRANT EXECUTE ON FUNCTION fn_register_legacy_receipt_import_source(uuid,text,jsonb) TO uten");
        try(Tx tx=tx("uten",PASSWORD)) {
            DataAccessException error=rejected(tx,()->register(tx.db,UUID.randomUUID(),"PURCHASE_HEADER",uncheckedSource(admin,"PURCHASE_HEADER")));
            assertTrue(error.getMessage().contains("dedicated migration identity"));
        } finally {admin.execute("REVOKE EXECUTE ON FUNCTION fn_register_legacy_receipt_import_source(uuid,text,jsonb) FROM uten");}
    }

    static ObjectNode source(JdbcTemplate db,String kind) throws Exception {
        String file=db.queryForObject("SELECT source_file FROM fn_legacy_receipt_import_kind(?)",String.class,kind);
        ObjectMapper mapper=new ObjectMapper();ObjectNode result=mapper.createObjectNode();
        db.queryForList("SELECT unnest(source_keys) FROM fn_legacy_receipt_import_kind(?)",String.class,kind).forEach(result::putNull);
        result.setAll((ObjectNode)mapper.readTree(LegacyFinanceImportFixture.source(file)));
        if(kind.endsWith("_ITEM")){result.putNull("order_item_legacy_id");result.putNull("color_legacy_id");}
        return result;
    }
    static ObjectNode uncheckedSource(JdbcTemplate db,String kind){try{return source(db,kind);}catch(Exception e){throw new IllegalStateException(e);}}
    static ObjectNode projection(JdbcTemplate db,String kind,ObjectNode source) throws Exception{return (ObjectNode)new ObjectMapper().readTree(db.queryForObject("SELECT fn_legacy_receipt_source_projection(?,?::jsonb)::text",String.class,kind,source.toString()));}
    static UUID register(JdbcTemplate db,UUID run,String kind,ObjectNode source){return db.queryForObject("SELECT fn_register_legacy_receipt_import_source(?,?,?::jsonb)",UUID.class,run,kind,source.toString());}
    static UUID importRow(JdbcTemplate db,UUID run,String kind,ObjectNode source) throws Exception {
        UUID id=register(db,run,kind,source);ObjectNode payload=projection(db,kind,source);
        payload.put("id",id.toString());payload.put("legacy_import_run_id",run.toString());
        if(kind.endsWith("_ITEM")) {
            UUID goods=UUID.fromString(payload.get("goods_id").asText());
            payload.put("line_no",1);payload.put("goods_code_snapshot",db.queryForObject("SELECT code FROM goods WHERE id=?",String.class,goods));
            payload.put("goods_name_snapshot",db.queryForObject("SELECT name FROM goods WHERE id=?",String.class,goods));
            payload.put("goods_snapshot_source","LEGACY_IMPORT");payload.put("goods_snapshot_locked_at","2025-01-02T00:00:00Z");
        }
        insert(db,db.queryForObject("SELECT target_table FROM fn_legacy_receipt_import_kind(?)",String.class,kind),payload);return id;
    }
    static void insert(JdbcTemplate db,String table,ObjectNode payload) {
        String columns=java.util.stream.StreamSupport.stream(java.util.Spliterators.spliteratorUnknownSize(payload.fieldNames(),0),false).sorted().map(key->'"'+key+'"').collect(java.util.stream.Collectors.joining(","));
        db.update("INSERT INTO public."+table+"("+columns+") SELECT "+columns+" FROM jsonb_populate_record(NULL::public."+table+",?::jsonb)",payload.toString());
    }
    static UUID context(JdbcTemplate db){UUID run=LegacyFinanceImportFixture.context(db);for(String file:new String[]{"purchase_receipts.csv","purchase_receipt_items.csv","subcontract_in_m.csv","subcontract_in_i.csv"})db.update("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,?,repeat('f',64),500)",run,file);return run;}
    static long count(JdbcTemplate db,String table){return db.queryForObject("SELECT count(*) FROM public."+table,Long.class);}
    static String snapshot(JdbcTemplate db,String table,UUID id,boolean after){return db.queryForObject("SELECT (to_jsonb(row)"+(after?"-'legacy_import_run_id'":"")+")::text FROM "+table+" row WHERE id=?",String.class,id);}
    static void migrate(String version){Flyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).target(version).load().migrate();}
    static Tx tx() throws Exception{return tx(PG.getUsername(),PG.getPassword());}
    static Tx tx(String user,String password)throws Exception {Connection c=DriverManager.getConnection(PG.getJdbcUrl(),user,password);c.setAutoCommit(false);return new Tx(c);}
    static final class Tx implements AutoCloseable{final Connection connection;final JdbcTemplate db;Tx(Connection c){connection=c;db=new JdbcTemplate(new SingleConnectionDataSource(c,true));}public void close()throws Exception{connection.rollback();connection.close();}}
    static DataAccessException rejected(Tx tx,Runnable action)throws Exception{var point=tx.connection.setSavepoint();try{return assertThrows(DataAccessException.class,action::run);}finally{tx.connection.rollback(point);}}
}
