package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Runs the real V860 views and actual reader against isolated PostgreSQL, not SQL string mocks. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsPriceSourcePostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    private GoodsPriceSourceReader reader;
    private UUID goods,unit,currency,supplier,owner;
    @BeforeAll static void start(){PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));}
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void schema() throws Exception {
        db.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        db.execute("CREATE TABLE goods(id uuid PRIMARY KEY,code text,name text,unit_id uuid,color_id uuid,is_deleted boolean DEFAULT false,auto_created boolean DEFAULT false)");
        for(String table:List.of("units","currencies","suppliers","colors"))db.execute("CREATE TABLE "+table+"(id uuid PRIMARY KEY,name text)");
        db.execute("CREATE TABLE clients(id uuid PRIMARY KEY,name text,owner_employee_id uuid)");
        for(String kind:List.of("purchase","subcontract","sales")){
            db.execute("CREATE TABLE "+kind+"_orders(id uuid PRIMARY KEY,bill_no text,bill_date date,updated_at timestamptz DEFAULT now(),supplier_id uuid,client_id uuid,currency_id uuid,tax_rate numeric,exchange_rate numeric,purchaser_id uuid,maker_id uuid,owner_employee_id uuid,status smallint DEFAULT 1,is_deleted boolean DEFAULT false,approved_at timestamptz DEFAULT now())");
            db.execute("CREATE TABLE "+kind+"_order_items(id uuid PRIMARY KEY,order_id uuid,goods_id uuid,goods_code_snapshot text DEFAULT 'FROZEN-CODE',goods_name_snapshot text DEFAULT 'Frozen item',color_id uuid,unit_id uuid,unit_rate numeric DEFAULT 1,qty numeric,price numeric,amount_original numeric,total_amount_input numeric,gift_qty numeric DEFAULT 0,discount numeric DEFAULT 0,extra_columns jsonb DEFAULT '[]',updated_at timestamptz DEFAULT now(),is_deleted boolean DEFAULT false,chain_status smallint DEFAULT 0)");
        }
        db.execute("CREATE TABLE procurement_order_approval_cases(id uuid PRIMARY KEY,order_type text,order_id uuid,status text,attempt integer,finance_exchange_rate numeric,finance_total_local numeric,submission_snapshot jsonb,display_snapshot jsonb,decided_at timestamptz DEFAULT now())");
        db.execute("CREATE TABLE procurement_order_approval_events(case_id uuid,event_type text)");
        db.execute("CREATE TABLE sales_quotes(id uuid PRIMARY KEY,bill_no text,maker_id uuid)");
        db.execute("CREATE TABLE sales_quote_revision_logs(id uuid PRIMARY KEY,quote_id uuid,action text,snapshot jsonb,created_at timestamptz DEFAULT now())");
        db.execute("CREATE TABLE permissions(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,code text UNIQUE,name text,module text,category text,sort_order integer,action_type text,description text,grant_policy text[],sensitivity text)");
        db.execute("CREATE TABLE permission_surfaces(id uuid PRIMARY KEY,surface_key text,enabled boolean)");
        db.execute("CREATE TABLE permission_surface_permissions(surface_id uuid,permission_id uuid,UNIQUE(surface_id,permission_id))");
        db.execute("CREATE TABLE departments(id uuid PRIMARY KEY,code text,is_deleted boolean DEFAULT false)");
        db.execute("CREATE TABLE department_permissions(department_id uuid,permission_id uuid,UNIQUE(department_id,permission_id))");
        try(var in=getClass().getResourceAsStream("/db/migration/V860__goods_price_analysis.sql")){db.execute(new String(Objects.requireNonNull(in).readAllBytes(),StandardCharsets.UTF_8));}
        var clients=mock(ClientAccessPolicy.class);when(clients.nativeReadScope(anyString(),any())).thenReturn(new ClientAccessPolicy.NativeReadScope("1=1",null,Set.of(),null,null));
        reader=new GoodsPriceSourceReader(new NamedParameterJdbcTemplate(db),json,clients,mock(GoodsPriceAccess.class));
        goods=UUID.randomUUID();unit=UUID.randomUUID();currency=UUID.randomUUID();supplier=UUID.randomUUID();owner=UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'NOW','Current name',?)",goods,unit);
        db.update("INSERT INTO units VALUES(?,'件')",unit);db.update("INSERT INTO currencies VALUES(?,'CNY')",currency);db.update("INSERT INTO suppliers VALUES(?,'Supplier')",supplier);
    }
    @Test void ownerFilterRunsBeforeLimitAndNullOwnerIsNotPublic(){
        var own=order("purchase",owner,"10","1");var hidden=order("purchase",UUID.randomUUID(),"999","1");
        db.update("UPDATE purchase_orders SET purchaser_id=? WHERE id=?",owner,hidden[0]);
        order("purchase",null,"888","1");
        var rows=read(scope(owner)).observations();assertThat(rows).hasSize(1);assertThat(rows.getFirst().sourceId()).isEqualTo(own[0]);
    }
    @Test void currencyTaxColorAndFrozenUnitRateNeverMix(){
        var valid=order("purchase",owner,"10","1");
        var rate=order("purchase",owner,"1","1");db.update("UPDATE purchase_order_items SET unit_rate=24 WHERE id=?",rate[1]);
        var tax=order("purchase",owner,"2","1");db.update("UPDATE purchase_orders SET tax_rate=13 WHERE id=?",tax[0]);
        var fx=order("purchase",owner,"3","1");db.update("UPDATE purchase_orders SET currency_id=? WHERE id=?",UUID.randomUUID(),fx[0]);
        var color=order("purchase",owner,"4","1");db.update("UPDATE purchase_order_items SET color_id=? WHERE id=?",UUID.randomUUID(),color[1]);
        assertThat(read(scope(owner)).observations()).extracting(Observation::sourceItemId).containsExactly(valid[1]);
    }
    @Test void exactTotalAndFinancialCaseRateWinOverDisplayPriceAndOrderRate() throws Exception {
        var ids=order("purchase",owner,"0.6666666667","3");
        db.update("UPDATE purchase_order_items SET amount_original=2,total_amount_input=2 WHERE id=?",ids[1]);
        UUID approved=approve(ids,1,"APPROVED");
        var row=read(scope(owner)).observations().getFirst();
        assertThat(row.comparable()).isTrue();assertThat(new BigDecimal(row.unitPrice())).isEqualByComparingTo(new BigDecimal("2").divide(new BigDecimal("3"),java.math.MathContext.DECIMAL128));
        assertThat(row.exchangeRateToLocal()).isEqualTo("7");assertThat(row.financeApprovalCaseId()).isEqualTo(approved);
    }
    @Test void pendingQuantityReviewNeverUsesOldApprovalForNewQuantity() throws Exception {
        var ids=order("purchase",owner,"10","1");approve(ids,1,"APPROVED");
        db.update("UPDATE purchase_order_items SET qty=2,amount_original=20 WHERE id=?",ids[1]);approve(ids,2,"PENDING");
        var row=read(scope(owner)).observations().getFirst();assertThat(row.comparable()).isFalse();assertThat(row.reasonCodes()).contains("FINANCE_REVIEW_NOT_APPROVED");
        var history=history(scope(owner),null,10);assertThat(history.observations()).hasSize(2);
        assertThat(history.observations()).anySatisfy(old->{assertThat(old.lifecycle()).isEqualTo("SUPERSEDED_APPROVED_VERSION");assertThat(old.quantity()).isEqualTo("1");assertThat(old.comparable()).isFalse();});
    }
    @Test void reverseAndHandoverPreserveHistoryButRevokeOldOwnersAccess() throws Exception {
        var ids=order("purchase",owner,"10","1");UUID approved=approve(ids,1,"APPROVED");
        assertThat(history(scope(owner),null,10).observations()).hasSize(1); // current case is not duplicated
        UUID recipient=UUID.randomUUID();db.update("UPDATE purchase_orders SET status=-1,is_deleted=true,maker_id=? WHERE id=?",recipient,ids[0]);
        assertThat(read(scope(recipient)).observations()).isEmpty();assertThat(history(scope(owner),null,10).observations()).isEmpty();
        var archived=history(scope(recipient),null,10).observations().getFirst();assertThat(archived.historyVersionId()).isEqualTo(approved);
        assertThat(archived.lifecycle()).isEqualTo("SOURCE_DELETED");assertThat(archived.canOpenSource()).isFalse();assertThat(archived.goodsNameSnapshot()).isEqualTo("Approved name");
    }
    @Test void allVersionsAreReachableWithKeysetPagination() throws Exception {
        var ids=order("purchase",owner,"10","1");approve(ids,1,"APPROVED");
        db.update("UPDATE purchase_order_items SET qty=2,amount_original=20 WHERE id=?",ids[1]);approve(ids,2,"APPROVED");
        var first=history(scope(owner),null,1);assertThat(first.hasMore()).isTrue();
        var second=history(scope(owner),first.nextCursor(),1);assertThat(second.hasMore()).isFalse();
        assertThat(first.observations().getFirst().historyVersionId()).isNotEqualTo(second.observations().getFirst().historyVersionId());
    }
    @Test void deletedUnknownLabelsAreNeverFilledFromCurrentMaster() throws Exception {
        var ids=order("purchase",owner,"10","1");UUID approved=approve(ids,1,"APPROVED");
        db.update("UPDATE procurement_order_approval_cases SET display_snapshot=NULL WHERE id=?",approved);db.update("UPDATE purchase_orders SET status=-1 WHERE id=?",ids[0]);
        var old=history(scope(owner),null,5).observations().getFirst();assertThat(old.goodsNameSnapshot()).isNull();assertThat(old.reasonCodes()).contains("SOURCE_IDENTITY_INCOMPLETE");
    }
    @Test void giftsAndUndividedFeesAreNotUnitPriceEvidence(){
        var gift=order("purchase",owner,"10","1");db.update("UPDATE purchase_order_items SET gift_qty=1 WHERE id=?",gift[1]);
        var fee=order("purchase",owner,"10","1");db.update("UPDATE purchase_order_items SET extra_columns='[{\"operation\":\"ADD\",\"value\":5}]',amount_original=15 WHERE id=?",fee[1]);
        assertThat(read(scope(owner)).observations()).allMatch(o->!o.comparable());
    }
    @Test void aSourceLimitIsReportedInsteadOfPublishingTruncatedStatistics(){
        var ids=order("purchase",owner,"10","1");
        db.update("INSERT INTO purchase_order_items(id,order_id,goods_id,unit_id,qty,price,amount_original) SELECT gen_random_uuid(),?,?,?,1,10,10 FROM generate_series(1,500)",ids[0],goods,unit);
        var data=read(scope(owner));assertThat(data.complete()).isFalse();assertThat(data.observations()).hasSize(500);
    }
    private GoodsPriceSourceReader.Data read(OwnerVisibility.OwnerScope scope){return reader.read(query(),reader.goods(goods),180,scope);}
    private History history(OwnerVisibility.OwnerScope scope,String cursor,int size){return reader.history(new HistoryQuery(query(),null,null,cursor,size),scope,false,true);}
    @Test void explicitNullColorDoesNotFallBackToCurrentMasterColor(){
        UUID red=UUID.randomUUID();db.update("UPDATE goods SET color_id=? WHERE id=?",red,goods);
        var plain=order("purchase",owner,"10","1");var coloured=order("purchase",owner,"99","1");
        db.update("UPDATE purchase_order_items SET color_id=? WHERE id=?",red,coloured[1]);
        assertThat(read(scope(owner)).observations()).extracting(Observation::sourceItemId).containsExactly(plain[1]);
    }
    @Test void financeQuoteScopeIncludesOtherOwnersAndDeletedClientsWithoutOpeningTheirOrders() throws Exception {
        UUID other=UUID.randomUUID(),client=UUID.randomUUID(),quote=UUID.randomUUID(),log=UUID.randomUUID();
        db.update("INSERT INTO clients VALUES(?,'Current client',?)",client,other);
        var sale=order("sales",other,"999","1");db.update("UPDATE sales_orders SET owner_employee_id=?,client_id=? WHERE id=?",other,client,sale[0]);
        db.update("INSERT INTO sales_quotes VALUES(?,'Q-HISTORY',?)",quote,other);
        Map<String,Object> line=Map.of("id",UUID.randomUUID(),"goodsId",goods,"goodsCode","OLD","goodsName","Quote original","unitId",unit,"unitRate","1","qty","1","price","15","amount","15");
        Map<String,Object> snapshot=Map.of("billDate",BusinessTime.today(),"clientId",client,"clientName","Frozen client","currencyId",currency,"lines",List.of(line));
        db.update("INSERT INTO sales_quote_revision_logs(id,quote_id,action,snapshot) VALUES(?,?,'CONFIRM',?::jsonb)",log,quote,json.writeValueAsString(snapshot));
        // Historical finance authority remains usable when today's client row is absent.
        db.update("DELETE FROM clients WHERE id=?",client);
        Query sales=new Query(goods,Kind.SALES,180,null,null,null,null,null,null,null,null,null,null,null);
        var request=new HistoryQuery(sales,null,null,null,20);
        assertThat(reader.history(request,scope(owner),true,true).observations()).extracting(Observation::sourceType).containsExactly("SALES_QUOTE_CONFIRMED");
        assertThat(reader.history(request,scope(owner),true,false).observations()).extracting(Observation::partnerName).containsExactly("Frozen client");
        assertThat(reader.history(request,scope(owner),false,true).observations()).isEmpty();
    }
    private Query query(){return new Query(goods,Kind.PURCHASE,180,null,null,unit,currency,"0",null,null,null,null,null,"1");}
    private static OwnerVisibility.OwnerScope scope(UUID owner){return new OwnerVisibility.OwnerScope(false,Set.of(owner));}
    private UUID[] order(String kind,UUID maker,String price,String qty){
        UUID id=UUID.randomUUID(),item=UUID.randomUUID();
        db.update("INSERT INTO "+kind+"_orders(id,bill_no,bill_date,supplier_id,currency_id,tax_rate,exchange_rate,maker_id) VALUES(?,? ,?,?,?,0,1,?)",id,"ORD-"+id,BusinessTime.today(),supplier,currency,maker);
        db.update("INSERT INTO "+kind+"_order_items(id,order_id,goods_id,unit_id,qty,price,amount_original) VALUES(?,?,?,?,?,?,?)",item,id,goods,unit,new BigDecimal(qty),new BigDecimal(price),new BigDecimal(qty).multiply(new BigDecimal(price)));
        return new UUID[]{id,item};
    }
    private UUID approve(UUID[] ids,int attempt,String state) throws Exception {
        var line=db.queryForMap("SELECT * FROM purchase_order_items WHERE id=?",ids[1]);
        Map<String,Object> item=new HashMap<>();item.put("itemId",ids[1]);item.put("goodsId",goods);item.put("unitId",unit);item.put("unitRate",line.get("unit_rate"));
        item.put("qty",line.get("qty"));item.put("price",line.get("price"));item.put("amountOriginal",line.get("amount_original"));item.put("totalAmountInput",line.get("total_amount_input"));
        Map<String,Object> snapshot=new HashMap<>();snapshot.put("orderId",ids[0]);snapshot.put("billNo","IMMUTABLE");snapshot.put("billDate",BusinessTime.today());
        snapshot.put("supplierId",supplier);snapshot.put("currencyId",currency);snapshot.put("taxRate","0");snapshot.put("exchangeRate","1");snapshot.put("makerEmployeeId",owner);snapshot.put("items",List.of(item));
        Map<String,Object> display=new HashMap<>(item);display.put("goodsCode","APPROVED");display.put("goodsName","Approved name");display.put("unitName","件");
        UUID id=UUID.randomUUID();db.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,status,attempt,finance_exchange_rate,finance_total_local,submission_snapshot,display_snapshot) VALUES(?,'PURCHASE',?,?,?,7,70,?::jsonb,?::jsonb)",id,ids[0],state,attempt,json.writeValueAsString(snapshot),json.writeValueAsString(Map.of("items",List.of(display),"currencyName","CNY","supplierName","Approved supplier")));
        if(state.equals("APPROVED"))db.update("INSERT INTO procurement_order_approval_events VALUES(?,'APPROVED')",id);return id;
    }
}
