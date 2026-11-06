package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.*;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** Real pre-adoption history, full forward migrations and deferred successor proof. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PurchaseReceiptSuccessorQuantityPostgresTest {
    private static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine")
        .withDatabaseName("receipt_quantity_history").withUsername("quantity_fixture")
        .withPassword("anonymous-quantity-only");
    private static Fixture historical;
    private static Fixture historicalNullBasis;
    private static UUID historicalDeletedLine;
    private static final java.util.Map<String,UUID> HISTORICAL_ORDER_ITEMS=new java.util.LinkedHashMap<>();
    private static final java.util.Map<String,String> HISTORICAL_ORDER_FACTS=new java.util.LinkedHashMap<>();
    private static final java.util.concurrent.atomic.AtomicInteger BILL_SEQUENCE=new java.util.concurrent.atomic.AtomicInteger(800000);
    private static final java.util.Map<UUID,String> BILLS=new java.util.concurrent.ConcurrentHashMap<>();
    private static final String QUANTITY_COLUMNS="goods_id,color_id,order_item_id,unit_id,unit_rate,qty,quantity_semantics,gift_qty,"
        +"charged_base_qty,gift_base_qty,replacement_intent,gift_replacement_intent,quantity_adoption_version,quantity_precision_policy,price,amount_original,amount_local";

    @BeforeAll static void migrateHistoricalFacts()throws Exception {
        DB.start();migrate(DB.getDatabaseName(),"1032");
        String original,audit;
        try(var c=connection(DB.getDatabaseName())) {
            historical=seed(c,false,(short)-1);
            historicalNullBasis=seed(c,false,(short)-1,true);
            historicalDeletedLine=UUID.randomUUID();
            execute(c,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,line_no,goods_id,unit_id,unit_rate,qty,charged_base_qty,gift_base_qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source,is_deleted) SELECT ?,bill_no,bill_date,receipt_id,2,goods_id,unit_id,unit_rate,qty,charged_base_qty,gift_base_qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source,true FROM purchase_receipt_items WHERE id=?",historicalDeletedLine,historical.item());
            seedHistoricalOrders(c);
            assertThat(scalar(c,"SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='purchase_receipt_items' AND column_name='quantity_adoption_version'")).isEqualTo("0");
            original=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",historical.item());
            audit=audit(c,historical.item());
        }
        migrate(DB.getDatabaseName(),null);
        try(var c=connection(DB.getDatabaseName())) {
            assertThat(scalar(c,"SELECT unapproval_source_item_id IS NULL FROM purchase_receipt_items WHERE id=?",historical.item())).isEqualTo("t");
            assertThat(scalar(c,"SELECT (to_jsonb(i)-ARRAY['quantity_adoption_version','quantity_precision_policy','unapproval_source_item_id'])::text FROM purchase_receipt_items i WHERE id=?",historical.item())).isEqualTo(original);
            assertThat(scalar(c,"SELECT quantity_adoption_version||':'||(quantity_precision_policy IS NULL) FROM purchase_receipt_items WHERE id=?",historical.item())).isEqualTo("1:true");
            assertThat(audit(c,historical.item())).isEqualTo(audit);
            for(var legacy:HISTORICAL_ORDER_ITEMS.entrySet()){
                assertThat(scalar(c,"SELECT reference_price_precision_policy IS NULL AND unapproval_source_item_id IS NULL FROM "+legacy.getKey()+" WHERE id=?",legacy.getValue())).isEqualTo("t");
                assertThat(scalar(c,"SELECT (to_jsonb(i)-ARRAY['charged_base_qty','gift_base_qty','quantity_adoption_version','quantity_precision_policy','reference_price_precision_policy','unapproval_source_item_id'])::text FROM "+legacy.getKey()+" i WHERE id=?",legacy.getValue()))
                    .isEqualTo(HISTORICAL_ORDER_FACTS.get(legacy.getKey()));
            }
        }
    }
    @AfterAll static void stop(){DB.stop();}

    @ParameterizedTest @ValueSource(booleans={false,true})
    void genuineV1AndV2SuccessorsRetainOriginalAdoptionAndRemainEditable(boolean current)throws Exception {
        try(var c=cloneConnection()) {
            Fixture f=current?seed(c,true,(short)-1):historical;
            String before=quantity(c,f.item()),original=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item());
            c.setAutoCommit(false);UUID draft=draft(c,f),line=copy(c,f,draft,true,null);c.commit();c.setAutoCommit(true);
            assertThat(quantity(c,line)).isEqualTo(before);
            // The historical original includes one deleted detail; its mapping
            // and deferred proof cover exactly the single live detail.
            if(!current)assertThat(scalar(c,"SELECT count(*) FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",draft)).isEqualTo("1");
            assertThat(scalar(c,"SELECT unapproval_source_item_id::text FROM purchase_receipt_items WHERE id=?",line)).isEqualTo(f.item().toString());
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item())).isEqualTo(original);
            assertThatThrownBy(()->execute(c,"UPDATE purchase_receipt_items SET unapproval_source_item_id=NULL WHERE id=?",line))
                .isInstanceOf(SQLException.class).hasMessageContaining("unapproval source identity cannot be replaced");
            UUID unrelated=draft(c,f);
            assertThatThrownBy(()->execute(c,"UPDATE purchase_receipt_items SET receipt_id=? WHERE id=?",unrelated,line))
                .isInstanceOf(SQLException.class).hasMessageContaining("retained record identity cannot move");
            assertThatThrownBy(()->execute(c,"UPDATE purchase_receipt_items SET id=? WHERE id=?",UUID.randomUUID(),line))
                .isInstanceOf(SQLException.class).hasMessageContaining("successor line identity is immutable");
            // A later genuine draft edit freezes a new adoption; it does not
            // rewrite the predecessor or its inherited provenance identity.
            execute(c,"UPDATE purchase_receipt_items SET qty=4,charged_base_qty=4,gift_base_qty=0 WHERE id=?",line);
            assertThat(scalar(c,"SELECT quantity_adoption_version||':'||charged_base_qty FROM purchase_receipt_items WHERE id=?",line)).isEqualTo("2:4");
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item())).isEqualTo(original);
            assertThat(scalar(c,"SELECT unapproval_source_item_id::text FROM purchase_receipt_items WHERE id=?",line)).isEqualTo(f.item().toString());
        }
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void ordinaryCreateCannotSupplyOldVersionOrPolicyWithoutSource(boolean current)throws Exception {
        try(var c=cloneConnection()) {
            Fixture f=current?seed(c,true,(short)-1):historical;UUID draft=draft(c,f);
            assertThatThrownBy(()->copy(c,f,draft,false,null)).isInstanceOf(SQLException.class)
                .hasMessageContaining("new quantity adoption requires the current exact operation proof");
            assertThat(scalar(c,"SELECT count(*) FROM purchase_receipt_items WHERE receipt_id=?",draft)).isEqualTo("0");
        }
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void missingOrWrongLineageRollsBackTheWholeDraftAndAudit(boolean wrongMapping)throws Exception {
        try(var c=cloneConnection()) {
            Fixture f=historical;
            String original=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item());
            String count=scalar(c,"SELECT count(*) FROM purchase_receipts"),audit=scalar(c,"SELECT count(*) FROM audit_log");
            c.setAutoCommit(false);UUID draft=draft(c,f),line=UUID.randomUUID();
            if(wrongMapping)lineage(c,f,draft,UUID.randomUUID());
            assertThatThrownBy(()->copyRow(c,f,draft,line,true,null)).isInstanceOf(SQLException.class)
                .hasMessageContaining("clone lacks its actual same-transaction source lineage");
            c.rollback();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT count(*) FROM purchase_receipts")).isEqualTo(count);
            assertThat(scalar(c,"SELECT count(*) FROM audit_log")).isEqualTo(audit);
            assertThat(scalar(c,"SELECT count(*) FROM document_unapprovals WHERE draft_id=?",draft)).isEqualTo("0");
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item())).isEqualTo(original);
        }
    }

    @Test void falseSourceChangedInputsAndDuplicateSuccessorsAreRejected()throws Exception {
        try(var c=cloneConnection()) {
            Fixture live=seed(c,true,(short)0);UUID liveDraft=draft(c,live);
            c.setAutoCommit(false);
            assertThatThrownBy(()->copy(c,live,liveDraft,true,null)).isInstanceOf(SQLException.class)
                .hasMessageContaining("mutable reversed original and draft successor");
            c.rollback();c.setAutoCommit(true);
            String original=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",historical.item());
            c.setAutoCommit(false);UUID changed=draft(c,historical);
            assertThatThrownBy(()->copy(c,historical,changed,true,"4")).isInstanceOf(SQLException.class)
                .hasMessageContaining("quantity clone differs from its original identity or operands");
            c.rollback();c.setAutoCommit(true);
            c.setAutoCommit(false);UUID first=draft(c,historical),line=copy(c,historical,first,true,null);c.commit();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT unapproval_source_item_id::text FROM purchase_receipt_items WHERE id=?",line)).isEqualTo(historical.item().toString());
            c.setAutoCommit(false);UUID another=draft(c,historical);
            assertThatThrownBy(()->copy(c,historical,another,true,null)).isInstanceOf(SQLException.class)
                .hasMessageContaining("document_unapprovals_original_unique");
            c.rollback();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT count(*) FROM purchase_receipt_items WHERE unapproval_source_item_id=?",historical.item())).isEqualTo("1");
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",historical.item())).isEqualTo(original);
        }
    }

    @Test void softDeletedSourceCannotBeRevivedAsAnInheritedDraft()throws Exception {
        try(var c=cloneConnection()) {
            Fixture deleted=new Fixture(historical.actor(),historical.receipt(),historicalDeletedLine);
            String source=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",historicalDeletedLine);
            c.setAutoCommit(false);UUID draft=draft(c,deleted);
            assertThatThrownBy(()->copy(c,deleted,draft,true,null)).isInstanceOf(SQLException.class)
                .hasMessageContaining("quantity clone differs from its original identity or operands");
            c.rollback();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",historicalDeletedLine)).isEqualTo(source);
            assertThat(scalar(c,"SELECT count(*) FROM purchase_receipt_items WHERE unapproval_source_item_id=?",historicalDeletedLine)).isEqualTo("0");
        }
    }

    @Test void initialCloneCannotBeSoftDeletedToEvadeCompleteMapping()throws Exception {
        try(var c=cloneConnection()) {
            c.setAutoCommit(false);UUID draft=draft(c,historical),line=copy(c,historical,draft,true,null);
            assertThatThrownBy(()->execute(c,"UPDATE purchase_receipt_items SET is_deleted=true WHERE id=?",line))
                .isInstanceOf(SQLException.class).hasMessageContaining("initial successor copy inputs cannot change");
            c.rollback();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT count(*) FROM purchase_receipt_items WHERE id=?",line)).isEqualTo("0");
            assertThat(scalar(c,"SELECT count(*) FROM document_unapprovals WHERE draft_id=?",draft)).isEqualTo("0");
        }
    }

    @Test void provedV1UnknownBasisCopiesOriginalNullsWithoutNativeReadoption()throws Exception {
        try(var c=cloneConnection()) {
            Fixture f=historicalNullBasis;
            String original=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item());
            String before=quantity(c,f.item());c.setAutoCommit(false);
            UUID draft=draft(c,f),line=copy(c,f,draft,true,null);c.commit();c.setAutoCommit(true);
            assertThat(quantity(c,line)).isEqualTo(before);
            assertThat(scalar(c,"SELECT unit_id IS NULL AND unit_rate IS NULL AND quantity_adoption_version=1 AND quantity_precision_policy IS NULL FROM purchase_receipt_items WHERE id=?",line)).isEqualTo("t");
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item())).isEqualTo(original);
            UUID ordinary=draft(c,f);
            assertThatThrownBy(()->copy(c,f,ordinary,false,null)).isInstanceOf(SQLException.class)
                .hasMessageContaining("new quantity adoption requires the current exact operation proof");
            assertThat(scalar(c,"SELECT count(*) FROM purchase_receipt_items WHERE receipt_id=?",ordinary)).isEqualTo("0");
        }
    }

    @Test void inheritedUnknownBasisCannotSilentlySupplyRateOne()throws Exception {
        try(var c=cloneConnection()) {
            Fixture f=historicalNullBasis;
            String original=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item());
            c.setAutoCommit(false);UUID draft=draft(c,f),line=UUID.randomUUID();lineage(c,f,draft,line);
            assertThatThrownBy(()->scalar(c,"SELECT fn_unapproval_source_item('purchase_receipt_items',to_jsonb(i)||jsonb_build_object('id',?::uuid,'receipt_id',?::uuid,'updated_by',?::uuid,'unapproval_source_item_id',?::uuid,'unit_rate',1))::text FROM purchase_receipt_items i WHERE id=?",line,draft,f.actor(),f.item(),f.item()))
                .isInstanceOfSatisfying(SQLException.class,error->assertThat(error.getSQLState()).isEqualTo("55000"))
                .hasMessageContaining("quantity clone differs from its original identity or operands");
            c.rollback();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",f.item())).isEqualTo(original);
            assertThat(scalar(c,"SELECT count(*) FROM document_unapprovals WHERE draft_id=?",draft)).isEqualTo("0");
        }
    }

    @Test void currentV2SourceCannotBorrowTheV1UnknownBasisPath()throws Exception {
        try(var c=cloneConnection()) {
            Fixture f=seed(c,true,(short)-1);
            c.setAutoCommit(false);UUID draft=draft(c,f),line=UUID.randomUUID();lineage(c,f,draft,line);
            assertThatThrownBy(()->scalar(c,"SELECT fn_unapproval_source_item('purchase_receipt_items',to_jsonb(i)||jsonb_build_object('id',?::uuid,'receipt_id',?::uuid,'updated_by',?::uuid,'unapproval_source_item_id',?::uuid,'unit_id',NULL,'unit_rate',NULL))::text FROM purchase_receipt_items i WHERE id=?",line,draft,f.actor(),f.item(),f.item()))
                .isInstanceOfSatisfying(SQLException.class,error->assertThat(error.getSQLState()).isEqualTo("55000"))
                .hasMessageContaining("quantity clone differs from its original identity or operands");
            c.rollback();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT unit_id IS NOT NULL AND unit_rate=1 AND quantity_adoption_version=2 FROM purchase_receipt_items WHERE id=?",f.item())).isEqualTo("t");
            assertThat(scalar(c,"SELECT count(*) FROM document_unapprovals WHERE draft_id=?",draft)).isEqualTo("0");
            UUID ordinary=draft(c,f);
            assertThatThrownBy(()->execute(c,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,line_no,goods_id,unit_id,unit_rate,qty,charged_base_qty,gift_base_qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source) SELECT ?,?,bill_date,?,1,goods_id,NULL,NULL,qty,charged_base_qty,gift_base_qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source FROM purchase_receipt_items WHERE id=?",UUID.randomUUID(),bill(ordinary),ordinary,f.item()))
                .isInstanceOf(SQLException.class).hasMessageContaining("quantity adoption requires its actual positive unit rate and original unit");
            assertThat(scalar(c,"SELECT count(*) FROM purchase_receipt_items WHERE receipt_id=?",ordinary)).isEqualTo("0");
        }
    }

    @ParameterizedTest @ValueSource(strings={"purchase_order_items","subcontract_order_items","purchase_receipt_items","subcontract_receipt_items"})
    void fourUnitPriceGuardsUseThePublicFortyIntegerTwentyFourFractionDomain(String table)throws Exception {
        try(var c=cloneConnection()) {
            String header=table.replace("_items","s"),parent=table.contains("order_items")?"order_id":"receipt_id";
            UUID draft=UUID.randomUUID(),line=UUID.randomUUID();
            String prefix=switch(header){case "purchase_orders"->"CD";case "subcontract_orders"->"EO";case "purchase_receipts"->"CJ";case "subcontract_receipts"->"EJ";default->throw new IllegalArgumentException(header);};
            String bill=number(prefix);
            execute(c,"INSERT INTO "+header+"(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,total_original,total_local,status) SELECT ?,?,bill_date,supplier_id,warehouse_id,currency_id,1,0,0,0 FROM purchase_receipts WHERE id=?",draft,bill,historical.receipt());
            boolean purchase=table.startsWith("purchase_");
            execute(c,"INSERT INTO "+table+"(id,bill_no,bill_date,"+parent+",line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_snapshot_source"+(purchase?",charged_base_qty,gift_base_qty":"")+") SELECT ?,?,bill_date,?,1,goods_id,unit_id,1,1,0,0,0,'MASTER_AT_SAVE'"+(purchase?",1,0":"")+" FROM purchase_receipt_items WHERE id=?",line,bill,draft,historical.item());
            String original=scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",historical.item());
            for(String value:new String[]{"9999999999999999999999999999999999999999.123456789012345678901234","0.000000000000000000000001","1.230000000000000000000000000000"}) {
                execute(c,"UPDATE "+table+" SET price=?::numeric,amount_original=?::numeric,amount_local=?::numeric WHERE id=?",value,value,value,line);
                execute(c,"UPDATE "+header+" SET total_original=?::numeric,total_local=?::numeric WHERE id=?",value,value,draft);
                assertThat(new java.math.BigDecimal(scalar(c,"SELECT price::text FROM "+table+" WHERE id=?",line)))
                    .isEqualByComparingTo(value);
            }
            String before=scalar(c,"SELECT to_jsonb(i)::text FROM "+table+" i WHERE id=?",line);
            String headerBefore=scalar(c,"SELECT to_jsonb(h)::text FROM "+header+" h WHERE id=?",draft);
            for(String invalid:new String[]{"1e40","0.0000000000000000000000001","NaN","Infinity","-Infinity"}) {
                c.setAutoCommit(false);
                execute(c,"UPDATE "+header+" SET remark='must roll back with invalid unit price' WHERE id=?",draft);
                var failure=catchThrowable(()->execute(c,"UPDATE "+table+" SET price=?::numeric WHERE id=?",invalid,line));
                assertThat(failure).isInstanceOf(org.postgresql.util.PSQLException.class);
                var sql=(org.postgresql.util.PSQLException)failure;
                assertThat(sql.getSQLState()).isEqualTo("23514");
                String constraint=java.util.Objects.requireNonNull(sql.getServerErrorMessage()).getConstraint();
                c.rollback();c.setAutoCommit(true);
                assertThat(scalar(c,"SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid=?::regclass AND conname=?",table,constraint))
                    .contains("fn_financial_amount_is_exact(price)");
                assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM "+table+" i WHERE id=?",line)).isEqualTo(before);
                assertThat(scalar(c,"SELECT to_jsonb(h)::text FROM "+header+" h WHERE id=?",draft)).isEqualTo(headerBefore);
            }
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM purchase_receipt_items i WHERE id=?",historical.item())).isEqualTo(original);
        }
    }

    @ParameterizedTest @ValueSource(strings={"purchase_order_items","subcontract_order_items"})
    void migratedTenPlaceReferenceFactsKeepNullProofWithoutGuessingANewChoice(String table)throws Exception {
        try(var c=cloneConnection()){
            UUID item=HISTORICAL_ORDER_ITEMS.get(table);
            assertThat(scalar(c,"SELECT reference_price_precision_policy::text FROM "+table+" WHERE id=?",item)).isNull();
            assertThat(scalar(c,"SELECT CASE WHEN fn_procurement_reference_price_matches(to_jsonb(i)) THEN 1 ELSE 0 END FROM "+table+" i WHERE id=?",item)).isEqualTo("1");
            assertThat(scalar(c,"SELECT price::text FROM "+table+" WHERE id=?",item)).isEqualTo("3.3744855963");
            assertThat(scalar(c,"SELECT CASE WHEN fn_procurement_reference_price_matches(to_jsonb(i)||jsonb_build_object('price',3.374485596366666666666666::numeric)) THEN 1 ELSE 0 END FROM "+table+" i WHERE id=?",item)).isEqualTo("0");
        }
    }

    @ParameterizedTest @ValueSource(strings={"purchase_order_items","subcontract_order_items"})
    void inheritedLegacyReferenceStillRequiresItsRealPermanentLineMapping(String table)throws Exception {
        try(var c=cloneConnection()){
            UUID source=HISTORICAL_ORDER_ITEMS.get(table);String header=table.replace("_items","s");
            String before=scalar(c,"SELECT to_jsonb(i)::text FROM "+table+" i WHERE id=?",source);
            String count=scalar(c,"SELECT count(*) FROM "+header);c.setAutoCommit(false);
            UUID draft=orderDraft(c,table,source);
            assertThatThrownBy(()->orderCopy(c,table,source,draft,true)).isInstanceOf(SQLException.class)
                .hasMessageContaining("clone lacks its actual same-transaction source lineage");
            c.rollback();c.setAutoCommit(true);
            assertThat(scalar(c,"SELECT count(*) FROM "+header)).isEqualTo(count);
            assertThat(scalar(c,"SELECT to_jsonb(i)::text FROM "+table+" i WHERE id=?",source)).isEqualTo(before);
        }
    }

    @ParameterizedTest @ValueSource(strings={"purchase_order_items","subcontract_order_items"})
    void ordinaryNewReferenceCannotBorrowHistoricalNullWithoutASource(String table)throws Exception {
        try(var c=cloneConnection()){
            UUID source=HISTORICAL_ORDER_ITEMS.get(table),draft=orderDraft(c,table,source);
            assertThatThrownBy(()->orderCopy(c,table,source,draft,false)).isInstanceOf(SQLException.class)
                .hasMessageContaining("actual current explicit choice");
            assertThat(scalar(c,"SELECT count(*) FROM "+table+" WHERE order_id=?",draft)).isEqualTo("0");
        }
    }

    private static void seedHistoricalOrders(Connection c)throws SQLException {
        for(String table:new String[]{"purchase_order_items","subcontract_order_items"}){
            String header=table.replace("_items","s"),prefix=table.startsWith("purchase")?"CD":"EO";
            UUID id=UUID.randomUUID(),item=UUID.randomUUID();String bill=number(prefix);
            execute(c,"INSERT INTO "+header+"(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,tax_rate,total_original,total_local,status,created_by,updated_by) SELECT ?,?,bill_date,supplier_id,warehouse_id,currency_id,1,0,10.1234567891,10.1234567891,-1,?,? FROM purchase_receipts WHERE id=?",id,bill,historical.actor(),historical.actor(),historical.receipt());
            execute(c,"INSERT INTO "+table+"(id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,unit_rate,qty,price,total_amount_input,amount_original,amount_local,goods_snapshot_source) SELECT ?,?,bill_date,?,1,goods_id,unit_id,1,3,3.3744855963,10.1234567891,10.1234567891,10.1234567891,'MASTER_AT_SAVE' FROM purchase_receipt_items WHERE id=?",item,bill,id,historical.item());
            HISTORICAL_ORDER_ITEMS.put(table,item);
            HISTORICAL_ORDER_FACTS.put(table,scalar(c,"SELECT to_jsonb(i)::text FROM "+table+" i WHERE id=?",item));
        }
    }
    private static UUID orderDraft(Connection c,String table,UUID source)throws SQLException {
        String header=table.replace("_items","s"),prefix=table.startsWith("purchase")?"CD":"EO";UUID id=UUID.randomUUID();String bill=number(prefix);BILLS.put(id,bill);
        execute(c,"INSERT INTO "+header+"(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,tax_rate,total_original,total_local,status,created_by,updated_by) SELECT ?,?,h.bill_date,h.supplier_id,h.warehouse_id,h.currency_id,h.exchange_rate,h.tax_rate,h.total_original,h.total_local,0,?,? FROM "+table+" i JOIN "+header+" h ON h.id=i.order_id WHERE i.id=?",id,bill,historical.actor(),historical.actor(),source);return id;
    }
    private static UUID orderCopy(Connection c,String table,UUID source,UUID draft,boolean inherited)throws SQLException {
        UUID line=UUID.randomUUID();String columns="goods_id,color_id,unit_id,unit_rate,qty,price,total_amount_input,amount_original,amount_local,extra_columns,reference_price_precision_policy";
        if(table.startsWith("purchase")){
            columns+=",quantity_semantics,gift_qty";
            if(inherited)columns+=",charged_base_qty,gift_base_qty,quantity_adoption_version,quantity_precision_policy";
        }
        execute(c,"INSERT INTO "+table+"(id,bill_no,bill_date,order_id,line_no,goods_snapshot_source,"+columns+(inherited?",unapproval_source_item_id":"")+") SELECT ?,?,bill_date,?,1,goods_snapshot_source,"+columns+(inherited?",id":"")+" FROM "+table+" WHERE id=?",line,BILLS.get(draft),draft,source);return line;
    }

    private static Fixture seed(Connection c,boolean current,short state)throws SQLException {return seed(c,current,state,false);}
    private static Fixture seed(Connection c,boolean current,short state,boolean nullBasis)throws SQLException {
        UUID actor=UUID.randomUUID(),employee=UUID.randomUUID(),supplier=UUID.randomUUID(),warehouse=UUID.randomUUID(),unit=UUID.randomUUID(),goods=UUID.randomUUID(),receipt=UUID.randomUUID(),item=UUID.randomUUID();
        execute(c,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),DATE '2026-01-01','active','regular')",employee,"QTY-"+employee,"匿名数量继任员工-"+employee);
        execute(c,"INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status)VALUES(?,?,?,'test-not-used',false,'active')",actor,employee,"quantity-"+actor);
        execute(c,"INSERT INTO suppliers(id,code,name,status,code_sequence)VALUES(?,?,'匿名数量继任供应商','使用',(SELECT coalesce(max(code_sequence),0)+1 FROM suppliers))",supplier,"QTY-"+supplier);
        execute(c,"INSERT INTO warehouses(id,code,name)VALUES(?,?,'匿名数量继任仓')",warehouse,"QTY-"+warehouse);
        execute(c,"INSERT INTO units(id,code,name)VALUES(?,?,'匿名数量继任单位')",unit,"QTY-"+unit);
        execute(c,"INSERT INTO goods(id,code,name,unit_id,code_sequence)VALUES(?,?,'匿名数量继任物料',?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",goods,"QTY-"+goods,unit);
        execute(c,"INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,total_original,total_local,status,created_by,updated_by) VALUES(?,?,DATE '2026-09-23',?,?,(SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted LIMIT 1),1,41.010803125,41.010803125,?,?,?)",receipt,bill(receipt),supplier,warehouse,state,actor,actor);
        execute(c,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,line_no,goods_id,unit_id,unit_rate,qty,charged_base_qty,gift_base_qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source) VALUES(?,?,DATE '2026-09-23',?,1,?,?,?,3.125,3.125,0,13.123457,41.010803125,41.010803125,'NORMAL','MASTER_AT_SAVE')",item,bill(receipt),receipt,goods,nullBasis?null:unit,nullBasis?null:java.math.BigDecimal.ONE);
        if(current)assertThat(scalar(c,"SELECT quantity_adoption_version FROM purchase_receipt_items WHERE id=?",item)).isEqualTo("2");
        return new Fixture(actor,receipt,item);
    }
    private static UUID draft(Connection c,Fixture f)throws SQLException {
        UUID id=UUID.randomUUID();
        execute(c,"INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,total_original,total_local,status,created_by,updated_by) SELECT ?,?,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,total_original,total_local,0,?,? FROM purchase_receipts WHERE id=?",id,bill(id),f.actor(),f.actor(),f.receipt());
        return id;
    }
    private static UUID copy(Connection c,Fixture f,UUID draft,boolean source,String changedQty)throws SQLException {
        UUID id=UUID.randomUUID();
        if(source)lineage(c,f,draft,id);
        copyRow(c,f,draft,id,source,changedQty);return id;
    }
    private static void copyRow(Connection c,Fixture f,UUID draft,UUID id,boolean source,String changedQty)throws SQLException {
        String columns=QUANTITY_COLUMNS;
        String values=java.util.Arrays.stream(columns.split(",")).map(name->name.equals("qty")&&changedQty!=null?changedQty:"source."+name).collect(java.util.stream.Collectors.joining(","));
        execute(c,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,line_no,goods_snapshot_source,updated_by,"+columns+(source?",unapproval_source_item_id":"")+") SELECT ?,?,source.bill_date,?,1,source.goods_snapshot_source,?,"+values+(source?",source.id":"")+" FROM purchase_receipt_items source WHERE source.id=?",id,bill(draft),draft,f.actor(),f.item());
    }
    private static void lineage(Connection c,Fixture f,UUID draft,UUID line)throws SQLException {
        execute(c,"INSERT INTO document_unapprovals(family,original_id,draft_id,draft_bill_no,request_key,reason,line_id_map,created_by)VALUES('purchaseReceipt',?,?,?,?,'匿名继任采用核对',jsonb_build_object(?::text,?::text),?)",f.receipt(),draft,bill(draft),"quantity-"+UUID.randomUUID(),f.item(),line,f.actor());
    }
    private static String quantity(Connection c,UUID item)throws SQLException {
        return scalar(c,"SELECT to_jsonb(q)::text FROM (SELECT "+QUANTITY_COLUMNS+" FROM purchase_receipt_items WHERE id=?)q",item);
    }
    private static String audit(Connection c,UUID item)throws SQLException {
        return scalar(c,"SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY id),'[]')::text FROM audit_log a WHERE target_type='purchase_receipt_items' AND target_id=?",item.toString());
    }
    private static void migrate(String name,String target) {
        var config=TestFlyway.configure().dataSource(url(name),DB.getUsername(),DB.getPassword()).locations("classpath:db/migration").cleanDisabled(true);
        if(target!=null)config.target(target);config.load().migrate();
    }
    private static Connection cloneConnection()throws SQLException {
        String name="receipt_successor_"+UUID.randomUUID().toString().replace("-","");
        try(var c=connection("postgres");var statement=c.createStatement()) {
            statement.execute("CREATE DATABASE "+name+" TEMPLATE "+DB.getDatabaseName());
        }
        return connection(name);
    }
    private static String url(String name){return DB.getJdbcUrl().replace("/"+DB.getDatabaseName(),"/"+name);}
    private static String bill(UUID id){return BILLS.computeIfAbsent(id,unused->number("CJ"));}
    private static String number(String prefix){int next=BILL_SEQUENCE.incrementAndGet();if(next>999999)throw new IllegalStateException("Anonymous fixture document sequence exhausted");return prefix+"20260923"+"%06d".formatted(next);}
    private static Connection connection(String name)throws SQLException{return DriverManager.getConnection(url(name),DB.getUsername(),DB.getPassword());}
    private static void execute(Connection c,String sql,Object...args)throws SQLException {
        try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);s.executeUpdate();}
    }
    private static String scalar(Connection c,String sql,Object...args)throws SQLException {
        try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);try(var r=s.executeQuery()){assertThat(r.next()).isTrue();return r.getString(1);}}
    }
    private record Fixture(UUID actor,UUID receipt,UUID item) { }
}
