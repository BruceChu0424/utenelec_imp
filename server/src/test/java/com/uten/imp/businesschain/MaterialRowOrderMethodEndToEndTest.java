package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderWriteService;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import com.uten.imp.features.production.analysis.MaterialAnalysisPlanWithdrawalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.HashSet;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real commands and a fresh migrated PostgreSQL; never uses a developer/company database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
    "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialRowOrderMethodEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){
        String port=System.getenv("UTEN_ROW_METHOD_PG_PORT");
        if(port==null||port.isBlank()){FullChainEndToEndTest.registerDataSource(registry);return;}
        if(!port.matches("[0-9]{1,5}")||Integer.parseInt(port)<1||Integer.parseInt(port)>65535)
            throw new IllegalArgumentException("The row-method fixture requires a local isolated PostgreSQL port");
        // Only this task's loopback fixture is accepted; no arbitrary developer/company URL.
        FixtureDatabaseProperties.bindSameRole(registry,()->"jdbc:postgresql://127.0.0.1:"+port+"/uten_row_method_core",
            ()->"fixture_admin",()->"row-method-fixture-only"); // gitleaks:allow synthetic isolated fixture password.
        try {
            var uploads=java.nio.file.Files.createTempDirectory("uten-row-method-fixture-");
            registry.add("uten.storage.local-dir",uploads::toString);
        }catch(java.io.IOException failure){throw new IllegalStateException(failure);}
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired AggregateMaterialOrderWriteService aggregateOrders;
    @Autowired MaterialAnalysisPlanWithdrawalService withdrawals;
    @Autowired ProductionScheduleService schedule;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;
    AggregateMaterialOrderEndToEndTest aggregateFixture;

    @BeforeEach void prepare(){
        // A restored synthetic template can retain earlier worlds. Follow its actual legacy-ID maximum.
        var sequence=(java.util.concurrent.atomic.AtomicInteger)ReflectionTestUtils.getField(FullChainEndToEndTest.class,"LEGACY_SEQ");
        assertNotNull(sequence);
        sequence.accumulateAndGet(db.queryForObject("SELECT COALESCE(max(legacy_id),9000) FROM units",Integer.class),Math::max);
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        aggregateFixture=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(aggregateFixture);aggregateFixture.before();
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @ParameterizedTest
    @CsvSource({"ORDER_ALL,1000","AVAILABLE_THEN_ORDER,880","AVAILABLE_ONLY,0"})
    void sales1000AndItsPrivate120KeepFullNeedAndRespectEachOrderMethod(String method,String expectedNew){
        var c=salesCase("120");
        assertDemandAndAvailable(c,"120");
        var original=reservations(c.salesItem());
        var request=notify(c,c.view(),method);
        var after=commands.notifySupply(c.view().analysisId(),request);
        amount(expectedNew,purchased(c.view().analysisId()));
        amount("120",rootFulfilled(c));
        assertEquals(original,reservations(c.salesItem()),"planning must acknowledge the existing sales reservation, never recreate or release it");
        assertEquals(1,db.queryForObject("SELECT count(*) FROM preplan_sales_stock_adoptions WHERE analysis_id=?",Integer.class,c.view().analysisId()));
        amount("120",material(after,c.goods()).preparationAdoptedQty());
        var replay=commands.notifySupply(c.view().analysisId(),request);
        amount(expectedNew,purchased(c.view().analysisId()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM preplan_sales_stock_adoptions WHERE analysis_id=?",Integer.class,c.view().analysisId()));
        assertEquals(after.version(),replay.version());
        assertEquals(original,reservations(c.salesItem()));
        if(method.equals("ORDER_ALL")){
            amount("120",after.supplyActions().stream().filter(action->"BUY".equals(action.route()))
                .map(SupplyActionView::publicSurplusQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        }
    }

    @ParameterizedTest
    @CsvSource({"AVAILABLE_ONLY,0","AVAILABLE_THEN_ORDER,0","ORDER_ALL,1000"})
    void fullyAvailableSales1000StillReachesPlanningAndRespectsTheSelectedMethod(String method,String expectedNew){
        var c=salesCase("1000");
        assertDemandAndAvailable(c,"1000");
        var original=reservations(c.salesItem());
        var request=notify(c,c.view(),method);
        var after=commands.notifySupply(c.view().analysisId(),request);
        amount(expectedNew,purchased(c.view().analysisId()));amount("1000",rootFulfilled(c));
        amount("0",after.products().getFirst().remainingQty());
        if(!method.equals("ORDER_ALL"))assertEquals("COMPLETED",after.status());
        assertEquals(original,reservations(c.salesItem()));
        commands.notifySupply(c.view().analysisId(),request);
        assertEquals(original,reservations(c.salesItem()));
    }

    @Test void cancellingAnAdoptionDoesNotReleaseSalesStockAndTheAcknowledgementIsAppendOnly(){
        var c=salesCase("120");var original=reservations(c.salesItem());
        var after=commands.notifySupply(c.view().analysisId(),notify(c,c.view(),"AVAILABLE_ONLY"));
        amount("120",rootFulfilled(c));
        assertThrows(DataAccessException.class,()->db.update("UPDATE preplan_sales_stock_adoptions SET qty_base=qty_base+1 WHERE analysis_id=?",c.view().analysisId()));
        var cancelled=commands.cancelAnalysis(c.view().analysisId(),new CancelRequest(after.version(),after.fingerprint(),key("cancel"),"撤销本次计划采用"));
        assertEquals("CANCELLED",cancelled.status());amount("0",rootFulfilled(c));
        assertEquals(original,reservations(c.salesItem()));
        amount("120",db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,c.salesItem()));
        amount("0",purchased(c.view().analysisId()));
    }

    @Test void reservationAvailabilityChangesClampTheAdoptionWithoutMutatingItsHistory(){
        var c=salesCase("120");commands.notifySupply(c.view().analysisId(),notify(c,c.view(),"AVAILABLE_ONLY"));
        amount("120",rootFulfilled(c));
        UUID reservation=db.queryForObject("SELECT id FROM stock_reservations WHERE order_item_id=? AND source=0 AND status=0 AND NOT is_deleted",UUID.class,c.salesItem());
        // Model an authoritative sales-side reservation reduction, inside this synthetic isolated fixture.
        db.update("UPDATE stock_reservations SET released_qty=80 WHERE id=?",reservation);
        amount("40",rootFulfilled(c));
        amount("120",db.queryForObject("SELECT qty_base FROM preplan_sales_stock_adoptions WHERE analysis_id=?",BigDecimal.class,c.view().analysisId()));
        amount("0",purchased(c.view().analysisId()));
    }

    @Test void parentAllOrderPreviewActivatesCoveredChildrenAndOnlyAvailableRetiresThemWithoutWritingOrders(){
        var c=aggregateFixture.createWithChild("1000",1,"SUBCONTRACT");
        aggregateFixture.receive(c,c.common(),"1000");
        var current=refresh(c);
        var parent=material(current,c.common());
        amount("1000",parent.sourceRequiredQty());amount("0",parent.shortageQty());
        amount("0",material(current,c.child()).requiredQty());
        var all=commands.previewIssuePlans(c.analysis(),preview(c,current,parent,"ORDER_ALL"));
        amount("1000",material(all,c.child()).requiredQty());
        amount("2000",material(all,c.material()).requiredQty());
        var only=commands.previewIssuePlans(c.analysis(),preview(c,current,parent,"AVAILABLE_ONLY"));
        amount("0",material(only,c.child()).requiredQty());amount("0",material(only,c.material()).requiredQty());
        assertEquals("INACTIVE_PARENT_COVERED",material(only,c.child()).requirementState());
        amount("0",db.queryForObject("SELECT sum(required_qty) FROM production_material_analysis_materials WHERE analysis_id=? AND goods_id=? AND active",BigDecimal.class,c.analysis(),c.child()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,c.analysis()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,c.analysis()));
        assertEquals(current.version(),all.version());assertEquals(current.fingerprint(),all.fingerprint());
    }

    @Test void coveredChildCanOrderItsOwnPublic880WithoutProducingTheParentAndStillNeedsExtraPermission(){
        var c=aggregateFixture.createWithChild("880",1,"SUBCONTRACT");aggregateFixture.receive(c,c.common(),"880");
        var current=refresh(c);var child=material(current,c.child());
        amount("0",child.requiredQty());amount("880",child.sourceRequiredQty());
        assertEquals("INACTIVE_PARENT_COVERED",child.requirementState());
        var input=new GroupInput("independent-covered-child",List.of(child.materialLineId()),"MAKE",new BigDecimal("880"),true,
            c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,Map.of(child.materialLineId(),new BigDecimal("880")),
            null,"COVERAGE_TOTAL","ORDER_ALL");
        var request=aggregateFixture.command(c,List.of(input));
        AuthUser original=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var grants=new HashSet<>(original.getPermissions());grants.remove("production_material_analysis:over_supply");
        AuthUser limited=new AuthUser(original.getId(),original.getEmployeeId(),original.getUsername(),grants,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities()));
        var denied=assertThrows(ApiException.class,()->aggregateOrders.submit(c.analysis(),request));
        // Aggregate admission already reports a blocked preview as CONFLICT;
        // prove this is the exact permission gate, not an invalid source/route.
        assertEquals(ErrorCode.CONFLICT,denied.getCode());
        assertEquals("独立公共备货需要超量下达权限",denied.getMessage());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,c.analysis()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,c.analysis()));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(original,null,original.getAuthorities()));
        var result=aggregateOrders.submit(c.analysis(),request);
        assertEquals(1,result.batches().size());var batch=result.batches().getFirst();
        amount("880",batch.qty());amount("880",batch.publicExtraQty());
        amount("0",batch.sources().stream().map(source->source.allocatedQty()).reduce(BigDecimal.ZERO,BigDecimal::add));
        amount("880",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND goods_id=? AND NOT is_deleted",BigDecimal.class,batch.planId(),c.child()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND goods_id=?",Integer.class,c.analysis(),c.common()));
        var after=analyses.detail(c.analysis());
        amount("0",after.flatMaterials().stream().filter(row->row.materialLineId().equals(child.materialLineId())).findFirst().orElseThrow().requiredQty());
        amount("1760",after.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).map(MaterialView::requiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        assertTrue(aggregateOrders.submit(c.analysis(),request).replayed());
    }

    @Test void onlyAvailableAdoptsRealPublicComponentStockInsteadOfReturningANoop(){
        var c=aggregateFixture.create(false,false,"500");
        aggregateFixture.receive(c,c.material(),"1000");
        var current=refresh(c);
        var source=current.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())&&row.allocatedAvailableQty().compareTo(new BigDecimal("1000"))==0)
            .findFirst().orElseThrow();
        amount("0",source.exactPeggedQty());amount("0",source.preparationOwnedAvailableQty());
        amount("0",source.sharedFutureClaimableQty());
        var input=new GroupInput("only-real-component-stock",List.of(source.materialLineId()),"BUY",new BigDecimal("1000"),true,
            null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(source.materialLineId(),new BigDecimal("1000")),
            null,"COVERAGE_TOTAL","AVAILABLE_ONLY");
        var request=aggregateFixture.command(c,List.of(input));
        var result=aggregateOrders.submit(c.analysis(),request);
        assertTrue(result.batches().isEmpty(),"stock adoption must not create any shortage order");
        var after=analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.materialLineId().equals(source.materialLineId())).findFirst().orElseThrow();
        amount("1000",after.preparationOwnedAvailableQty());amount("1000",after.preparationAdoptedQty());
        assertTrue(current.version()!=result.analysis().version()||!current.fingerprint().equals(result.analysis().fingerprint()),
            "successful adoption must have an authoritative receipt");
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,c.analysis()));
        assertTrue(aggregateOrders.submit(c.analysis(),request).replayed());
        amount("1000",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.material()));
        amount("1000",db.queryForObject("SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations WHERE goods_id=? AND status=0 AND NOT is_deleted",BigDecimal.class,c.material()));
    }

    @Test void allOrderKeepsUnownedPublic120FreeAndAssignsTheFullNew1000ToItsSource(){
        var c=aggregateFixture.create(false,false,"500");aggregateFixture.receive(c,c.material(),"120");
        var current=refresh(c);
        var source=current.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())&&row.allocatedAvailableQty().compareTo(new BigDecimal("120"))==0)
            .findFirst().orElseThrow();
        amount("1000",source.sourceRequiredQty());amount("0",source.preparationOwnedAvailableQty());
        var input=new GroupInput("all-with-public-stock",List.of(source.materialLineId()),"BUY",new BigDecimal("1000"),false,
            null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(source.materialLineId(),new BigDecimal("1000")),
            null,"COVERAGE_TOTAL","ORDER_ALL");
        var result=aggregateOrders.submit(c.analysis(),aggregateFixture.command(c,List.of(input)));
        assertEquals(1,result.batches().size());var batch=result.batches().getFirst();
        amount("1000",batch.qty());amount("0",batch.publicExtraQty());
        amount("1000",batch.sources().stream().map(sourceRow->sourceRow.allocatedQty()).reduce(BigDecimal.ZERO,BigDecimal::add));
        amount("120",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.material()));
        amount("0",db.queryForObject("SELECT COALESCE(sum(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE goods_id=? AND status=0 AND NOT is_deleted",BigDecimal.class,c.material()));
    }

    @Test void adoptedPhysicalStockFollowsItsOwnPlanThenRestoresAndCancelsWithoutTouchingSalesOrSafety(){
        var c=aggregateFixture.create(false,false,"500");
        db.update("UPDATE goods SET min_qty=100 WHERE id=?",c.material());
        aggregateFixture.receive(c,c.material(),"1120");
        UUID sale=aggregateFixture.fixture.createApprovedOrder(c.world(),c.material(),"20","100");
        UUID saleItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,sale);
        var oldSales=reservations(saleItem);
        var current=refresh(c);
        var source=current.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())&&row.allocatedAvailableQty().compareTo(new BigDecimal("1000"))==0)
            .findFirst().orElseThrow();
        var input=new GroupInput("only-stock-lineage",List.of(source.materialLineId()),"BUY",new BigDecimal("1000"),true,
            null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(source.materialLineId(),new BigDecimal("1000")),
            null,"COVERAGE_TOTAL","AVAILABLE_ONLY");
        var adopted=aggregateOrders.submit(c.analysis(),aggregateFixture.command(c,List.of(input)));
        assertTrue(adopted.batches().isEmpty());
        var beforePlan=analyses.detail(c.analysis());
        var generated=commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(beforePlan.version(),beforePlan.fingerprint(),key("root-plan"),
            c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(
            new IssueWorkshopPlansRequest.IssuePlanLine(null,source.analysisLineId(),new BigDecimal("500"),null,null,c.workshop(),null,c.worker(),null,null,false,
                BigDecimal.ZERO,"COVERAGE_TOTAL","ORDER_ALL"))));
        assertEquals(1,generated.plans().size());UUID plan=generated.plans().getFirst().planId();
        amount("1000",db.queryForObject("""
            SELECT COALESCE(sum(reservation.qty-reservation.consumed_qty-reservation.released_qty),0)
            FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.demand_id
            WHERE demand.plan_id=? AND reservation.goods_id=? AND reservation.status=0 AND NOT reservation.is_deleted
            """,BigDecimal.class,plan,c.material()));
        assertEquals(oldSales,reservations(saleItem));
        var live=analyses.detail(c.analysis());
        var restored=withdrawals.withdraw(c.analysis(),plan,new PlanWithdrawalRequest(live.version(),live.fingerprint(),key("withdraw"),"撤回本来源未执行计划"));
        var restoredSource=restored.flatMaterials().stream().filter(row->row.materialLineId().equals(source.materialLineId())).findFirst().orElseThrow();
        amount("1000",restoredSource.preparationOwnedAvailableQty());
        for(var sibling:restored.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())&&!row.materialLineId().equals(source.materialLineId())).toList())
            amount("0",sibling.preparationOwnedAvailableQty());
        var cancelled=commands.cancelAnalysis(c.analysis(),new CancelRequest(restored.version(),restored.fingerprint(),key("cancel-stock"),"取消本批公共现货采用"));
        assertEquals("CANCELLED",cancelled.status());assertEquals(oldSales,reservations(saleItem));
        amount("20",db.queryForObject("SELECT COALESCE(sum(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE goods_id=? AND status=0 AND NOT is_deleted",BigDecimal.class,c.material()));
        amount("1120",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.material()));
    }

    private AnalysisView refresh(AggregateMaterialOrderEndToEndTest.Case c){
        var current=analyses.detail(c.analysis());
        var sources=current.products().stream().filter(product->"SALES_ORDER_ITEM".equals(product.sourceType()))
            .map(product->new PreviewItem("SALES_ORDER_ITEM",product.salesOrderItemId(),null,null,null,null,null,product.deliveryDate(),product.requestedQty())).toList();
        return analyses.preview(new PreviewRequest(c.analysis(),current.version(),current.fingerprint(),c.world().warehouseId(),key("refresh"),sources));
    }

    private SalesCase salesCase(String available){
        var world=fixture.seedWorld("row-method-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        UUID goods=world.goodsC();fixture.seedGoodsSources(Map.of(goods,"BUY"));receive(world,goods,available);
        UUID order=fixture.createApprovedOrder(world,goods,"1000","100");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        String number=db.queryForObject("SELECT bill_no FROM sales_orders WHERE id=?",String.class,order);
        amount(available,db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item));
        var candidates=schedule.pending(1,100,null,null,null,null,null,null,number).getItems();
        var candidate=candidates.stream().filter(row->row.orderItemId().equals(item)).findFirst().orElseThrow();
        amount("1000",candidate.needQty());amount(available,candidate.reservedQty());
        amount("1000",schedule.orderLines(order).stream().filter(row->row.orderItemId().equals(item)).findFirst().orElseThrow().needQty());
        var view=analyses.preview(new PreviewRequest(null,null,null,world.warehouseId(),key("preview"),List.of(
            new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,BusinessTime.today().plusDays(10),candidate.needQty()))));
        return new SalesCase(world,goods,item,view);
    }
    private void assertDemandAndAvailable(SalesCase c,String available){
        var root=material(c.view(),c.goods());
        assertEquals("ROOT_SUPPLY",root.nodeRole());assertEquals("BUY",root.sourceConfirmed());
        amount("1000",root.sourceRequiredQty());amount("1000",c.view().products().getFirst().requestedQty());
        amount(available,root.preparationOwnedAvailableQty());
    }
    private NotifyRequest notify(SalesCase c,AnalysisView view,String method){
        var root=material(view,c.goods());
        return new NotifyRequest(view.version(),view.fingerprint(),key("notify"),"BUY",List.of(root.materialLineId()),List.of(),List.of(
            new SupplyQuantityInput(null,root.materialLineId(),new BigDecimal("1000"),BigDecimal.ZERO,"COVERAGE_TOTAL",method)));
    }
    private PreviewIssuePlansRequest preview(AggregateMaterialOrderEndToEndTest.Case c,AnalysisView view,MaterialView parent,String method){
        return new PreviewIssuePlansRequest(view.version(),view.fingerprint(),key("typed"),c.world().warehouseId(),BusinessTime.today(),
            BusinessTime.today().plusDays(10),false,List.of(),List.of(new PreviewIssuePlansRequest.TypedOutput(parent.materialLineId(),
            new BigDecimal("1000"),"COVERAGE_TOTAL",method)));
    }
    private void receive(FullChainEndToEndTest.World world,UUID goods,String quantity){
        var request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(world.warehouseId());request.setBillDate(BusinessTime.today());
        var line=new StockDocItemLine();line.setGoodsId(goods);line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(quantity));
        line.setPrice(BigDecimal.TEN);line.setAmountOriginal(line.getQty().multiply(BigDecimal.TEN));line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));stock.approve(stock.create(request).getId());
    }
    private List<Map<String,Object>> reservations(UUID item){return db.queryForList("""
        SELECT id,owner_type,owner_id,warehouse_id,qty,consumed_qty,released_qty,status,is_deleted
        FROM stock_reservations WHERE order_item_id=? ORDER BY id
        """,item);}
    private BigDecimal purchased(UUID analysis){return db.queryForObject("""
        SELECT COALESCE(sum(item.qty),0) FROM purchase_request_items item
        WHERE NOT item.is_deleted AND item.request_id IN(
            SELECT external_document_id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY' AND operation_type='SUPPLY')
        """,BigDecimal.class,analysis);}
    private BigDecimal rootFulfilled(SalesCase c){return db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE analysis_id=? AND sales_order_item_id=?",BigDecimal.class,c.view().analysisId(),c.salesItem());}
    private static MaterialView material(AnalysisView view,UUID goods){return view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).findFirst().orElseThrow();}
    private static String key(String action){return "row-method-"+action+"-"+UUID.randomUUID();}
    private static void amount(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual);}
    private record SalesCase(FullChainEndToEndTest.World world,UUID goods,UUID salesItem,AnalysisView view){}
}
