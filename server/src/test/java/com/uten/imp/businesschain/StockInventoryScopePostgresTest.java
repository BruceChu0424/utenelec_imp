package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.stock.StockReadSideSeed;
import org.hibernate.resource.jdbc.spi.StatementInspector;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.autoconfigure.orm.jpa.HibernatePropertiesCustomizer;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real schema, real SQL and real method authorization; no production connection is used. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000", "uten.workshop-material.auto-close.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import(StockInventoryScopePostgresTest.ProbeConfiguration.class)
class StockInventoryScopePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_inventory_scope").withUsername("uten").withPassword("uten");
    private static final ThreadLocal<List<String>> SQL=new ThreadLocal<>();
    @TestConfiguration static class ProbeConfiguration {
        @Bean HibernatePropertiesCustomizer inventoryScopeSqlProbe() {
            return properties -> properties.put("hibernate.session_factory.statement_inspector", (StatementInspector) sql -> {
                var capture=SQL.get(); if(capture!=null) capture.add(sql); return sql;
            });
        }
    }
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        POSTGRES.start(); properties.add("spring.datasource.url",POSTGRES::getJdbcUrl);
        properties.add("spring.datasource.username",POSTGRES::getUsername);
        properties.add("spring.datasource.password",POSTGRES::getPassword);
    }
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired DataSource dataSource;
    @Autowired AutowireCapableBeanFactory beans;
    private FullChainEndToEndTest fixture;
    private Authentication viewer;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);viewer=auth("stock:view");}
    @AfterEach void cleanup(){SQL.remove();SecurityContextHolder.clearContext();}

    record World(UUID parent, UUID normal, UUID defective, UUID lineSide, UUID nonAccountable,
                 UUID outside, UUID goods, UUID unit, UUID red, UUID blue) {}

    @Test void stockViewAloneReadsZeroMasterAndOnlyAbsentOrDeletedGoodsAre404() throws Exception {
        World w=world(); UUID empty;
        try(var seed=new StockReadSideSeed(dataSource)){empty=seed.goods("无库存仍有主档",w.unit(),null);}
        JsonNode context=read(context(empty),viewer,Map.of("colorId",w.red().toString()),200);
        assertEquals(1,context.path("total").asInt());
        JsonNode item=context.path("items").get(0);
        assertEquals(empty.toString(),item.path("goodsId").asText());
        assertEquals(w.red().toString(),item.path("colorId").asText());
        assertFalse(item.path("name").asText().isBlank());decimal(item.path("qty"),"0");decimal(item.path("weight"),"0");
        assertTrue(item.path("costMasked").asBoolean());assertTrue(item.path("costAmount").isNull());
        assertTrue(item.path("unitWeightKg").isNull());
        read(context(UUID.randomUUID()),viewer,Map.of(),404);
        db.update("UPDATE goods SET is_deleted=true WHERE id=?",empty);
        read(context(empty),viewer,Map.of(),404);
        read(ledger(empty),viewer,Map.of(),404);
        read("/api/stock/balances",viewer,Map.of("goodsId",empty.toString()),404);
    }

    @Test void parentScopeAllModesAndLeafExceptionsAgreeAcrossContextBalancesAndLedger() throws Exception {
        World w=world();
        aligned(w,scope(w.parent(),w.red(),false,false,false,false),"25");
        aligned(w,scope(w.parent(),w.red(),false,true,false,false),"10");
        aligned(w,scope(w.parent(),w.red(),false,true,true,false),"13");
        aligned(w,scope(w.parent(),w.red(),false,true,true,true),"18");
        aligned(w,scope(w.defective(),w.red(),false,true,false,false),"3");
        aligned(w,scope(w.lineSide(),w.red(),false,true,false,false),"5");
        aligned(w,scope(w.nonAccountable(),w.red(),false,true,false,false),"7");
        aligned(w,scope(null,null,false,false,true,false),"42");
        aligned(w,scope(null,null,false,true,true,false),"30");
        JsonNode opening=read(ledger(w.goods()),viewer,scope(w.lineSide(),w.red(),false,true,false,false),200);
        assertEquals(0,opening.path("total").asInt());
        decimal(opening.path("summary").path("openingQty"),"5");
        decimal(opening.path("summary").path("closingQty"),"5");
    }

    @Test void exactNullColorDoesNotSelectAllColorsAndOldClientsKeepAllWarehouseMode() throws Exception {
        World w=world();aligned(w,scope(w.parent(),null,true,true,true,false),"2");
        JsonNode legacy=read("/api/stock/balances",viewer,Map.of("goodsId",w.goods().toString()),200);
        decimal(sum(legacy.path("items"),"qty"),"42");
        JsonNode oldLedger=read(ledger(w.goods()),viewer,Map.of(),200);
        decimal(oldLedger.path("summary").path("closingQty"),"42");
    }

    @Test void unknownWeightAndOwningWarehouseArePreservedAndSelectedEmptyColorIsTrueZero() throws Exception {
        World w=world();JsonNode page=read(context(w.goods()),viewer,scope(w.parent(),w.red(),false,true,true,false),200);
        JsonNode item=page.path("items").get(0);decimal(item.path("qty"),"13");
        assertTrue(item.path("weight").isNull());assertTrue(item.path("weightUnknown").asBoolean());
        assertEquals(w.normal().toString(),item.path("owningWarehouseId").asText());
        assertTrue(item.path("owningWarehouseName").asText().startsWith("正常仓"));
        assertEquals("上下文型号",item.path("model").asText());assertEquals("客户型号",item.path("cNumber").asText());
        assertEquals("主档备注",item.path("remark").asText());
        JsonNode empty=read(context(w.goods()),viewer,scope(w.nonAccountable(),w.blue(),false,true,false,false),200);
        assertEquals(1,empty.path("items").size());decimal(empty.path("items").get(0).path("qty"),"0");
        decimal(empty.path("items").get(0).path("weight"),"0");
        assertEquals(w.blue().toString(),empty.path("items").get(0).path("colorId").asText());
    }

    @Test void emptyEligibleParentScopeFailsClosedWhileLegacyNullScopeStillMeansAllWarehouses() throws Exception {
        World w=world(); UUID parent;
        try(var seed=new StockReadSideSeed(dataSource)){
            parent=seed.warehouse("全非核算父仓",null);UUID child=seed.warehouse("全非核算子仓",parent);
            seed.jdbc().update("UPDATE warehouses SET is_accountable=false WHERE id IN (?,?)",parent,child);
            balance(seed,child,w.goods(),w.red(),"9","0.9");
        }
        aligned(w,scope(parent,w.red(),false,true,true,true),"0");
        aligned(w,scope(parent,w.red(),false,false,true,true),"9");
    }

    @Test void pendingInspectionAndPendingStockInNeverBecomeBalanceAndGlobalPlanIgnoresWarehouseScope() throws Exception {
        World w=world();
        try(var seed=new StockReadSideSeed(dataSource)) {
            seed.jdbc().update("""
                    INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,
                        goods_id,color_id,unit_id,unit_rate,received_base_qty,passed_base_qty,failed_base_qty,status)
                    VALUES(?,'PURCHASE',?,?,?,?,?,?,1,9,3,2,'PARTIAL')
                    """,UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),w.normal(),w.goods(),w.red(),w.unit());
            seed.jdbc().update("""
                    INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,color_id,
                        unit_id,unit_rate,qty,oqty,iqty,lqty,allowed_overproduction_rate)
                    VALUES(?,?,?,CURRENT_DATE,?,?,?,?,1,20,2,3,0,0)
                    """,UUID.randomUUID(),UUID.randomUUID(),"SCOPE-PLAN-"+w.goods(),"SCOPE-PROD-"+w.goods(),w.goods(),w.red(),w.unit());
        }
        JsonNode item=read(context(w.goods()),viewer,scope(w.normal(),w.red(),false,true,true,false),200).path("items").get(0);
        decimal(item.path("qty"),"10");decimal(item.path("pendingQty"),"4");decimal(item.path("pendingStockInQty"),"3");
        decimal(item.path("moreQty"),"15");
        JsonNode outside=read(context(w.goods()),viewer,scope(w.outside(),w.red(),false,true,true,false),200).path("items").get(0);
        decimal(outside.path("qty"),"0");decimal(outside.path("pendingQty"),"0");decimal(outside.path("moreQty"),"15");
    }

    @Test void pageTotalsCoverWholeScopeAndContextQueriesReadCurrentFactsWithoutScanningMovements() throws Exception {
        World w=world();Map<String,String> options=new HashMap<>(scope(w.parent(),null,false,true,false,false));
        options.put("size","1");SQL.set(new ArrayList<>());
        JsonNode first=read(context(w.goods()),viewer,options,200);
        assertEquals(1,first.path("items").size());assertEquals(3,first.path("total").asInt());
        decimal(total(first,"qty"),"16");int count=SQL.get().size();assertEquals(6,count);
        assertTrue(SQL.get().stream().noneMatch(s->s.toLowerCase().contains("stock_movements")));
        assertTrue(SQL.get().stream().filter(s->s.contains("SUM(t."))
                .allMatch(s->!s.contains("LIMIT")&&!s.contains("OFFSET")));
        SQL.set(new ArrayList<>());options.put("page","2");JsonNode second=read(context(w.goods()),viewer,options,200);
        decimal(total(second,"qty"),"16");assertEquals(count,SQL.get().size());
        assertNotEquals(first.path("items").get(0).path("colorId"),second.path("items").get(0).path("colorId"));
        assertFalse(first.path("totals").toString().contains("cost_amount"));
        assertFalse(first.path("totals").toString().contains("more_qty"));
        assertEquals("INSTANT_INVENTORY",first.path("scope").path("warehouseMode").asText());
        assertEquals("GLOBAL_GOODS_COLOR",first.path("scope").path("productionPlanScope").asText());
    }

    @Test void costsAreMaskedAcrossAllStockViewsWithoutGrantingGoodsOrHrReadPermission() throws Exception {
        World w=world();JsonNode masked=read(context(w.goods()),viewer,scope(w.normal(),w.red(),false,true,true,false),200);
        assertTrue(masked.path("items").get(0).path("costAmount").isNull());
        Authentication costViewer=auth("stock:view","goods:cost:view");
        JsonNode allowed=read(context(w.goods()),costViewer,scope(w.normal(),w.red(),false,true,true,false),200);
        assertFalse(allowed.path("items").get(0).path("costMasked").asBoolean());
        decimal(allowed.path("items").get(0).path("costAmount"),"100");
        JsonNode balances=read("/api/stock/balances",viewer,Map.of("goodsId",w.goods().toString()),200);
        for(JsonNode row:balances.path("items")){assertTrue(row.path("amountLocal").isNull());assertTrue(row.path("costMasked").asBoolean());}
        JsonNode ledger=read(ledger(w.goods()),viewer,Map.of(),200);
        for(JsonNode row:ledger.path("items")){assertTrue(row.path("amountLocal").isNull());assertTrue(row.path("costMasked").asBoolean());}
        read(context(w.goods()),auth("goods:view"),Map.of(),403);
    }

    @Test void conflictingColorFiltersAre400OnAllThreeViews() throws Exception {
        World w=world();Map<String,String> params=Map.of("colorId",w.red().toString(),"colorNull","true");
        read(context(w.goods()),viewer,params,400);read(ledger(w.goods()),viewer,params,400);
        Map<String,String> balance=new HashMap<>(params);balance.put("goodsId",w.goods().toString());
        read("/api/stock/balances",viewer,balance,400);
    }

    private void aligned(World w,Map<String,String> options,String expected)throws Exception {
        JsonNode page=read(context(w.goods()),viewer,options,200);decimal(sum(page.path("items"),"qty"),expected);
        decimal(total(page,"qty"),expected);
        Map<String,String> balance=new HashMap<>(options);balance.put("goodsId",w.goods().toString());
        JsonNode rows=read("/api/stock/balances",viewer,balance,200);decimal(sum(rows.path("items"),"qty"),expected);
        JsonNode ledger=read(ledger(w.goods()),viewer,options,200);decimal(ledger.path("summary").path("closingQty"),expected);
    }
    private static Map<String,String> scope(UUID warehouse,UUID color,boolean colorNull,boolean inventoryOnly,boolean defective,boolean lineSide){
        Map<String,String> values=new HashMap<>();if(warehouse!=null)values.put("warehouseId",warehouse.toString());
        if(color!=null)values.put("colorId",color.toString());values.put("colorNull",String.valueOf(colorNull));
        values.put("inventoryOnly",String.valueOf(inventoryOnly));values.put("includeDefective",String.valueOf(defective));
        values.put("includeLineSide",String.valueOf(lineSide));return values;
    }
    private World world()throws Exception {
        try(var seed=new StockReadSideSeed(dataSource)) {
            UUID parent=seed.warehouse("父仓",null),normal=seed.warehouse("正常仓",parent),defective=seed.warehouse("不良仓",parent),
                    lineSide=seed.warehouse("线边仓",parent),nonAccountable=seed.warehouse("非核算仓",parent),outside=seed.warehouse("其他仓",null);
            seed.jdbc().update("UPDATE warehouses SET is_defective=true WHERE id=?",defective);
            seed.jdbc().update("UPDATE warehouses SET is_line_side=true WHERE id=?",lineSide);
            seed.jdbc().update("UPDATE warehouses SET is_accountable=false WHERE id=?",nonAccountable);
            UUID unit=seed.unit("个",null),goods=seed.goods("完整库存主档",unit,null),red=color(seed,"红"),blue=color(seed,"蓝");
            seed.jdbc().update("UPDATE goods SET model='上下文型号',c_number='客户型号',paper='主档备注',owning_warehouse_id=? WHERE id=?",normal,goods);
            balance(seed,normal,goods,red,"10","1");balance(seed,normal,goods,blue,"4","0.4");balance(seed,normal,goods,null,"2","0.2");
            balance(seed,defective,goods,red,"3",null);balance(seed,lineSide,goods,red,"5","0.5");
            balance(seed,nonAccountable,goods,red,"7","0.7");balance(seed,outside,goods,blue,"11","1.1");
            return new World(parent,normal,defective,lineSide,nonAccountable,outside,goods,unit,red,blue);
        }
    }
    private UUID color(StockReadSideSeed seed,String name){UUID id=UUID.randomUUID();seed.jdbc().update("INSERT INTO colors(id,code,name,status) VALUES(?,?,?,'使用')",id,"SCOPE-C-"+id,name);return id;}
    private void balance(StockReadSideSeed seed,UUID warehouse,UUID goods,UUID color,String qty,String weight){
        seed.balance(warehouse,goods,qty,weight,false,new BigDecimal(qty).multiply(BigDecimal.TEN).toPlainString(),LocalDate.of(2026,9,30));
        if(color!=null)seed.jdbc().update("UPDATE stock_balances SET color_id=? WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",color,warehouse,goods);
        // A read-side opening balance is sufficient to verify the technical warehouse scope and ledger anchor.
        // Never invent an ordinary OTHER_IN for a technical rack: its physical provenance guard must stay intact.
        if (Boolean.TRUE.equals(seed.jdbc().queryForObject("SELECT is_line_side FROM warehouses WHERE id=?",Boolean.class,warehouse))) return;
        UUID doc=seed.stockDoc("OTHER_IN","SCOPE-IN-"+UUID.randomUUID(),LocalDate.of(2026,9,30),warehouse,null,null,1);
        UUID movement=seed.movement(LocalDate.of(2026,9,30),11,"STOCK_DOC",doc,UUID.randomUUID(),goods,warehouse,1,qty,weight,null,qty);
        if(color!=null)seed.jdbc().update("UPDATE stock_movements SET color_id=? WHERE id=?",color,movement);
    }
    private Authentication auth(String...permissions){UUID id=UUID.randomUUID(), employee=UUID.randomUUID(), department=UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",department,"SCOPE-D-"+id,"库存权限测试");
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"SCOPE-E-"+id,"库存只读测试",department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",id,employee,"scope-"+id);
        for(String permission:permissions)assertEquals(1,db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=?",id,permission));
        fixture.loginAs(id);Authentication actor=SecurityContextHolder.getContext().getAuthentication();SecurityContextHolder.clearContext();return actor;}
    private JsonNode read(String path,Authentication actor,Map<String,String> query,int status)throws Exception {
        var request=get(path).with(authentication(actor));query.forEach(request::param);
        var response=http.perform(request).andReturn().getResponse();assertEquals(status,response.getStatus(),response.getContentAsString());
        return json.readTree(response.getContentAsByteArray());
    }
    private static String context(UUID goods){return "/api/stock/goods/"+goods+"/inventory-context";}
    private static String ledger(UUID goods){return "/api/stock/goods/"+goods+"/ledger";}
    private static BigDecimal sum(JsonNode rows,String field){BigDecimal sum=BigDecimal.ZERO;for(JsonNode row:rows)sum=sum.add(row.path(field).decimalValue());return sum;}
    private static BigDecimal total(JsonNode page,String key){for(JsonNode total:page.path("totals"))if(total.path("key").asText().equals(key)){BigDecimal value=BigDecimal.ZERO;for(JsonNode group:total.path("groups"))value=value.add(group.path("value").decimalValue());return value;}fail("Missing total "+key);return null;}
    private static void decimal(JsonNode actual,String expected){assertFalse(actual.isMissingNode());assertFalse(actual.isNull());decimal(actual.decimalValue(),expected);}
    private static void decimal(BigDecimal actual,String expected){assertEquals(0,actual.compareTo(new BigDecimal(expected)),actual+" != "+expected);}
}
