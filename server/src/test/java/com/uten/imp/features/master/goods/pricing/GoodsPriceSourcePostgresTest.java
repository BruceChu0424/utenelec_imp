package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
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
        GoodsPriceProjectionFixture.history(db,"FROZEN-CODE");
        try(var in=getClass().getResourceAsStream("/db/migration/V860__goods_price_analysis.sql")){db.execute(new String(Objects.requireNonNull(in).readAllBytes(),StandardCharsets.UTF_8));}
        var clients=mock(ClientAccessPolicy.class);when(clients.nativeReadScope(anyString(),any())).thenReturn(new ClientAccessPolicy.NativeReadScope("1=1",null,Set.of(),null,null));
        reader=new GoodsPriceSourceReader(new NamedParameterJdbcTemplate(db),json,clients,mock(GoodsPriceAccess.class));
        goods=UUID.randomUUID();unit=UUID.randomUUID();currency=UUID.randomUUID();supplier=UUID.randomUUID();owner=UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'NOW','Current name',?)",goods,unit);
        db.update("INSERT INTO units(id,name) VALUES(?,'件')",unit);db.update("INSERT INTO currencies(id,name) VALUES(?,'CNY')",currency);db.update("INSERT INTO suppliers(id,name) VALUES(?,'Supplier')",supplier);
    }
    @Test void ownerFilterRunsBeforeLimitAndNullOwnerIsNotPublic(){
        var own=order("purchase",owner,"10","1");var hidden=order("purchase",UUID.randomUUID(),"999","1");
        db.update("UPDATE purchase_orders SET purchaser_id=? WHERE id=?",owner,hidden[0]);
        order("purchase",null,"888","1");
        var rows=read(scope(owner)).observations();assertThat(rows).hasSize(1);assertThat(rows.getFirst().sourceId()).isEqualTo(own[0]);
    }
    @ParameterizedTest
    @CsvSource({"12345678901234.0001,1","1,0.123456789012345678"})
    void numericApprovalSnapshotKeepsFullQuantityAndPricePrecision(String quantity,String price) throws Exception {
        var ids=order("purchase",owner,price,quantity);UUID approval=approve(ids,1,"APPROVED");
        BigDecimal original=new BigDecimal(quantity).multiply(new BigDecimal(price));
        db.update("UPDATE procurement_order_approval_cases SET finance_total_local=? WHERE id=?",original.multiply(new BigDecimal("7")),approval);
        var current=read(scope(owner)).observations().getFirst();
        assertThat(current.reasonCodes()).isEmpty();assertThat(current.comparable()).isTrue();
        assertThat(new BigDecimal(current.quantity())).isEqualByComparingTo(quantity);
        assertThat(new BigDecimal(current.unitPrice())).isEqualByComparingTo(price);
        assertThat(new BigDecimal(current.amount())).isEqualByComparingTo(original);
    }
    @Test void financeConfirmedTaxHasIndependentEvidenceAndSurvivesTheHistoricalProjection() throws Exception {
        try(var in=getClass().getResourceAsStream("/db/migration/V865__procurement_finance_tax_rate.sql")){
            // The oracle already copied the latest migrated column shapes.
            // Install the actual new function/views against those shapes; the
            // full application-chain test applies the complete forward DDL.
            String migration=new String(Objects.requireNonNull(in).readAllBytes(),StandardCharsets.UTF_8);
            db.execute(migration.substring(migration.indexOf("CREATE FUNCTION fn_procurement_approved_tax_rate")));
        }
        var ids=order("purchase",owner,"10","1"); UUID approval=approve(ids,1,"APPROVED");
        String submitted=db.queryForObject("SELECT submission_snapshot::text FROM procurement_order_approval_cases WHERE id=?",String.class,approval);
        db.update("UPDATE procurement_order_approval_cases SET finance_tax_rate=13.1234 WHERE id=?",approval);
        Query query=new Query(goods,Kind.PURCHASE,180,null,null,unit,currency,"13.1234",null,null,null,null,null,"1");
        var current=reader.read(query,reader.goods(goods),180,scope(owner)).observations().getFirst();
        assertThat(current.comparable()).isTrue();assertThat(current.taxRate()).isEqualTo("13.1234");
        assertThat(db.queryForObject("SELECT submission_snapshot::text FROM procurement_order_approval_cases WHERE id=?",String.class,approval)).isEqualTo(submitted);
        var tampered=new HashMap<>(db.queryForMap("SELECT * FROM v_goods_price_observations WHERE source_item_id=?",ids[1]));
        tampered.put("tax_rate",new BigDecimal("9"));
        assertThat(reader.observation(tampered).reasonCodes()).contains("APPROVED_SNAPSHOT_MISMATCH");
        db.update("UPDATE purchase_orders SET tax_rate=5 WHERE id=?",ids[0]);
        assertThat(reader.read(query,reader.goods(goods),180,scope(owner)).observations().getFirst().reasonCodes()).contains("APPROVED_SNAPSHOT_MISMATCH");
        db.update("UPDATE purchase_orders SET status=-1 WHERE id=?",ids[0]);
        var historical=reader.history(new HistoryQuery(query,null,null,null,10),scope(owner),false,true).observations().getFirst();
        assertThat(historical.taxRate()).isEqualTo("13.1234");
        assertThat(historical.reasonCodes()).containsExactly("HISTORICAL_VERSION_ONLY");
    }
    @Test void currencyTaxColorAndFrozenUnitRateNeverMix(){
        var valid=order("purchase",owner,"10","1");
        var rate=order("purchase",owner,"1","1");db.update("UPDATE purchase_order_items SET unit_rate=24 WHERE id=?",rate[1]);
        var tax=order("purchase",owner,"2","1");db.update("UPDATE purchase_orders SET tax_rate=13 WHERE id=?",tax[0]);
        var fx=order("purchase",owner,"3","1");db.update("UPDATE purchase_orders SET currency_id=? WHERE id=?",UUID.randomUUID(),fx[0]);
        var color=order("purchase",owner,"4","1");db.update("UPDATE purchase_order_items SET color_id=? WHERE id=?",UUID.randomUUID(),color[1]);
        assertThat(read(scope(owner)).observations()).extracting(Observation::sourceItemId).containsExactly(valid[1]);
    }

    @Test void approvedTaxVersionsStayIndependentAcrossPendingRejectedAndReversedOrders() throws Exception {
        try(var in=getClass().getResourceAsStream("/db/migration/V865__procurement_finance_tax_rate.sql")) {
            String migration=new String(Objects.requireNonNull(in).readAllBytes(),StandardCharsets.UTF_8);
            db.execute(migration.substring(migration.indexOf("CREATE FUNCTION fn_procurement_approved_tax_rate")));
        }
        var ids=order("purchase",owner,"10","1");UUID first=approve(ids,1,"APPROVED");
        db.update("UPDATE procurement_order_approval_cases SET finance_tax_rate=13.1234 WHERE id=?",first);
        UUID pending=approve(ids,2,"PENDING");
        var query=new Query(goods,Kind.PURCHASE,180,null,null,unit,currency,null,null,null,null,null,null,"1");
        assertThat(reader.read(query,reader.goods(goods),180,scope(owner)).observations().getFirst().reasonCodes())
                .contains("FINANCE_REVIEW_NOT_APPROVED");
        db.update("UPDATE procurement_order_approval_cases SET status='REJECTED' WHERE id=?",pending);
        assertThat(reader.read(query,reader.goods(goods),180,scope(owner)).observations().getFirst().comparable()).isFalse();
        UUID latest=approve(ids,3,"APPROVED");
        db.update("UPDATE procurement_order_approval_cases SET finance_tax_rate=9 WHERE id=?",latest);
        var current=reader.read(query,reader.goods(goods),180,scope(owner)).observations().getFirst();
        assertThat(current.taxRate()).isEqualTo("9");assertThat(current.comparable()).isTrue();
        db.update("UPDATE purchase_orders SET status=-1 WHERE id=?",ids[0]);
        var history=reader.history(new HistoryQuery(query,null,null,null,20),scope(owner),false,true).observations();
        assertThat(history).filteredOn(row->first.equals(row.historyVersionId())).singleElement()
                .satisfies(row->{assertThat(row.taxRate()).isEqualTo("13.1234");assertThat(row.comparable()).isFalse();});
        assertThat(history).filteredOn(row->latest.equals(row.historyVersionId())).singleElement()
                .satisfies(row->assertThat(row.taxRate()).isEqualTo("9"));
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
    @Test void detailRevalidatesBothAnalysisAndActiveHistoryWithoutChangingExactPriceText() throws Exception {
        var ids=order("purchase",owner,"0.6666666667","3");
        db.update("UPDATE purchase_order_items SET amount_original=2,total_amount_input=2 WHERE id=?",ids[1]);approve(ids,1,"APPROVED");
        Observation window=read(scope(owner)).observations().getFirst(),history=history(scope(owner),null,5).observations().getFirst();
        assertThat(window.historyVersionId()).isNull();assertThat(history.historyVersionId()).isNotNull();
        assertThat(reader.detail(goods,detailQuery(Kind.PURCHASE,window),scope(owner),false,true)).isEqualTo(window);
        assertThat(reader.detail(goods,detailQuery(Kind.PURCHASE,history),scope(owner),false,true)).isEqualTo(history);
        assertThat(window.unitPrice()).isEqualTo(history.unitPrice());assertThat(window.amount()).isEqualTo("2");
        // A changed source is not silently shown under the old double-clicked row.
        db.update("UPDATE purchase_order_items SET qty=4,amount_original=3,total_amount_input=3 WHERE id=?",ids[1]);
        assertThatThrownBy(()->reader.detail(goods,detailQuery(Kind.PURCHASE,window),scope(owner),false,true)).hasMessageContaining("已变化");
        assertThatThrownBy(()->reader.detail(goods,detailQuery(Kind.PURCHASE,history),scope(owner),false,true)).hasMessageContaining("已变化");
    }
    @Test void detailBindsGoodsItemSourceTypeAndExactHistoricalVersion() throws Exception {
        var ids=order("purchase",owner,"10","1");UUID old=approve(ids,1,"APPROVED");
        db.update("UPDATE purchase_order_items SET qty=2,amount_original=20 WHERE id=?",ids[1]);approve(ids,2,"APPROVED");
        Observation row=history(scope(owner),null,10).observations().stream().filter(r->old.equals(r.historyVersionId())).findFirst().orElseThrow();
        DetailQuery request=detailQuery(Kind.PURCHASE,row);
        Observation detail=reader.detail(goods,request,scope(owner),false,true);
        assertThat(detail.quantity()).isEqualTo("1");assertThat(detail.amount()).isEqualTo("10");assertThat(detail.canOpenSource()).isFalse();
        assertThatThrownBy(()->reader.detail(UUID.randomUUID(),request,scope(owner),false,true)).hasMessageContaining("不存在或无权");
        for(DetailQuery wrong:List.of(
                new DetailQuery(Kind.PURCHASE,row.sourceType(),UUID.randomUUID(),row.sourceItemId(),old,row.sourceRevision()),
                new DetailQuery(Kind.PURCHASE,row.sourceType(),row.sourceId(),UUID.randomUUID(),old,row.sourceRevision()),
                new DetailQuery(Kind.PURCHASE,row.sourceType(),row.sourceId(),row.sourceItemId(),UUID.randomUUID(),row.sourceRevision()),
                new DetailQuery(Kind.PURCHASE,"PURCHASE_ORDER",row.sourceId(),row.sourceItemId(),old,row.sourceRevision())))
            assertThatThrownBy(()->reader.detail(goods,wrong,scope(owner),false,true)).hasMessageContaining("不存在或无权");
        UUID recipient=UUID.randomUUID();db.update("UPDATE purchase_orders SET maker_id=? WHERE id=?",recipient,ids[0]);
        assertThatThrownBy(()->reader.detail(goods,request,scope(owner),false,true)).hasMessageContaining("不存在或无权");
        // The new owner must reload: even the old immutable snapshot's authorization provenance changed.
        assertThatThrownBy(()->reader.detail(goods,request,scope(recipient),false,true)).hasMessageContaining("已变化");
        Observation refreshed=history(scope(recipient),null,10).observations().stream().filter(r->old.equals(r.historyVersionId())).findFirst().orElseThrow();
        assertThat(reader.detail(goods,detailQuery(Kind.PURCHASE,refreshed),scope(recipient),false,true).amount()).isEqualTo("10");
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
        db.update("INSERT INTO clients(id,name,owner_employee_id) VALUES(?,'Current client',?)",client,other);
        var sale=order("sales",other,"999","1");db.update("UPDATE sales_orders SET owner_employee_id=?,client_id=? WHERE id=?",other,client,sale[0]);
        db.update("INSERT INTO sales_quotes(id,bill_no,maker_id) VALUES(?,'Q-HISTORY',?)",quote,other);
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
        Observation row=reader.history(request,scope(owner),true,false).observations().getFirst();
        assertThat(reader.detail(goods,detailQuery(Kind.SALES,row),scope(owner),true,false)).isEqualTo(row);
        assertThatThrownBy(()->reader.detail(goods,detailQuery(Kind.SALES,row),scope(owner),false,true)).hasMessageContaining("不存在或无权");
        assertThatThrownBy(()->reader.detail(goods,new DetailQuery(Kind.SALES,"SALES_ORDER",sale[0],sale[1],null,row.sourceRevision()),scope(owner),true,false))
                .hasMessageContaining("不存在或无权");
    }
    @Test void quoteFinanceOnlyCannotOpenEvenAnOwnSalesOrderDetail() {
        UUID client=UUID.randomUUID();db.update("INSERT INTO clients(id,name,owner_employee_id) VALUES(?,'Own client',?)",client,owner);
        var sale=order("sales",owner,"10","1");
        db.update("UPDATE sales_orders SET owner_employee_id=?,client_id=? WHERE id=?",owner,client,sale[0]);
        Query sales=new Query(goods,Kind.SALES,180,null,null,unit,currency,"0",null,null,client,null,null,"1");
        Observation row=reader.read(sales,reader.goods(goods),180,scope(owner)).observations().getFirst();
        assertThat(row.sourceId()).isEqualTo(sale[0]);
        assertThatThrownBy(()->reader.detail(goods,detailQuery(Kind.SALES,row),scope(owner),true,false))
                .isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,error->{
                    assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.NOT_FOUND);
                    assertThat(error.getMessage()).contains("不存在或无权");
                });
    }
    private static DetailQuery detailQuery(Kind kind,Observation row){return new DetailQuery(kind,row.sourceType(),row.sourceId(),row.sourceItemId(),row.historyVersionId(),row.sourceRevision());}
    private Query query(){return new Query(goods,Kind.PURCHASE,180,null,null,unit,currency,"0",null,null,null,null,null,"1");}
    private static OwnerVisibility.OwnerScope scope(UUID owner){return new OwnerVisibility.OwnerScope(false,Set.of(owner));}
    private UUID[] order(String kind,UUID maker,String price,String qty){
        UUID id=UUID.randomUUID(),item=UUID.randomUUID();
        if("sales".equals(kind)) {
            UUID client=GoodsPriceProjectionFixture.salesClient(db,maker);
            db.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,tax_rate,exchange_rate,maker_id,owner_employee_id) VALUES(?,?,?,?,?,0,1,?,?)",id,"ORD-"+id,BusinessTime.today(),client,currency,maker,maker);
        } else
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
        if(state.equals("APPROVED"))db.update("INSERT INTO procurement_order_approval_events(case_id,event_type) VALUES(?,'APPROVED')",id);return id;
    }
}
