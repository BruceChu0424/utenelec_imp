package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundProjectionService;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundWarehouseChoice;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SalesShipmentWarehouseAssignmentEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesShipmentService shipments;
    @Autowired com.uten.imp.features.sales.order.SalesOrderService orders;
    @Autowired WarehouseSalesOutboundProjectionService warehouse;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void salesCanRequestTenOfAThousandWithoutAWarehouseAndWarehouseConfirmsOutboundAfterFinance() {
        var w=fixture.seedWorld("sales-physical-pick");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"10");
        UUID order=fixture.createApprovedOrder(w,w.goodsE(),"1000","100");
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"shipmentRequest",w,orderItem,w.goodsE(),"10");
        assertNotNull(request);request.setWarehouseId(null);
        var draft=shipments.create(request);assertNull(draft.getWarehouseId());
        String frozen=db.queryForObject("SELECT commercial_snapshot::text FROM sales_shipment_submission_events WHERE shipment_id=?",String.class,draft.getId());
        var outbound=new WarehouseWorkTransitionRequest();outbound.setTargetStatus("SHIPPED");outbound.setWarehouseId(w.warehouseId());
        outbound.setStockPlaces(List.of(new WarehouseWorkTransitionRequest.StockPlace(draft.getItems().getFirst().getId(),"A-02-03")));
        assertThrows(ApiException.class,()->shipments.transitionWarehouseWork(draft.getId(),outbound));
        assertThrows(ApiException.class,()->warehouse.detail(draft.getId()));
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",draft.getId());
        UUID warehouseUser=fixture.createUserWithPerms(w,"physical-picker","warehouse_sales_outbound:view", "warehouse_sales_outbound:execute");fixture.loginAs(warehouseUser);
        var task=warehouse.detail(draft.getId());
        // 小类行计数与 /count 同源同数(同库里可能有别的用例留下的待出库单, 只断言一致性、包含本单与后面的增减量).
        var countsBefore=warehouse.counts();assertEquals(countsBefore.get("PENDING_PICK").longValue(),warehouse.pendingCount());assertTrue(countsBefore.get("PENDING_PICK")>=1L);
        assertTrue(warehouse.list(draft.getBillNo(),"PENDING_PICK",null,null,1,20).getItems().stream().anyMatch(item->item.id().equals(draft.getId())));
        // V631：发出仓按行给候选与可发量，表头仓能发就预填表头仓。
        var choice=task.lines().getFirst().warehouseChoices().stream().filter(value->value.warehouseId().equals(w.warehouseId())).findFirst().orElseThrow();
        assertTrue(choice.canFulfill());qty("10",choice.availableQty());
        assertEquals(w.warehouseId(),task.lines().getFirst().suggestedWarehouseId());
        var missing=new WarehouseWorkTransitionRequest();missing.setTargetStatus("SHIPPED");
        assertThrows(ApiException.class,()->warehouse.transition(draft.getId(),missing));
        UUID wrongWarehouse=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',TRUE)",wrongWarehouse,"EMPTY-"+wrongWarehouse,"没有本批库存的仓");
        outbound.setWarehouseId(wrongWarehouse);
        assertThrows(ApiException.class,()->warehouse.transition(draft.getId(),outbound));
        // 整事务回滚：错仓被拒后既不落仓、也不推状态。
        assertNull(db.queryForObject("SELECT warehouse_id FROM sales_shipments WHERE id=?",UUID.class,draft.getId()));
        assertEquals("PENDING_PICK",db.queryForObject("SELECT warehouse_work_status FROM sales_shipments WHERE id=?",String.class,draft.getId()));
        outbound.setWarehouseId(w.warehouseId());
        var shipped=warehouse.transition(draft.getId(),outbound);
        // 一步式确认出库把 status 翻成 1: 仓库投影不能再按 status=0 过滤, 「已出库」段与历史段都要列得出这张单; 计数从 PENDING_PICK 转到 SHIPPED 各差 1.
        assertTrue(warehouse.list(draft.getBillNo(),"SHIPPED",null,null,1,20).getItems().stream().anyMatch(item->item.id().equals(draft.getId())));
        assertTrue(warehouse.list(draft.getBillNo(),null,null,null,1,20).getItems().stream().anyMatch(item->item.id().equals(draft.getId())));
        var countsAfter=warehouse.counts();
        assertEquals(countsBefore.get("PENDING_PICK")-1L,countsAfter.get("PENDING_PICK").longValue());
        assertEquals(countsBefore.get("SHIPPED")+1L,countsAfter.get("SHIPPED").longValue());
        assertEquals(countsAfter.get("PENDING_PICK").longValue(),warehouse.pendingCount());
        assertEquals("SHIPPED",shipped.warehouseWorkStatus());assertEquals(w.warehouseId(),shipped.warehouseId());
        assertEquals("A-02-03",shipped.lines().getFirst().actualStockPlace());
        assertEquals(w.warehouseId(),shipped.lines().getFirst().warehouseId());assertTrue(shipped.lines().getFirst().warehouseChoices().isEmpty());
        assertEquals(w.warehouseId(),db.queryForObject("SELECT warehouse_id FROM sales_shipment_items WHERE shipment_id=?",UUID.class,draft.getId()));
        assertEquals(frozen,db.queryForObject("SELECT fn_customer_shipment_commercial_snapshot(?)",String.class,draft.getId()));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE sales_shipments SET warehouse_id=? WHERE id=?",wrongWarehouse,draft.getId()));
        qty("10",db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,orderItem));
        qty("0",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,w.warehouseId(),w.goodsE()));
        assertEquals(frozen,db.queryForObject("SELECT commercial_snapshot::text FROM sales_shipment_submission_events WHERE shipment_id=?",String.class,draft.getId()));
        // 一步式：实仓与库位证据只挂在那一条确认出库事件上，且没有任何 PICKING 事件。
        assertEquals(1,db.queryForObject("SELECT count(*) FROM sales_shipment_warehouse_events WHERE shipment_id=? AND to_status='SHIPPED' AND warehouse_id=?",Integer.class,draft.getId(),w.warehouseId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM sales_shipment_warehouse_events WHERE shipment_id=? AND to_status IN ('PICKING','PICKED','EXCEPTION')",Integer.class,draft.getId()));
        qty("1000",db.queryForObject("SELECT amount_original FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",BigDecimal.class,draft.getId()));
        assertThrows(ApiException.class,()->warehouse.transition(draft.getId(),outbound));
    }

    @Test void freeCustomerShipmentCanUseAnUnassignedWarehouseAndAnEmptyLocationWithoutCreatingReceivables() {
        var w=fixture.seedWorld("sales-free-physical");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsB(),"5");
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"directCustomerShipmentRequest",w,"FREE","5");
        assertNotNull(request);request.setWarehouseId(null);
        var draft=shipments.create(request);shipments.confirmSales(draft.getId(),0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",draft.getId());
        var outbound=new WarehouseWorkTransitionRequest();outbound.setTargetStatus("SHIPPED");outbound.setWarehouseId(w.warehouseId());
        outbound.setStockPlaces(List.of(new WarehouseWorkTransitionRequest.StockPlace(draft.getItems().getFirst().getId(),"")));
        warehouse.transition(draft.getId(),outbound);
        assertFalse(db.queryForObject("SELECT ar_posted FROM sales_shipments WHERE id=?",Boolean.class,draft.getId()));
        assertEquals("",warehouse.detail(draft.getId()).lines().getFirst().actualStockPlace());
        qty("0",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,w.warehouseId(),w.goodsB()));
    }

    @Test void editingAnInternallySuggestedWarehouseDraftWithoutASalesWarehousePreservesTheSuggestion() {
        var w=fixture.seedWorld("sales-source-suggestion");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"10");
        UUID order=fixture.createApprovedOrder(w,w.goodsE(),"10","100");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"shipmentRequest",w,item,w.goodsE(),"5");
        assertNotNull(request);request.setWarehouseChoiceByWarehouse(true);
        var draft=shipments.create(request);assertEquals(w.warehouseId(),draft.getWarehouseId());
        request.setWarehouseId(null);request.setExpectedRevision(0L);request.setRemark("销售补充包装备注，仓库仍由仓库核对");
        var updated=shipments.update(draft.getId(),request);
        assertEquals(w.warehouseId(),updated.getWarehouseId());
        assertEquals(1L,db.queryForObject("SELECT review_revision FROM sales_shipments WHERE id=?",Long.class,draft.getId()));
        assertNull(db.queryForObject("SELECT fn_customer_shipment_commercial_snapshot(?)::jsonb#>>'{header,warehouseId}'",String.class,draft.getId()));
        request.setExpectedRevision(0L);assertThrows(ApiException.class,()->shipments.update(draft.getId(),request));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE sales_shipments SET warehouse_chosen_at_pick=FALSE WHERE id=?",draft.getId()));
    }

    @Test void anExistingSalesSelectedWarehouseCannotBeChangedAfterItsFinanceConfirmation() {
        var w=fixture.seedWorld("sales-existing-warehouse");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"10");
        UUID order=fixture.createApprovedOrder(w,w.goodsE(),"10","100");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        UUID shipment=fixture.createShipment(w,item,w.goodsE(),"5");
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var picking=new WarehouseWorkTransitionRequest();picking.setTargetStatus("SHIPPED");picking.setWarehouseId(UUID.randomUUID());
        assertThrows(ApiException.class,()->shipments.transitionWarehouseWork(shipment,picking));
        assertEquals(w.warehouseId(),db.queryForObject("SELECT warehouse_id FROM sales_shipments WHERE id=?",UUID.class,shipment));
        assertEquals(w.warehouseId(),warehouse.detail(shipment).lines().getFirst().suggestedWarehouseId());
        picking.setWarehouseId(null);assertEquals("SHIPPED",warehouse.transition(shipment,picking).warehouseWorkStatus());
    }

    @Test void warehouseOptionsProtectOtherOrdersGlobalReservationsAndKeepFractionalStockExact() {
        var w=fixture.seedWorld("sales-global-picking-budget");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsB(),"3.7500");
        db.update("UPDATE goods SET min_qty=0.15 WHERE id=?",w.goodsB());
        UUID order=fixture.createApprovedOrder(w,w.goodsB(),"3","100");
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"directCustomerShipmentRequest",w,"FREE","1");
        assertNotNull(request);request.setWarehouseId(null);
        var draft=shipments.create(request);shipments.confirmSales(draft.getId(),0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",draft.getId());
        var choice=warehouse.detail(draft.getId()).lines().getFirst().warehouseChoices().stream().filter(value->value.warehouseId().equals(w.warehouseId())).findFirst().orElseThrow();
        assertFalse(choice.canFulfill());qty("0.6000",choice.availableQty());
        var picking=new WarehouseWorkTransitionRequest();picking.setTargetStatus("SHIPPED");picking.setWarehouseId(w.warehouseId());
        assertThrows(ApiException.class,()->warehouse.transition(draft.getId(),picking));
        qty("3",db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE order_id=?",BigDecimal.class,order));
        qty("3.7500",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,w.warehouseId(),w.goodsB()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_reservations WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",Integer.class,draft.getId()));
    }

    @Test void outboundCannotUseOneOrderLinesSameGoodsReservationToCoverAnotherLinesDifferentWarehouse() {
        var w=fixture.seedWorld("sales-exact-pick-source");fixture.loginAs(w.superAdminUserId());
        UUID otherWarehouse=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',TRUE)",otherWarehouse,"SOURCE-"+otherWarehouse,"第二行真实来源仓");
        var other=new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),otherWarehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"4");
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",other,w.goodsE(),"2");
        var orderRequest=fixture.orderRequest(w,w.goodsE(),"4","100");
        orderRequest.setItems(List.of(orderRequest.getItems().getFirst(),fixture.orderRequest(w,w.goodsE(),"2","100").getItems().getFirst()));
        UUID order=orders.create(orderRequest).getId();orders.approve(order);ReflectionTestUtils.invokeMethod(fixture,"confirmInitialSalesFinance",order);
        var sourceItems=db.queryForList("SELECT id FROM sales_order_items WHERE order_id=? ORDER BY line_no",UUID.class,order);
        // Explicit fixture placement of unused global reservations in their
        // actual existing warehouses; no quantity or fulfilment is invented.
        db.update("UPDATE stock_reservations SET warehouse_id=? WHERE order_item_id=? AND status=0",w.warehouseId(),sourceItems.get(0));
        db.update("UPDATE stock_reservations SET warehouse_id=? WHERE order_item_id=? AND status=0",otherWarehouse,sourceItems.get(1));
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"shipmentRequest",w,sourceItems.get(0),w.goodsE(),"2");
        ShipmentSaveRequest second=ReflectionTestUtils.invokeMethod(fixture,"shipmentRequest",w,sourceItems.get(1),w.goodsE(),"2");
        assertNotNull(request);assertNotNull(second);request.setWarehouseId(null);request.setItems(List.of(request.getItems().getFirst(),second.getItems().getFirst()));
        UUID shipment=shipments.create(request).getId();ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var task=warehouse.detail(shipment);
        // V631：没有哪个仓能一次发出两行，但每行各有唯一能发出它的仓，预填即各自的来源仓。
        assertTrue(task.lines().stream().allMatch(line->line.warehouseChoices().stream()
                .filter(WarehouseSalesOutboundWarehouseChoice::canFulfill).count()==1));
        assertEquals(w.warehouseId(),task.lines().get(0).suggestedWarehouseId());
        assertEquals(otherWarehouse,task.lines().get(1).suggestedWarehouseId());
        // 整单硬按一个仓发仍被拒：第二行的预留不在这个仓。
        var picking=new WarehouseWorkTransitionRequest();picking.setTargetStatus("SHIPPED");picking.setWarehouseId(w.warehouseId());
        assertThrows(ApiException.class,()->warehouse.transition(shipment,picking));
        assertNull(db.queryForObject("SELECT warehouse_id FROM sales_shipments WHERE id=?",UUID.class,shipment));
        assertEquals("PENDING_PICK",db.queryForObject("SELECT warehouse_work_status FROM sales_shipments WHERE id=?",String.class,shipment));
        // 按行选仓即可一次出库：库存与预留各扣各仓，表头仓取第一行的发出仓，事件冻结逐行发出仓。
        var perLine=new WarehouseWorkTransitionRequest();perLine.setTargetStatus("SHIPPED");
        perLine.setStockPlaces(List.of(
                new WarehouseWorkTransitionRequest.StockPlace(task.lines().get(0).id(),"A-1",w.warehouseId()),
                new WarehouseWorkTransitionRequest.StockPlace(task.lines().get(1).id(),"B-1",otherWarehouse)));
        var shipped=warehouse.transition(shipment,perLine);
        assertEquals("SHIPPED",shipped.warehouseWorkStatus());assertEquals(w.warehouseId(),shipped.warehouseId());
        assertEquals(w.warehouseId(),shipped.lines().get(0).warehouseId());assertEquals(otherWarehouse,shipped.lines().get(1).warehouseId());
        qty("2",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,w.warehouseId(),w.goodsE()));
        qty("0",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,otherWarehouse,w.goodsE()));
        assertEquals(2,db.queryForObject("SELECT count(DISTINCT warehouse_id) FROM stock_movements WHERE source_doc_id=?",Integer.class,shipment));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM sales_shipment_warehouse_events e, jsonb_each_text(e.line_warehouses) WHERE e.shipment_id=? AND e.to_status='SHIPPED'",Integer.class,shipment));
    }

    private static void qty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
