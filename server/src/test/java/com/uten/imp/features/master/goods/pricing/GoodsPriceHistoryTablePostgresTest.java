package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.*;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceHistoryTableContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsPriceHistoryTablePostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    private NamedParameterJdbcTemplate named;
    private GoodsPriceSourceReader reader;
    private GoodsPriceAccess access;
    private MasterReferenceValidationPort references;
    private GoodsPriceHistoryTableService table;
    private UUID goods,unit,currency,supplier,owner;
    @BeforeAll static void start(){PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));}
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void schema() throws Exception {
        db.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        db.execute("CREATE TABLE goods(id uuid PRIMARY KEY,code text,name text,unit_id uuid,color_id uuid,is_deleted boolean DEFAULT false,auto_created boolean DEFAULT false)");
        for(String name:List.of("units","currencies","suppliers","colors"))db.execute("CREATE TABLE "+name+"(id uuid PRIMARY KEY,name text)");
        db.execute("CREATE TABLE clients(id uuid PRIMARY KEY,name text,owner_employee_id uuid)");
        for(String kind:List.of("purchase","subcontract","sales")){
            db.execute("CREATE TABLE "+kind+"_orders(id uuid PRIMARY KEY,bill_no text,bill_date date,updated_at timestamptz DEFAULT now(),supplier_id uuid,client_id uuid,currency_id uuid,tax_rate numeric,exchange_rate numeric,purchaser_id uuid,maker_id uuid,owner_employee_id uuid,status smallint DEFAULT 1,is_deleted boolean DEFAULT false,approved_at timestamptz DEFAULT now())");
            db.execute("CREATE TABLE "+kind+"_order_items(id uuid PRIMARY KEY,order_id uuid,goods_id uuid,goods_code_snapshot text DEFAULT 'FROZEN',goods_name_snapshot text DEFAULT 'Frozen item',color_id uuid,unit_id uuid,unit_rate numeric DEFAULT 1,qty numeric,price numeric,amount_original numeric,total_amount_input numeric,gift_qty numeric DEFAULT 0,discount numeric DEFAULT 0,extra_columns jsonb DEFAULT '[]',updated_at timestamptz DEFAULT now(),is_deleted boolean DEFAULT false,chain_status smallint DEFAULT 0)");
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
        goods=UUID.randomUUID();unit=UUID.randomUUID();currency=UUID.randomUUID();supplier=UUID.randomUUID();owner=UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'NOW','Current name',?)",goods,unit);db.update("INSERT INTO units VALUES(?,'件')",unit);
        db.update("INSERT INTO currencies VALUES(?,'CNY')",currency);db.update("INSERT INTO suppliers VALUES(?,'Supplier')",supplier);
        var clients=mock(ClientAccessPolicy.class);when(clients.nativeReadScope(anyString(),any())).thenReturn(new ClientAccessPolicy.NativeReadScope("1=1",null,Set.of(),null,null));
        access=mock(GoodsPriceAccess.class);when(access.available(any())).thenReturn(true);when(access.sourceScope(any())).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(owner)));
        named=spy(new NamedParameterJdbcTemplate(db));references=mock(MasterReferenceValidationPort.class);
        reader=new GoodsPriceSourceReader(named,json,clients,access);table=new GoodsPriceHistoryTableService(named,access,references,reader);
    }
    @Test void fullFacetsAndFilteringIncludeRowsBeyondFirstFiveHundredButExcludeHiddenAndFutureSources(){
        UUID[] first=order("purchase",owner,"0","1",null);
        db.update("INSERT INTO purchase_order_items(id,order_id,goods_id,unit_id,qty,price,amount_original) SELECT gen_random_uuid(),?,?,?,1,n,n FROM generate_series(1,501) n",first[0],goods,unit);
        order("purchase",UUID.randomUUID(),"99999","1",null);order("purchase",null,"88888","1",null);
        var future=order("purchase",owner,"77777","1",null);db.update("UPDATE purchase_orders SET bill_date=? WHERE id=?",BusinessTime.today().plusDays(1),future[0]);
        TablePage firstPage=table.table(query(Kind.PURCHASE,1,10,"unitPrice",true,Map.of()));
        assertThat(firstPage.total()).isEqualTo(502);assertThat(firstPage.observations()).hasSize(10);
        assertThat(firstPage.facetTotals().get("unitPrice")).isEqualTo(502);assertThat(firstPage.facetsHasMore().get("unitPrice")).isTrue();
        assertThat(firstPage.facets().get("unitPrice")).hasSize(200);assertThat(firstPage.nullCounts().get("colorName")).isEqualTo(502);
        var filtered=table.table(query(Kind.PURCHASE,1,10,"unitPrice",true,Map.of("unitPrice","501")));
        assertThat(filtered.total()).isEqualTo(1);assertThat(filtered.observations().getFirst().unitPrice()).isEqualTo("501");
        assertThat(filtered.facetTotals().get("unitPrice")).isEqualTo(502); // self-filter excluded, other filters retained
        var searched=table.facets(new FacetQuery(query(Kind.PURCHASE,1,10,null,false,Map.of()),"unitPrice","501",1,50));
        assertThat(searched.buckets()).extracting(com.uten.imp.common.web.FacetBucket::value).containsExactly("501");assertThat(searched.total()).isEqualTo(1);
    }
    @Test void numericSortAndNullPlacementAreNumericInBothDirections(){
        order("purchase",owner,"10","1",null);order("purchase",owner,"2","1",null);var unknown=order("purchase",owner,"5","1",null);
        db.update("UPDATE purchase_order_items SET amount_original=NULL WHERE id=?",unknown[1]);
        assertThat(table.table(query(Kind.PURCHASE,1,10,"amount",true,Map.of())).observations()).extracting(Observation::amount).containsExactly("2","10",null);
        assertThat(table.table(query(Kind.PURCHASE,1,10,"amount",false,Map.of())).observations()).extracting(Observation::amount).containsExactly("10","2",null);
        assertThat(table.table(query(Kind.PURCHASE,1,10,null,false,Map.of("amount","__null__"))).total()).isEqualTo(1);
    }
    @Test void fractionAndTinyTotalInputUseDecimal128RatherThanRoundedRecordedPrice(){
        var fraction=order("purchase",owner,"0.3333333333","3","1");
        order("purchase",owner,"0.34","1",null);var tiny=order("purchase",owner,"0.0000000001","99999999999999.9999","0.000000000000000000000001");
        var result=table.table(query(Kind.PURCHASE,1,10,"unitPrice",true,Map.of()));
        assertThat(result.observations()).extracting(Observation::sourceItemId).startsWith(tiny[1],fraction[1]);
        for(Observation row:result.observations()){
            assertThat(result.facets().get("unitPrice")).extracting(com.uten.imp.common.web.FacetBucket::value).contains(row.unitPrice());
            assertThat(table.table(query(Kind.PURCHASE,1,10,null,false,Map.of("unitPrice",row.unitPrice()))).observations()).extracting(Observation::sourceItemId).contains(row.sourceItemId());
            assertThat(reader.detail(goods,new DetailQuery(Kind.PURCHASE,row.sourceType(),row.sourceId(),row.sourceItemId(),row.historyVersionId(),row.sourceRevision()),new OwnerVisibility.OwnerScope(false,Set.of(owner)),false,true)).isEqualTo(row);
        }
        assertThat(result.observations().get(1).unitPrice()).isEqualTo(BigDecimal.ONE.divide(new BigDecimal("3"),MathContext.DECIMAL128).toPlainString());
    }
    @Test void salesDiscountChangesThePriceSortAndEqualityFilter(){
        UUID client=UUID.randomUUID();db.update("INSERT INTO clients VALUES(?,'Client',?)",client,owner);
        var discounted=order("sales",owner,"100","1",null);var ordinary=order("sales",owner,"90","1",null);
        db.update("UPDATE sales_orders SET client_id=?,owner_employee_id=?",client,owner);db.update("UPDATE sales_order_items SET discount=0.8,amount_original=80 WHERE id=?",discounted[1]);
        assertThat(table.table(query(Kind.SALES,1,10,"unitPrice",true,Map.of())).observations()).extracting(Observation::sourceItemId).containsExactly(discounted[1],ordinary[1]);
        assertThat(table.table(query(Kind.SALES,1,10,null,false,Map.of("unitPrice","80"))).total()).isEqualTo(1);
    }
    @Test void totalPricesUseTheSameHalfEvenBoundaryAsJavaDecimal128(){
        String qty="1000000000000";
        List<String> totals=List.of("1234567890123456789012345.6789012345","1234567890123456789012345.6789012355");
        for(String total:totals)order("purchase",owner,"1234567890123.4567890123",qty,total);
        var result=table.table(query(Kind.PURCHASE,1,10,"unitPrice",true,Map.of()));
        List<String> expected=totals.stream().map(total->new BigDecimal(total).divide(new BigDecimal(qty),MathContext.DECIMAL128).stripTrailingZeros().toPlainString()).toList();
        assertThat(result.observations()).extracting(Observation::unitPrice).containsExactlyElementsOf(expected);
        assertThat(result.facets().get("unitPrice")).extracting(com.uten.imp.common.web.FacetBucket::value).containsExactlyElementsOf(expected);
        for(String price:expected)assertThat(table.table(query(Kind.PURCHASE,1,10,null,false,Map.of("unitPrice",price))).total()).isEqualTo(1);
    }
    @Test void quoteFinanceFacetsDoNotRevealOrderPricesOutsideTheOrderPermission() throws Exception {
        UUID quote=UUID.randomUUID(),client=UUID.randomUUID(),other=UUID.randomUUID(),log=UUID.randomUUID();
        var ownOrder=order("sales",owner,"99999","1",null);db.update("UPDATE sales_orders SET client_id=?,owner_employee_id=? WHERE id=?",client,owner,ownOrder[0]);
        db.update("INSERT INTO sales_quotes VALUES(?,'CONFIRMED-ONLY',?)",quote,other);
        var line=Map.of("id",UUID.randomUUID(),"goodsId",goods,"goodsCode","QUOTE","goodsName","Original quote","unitId",unit,"unitRate",1,"qty",1,"price",15,"amount",15);
        var snapshot=Map.of("billDate",BusinessTime.today(),"clientId",client,"clientName","Original customer","currencyId",currency,"lines",List.of(line));
        db.update("INSERT INTO sales_quote_revision_logs(id,quote_id,action,snapshot) VALUES(?,?,'CONFIRM',?::jsonb)",log,quote,json.writeValueAsString(snapshot));
        when(access.available(Kind.SALES)).thenReturn(false);when(access.has("sales_quote_finance:view")).thenReturn(true);
        var result=table.table(query(Kind.SALES,1,10,null,false,Map.of()));assertThat(result.total()).isEqualTo(1);
        assertThat(result.facets().get("unitPrice")).extracting(com.uten.imp.common.web.FacetBucket::value).containsExactly("15");
        assertThat(result.facets().get("partnerName")).extracting(com.uten.imp.common.web.FacetBucket::value).containsExactly("Original customer");
        when(access.has("sales_quote_finance:view")).thenReturn(false);
        assertThat(table.table(query(Kind.SALES,1,10,null,false,Map.of())).total()).isZero();
    }
    @Test void facetsKeepExactVersionsAndRevokedOwnersDisappearBeforeAggregation() throws Exception {
        var ids=order("purchase",owner,"10","1",null);approve(ids,1);db.update("UPDATE purchase_order_items SET qty=2,amount_original=20 WHERE id=?",ids[1]);approve(ids,2);
        var first=table.table(query(Kind.PURCHASE,1,1,"quantity",true,Map.of()));var second=table.table(query(Kind.PURCHASE,2,1,"quantity",true,Map.of()));
        assertThat(first.total()).isEqualTo(2);assertThat(first.observations().getFirst().historyVersionId()).isNotEqualTo(second.observations().getFirst().historyVersionId());
        assertThat(first.facets().get("lifecycle")).extracting(com.uten.imp.common.web.FacetBucket::value).containsExactlyInAnyOrder("ACTIVE","SUPERSEDED_APPROVED_VERSION");
        db.update("UPDATE purchase_orders SET maker_id=? WHERE id=?",UUID.randomUUID(),ids[0]);
        var after=table.table(query(Kind.PURCHASE,1,10,null,false,Map.of()));assertThat(after.total()).isZero();assertThat(after.facets().get("unitPrice")).isEmpty();assertThat(after.facetTotals().get("quantity")).isZero();
    }
    @Test void pageUsesThreeSourceQueriesAndSingleFacetUsesOne(){
        order("purchase",owner,"10","1",null);clearInvocations(named);
        table.table(query(Kind.PURCHASE,1,10,null,false,Map.of()));
        verify(named,times(1)).queryForObject(anyString(),any(SqlParameterSource.class),eq(Long.class));
        verify(named,times(2)).queryForList(anyString(),any(SqlParameterSource.class));
        clearInvocations(named);table.facets(new FacetQuery(query(Kind.PURCHASE,1,10,null,false,Map.of()),"sourceNo",null,1,50));
        verify(named,times(1)).queryForList(anyString(),any(SqlParameterSource.class));verify(named,never()).queryForObject(anyString(),any(SqlParameterSource.class),eq(Long.class));
    }
    @Test void malformedColumnsAndNumericValuesCannotBecomeSqlOrTriggerAnUnboundedPage(){
        for(String key:List.of("unitPrice DESC; DROP TABLE goods","comparable","unknown"))assertThatThrownBy(()->table.table(query(Kind.PURCHASE,1,10,key,true,Map.of()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->table.table(query(Kind.PURCHASE,1,10,null,false,Map.of("unitPrice","NaN")))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->table.table(query(Kind.PURCHASE,1,101,null,false,Map.of()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->table.table(new TableQuery(context(Kind.PURCHASE),null,BusinessTime.today().plusDays(1),1,50,null,null,Map.of()))).isInstanceOf(ApiException.class);
        doThrow(new ApiException(ErrorCode.FORBIDDEN,"revoked")).when(access).requireHistory(Kind.PURCHASE);clearInvocations(named);
        assertThatThrownBy(()->table.table(query(Kind.PURCHASE,1,10,null,false,Map.of()))).hasMessageContaining("revoked");verifyNoInteractions(named);
    }
    private TableQuery query(Kind kind,int page,int size,String sort,boolean asc,Map<String,String> filters){return new TableQuery(context(kind),null,null,page,size,sort,asc,filters);}
    private Query context(Kind kind){return new Query(goods,kind,null,null,null,null,null,null,null,null,null,null,null,null);}
    private UUID[] order(String kind,UUID maker,String price,String qty,String total){
        UUID id=UUID.randomUUID(),item=UUID.randomUUID();BigDecimal q=new BigDecimal(qty),p=new BigDecimal(price),amount=total==null?q.multiply(p):new BigDecimal(total);
        db.update("INSERT INTO "+kind+"_orders(id,bill_no,bill_date,supplier_id,currency_id,tax_rate,exchange_rate,maker_id) VALUES(?,?,?,?,?,0,1,?)",id,"ORDER-"+id,BusinessTime.today(),supplier,currency,maker);
        db.update("INSERT INTO "+kind+"_order_items(id,order_id,goods_id,unit_id,qty,price,amount_original,total_amount_input) VALUES(?,?,?,?,?,?,?,?)",item,id,goods,unit,q,p,amount,total==null?null:new BigDecimal(total));return new UUID[]{id,item};
    }
    private void approve(UUID[] ids,int attempt) throws Exception {
        var line=db.queryForMap("SELECT * FROM purchase_order_items WHERE id=?",ids[1]);var i=new LinkedHashMap<String,Object>();
        i.put("itemId",ids[1]);i.put("goodsId",goods);i.put("unitId",unit);i.put("unitRate",1);i.put("qty",line.get("qty"));i.put("price",line.get("price"));i.put("amountOriginal",line.get("amount_original"));
        var snapshot=new LinkedHashMap<String,Object>();snapshot.put("orderId",ids[0]);snapshot.put("billNo","ORIGINAL");snapshot.put("billDate",BusinessTime.today());snapshot.put("supplierId",supplier);snapshot.put("currencyId",currency);snapshot.put("taxRate",0);snapshot.put("exchangeRate",1);snapshot.put("items",List.of(i));
        var d=new LinkedHashMap<>(i);d.put("goodsCode","OLD");d.put("goodsName","Old item");d.put("unitName","件");
        UUID id=UUID.randomUUID();db.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,status,attempt,finance_exchange_rate,finance_total_local,submission_snapshot,display_snapshot) VALUES(?,'PURCHASE',?,'APPROVED',?,1,10,?::jsonb,?::jsonb)",id,ids[0],attempt,json.writeValueAsString(snapshot),json.writeValueAsString(Map.of("items",List.of(d),"currencyName","CNY","supplierName","Original supplier")));
    }
}
