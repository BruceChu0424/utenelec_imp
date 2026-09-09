package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.CancelRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.dao.DataAccessException;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.sql.SQLException;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real SC assembly, two physical FG receipts, finance, outbound and original-source reversal. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractPreparationActualWarehousePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired SubcontractOrderService orders;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;

    @Test void splitPreparedOutputStaysExclusiveAndShipsAndRestoresAtItsActualWarehouses(){
        verifyPreparationWarehouses(true);
    }

    @Test void partialPreparedOutputInOneOtherWarehouseCompletesItsExactOutboundAndReversal(){
        verifyPreparationWarehouses(false);
    }

    @Test void directDraftFinishedOutputBelongsOnlyToItsOriginalOrderThroughFinanceAndReversal(){
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var w=fixture.seedWorld("direct-sc-owned-output");fixture.loginAs(w.superAdminUserId());
        UUID product=UUID.randomUUID();fixture.insertGoods(product,"DIRECT-SC-"+product,"原订货专属委外前置产出","委外",w.unitId(),w.unitLegacy());
        fixture.insertBom(product,w.goodsC(),"1");
        call(fixture,"putDirectTargetStock",w,w.goodsC(),"1"); // Actual OTHER_IN, known source cost 10.
        OrderSaveRequest request=call(fixture,"directSubcontractDraft",w,product,(Object)new String[]{"1"});
        var order=orders.create(request);UUID orderItem=order.getItems().getFirst().getId();
        UUID analysis=db.queryForObject("SELECT analysis_id FROM production_material_analysis_items WHERE subcontract_order_item_id=?",UUID.class,orderItem);
        var view=analyses.detail(analysis);
        var generated=commands.issueWorkshopPlans(analysis,new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "direct-owned-plan-"+orderItem,w.warehouseId(),BusinessTime.today(),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,view.products().getFirst().analysisLineId(),BigDecimal.ONE,
                        BusinessTime.today(),null,null,null,null,null,null)))).plans().getFirst();
        for(UUID draw:db.queryForList("SELECT draw_id FROM plan_draw_links WHERE plan_id=? AND NOT is_deleted",UUID.class,generated.planId())){
            com.uten.imp.features.stock.dto.StockDocIssueRequest issue=call(fixture,"drawIssueRequest",draw,"direct-owned-draw-"+draw,null,BigDecimal.ZERO);
            stock.approveAndIssue(draw,issue);
        }
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND goods_id=?",UUID.class,generated.planId(),product);
        UUID actual=warehouse("Direct SC owned actual warehouse",false);
        call(fixture,"produceInternal",withWarehouse(w,actual),planItem,product,"1");
        qty("1",held("SUBCONTRACT_ORDER_PREPARATION",orderItem,actual));
        qty("1",balance(actual,product));
        qty("0",db.queryForObject("SELECT available_qty FROM v_stock_available WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,actual,product));
        UUID originalFg=db.queryForObject("SELECT source_doc_id FROM stock_reservations WHERE owner_type='SUBCONTRACT_ORDER_PREPARATION' AND owner_id=?",UUID.class,orderItem);
        UUID originalFgItem=db.queryForObject("SELECT supply_id FROM stock_reservations WHERE owner_type='SUBCONTRACT_ORDER_PREPARATION' AND owner_id=?",UUID.class,orderItem);
        rejectIdentityChange(() -> db.update("UPDATE stock_reservations SET released_qty=qty,status=1 WHERE owner_type='SUBCONTRACT_ORDER_PREPARATION' AND owner_id=?",orderItem));
        qty("1",held("SUBCONTRACT_ORDER_PREPARATION",orderItem,actual));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_analysis_stock_exact_pegs exact JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id WHERE reservation.goods_id=?",Integer.class,product));
        assertThrows(ApiException.class,()->orders.delete(order.getId()));
        OrderSaveRequest otherRequest=call(fixture,"directSubcontractDraft",w,product,(Object)new String[]{"1"});
        var other=orders.create(otherRequest);UUID otherItem=other.getItems().getFirst().getId();
        qty("1",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE subcontract_order_item_id=?",BigDecimal.class,otherItem));
        UUID reviewer=call(fixture,"createApprover",w);Object finance=ReflectionTestUtils.getField(fixture,"financeApproval");
        assertThrows(ApiException.class,()->call(finance,"submit","SUBCONTRACT",other.getId()));
        call(finance,"submit","SUBCONTRACT",order.getId());fixture.loginAs(reviewer);call(fixture,"approvePendingFinance","SUBCONTRACT",order.getId());
        fixture.loginAs(w.superAdminUserId());
        UUID outbound=db.queryForObject("SELECT id FROM subcontract_material_plan_items WHERE order_item_id=? AND flow_mode='PREPARED_OUTBOUND' AND NOT is_deleted",UUID.class,orderItem);
        qty("0",held("SUBCONTRACT_ORDER_PREPARATION",orderItem,actual));qty("1",held("SUBCONTRACT_OUTBOUND",outbound,actual));
        assertThrows(ApiException.class,()->stock.reverseFinishedInbound(originalFg));
        UUID draft=db.queryForObject("SELECT issue.id FROM subcontract_material_issues issue JOIN subcontract_material_issue_items item ON item.issue_id=issue.id WHERE item.plan_item_id=? AND issue.status=0 AND NOT issue.is_deleted",UUID.class,outbound);
        assertEquals(actual,db.queryForObject("SELECT warehouse_id FROM subcontract_material_issues WHERE id=?",UUID.class,draft));
        issues.approve(draft);qty("0",balance(actual,product));issues.reverse(draft);qty("1",balance(actual,product));
        orders.reverse(order.getId());
        qty("1",held("SUBCONTRACT_ORDER_PREPARATION",orderItem,actual));
        assertEquals(originalFgItem,db.queryForObject("SELECT supply_id FROM stock_reservations WHERE owner_type='SUBCONTRACT_ORDER_PREPARATION' AND owner_id=? AND status=0 AND qty>released_qty",UUID.class,orderItem));
        qty("0",db.queryForObject("SELECT available_qty FROM v_stock_available WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,actual,product));
        stock.reverseFinishedInbound(originalFg);qty("0",balance(actual,product));qty("0",held("SUBCONTRACT_ORDER_PREPARATION",orderItem,actual));
        orders.delete(other.getId());
    }

    private void verifyPreparationWarehouses(boolean multipleActualWarehouses){
        var setup=new QualifiedSourceWarehouseEndToEndTest();beans.autowireBean(setup);setup.prepare();
        Object source=call(setup,"makeCase",multipleActualWarehouses?"sc-actual-two-warehouses":"sc-actual-one-warehouse",true);
        FullChainEndToEndTest fixture=(FullChainEndToEndTest)ReflectionTestUtils.getField(setup,"fixture");
        assertNotNull(fixture);
        FullChainEndToEndTest.World world=call(source,"world");
        UUID analysis=call(source,"analysis"), child=call(source,"childAnalysisItem"), goods=call(source,"childGoods");
        UUID childPlan=call(source,"childPlan"), parentPlan=call(source,"parentPlan");
        UUID childPlanItem=call(source,"childPlanItem"), leafPlanItem=call(source,"leafPlanItem"), leafGoods=call(source,"leafGoods");
        UUID b=warehouse("SC actual B",true),c=multipleActualWarehouses?warehouse("SC actual C",false):b;
        List<Object[]> expectedWarehouses=multipleActualWarehouses
                ? List.of(new Object[]{b,"0.4"},new Object[]{c,"0.6"})
                : java.util.Collections.singletonList(new Object[]{b,"1"});
        call(fixture,"produceInternal",world,leafPlanItem,leafGoods,"1");
        for(UUID draw:db.queryForList("SELECT draw_id FROM plan_draw_links WHERE plan_id=? AND NOT is_deleted",UUID.class,childPlan)){
            com.uten.imp.features.stock.dto.StockDocIssueRequest request=call(fixture,"drawIssueRequest",draw,"sc-actual-draw-"+draw,null,BigDecimal.ZERO);
            stock.approveAndIssue(draw,request);
        }
        call(fixture,"produceInternal",withWarehouse(world,b),childPlanItem,goods,"0.4");
        UUID task=db.queryForObject("SELECT id FROM preplan_subcontract_make_tasks WHERE preparation_item_id=?",UUID.class,child);
        qty("0.4",held("SUBCONTRACT_PREPARE_TASK",task,b));
        qty("0",db.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",BigDecimal.class,task));
        call(fixture,"produceInternal",withWarehouse(world,c),childPlanItem,goods,"0.6");
        qty(multipleActualWarehouses?"0.6":"1",held("SUBCONTRACT_PREPARE_TASK",task,c));
        qty("1",db.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",BigDecimal.class,task));
        assertWaiting(parentPlan);
        assertEquals(0,db.queryForObject("""
                SELECT count(*) FROM preplan_stock_entitlement_events event
                JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id
                WHERE event.event_type='ORIGIN_MAKE' AND reservation.goods_id=?
                """,Integer.class,goods));
        assertEquals(2,db.queryForObject("""
                SELECT count(*) FROM stock_reservations WHERE owner_type='SUBCONTRACT_PREPARE_TASK' AND owner_id=?
                  AND fn_subcontract_preparation_reservation_has_qualified_origin(id)
                """,Integer.class,task));
        rejectIdentityChange(() -> db.update("UPDATE production_material_analysis_items SET source_type='MAKE_COMPONENT' WHERE id=?",child));
        assertEquals("SUBCONTRACT_MAKE",db.queryForObject("SELECT source_type FROM production_material_analysis_items WHERE id=?",String.class,child));
        UUID originalReservation=db.queryForObject("SELECT id FROM stock_reservations WHERE owner_type='SUBCONTRACT_PREPARE_TASK' AND owner_id=? ORDER BY id LIMIT 1",UUID.class,task);
        UUID originalWarehouse=db.queryForObject("SELECT warehouse_id FROM stock_reservations WHERE id=?",UUID.class,originalReservation);
        rejectIdentityChange(() -> db.update("UPDATE stock_reservations SET warehouse_id=? WHERE id=?",world.warehouseId(),originalReservation));
        assertEquals(originalWarehouse,db.queryForObject("SELECT warehouse_id FROM stock_reservations WHERE id=?",UUID.class,originalReservation));
        List<UUID> originalFg=db.queryForList("""
                SELECT reservation.source_doc_id FROM stock_reservations reservation
                JOIN stock_documents document ON document.id=reservation.source_doc_id
                WHERE reservation.owner_type='SUBCONTRACT_PREPARE_TASK' AND reservation.owner_id=?
                GROUP BY reservation.source_doc_id,document.created_at
                ORDER BY document.created_at DESC,reservation.source_doc_id DESC
                """,UUID.class,task);
        UUID applicationItem=db.queryForObject("SELECT application_item_id FROM preplan_subcontract_make_task_batches WHERE task_id=?",UUID.class,task);
        UUID application=db.queryForObject("SELECT application_id FROM subcontract_application_items WHERE id=?",UUID.class,applicationItem);
        var request=new OrderSaveRequest();
        request.setSettlementMethodId(call(fixture,"activeSettlementMethodId"));request.setBillDate(BusinessTime.today());
        request.setSupplierId(world.supplierId());request.setWarehouseId(world.warehouseId());request.setCurrencyId(world.currencyId());
        request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        var line=new OrderItemLine();line.setGoodsId(goods);line.setApplicationItemId(applicationItem);
        line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);
        line.setPrice(new BigDecimal("30"));line.setAmountOriginal(new BigDecimal("30"));line.setAmountLocal(new BigDecimal("30"));request.setItems(List.of(line));
        UUID order=orders.create(request).getId();
        UUID reviewer=call(fixture,"createApprover",world);
        Object finance=ReflectionTestUtils.getField(fixture,"financeApproval");assertNotNull(finance);
        call(finance,"submit","SUBCONTRACT",order);
        fixture.loginAs(reviewer);call(fixture,"approvePendingFinance","SUBCONTRACT",order);
        fixture.loginAs(world.superAdminUserId());
        UUID planItem=db.queryForObject("""
                SELECT item.id FROM subcontract_material_plan_items item
                JOIN subcontract_material_plans plan ON plan.id=item.plan_id WHERE plan.order_id=? AND NOT item.is_deleted
                """,UUID.class,order);
        for(Object[] expected:expectedWarehouses){
            UUID actual=(UUID)expected[0];qty((String)expected[1],held("SUBCONTRACT_OUTBOUND",planItem,actual));
            qty((String)expected[1],db.queryForObject("""
                    SELECT sum(item.qty) FROM subcontract_material_issue_items item
                    JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                    WHERE item.plan_item_id=? AND issue.warehouse_id=? AND issue.status=0 AND NOT issue.is_deleted
                    """,BigDecimal.class,planItem,actual));
        }
        List<UUID> drafts=db.queryForList("""
                SELECT DISTINCT issue.id FROM subcontract_material_issues issue
                JOIN subcontract_material_issue_items item ON item.issue_id=issue.id
                WHERE item.plan_item_id=? AND issue.status=0 AND NOT issue.is_deleted ORDER BY issue.id
                """,UUID.class,planItem);
        assertEquals(expectedWarehouses.size(),drafts.size());
        for(UUID draft:drafts)issues.approve(draft);
        qty("0",balance(b,goods));qty("0",balance(c,goods));assertWaiting(parentPlan);
        for(UUID draft:drafts)issues.reverse(draft);
        for(Object[] expected:expectedWarehouses)qty((String)expected[1],balance((UUID)expected[0],goods));
        orders.reverse(order);
        for(Object[] expected:expectedWarehouses)qty((String)expected[1],held("SUBCONTRACT_PREPARE_TASK",task,(UUID)expected[0]));
        assertEquals(0,db.queryForObject("""
                SELECT count(*) FROM stock_reservations reservation
                WHERE reservation.owner_type='SUBCONTRACT_PREPARE_TASK' AND reservation.owner_id=?
                  AND reservation.qty>reservation.released_qty
                  AND (NOT fn_subcontract_preparation_reservation_has_qualified_origin(reservation.id)
                       OR reservation.source_doc_id NOT IN (SELECT doc_id FROM stock_document_items WHERE id=reservation.supply_id))
                """,Integer.class,task));
        UUID notification=db.queryForObject("""
                SELECT id FROM preplan_supply_actions WHERE analysis_id=?
                  AND external_document_type='SUBCONTRACT_APPLICATION' AND external_document_id=?
                """,UUID.class,analysis,application);
        var current=analyses.detail(analysis);
        commands.cancelAction(analysis,notification,new CancelRequest(current.version(),current.fingerprint(),"sc-actual-cancel-"+task,"原来源出仓已反向"));
        for(UUID inbound:originalFg)stock.reverseFinishedInbound(inbound);
        qty("0",db.queryForObject("SELECT produced_qty FROM preplan_subcontract_make_tasks WHERE id=?",BigDecimal.class,task));
        qty("0",balance(b,goods));qty("0",balance(c,goods));assertWaiting(parentPlan);
    }

    private BigDecimal held(String owner,UUID id,UUID warehouse){return db.queryForObject("SELECT coalesce(sum(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE owner_type=? AND owner_id=? AND warehouse_id=? AND status=0 AND NOT is_deleted",BigDecimal.class,owner,id,warehouse);}
    private BigDecimal balance(UUID warehouse,UUID goods){return db.queryForObject("SELECT coalesce(sum(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,warehouse,goods);}
    private void assertWaiting(UUID plan){assertEquals("WAITING",db.queryForObject("SELECT status FROM production_execution_segments WHERE plan_id=?",String.class,plan));}
    private UUID warehouse(String name,boolean defective){UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective) VALUES(?,?,?,'使用',TRUE,?)",id,"SC-WH-"+id,name,defective);return id;}
    private static FullChainEndToEndTest.World withWarehouse(FullChainEndToEndTest.World w,UUID warehouse){return new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),warehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());}
    private static <T>T call(Object target,String method,Object...args){return ReflectionTestUtils.invokeMethod(target,method,args);}
    private static void qty(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual));}
    private static void rejectIdentityChange(Runnable mutation){
        DataAccessException failure=assertThrows(DataAccessException.class,mutation::run);
        SQLException sql=null;
        for(Throwable cause=failure;cause!=null;cause=cause.getCause())if(cause instanceof SQLException found){sql=found;break;}
        assertNotNull(sql);assertEquals("23514",sql.getSQLState(),sql.getMessage());
    }
}
