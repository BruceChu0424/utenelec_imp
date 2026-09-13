package com.uten.imp.businesschain;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.BatchShipRequest;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SalesShipmentBatchPhysicalSourcesEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesShipmentService shipments;
    @Autowired SalesOrderService orders;
    @Autowired StockDocService stock;
    @Autowired StockReservationService reservations;
    @Autowired PlatformTransactionManager transactions;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare() { fixture=new FullChainEndToEndTest();beans.autowireBean(fixture); }
    @Test void partialStockForThousandUnitOrderSplitsPhysicalSourcesAndReplaysWithoutDuplicateDrafts() { run(false); }
    @Test void exactReservationsAtTwoWarehousesSplitAndKeepEachOriginalPhysicalSource() { run(true); }
    private void run(boolean exact) {
        var w=fixture.seedWorld("ship-batch-"+exact);fixture.loginAs(w.superAdminUserId());
        UUID second=UUID.randomUUID(), main=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",main,"BATCH-MAIN-"+main,"成品主仓");
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",second,"BATCH-W-"+second,"第二成品仓");
        db.update("UPDATE warehouses SET parent_id=? WHERE id IN (?,?)",main,w.warehouseId(),second);
        opening(w,w.warehouseId(),"3");opening(w,second,"7");
        UUID order=fixture.createApprovedOrder(w,w.goodsA(),"1000","100");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        fixture.loginAs(w.superAdminUserId());
        if(exact) new TransactionTemplate(transactions).executeWithoutResult(status->{
            reservations.releaseForOrderItem(item,BigDecimal.TEN);
            reservations.reserve(item,w.goodsA(),null,w.warehouseId(),new BigDecimal("3"),(short)0,"SALES_ORDER",order);
            reservations.reserve(item,w.goodsA(),null,second,new BigDecimal("7"),(short)0,"SALES_ORDER",order);
        });
        var before=orders.planProgress(order).getFirst();qty("10",before.shippableQty());qty("0",before.pendingShipmentQty());
        BatchShipRequest request=new BatchShipRequest();request.setBillDate(BusinessTime.today());
        request.setIdempotencyKey("batch-intent-"+item);request.setShipAddr("客户明确填写的送货地址");
        request.setLinkPhone("13800000000");request.setLogisticsNo("LOG-"+item);request.setRemark("先发已入库的十件");
        BatchShipRequest.Line line=new BatchShipRequest.Line();line.setOrderItemId(item);line.setQty(BigDecimal.TEN);line.setRemark("本批十件");
        request.setLines(List.of(line));
        db.update("UPDATE warehouses SET status='禁用' WHERE id=?",main);
        assertThrows(ApiException.class,()->shipments.batchCreate(request),"disabled ancestor must not produce unusable source suggestions");
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM sales_shipments WHERE source_order_id=?",Integer.class,order));
        db.update("UPDATE warehouses SET status='使用' WHERE id=?",main);
        List<ShipmentDetail> created=shipments.batchCreate(request);
        assertEquals(2,created.size());assertEquals(Set.of(w.warehouseId(),second),Set.copyOf(created.stream().map(ShipmentDetail::getWarehouseId).toList()));
        assertEquals(Set.of("3.0000","7.0000"),Set.copyOf(created.stream().map(s->s.getItems().getFirst().getQty().setScale(4).toPlainString()).toList()));
        for(var document:created) {
            assertEquals(request.getShipAddr(),document.getShipAddr());assertEquals(request.getLogisticsNo(),document.getLogisticsNo());
            assertEquals("本批十件",document.getItems().getFirst().getRemark());
            assertTrue(db.queryForObject("SELECT warehouse_chosen_at_pick FROM sales_shipments WHERE id=?",Boolean.class,document.getId()));
            assertEquals("null",db.queryForObject("SELECT (fn_customer_shipment_commercial_snapshot(?)::jsonb #> '{header,warehouseId}')::text",String.class,document.getId()));
        }
        assertEquals(created.stream().map(ShipmentDetail::getId).toList(),shipments.batchCreate(request).stream().map(ShipmentDetail::getId).toList());
        var after=orders.planProgress(order).getFirst();qty("0",after.shippableQty());qty("10",after.pendingShipmentQty());
        line.setQty(new BigDecimal("9"));assertThrows(ApiException.class,()->shipments.batchCreate(request));
        line.setQty(BigDecimal.ONE);request.setIdempotencyKey("new-intent-"+item);assertThrows(ApiException.class,()->shipments.batchCreate(request));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM sales_shipments WHERE source_order_id=?",Integer.class,order));
        qty("10",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,w.goodsA()));
        qty("0",db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item));
        line.setQty(BigDecimal.TEN);request.setIdempotencyKey("batch-intent-"+item);
        shipments.delete(created.getFirst().getId());
        assertThrows(ApiException.class,()->shipments.batchCreate(request),"deleted member must not cause a replay to create a replacement batch");
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM sales_shipments WHERE source_order_id=?",Integer.class,order));
    }
    private void opening(FullChainEndToEndTest.World w,UUID warehouse,String amount) {
        StockDocSaveRequest request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setBillDate(BusinessTime.today());request.setWarehouseId(warehouse);
        StockDocItemLine line=new StockDocItemLine();line.setGoodsId(w.goodsA());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(amount));line.setPrice(BigDecimal.TEN);line.setAmountOriginal(line.getQty().multiply(BigDecimal.TEN));line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));stock.approve(stock.create(request).getId());
    }
    private static void qty(String expected,BigDecimal actual) { assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual); }
}
