package com.uten.imp.businesschain;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.uten.imp.testsupport.TestFlyway;
import java.math.BigDecimal;
import java.sql.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.*;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;

/** Genuine pre1033 public-command originals become version1 on real upgrade.
 * Historical orphan inputs retain their original conversion and fail closed;
 * supported old/current sources inherit, publicly edit and approve again. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.inventory.value-work.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=successor-quantity-synthetic-jwt-0123456789-test-only",
    "uten.crypto.pgp-master-key=successor-quantity-synthetic-pgp-0123456789-test-only",
    "uten.crypto.hmac-key=successor-quantity-synthetic-hmac-test-only",
    "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=DocumentQuantitySuccessorEndToEndTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class DocumentQuantitySuccessorEndToEndTest {
    private static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("document_successor_quantity");
    private static final Map<String,Legacy> LEGACY=new LinkedHashMap<>();
    private static HistoricalSubcontractCommandFixture.Originals originalSubcontract;
    private static final AtomicInteger NUMBERS=new AtomicInteger(810000);
    private static final List<String> FAMILIES=List.of("purchaseOrder","purchaseReceipt","purchaseReturn","subcontractReceipt","subcontractMaterialReturn","salesReturn");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception {
        DB.start();TestFlyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()).locations("classpath:db/migration").target("1032").load().migrate();
        if(LEGACY.isEmpty())seedLegacy();
        if(originalSubcontract==null)originalSubcontract=HistoricalInventoryJdbc.originalSubcontract1032(
                new org.springframework.jdbc.datasource.DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()),
                DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        FixtureDatabaseProperties.bindSameRole(registry,DB::getJdbcUrl,DB::getUsername,DB::getPassword);
    }
    public static final class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){DB.stop();}
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired DocNumberService numbers;
    @Autowired com.uten.imp.security.TxSessionVars identity;
    @Autowired com.uten.imp.security.SecurityContextCurrentUser current;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired List<DocumentUnapprovalPort> adapters;
    @Autowired com.uten.imp.features.purchase.order.PurchaseOrderService purchaseOrders;
    @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService purchaseReceipts;
    @Autowired com.uten.imp.features.purchase.ret.PurchaseReturnService purchaseReturns;
    @Autowired com.uten.imp.features.subcontract.receipt.SubcontractReceiptService subcontractReceipts;
    @Autowired com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService materialReturns;
    @Autowired com.uten.imp.features.sales.ret.SalesReturnService salesReturns;
    FullChainEndToEndTest worldFactory;
    @BeforeEach void setup(){worldFactory=new FullChainEndToEndTest();beans.autowireBean(worldFactory);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    static java.util.stream.Stream<org.junit.jupiter.params.provider.Arguments> families(){return FAMILIES.stream().flatMap(f->java.util.stream.Stream.of(false,true).map(v->org.junit.jupiter.params.provider.Arguments.of(f,v)));}

    @ParameterizedTest @MethodSource("families")
    void copiedV1OrV2FactsRemainExactThenPublicEditingUsesNormalAdoption(String family,boolean legacy)throws Exception {
        Scenario scenario=scenario(family,legacy);DocumentUnapprovalPort adapter=adapter(family);
        var genuine=legacy?genuineOriginal(family):null;
        Legacy historical=genuine==null?LEGACY.get(family):new Legacy(genuine.document(),genuine.item());
        UUID source=legacy?historical.document():scenario.original();
        UUID sourceLine=legacy?historical.item():item(adapter,source);
        if(legacy){
            reverse(scenario);
            if(genuine!=null){assertOriginalUpgrade(adapter,genuine);worldFactory.loginAs(genuine.actor());reverseOriginal(family,source);}
        }
        String before=facts(adapter,sourceLine);
        UUID draft=legacy?copyLegacy(adapter,historical):unapprove(family,source);
        UUID initial=item(adapter,draft);String inherited=facts(adapter,initial);
        if(genuine==null)assertThat(inherited).isEqualTo(before);
        else {
            var json=new com.fasterxml.jackson.databind.ObjectMapper();
            var original=(com.fasterxml.jackson.databind.node.ObjectNode)json.readTree(before);
            var cloned=(com.fasterxml.jackson.databind.node.ObjectNode)json.readTree(inherited);
            assertThat(original.has("adopted_base_qty")&&original.path("adopted_base_qty").isNull()).isTrue();
            assertThat(cloned.path("adopted_base_qty").decimalValue()).isEqualByComparingTo(genuine.physicalQuantity());
            // The one derived column is asserted separately against a frozen,
            // unique actual preupgrade physical fact. Every other field remains exact.
            original.remove("adopted_base_qty");cloned.remove("adopted_base_qty");assertThat(cloned).isEqualTo(original);
            assertThat(facts(adapter,sourceLine)).isEqualTo(before);
        }
        if(legacy)assertThat(version(adapter,initial)).isEqualTo(1);else assertThat(version(adapter,initial)).isEqualTo(2);
        UUID origin=db.queryForObject("SELECT unapproval_source_item_id FROM "+adapter.lines().table()+" WHERE id=?",UUID.class,initial);
        assertThat(origin).isEqualTo(sourceLine);
        String savedAdoption=adoption(adapter,initial);
        saveSameQuantity(adapter,draft,false);
        UUID saved=item(adapter,draft);
        if(!saved.equals(initial)){
            var json=new com.fasterxml.jackson.databind.ObjectMapper();var beforeTree=json.readTree(savedAdoption);var afterTree=json.readTree(adoption(adapter,saved));
            var changed=new ArrayList<String>();beforeTree.fieldNames().forEachRemaining(key->{if(!Objects.equals(beforeTree.get(key),afterTree.get(key)))changed.add(key);});
            fail("Same quantity save replaced its original row; changed source/adoption fields: "+changed);
        }
        assertThat(saved).as("same original operands retain the locked row and its original adoption").isEqualTo(initial);
        assertThat(adoption(adapter,initial)).isEqualTo(savedAdoption);
        saveSameQuantity(adapter,draft,true);
        assertThat(item(adapter,draft)).as("a changed header date is not a request to re-adopt quantity").isEqualTo(initial);
        assertThat(adoption(adapter,initial)).isEqualTo(savedAdoption);
        assertThatThrownBy(()->saveSameQuantity(adapter,draft,false,sourceLine)).isInstanceOf(RuntimeException.class);
        assertThat(item(adapter,draft)).isEqualTo(initial);assertThat(adoption(adapter,initial)).isEqualTo(savedAdoption);
        editAndApprove(scenario,draft);
        UUID edited=item(adapter,draft);
        assertThat(edited).as("current public editing replaces detail identities without rewriting the initial lineage").isNotEqualTo(initial);
        assertThat(version(adapter,edited)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT line_id_map->>? FROM document_unapprovals WHERE family=? AND original_id=?",String.class,sourceLine.toString(),family,source)).isEqualTo(initial.toString());
        assertThat(db.queryForObject("SELECT (payload->>?)::int FROM business_record_history WHERE source_table=? AND source_id=? AND parent_id=? ORDER BY id DESC LIMIT 1",Integer.class,family.equals("salesReturn")?"receipt_quantity_version":"quantity_adoption_version",adapter.lines().table(),initial.toString(),draft.toString())).isEqualTo(legacy?1:2);
        assertThat(facts(adapter,sourceLine)).isEqualTo(before);
    }

    @ParameterizedTest @ValueSource(strings={"purchaseOrder","purchaseReceipt","purchaseReturn","subcontractReceipt","subcontractMaterialReturn","salesReturn"})
    void initialCopyCannotBeMutatedMovedOrLeftWithoutItsPermanentMap(String family)throws Exception {
        Scenario scenario=scenario(family);DocumentUnapprovalPort adapter=adapter(family);
        Legacy old=new Legacy(scenario.original(),item(adapter,scenario.original()));
        reverse(scenario); // A valid current source includes its actual physical/cost proof.
        String before=facts(adapter,old.item());long rows=db.queryForObject("SELECT count(*) FROM "+adapter.header().table(),Long.class);
        String history=sourceHistory(adapter,old.item());
        for(String mode:List.of("NO_MAP","EDIT","QTY","MOVE","DELETE","FALSE_SOURCE")){
            var assembled=new java.util.concurrent.atomic.AtomicBoolean();
            var copyAttempted=new java.util.concurrent.atomic.AtomicBoolean();
            assertThatThrownBy(()->new TransactionTemplate(transactions).executeWithoutResult(status->{
                identity.bind();InitialCopy plan=copyHeader(adapter,old);
                if(!mode.equals("NO_MAP"))lineage(adapter,old,plan.draft(),plan.line());
                copyAttempted.set(true);copyLine(adapter,old,plan,mode.equals("FALSE_SOURCE")?LEGACY.get(family).item():null);
                UUID line=plan.line();assembled.set(true);
                if(mode.equals("EDIT"))db.update("UPDATE "+adapter.lines().table()+" SET price=COALESCE(price,0)+1 WHERE id=?",line);
                if(mode.equals("QTY")){
                    String bases=family.startsWith("purchase")?",charged_base_qty=(qty+1)*unit_rate,gift_base_qty=COALESCE(gift_qty,0)*unit_rate":"";
                    db.update("UPDATE "+adapter.lines().table()+" SET qty=qty+1"+bases+" WHERE id=?",line);
                }
                if(mode.equals("MOVE"))db.update("UPDATE "+adapter.lines().table()+" SET "+adapter.lines().parentColumn()+"=? WHERE id=?",scenario.original(),line);
                if(mode.equals("DELETE"))db.update("DELETE FROM "+adapter.lines().table()+" WHERE id=?",line);
            })).isInstanceOf(RuntimeException.class).satisfies(failure->{
                if(Set.of("NO_MAP","FALSE_SOURCE").contains(mode))assertThat(sqlState(failure)).isEqualTo("55000");
            });
            assertThat(copyAttempted.get()).as("header and intended lineage completed before the guarded copy INSERT: %s",mode).isTrue();
            assertThat(assembled.get()).as("actual source guard rejects missing/false lineage at INSERT; other mutations start from a valid copy: %s",mode)
                    .isEqualTo(!Set.of("NO_MAP","FALSE_SOURCE").contains(mode));
            assertThat(db.queryForObject("SELECT count(*) FROM "+adapter.header().table(),Long.class)).isEqualTo(rows);
            assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE family=? AND original_id=?",Long.class,family,old.document())).isZero();
            assertThat(facts(adapter,old.item())).isEqualTo(before);assertThat(sourceHistory(adapter,old.item())).isEqualTo(history);
        }
    }

    @ParameterizedTest @ValueSource(strings={"subcontractReceipt","subcontractMaterialReturn"})
    void unknownHistoricalPhysicalBasisKeepsItsOriginalConvertedInputAndCannotCreateACloneOrMoney(String family){
        var adapter=adapter(family);Legacy original=LEGACY.get(family);
        worldFactory.loginAs(db.queryForObject("SELECT created_by FROM "+adapter.header().table()+" WHERE id=?",UUID.class,original.document()));
        String header=db.queryForObject("SELECT to_jsonb(value)::text FROM "+adapter.header().table()+" value WHERE id=?",String.class,original.document());
        String row=db.queryForObject("SELECT to_jsonb(value)::text FROM "+adapter.lines().table()+" value WHERE id=?",String.class,original.item());
        String history=sourceHistory(adapter,original.item());String inputs=facts(adapter,original.item());
        assertThat(db.queryForObject("SELECT unit_rate FROM "+adapter.lines().table()+" WHERE id=?",BigDecimal.class,original.item())).isEqualByComparingTo("1.00005");
        var counts=new LinkedHashMap<String,Long>();for(String table:List.of(adapter.header().table(),"document_unapprovals","stock_movements","stock_value_events","gl_entries","ar_ap_ledger"))counts.put(table,db.queryForObject("SELECT count(*) FROM "+table,Long.class));
        assertThatThrownBy(()->copyLegacy(adapter,original)).isInstanceOf(RuntimeException.class)
                .hasMessageContaining("legacy unapproval requires its actual original physical quantity evidence")
                .satisfies(failure->assertThat(sqlState(failure)).isEqualTo("55000"));
        assertThat(db.queryForObject("SELECT to_jsonb(value)::text FROM "+adapter.header().table()+" value WHERE id=?",String.class,original.document())).isEqualTo(header);
        assertThat(db.queryForObject("SELECT to_jsonb(value)::text FROM "+adapter.lines().table()+" value WHERE id=?",String.class,original.item())).isEqualTo(row);
        assertThat(facts(adapter,original.item())).isEqualTo(inputs);assertThat(sourceHistory(adapter,original.item())).isEqualTo(history);
        counts.forEach((table,count)->assertThat(db.queryForObject("SELECT count(*) FROM "+table,Long.class)).as(table).isEqualTo(count));
    }

    @ParameterizedTest @ValueSource(strings={"purchaseOrder","purchaseReceipt","purchaseReturn"})
    void nullableHistoricalBasisCannotBeInferredFromTheCurrentGoodsDefault(String family)throws Exception {
        var adapter=adapter(family);var legacy=LEGACY.get(family+"-null-basis");
        UUID actor=db.queryForObject("SELECT created_by FROM "+adapter.header().table()+" WHERE id=?",UUID.class,legacy.document());worldFactory.loginAs(actor);
        UUID draft=copyLegacy(adapter,legacy);UUID initial=item(adapter,draft);
        assertThat(version(adapter,initial)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT unit_id IS NULL AND unit_rate IS NULL FROM "+adapter.lines().table()+" WHERE id=?",Boolean.class,initial)).isTrue();
        String before=db.queryForObject("SELECT to_jsonb(item)::text FROM "+adapter.lines().table()+" item WHERE id=?",String.class,initial);
        String header=db.queryForObject("SELECT to_jsonb(doc)::text FROM "+adapter.header().table()+" doc WHERE id=?",String.class,draft);
        assertThatThrownBy(()->saveSameQuantity(adapter,draft,false)).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("原明细单位/换算率缺少依据");
        assertThat(db.queryForObject("SELECT to_jsonb(item)::text FROM "+adapter.lines().table()+" item WHERE id=?",String.class,initial)).isEqualTo(before);
        assertThat(db.queryForObject("SELECT to_jsonb(doc)::text FROM "+adapter.header().table()+" doc WHERE id=?",String.class,draft)).isEqualTo(header);
        UUID selected=db.queryForObject("SELECT id FROM units WHERE code LIKE 'LEG-CONVERT-%'",UUID.class);
        saveSameQuantity(adapter,draft,false,null,selected,new BigDecimal("1.00005"));
        UUID adopted=item(adapter,draft);assertThat(adopted).isNotEqualTo(initial);assertThat(version(adapter,adopted)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT unit_id FROM "+adapter.lines().table()+" WHERE id=?",UUID.class,adopted)).isEqualTo(selected);
        assertThat(db.queryForObject("SELECT unit_id IS NULL AND unit_rate IS NULL FROM "+adapter.lines().table()+" WHERE id=?",Boolean.class,legacy.item())).isTrue();
        assertThat(db.queryForObject("SELECT (payload->>'quantity_adoption_version')::int FROM business_record_history WHERE source_table=? AND source_id=? AND operation='DELETE' ORDER BY id DESC LIMIT 1",Integer.class,adapter.lines().table(),initial.toString())).isEqualTo(1);
    }

    private String adoption(DocumentUnapprovalPort adapter,UUID item){
        return db.queryForObject("SELECT jsonb_object_agg(cell.key,cell.value)::text FROM "+adapter.lines().table()+" item CROSS JOIN LATERAL jsonb_each(to_jsonb(item)) cell WHERE item.id=? AND cell.key=ANY(ARRAY['goods_id','color_id','qty','gift_qty','unit_id','unit_rate','quantity_semantics','charged_base_qty','gift_base_qty','adopted_base_qty','quantity_adoption_version','quantity_precision_policy','quantity_source_proof','receipt_quantity_version','receipt_base_qty','receipt_quantity_proof','order_item_id','receipt_item_id','material_issue_item_id','out_item_id','parent_goods_id','parent_color_id','replacement_intent','gift_replacement_intent'])",String.class,item);
    }
    private void saveSameQuantity(DocumentUnapprovalPort adapter,UUID draft,boolean changeDate)throws Exception {saveSameQuantity(adapter,draft,changeDate,null);}
    private void saveSameQuantity(DocumentUnapprovalPort adapter,UUID draft,boolean changeDate,UUID foreignIdentity)throws Exception {saveSameQuantity(adapter,draft,changeDate,foreignIdentity,null,null);}
    private void saveSameQuantity(DocumentUnapprovalPort adapter,UUID draft,boolean changeDate,UUID foreignIdentity,UUID repairUnit,BigDecimal repairRate)throws Exception {
        UUID initial=item(adapter,draft);
        var line=db.queryForMap("SELECT * FROM "+adapter.lines().table()+" WHERE id=?",initial);
        var header=db.queryForMap("SELECT * FROM "+adapter.header().table()+" WHERE id=?",draft);
        String owner=adapter.family().equals("salesReturn")?"owner_employee_id":"maker_id";
        UUID actor=db.queryForObject("SELECT u.id FROM users u JOIN "+adapter.header().table()+" d ON d."+owner+"=u.employee_id WHERE d.id=? ORDER BY u.is_super_admin DESC,u.id LIMIT 1",UUID.class,draft);
        worldFactory.loginAs(actor);
        String pkg=switch(adapter.family()){
            case "purchaseOrder"->"purchase.order";case "purchaseReceipt"->"purchase.receipt";case "purchaseReturn"->"purchase.ret";
            case "subcontractReceipt"->"subcontract.receipt";case "subcontractMaterialReturn"->"subcontract.material_return";case "salesReturn"->"sales.ret";default->throw new IllegalArgumentException();};
        String stem=adapter.family().equals("purchaseOrder")?"Order":adapter.family().equals("subcontractMaterialReturn")?"MaterialReturn":adapter.family().endsWith("Receipt")?"Receipt":"Return";
        Object request=Class.forName("com.uten.imp.features."+pkg+".dto."+stem+"SaveRequest").getDeclaredConstructor().newInstance();
        Object row=Class.forName("com.uten.imp.features."+pkg+".dto."+stem+"ItemLine").getDeclaredConstructor().newInstance();
        populate(request,header);populate(row,line);
        if(repairUnit!=null){var selected=new org.springframework.beans.BeanWrapperImpl(row);selected.setPropertyValue("unitId",repairUnit);selected.setPropertyValue("unitRate",repairRate);}
        if(foreignIdentity!=null){
            var fields=new org.springframework.beans.BeanWrapperImpl(row);
            if(fields.isWritableProperty("id"))fields.setPropertyValue("id",foreignIdentity);
            else fields.setPropertyValue("platformFields",new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(foreignIdentity,0,List.of()));
        }
        var body=new org.springframework.beans.BeanWrapperImpl(request);
        if(body.isWritableProperty("currencyId")&&body.getPropertyValue("currencyId")==null)body.setPropertyValue("currencyId",db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class));
        if(body.isWritableProperty("settlementMethodId")&&body.getPropertyValue("settlementMethodId")==null)body.setPropertyValue("settlementMethodId",settlement());
        if(body.isWritableProperty("exchangeRate")&&body.getPropertyValue("exchangeRate")==null)body.setPropertyValue("exchangeRate",BigDecimal.ONE);
        if(body.isWritableProperty("taxRate")&&body.getPropertyValue("taxRate")==null)body.setPropertyValue("taxRate",BigDecimal.ZERO);
        if(body.isWritableProperty("confirmGiftSemantics"))body.setPropertyValue("confirmGiftSemantics","CHARGED_PLUS_GIFT_V1".equals(header.get("quantity_semantics")));
        if(changeDate)body.setPropertyValue("billDate",((java.time.LocalDate)body.getPropertyValue("billDate")).plusDays(1));
        body.setPropertyValue("items",List.of(row));
        Object service=switch(adapter.family()){case "purchaseOrder"->purchaseOrders;case "purchaseReceipt"->purchaseReceipts;case "purchaseReturn"->purchaseReturns;case "subcontractReceipt"->subcontractReceipts;case "subcontractMaterialReturn"->materialReturns;case "salesReturn"->salesReturns;default->throw new IllegalArgumentException();};
        call(service,"update",draft,request);
    }
    private static void populate(Object target,Map<String,Object> values){
        var bean=new org.springframework.beans.BeanWrapperImpl(target);
        values.forEach((key,value)->{String[] words=key.split("_");StringBuilder property=new StringBuilder(words[0]);for(int i=1;i<words.length;i++)property.append(Character.toUpperCase(words[i].charAt(0))).append(words[i].substring(1));
            String name=property.toString();if(name.equals("extraColumns")||!bean.isWritableProperty(name))return;
            bean.setPropertyValue(name,value instanceof java.sql.Date date?date.toLocalDate():value);
        });
    }

    private record Scenario(String family,FullChainEndToEndTest.World world,Object financial,Object salesSource,UUID original,UUID materialIssueItem){}
    private Scenario scenario(String family)throws Exception {return scenario(family,false);}
    private Scenario scenario(String family,boolean legacy)throws Exception {
        if(family.equals("salesReturn")){
            var helper=new SalesReturnActualSourceQuantityEndToEndTest();beans.autowireBean(helper);helper.setup();
            Object source;
            if(legacy){
                var w=worldFactory.seedWorld("legacy-sales-source-"+UUID.randomUUID());
                var original=db.queryForMap("SELECT maker_id,owner_employee_id,created_by,client_id FROM sales_returns WHERE id=?",LEGACY.get(family).document());
                var ownerWorld=new FullChainEndToEndTest.World(w.departmentId(),(UUID)original.get("owner_employee_id"),(UUID)original.get("created_by"),
                    w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),(UUID)original.get("client_id"),w.supplierId(),w.warehouseId(),w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
                source=call(helper,"shipForWorld",ownerWorld,".1","1.2",false);
            }else source=call(helper,"ship","successor-edit-"+UUID.randomUUID(),".1","1.2",false);
            UUID returned=call(helper,"approve",source,".1");
            return new Scenario(family,call(source,"world"),helper,source,returned,null);
        }
        var helper=new ProcurementFinanceEffectiveExchangeRateEndToEndTest();beans.autowireBean(helper);helper.prepare();
        Object f=call(helper,"fixture",family.startsWith("subcontract")?"SUBCONTRACT":"PURCHASE","5",true);
        call(helper,"approve",f,BigDecimal.ONE);FullChainEndToEndTest.World w=call(f,"world");
        UUID order=call(f,"order"),orderItem=call(f,"item");
        if(family.equals("purchaseOrder"))return new Scenario(family,w,helper,f,order,null);
        if(family.equals("subcontractMaterialReturn")){
            worldFactory.drawAndIssueSubcontract(orderItem,new BigDecimal("5"),"successor-material-"+UUID.randomUUID());
            UUID issue=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE order_item_id=? AND NOT is_deleted ORDER BY created_at DESC LIMIT 1",UUID.class,orderItem);
            var request=materialRequest(w,orderItem,issue,"1");UUID returned=materialReturns.create(request).getId();materialReturns.approve(returned);
            return new Scenario(family,w,helper,f,returned,issue);
        }
        UUID received=call(helper,"receipt",f,"2");call(helper,"approveReceipt",f,received);
        if(family.equals("subcontractReceipt")){
            call(helper,"resolveInspection",f,received);return new Scenario(family,w,helper,f,received,null);
        }
        call(worldFactory,"passAndStockPurchaseReceipt",w,received,new BigDecimal("2"));
        if(family.equals("purchaseReceipt"))return new Scenario(family,w,helper,f,received,null);
        UUID source=item(adapter("purchaseReceipt"),received);var request=purchaseReturnRequest(w,orderItem,source,"1");
        UUID returned=purchaseReturns.create(request).getId();purchaseReturns.approve(returned);
        return new Scenario(family,w,helper,f,returned,source);
    }
    private void editAndApprove(Scenario s,UUID draft){
        worldFactory.loginAs(s.world().superAdminUserId());UUID orderItem=s.family().equals("salesReturn")?null:call(s.salesSource(),"item");
        switch(s.family()){
            case "purchaseOrder"->{
                var request=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(s.world().supplierId());request.setWarehouseId(s.world().warehouseId());request.setCurrencyId(call(s.salesSource(),"currency"));request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(settlement());
                var row=new com.uten.imp.features.purchase.order.dto.OrderItemLine();row.setGoodsId(s.world().goodsD());row.setUnitId(s.world().unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(BigDecimal.ONE);row.setPrice(BigDecimal.TEN);row.setRequestItemId(call(s.salesSource(),"purchaseSource"));request.setItems(List.of(row));purchaseOrders.update(draft,request);
                Object f=callFixture(s,draft,item(adapter(s.family()),draft));call(s.financial(),"approve",f,BigDecimal.ONE);
            }
            case "purchaseReceipt"->{var request=call(s.financial(),"purchaseReceipt",s.salesSource(),"1");purchaseReceipts.update(draft,(com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest)request);purchaseReceipts.approve(draft);}
            case "purchaseReturn"->{purchaseReturns.update(draft,purchaseReturnRequest(s.world(),orderItem,s.materialIssueItem(),".5"));purchaseReturns.approve(draft);}
            case "subcontractReceipt"->{
                var request=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(s.world().supplierId());request.setWarehouseId(s.world().warehouseId());request.setExchangeRate(BigDecimal.ONE);
                var row=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();row.setGoodsId(s.world().goodsE());row.setUnitId(s.world().unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(BigDecimal.ONE);row.setPrice(new BigDecimal("13.123457"));row.setOrderItemId(orderItem);request.setItems(List.of(row));subcontractReceipts.update(draft,request);subcontractReceipts.approve(draft);
            }
            case "subcontractMaterialReturn"->{materialReturns.update(draft,materialRequest(s.world(),orderItem,s.materialIssueItem(),".5"));materialReturns.approve(draft);}
            case "salesReturn"->{
                // Historical drafts retain their original responsible employee.
                UUID responsible=db.queryForObject("SELECT u.id FROM users u JOIN sales_returns d ON d.owner_employee_id=u.employee_id WHERE d.id=?",UUID.class,draft);
                worldFactory.loginAs(responsible);ReturnEdit edit=new ReturnEdit(s);salesReturns.update(draft,edit.request());salesReturns.approve(draft);
            }
            default->throw new IllegalArgumentException(s.family());
        }
    }
    private Object callFixture(Scenario s,UUID draft,UUID line){
        try{var type=s.salesSource().getClass();var ctor=type.getDeclaredConstructors()[0];ctor.setAccessible(true);return ctor.newInstance(s.world(),call(s.salesSource(),"reviewer"),call(s.salesSource(),"currency"),"PURCHASE",draft,line,call(s.salesSource(),"purchaseSource"));}
        catch(ReflectiveOperationException failure){throw new AssertionError(failure);}
    }
    private static final class ReturnEdit {
        private final Scenario s;ReturnEdit(Scenario s){this.s=s;}
        com.uten.imp.features.sales.ret.dto.ReturnSaveRequest request(){return call(s.financial(),"request",s.salesSource(),".05");}
    }
    private com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest purchaseReturnRequest(FullChainEndToEndTest.World w,UUID order,UUID receipt,String qty){
        var request=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());request.setCurrencyId(db.queryForObject("SELECT currency_id FROM purchase_orders WHERE id=(SELECT order_id FROM purchase_order_items WHERE id=?)",UUID.class,order));request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(settlement());
        var row=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();row.setGoodsId(w.goodsD());row.setUnitId(w.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(new BigDecimal(qty));row.setPrice(new BigDecimal("13.123457"));row.setReceiptItemId(receipt);row.setOrderItemId(order);request.setItems(List.of(row));return request;
    }
    private com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest materialRequest(FullChainEndToEndTest.World w,UUID order,UUID issue,String qty){
        var request=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        var source=db.queryForMap("SELECT * FROM subcontract_material_issue_items WHERE id=?",issue);
        var row=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();row.setGoodsId((UUID)source.get("goods_id"));row.setUnitId((UUID)source.get("unit_id"));row.setUnitRate((BigDecimal)source.get("unit_rate"));row.setQty(new BigDecimal(qty));row.setPrice(BigDecimal.TEN);row.setMaterialIssueItemId(issue);row.setOrderItemId(order);row.setParentGoodsId(w.goodsE());request.setItems(List.of(row));return request;
    }
    private HistoricalSubcontractCommandFixture.Original genuineOriginal(String family){return switch(family){
        case "subcontractReceipt"->Objects.requireNonNull(originalSubcontract).receipt();
        case "subcontractMaterialReturn"->Objects.requireNonNull(originalSubcontract).materialReturn();default->null;};}
    private void assertOriginalUpgrade(DocumentUnapprovalPort adapter,HistoricalSubcontractCommandFixture.Original original){
        for(var part:List.of(new String[]{adapter.header().table(),original.document().toString(),original.headerBeforeUpgrade()},
                new String[]{adapter.lines().table(),original.item().toString(),original.itemBeforeUpgrade()},
                new String[]{original.family().equals("subcontractReceipt")?"procurement_inspection_items":"stock_movements",original.physicalFact().toString(),original.physicalBeforeUpgrade()}))
            assertThat(db.queryForObject("SELECT (SELECT jsonb_object_agg(cell.key,cell.value) FROM jsonb_each(to_jsonb(stored)) cell WHERE cell.key IN(SELECT jsonb_object_keys(CAST(? AS jsonb))))::text FROM "+part[0]+" stored WHERE id=?",String.class,part[2],UUID.fromString(part[1]))).as("All genuinely stored original columns survive the upgrade: %s",part[0]).isEqualTo(part[2]);
        assertThat(db.queryForObject("SELECT quantity_adoption_version=1 AND quantity_precision_policy IS NULL AND adopted_base_qty IS NULL FROM "+adapter.lines().table()+" WHERE id=?",Boolean.class,original.item())).isTrue();
        if(original.family().equals("subcontractReceipt"))assertThat(db.queryForObject("SELECT received_base_qty FROM procurement_inspection_items WHERE id=? AND receipt_type='SUBCONTRACT' AND receipt_id=? AND receipt_item_id=?",BigDecimal.class,original.physicalFact(),original.document(),original.item())).isEqualByComparingTo(original.physicalQuantity());
        else assertThat(db.queryForObject("SELECT qty FROM stock_movements WHERE id=? AND source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND source_item_id=? AND movement_type=16 AND direction=1",BigDecimal.class,original.physicalFact(),original.document(),original.item())).isEqualByComparingTo(original.physicalQuantity());
    }
    private void reverseOriginal(String family,UUID id){switch(family){case "subcontractReceipt"->subcontractReceipts.reverse(id);case "subcontractMaterialReturn"->materialReturns.reverse(id);default->throw new IllegalArgumentException(family);}}
    private void reverse(Scenario s){switch(s.family()){case "purchaseOrder"->purchaseOrders.reverse(s.original());case "purchaseReceipt"->purchaseReceipts.reverse(s.original());case "purchaseReturn"->purchaseReturns.reverse(s.original());case "subcontractReceipt"->subcontractReceipts.reverse(s.original());case "subcontractMaterialReturn"->materialReturns.reverse(s.original());case "salesReturn"->salesReturns.reverse(s.original());default->throw new IllegalArgumentException();}}
    private UUID unapprove(String family,UUID id){unapproval.unapprove(family,id,new DocumentUnapprovalService.UnapproveRequest("quantity-successor-"+UUID.randomUUID(),"保存原数量决定，正常编辑后再审核"));return db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family=? AND original_id=?",UUID.class,family,id);}
    private UUID settlement(){return db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);}
    private DocumentUnapprovalPort adapter(String family){return adapters.stream().filter(a->a.family().equals(family)).findFirst().orElseThrow();}
    private UUID item(DocumentUnapprovalPort a,UUID parent){return db.queryForObject("SELECT id FROM "+a.lines().table()+" WHERE "+a.lines().parentColumn()+"=? AND NOT is_deleted ORDER BY line_no,id LIMIT 1",UUID.class,parent);}
    private String facts(DocumentUnapprovalPort a,UUID id){
        // Fixed observation projection retains the original test's complete field
        // set without introducing another business source/profile authority.
        return db.queryForObject("SELECT jsonb_object_agg(cell.key,cell.value)::text FROM "+a.lines().table()+" item CROSS JOIN LATERAL jsonb_each(to_jsonb(item)) cell WHERE item.id=? AND cell.key=ANY(ARRAY['bill_date','goods_id','color_id','unit_id','unit_rate','qty','quantity_semantics','gift_qty',"+
            "'charged_base_qty','gift_base_qty','adopted_base_qty','quantity_adoption_version','quantity_precision_policy','quantity_source_proof',"+
            "'receipt_quantity_version','receipt_base_qty','receipt_quantity_proof','order_item_id','receipt_item_id','out_item_id',"+
            "'material_issue_item_id','request_item_id','replacement_intent','gift_replacement_intent','price','amount_original','amount_local',"+
            "'parent_goods_id','parent_color_id','cost_amount']::text[] || CASE WHEN ? IN('purchase_order_items','subcontract_order_items') THEN ARRAY['total_amount_input','reference_price_precision_policy','extra_columns']::text[] ELSE ARRAY[]::text[] END)",String.class,id,a.lines().table());
    }
    private String sourceHistory(DocumentUnapprovalPort a,UUID id){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(value) ORDER BY id),'[]'::jsonb)::text FROM business_record_history value WHERE source_table=? AND source_id=?",String.class,a.lines().table(),id.toString());}
    private static String sqlState(Throwable failure){for(Throwable cause=failure;cause!=null;cause=cause.getCause()){
        if(cause instanceof SQLException sql&&sql.getSQLState()!=null){
        return sql.getSQLState();
    }

    }
    return null;}
    private int version(DocumentUnapprovalPort a,UUID id){return db.queryForObject("SELECT "+(a.family().equals("salesReturn")?"receipt_quantity_version":"quantity_adoption_version")+" FROM "+a.lines().table()+" WHERE id=?",Integer.class,id);}
    private record InitialCopy(UUID draft,UUID line,String bill){}
    private UUID copyLegacy(DocumentUnapprovalPort a,Legacy l){return new TransactionTemplate(transactions).execute(status->{
        identity.bind();InitialCopy plan=copyHeader(a,l);lineage(a,l,plan.draft(),plan.line());copyLine(a,l,plan,null);return plan.draft();
    });}
    private InitialCopy copyHeader(DocumentUnapprovalPort a,Legacy l){
        var plan=new InitialCopy(UUID.randomUUID(),UUID.randomUUID(),numbers.nextNumber(a.numberPrefix(l.document())));
        var head=new ArrayList<>(List.of("id","bill_no","status","created_by","updated_by"));head.addAll(a.header().inputs());
        var values=new ArrayList<>(List.of("?","?","0","source.created_by","?"));values.addAll(a.header().inputs().stream().map(x->a.generatedHeaderInputs().getOrDefault(x,"source."+x)).toList());
        assertThat(db.update("INSERT INTO "+a.header().table()+"("+String.join(",",head)+") SELECT "+String.join(",",values)+" FROM "+a.header().table()+" source WHERE id=? AND status=-1 AND NOT is_deleted",plan.draft(),plan.bill(),current.requireId(),l.document())).isEqualTo(1);
        return plan;
    }
    private void copyLine(DocumentUnapprovalPort a,Legacy l,InitialCopy plan,UUID falseSource){
        assertThat(a.inheritsFrozenLineFacts()).isTrue();
        var cols=new ArrayList<>(List.of("id",a.lines().parentColumn(),"created_by","updated_by"));
        var vals=new ArrayList<>(List.of("?","?","source.created_by","?"));
        var arguments=new ArrayList<Object>(List.of(plan.line(),plan.draft(),current.requireId()));
        if(a.lines().lineBillNumber()){cols.add("bill_no");vals.add("?");arguments.add(plan.bill());}
        cols.addAll(a.lines().inputs());vals.addAll(a.lines().inputs().stream().map(x->"source."+x).toList());
        cols.add("unapproval_source_item_id");vals.add("?");arguments.add(falseSource==null?l.item():falseSource);
        cols.addAll(a.generatedLineInputs().keySet());vals.addAll(a.generatedLineInputs().values());arguments.add(l.item());
        assertThat(db.update("INSERT INTO "+a.lines().table()+"("+String.join(",",cols)+") SELECT "+String.join(",",vals)+" FROM "+a.lines().table()+" source WHERE id=? AND NOT is_deleted",arguments.toArray())).isEqualTo(1);
    }
    private void lineage(DocumentUnapprovalPort a,Legacy l,UUID draft,UUID line){db.update("INSERT INTO document_unapprovals(family,original_id,draft_id,draft_bill_no,request_key,reason,line_id_map,created_by) SELECT ?,?,?,bill_no,?,'匿名旧数量继任',jsonb_build_object(?::text,?::text),? FROM "+a.header().table()+" WHERE id=?",a.family(),l.document(),draft,"legacy-quantity-"+UUID.randomUUID(),l.item(),line,current.requireId(),draft);}
    @SuppressWarnings("unchecked") private static <T>T call(Object target,String method,Object...args){return (T)ReflectionTestUtils.invokeMethod(target,method,args);}
    private record Legacy(UUID document,UUID item){}
    private static void seedLegacy()throws SQLException {
        try(var c=DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword())){
            UUID unit=UUID.randomUUID(),lineUnit=UUID.randomUUID(),goods=UUID.randomUUID(),warehouse=UUID.randomUUID(),supplier=UUID.randomUUID(),client=UUID.randomUUID(),maker=UUID.randomUUID(),owner=UUID.randomUUID();
            execute(c,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),DATE '2026-01-01','active','regular')",maker,"LEG-Q-"+maker,"旧数量员工-"+maker);
            execute(c,"INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status)VALUES(?,?,?,'test-not-used',false,true,'active')",owner,maker,"legacy-quantity-"+owner);
            execute(c,"INSERT INTO units(id,code,name)VALUES(?,?,'旧数量单位')",unit,"LEG-Q-"+unit);
            execute(c,"INSERT INTO units(id,code,name)VALUES(?,?,'旧数量箱')",lineUnit,"LEG-CONVERT-"+lineUnit);
            execute(c,"INSERT INTO goods(id,code,name,unit_id,code_sequence)VALUES(?,?,'旧数量货品',?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",goods,"LEG-Q-"+goods,unit);
            execute(c,"INSERT INTO warehouses(id,code,name)VALUES(?,?,'旧数量仓')",warehouse,"LEG-Q-"+warehouse);
            execute(c,"INSERT INTO suppliers(id,code,name,code_sequence)VALUES(?,?,'旧数量供应商',(SELECT coalesce(max(code_sequence),0)+1 FROM suppliers))",supplier,"LEG-Q-"+supplier);
            execute(c,"INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id)VALUES(?,?,'旧数量客户','使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients),?)",client,"LEG-Q-"+client,maker);
            UUID receiptSource=UUID.randomUUID(),receiptSourceLine=UUID.randomUUID();String sourceBill="CJ20260923"+"%06d".formatted(NUMBERS.incrementAndGet());
            c.setAutoCommit(false);
            execute(c,"INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,warehouse_id,maker_id,approver_id,status,currency_id,exchange_rate,tax_rate,settlement_method_id,total_original,total_local,created_by,updated_by)VALUES(?,?,DATE '2026-09-23',?,?,?,?,1,(SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted),1,0,(SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1),0,0,?,?)",receiptSource,sourceBill,supplier,warehouse,maker,maker,owner,owner);
            execute(c,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,line_no,goods_id,goods_code_snapshot,goods_name_snapshot,unit_id,unit_rate,qty,charged_base_qty,gift_base_qty,price,amount_original,amount_local,goods_snapshot_source,replacement_intent)VALUES(?,?,DATE '2026-09-23',?,1,?,'LEG-SOURCE','旧数量原收货',?,1.00005,1,1.0001,0,0,0,0,'MASTER_AT_SAVE','NORMAL')",receiptSourceLine,sourceBill,receiptSource,goods,lineUnit);
            execute(c,"INSERT INTO procurement_receipt_consideration_parts(id,receipt_type,receipt_id,receipt_item_id,billing_mode,base_qty,nominal_original,nominal_local,payable_original,payable_local,created_by,quantity_tranche)VALUES(gen_random_uuid(),'PURCHASE',?,?,'STANDARD',1.00005,0,0,0,0,?,'LEGACY')",receiptSource,receiptSourceLine,owner);
            c.commit();c.setAutoCommit(true);
            String[][] specs={{"purchaseOrder","purchase_orders","purchase_order_items","order_id","CD"},{"purchaseReceipt","purchase_receipts","purchase_receipt_items","receipt_id","CJ"},{"purchaseReturn","purchase_returns","purchase_return_items","return_id","CT"},{"subcontractReceipt","subcontract_receipts","subcontract_receipt_items","receipt_id","EJ"},{"subcontractMaterialReturn","subcontract_material_returns","subcontract_material_return_items","material_return_id","ER"},{"salesReturn","sales_returns","sales_return_items","return_id","XT"}};
            var allSpecs=new ArrayList<String[]>();
            for(String[] spec:specs){allSpecs.add(spec);
                if(spec[0].startsWith("purchase")){var missing=spec.clone();missing[0]+="-null-basis";allSpecs.add(missing);}}

            for(String[] spec:allSpecs){UUID h=UUID.randomUUID(),i=UUID.randomUUID();String bill=spec[4]+"20260923"+"%06d".formatted(NUMBERS.incrementAndGet());String party=spec[1].equals("sales_returns")?"client_id":"supplier_id";
                String responsibility=spec[1].equals("sales_returns")?",owner_employee_id":"";
                String responsibleValue=spec[1].equals("sales_returns")?",'"+maker+"'::uuid":"";
                execute(c,"INSERT INTO "+spec[1]+"(id,bill_no,bill_date,"+party+",warehouse_id,maker_id,status,created_by,updated_by"+responsibility+")VALUES(?,?,DATE '2026-09-23',?,?,?,-1,?,?"+responsibleValue+")",h,bill,spec[1].equals("sales_returns")?client:supplier,warehouse,maker,owner,owner);
                String bases=spec[0].startsWith("purchase")&&!spec[1].equals("purchase_orders")?",charged_base_qty,gift_base_qty":"";
                String returnSource=spec[2].equals("purchase_return_items")?",receipt_item_id":"";
                String returnValue=spec[2].equals("purchase_return_items")?",'"+receiptSourceLine+"'::uuid":"";
                execute(c,"INSERT INTO "+spec[2]+"(id,bill_no,bill_date,"+spec[3]+",line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_snapshot_source"+bases+returnSource+")VALUES(?,?,DATE '2026-09-23',?,1,?,?,?,1,10,10,10,'MASTER_AT_SAVE'"+(bases.isEmpty()?"":",1.0001,0")+returnValue+")",i,bill,h,goods,spec[0].endsWith("-null-basis")?null:lineUnit,spec[0].endsWith("-null-basis")?null:new BigDecimal("1.00005"));LEGACY.put(spec[0],new Legacy(h,i));
            }
        }
    }
    private static void execute(Connection c,String sql,Object...args)throws SQLException {try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++){
        s.setObject(i+1,args[i]);
    }
    s.executeUpdate();}}
}
