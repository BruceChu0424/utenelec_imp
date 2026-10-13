package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInService;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Real root procurement: the analysis owns a scope; each qualified receipt retains its accounting leaf. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false"})
class RootSupplyActualWarehouseEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired PurchaseReceiptService receipts;
    @Autowired ProcurementIqcPreStockInService preStock;
    @Autowired ProcurementInspectionService inspections;
    @Autowired SalesOrderService sales;
    @Autowired SalesOrderFinanceConfirmService salesFinance;
    @Autowired TaskClaimService claims;
    @Autowired com.uten.imp.features.stock.StockDocService stock;
    @Autowired com.uten.imp.features.production.analysis.MaterialAnalysisRootSupplyService roots;
    @Autowired org.springframework.transaction.support.TransactionTemplate transactions;
    private FullChainEndToEndTest harness;

    @BeforeEach void prepare() { harness=new FullChainEndToEndTest();beans.autowireBean(harness); }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void twoFiveHundredRootsShelvedInOneLeafPassReplayAndReverseWithoutLosingTheirExactSources() {
        Fixture fixture=manualFixture();
        BigDecimal fiveHundred=new BigDecimal("500");
        var pending=db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=? ORDER BY id",
                UUID.class,fixture.receipt());
        assertThat(pending).hasSize(2);
        preStock.preStockIn("PURCHASE",fixture.receipt(),new PreStockInRequest(pending.stream()
                .map(id->new PreStockInItem(id,fixture.leaf(),"11")).toList()));
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id IN (?,?)",
                fixture.goods().get(0),fixture.goods().get(1))).isZero();
        var command=new BatchInspectionPassRequest(pending.stream().map(id->new BatchInspectionPassRequest.Item(
                id,fiveHundred,"root-actual-pass-"+id)).toList(),"两种包材实际在叶仓同库位合格");
        inspections.passBatch("PURCHASE",fixture.receipt(),command);
        assertRootsAndPhysical(fixture,"500","25000");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL'",
                fixture.analysis())).isEqualByComparingTo("2");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND warehouse_id<>?",
                fixture.analysis(),fixture.leaf())).isZero();
        assertThat(number("SELECT count(*) FROM stock_reservations WHERE source_doc_id=? AND owner_type='PREPLAN_ANALYSIS' AND qty-consumed_qty-released_qty<>0",
                fixture.receipt())).isZero();
        inspections.passBatch("PURCHASE",fixture.receipt(),command);
        assertRootsAndPhysical(fixture,"500","25000");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL'",
                fixture.analysis())).isEqualByComparingTo("2");
        harness.loginAs(fixture.world().superAdminUserId());
        receipts.reverse(fixture.receipt());
        assertRootsAndPhysical(fixture,"0","0");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='REVERSE'",
                fixture.analysis())).isEqualByComparingTo("2");
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id IN (?,?)",
                fixture.scope(),fixture.goods().get(0),fixture.goods().get(1))).isZero();
    }

    @Test void salesRootPartialPassesReserveTheActualLeafAndReceiptReversalMirrorsBothOriginalSlices() {
        SalesFixture fixture=salesFixture();
        UUID inspection=shelve(fixture);
        var first=new InspectionDispositionRequest("PASS",new BigDecimal("5"),"先合格五个","root-sale-first-"+inspection);
        inspections.dispose("PURCHASE",fixture.receipt(),inspection,first);
        assertSalesAndPhysical(fixture,"5","250");
        inspections.dispose("PURCHASE",fixture.receipt(),inspection,first);
        assertSalesAndPhysical(fixture,"5","250");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL'",fixture.analysis())).isEqualByComparingTo("1");
        inspections.dispose("PURCHASE",fixture.receipt(),inspection,new InspectionDispositionRequest("PASS",new BigDecimal("5"),"余下五个合格","root-sale-second-"+inspection));
        assertSalesAndPhysical(fixture,"10","500");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL'",fixture.analysis())).isEqualByComparingTo("2");
        assertThat(number("""
                SELECT count(*) FROM preplan_root_output_events output JOIN stock_reservations sale ON sale.id=output.sales_reservation_id
                WHERE output.analysis_id=? AND (output.warehouse_id<>? OR sale.warehouse_id<>output.warehouse_id)
                """,fixture.analysis(),fixture.leaf())).isZero();
        receipts.reverse(fixture.receipt());
        assertSalesAndPhysical(fixture,"0","0");
        assertThat(number("""
                SELECT count(*) FROM preplan_root_output_events reverse JOIN preplan_root_output_events original ON original.id=reverse.reversed_event_id
                WHERE reverse.analysis_id=? AND (reverse.warehouse_id<>original.warehouse_id OR reverse.source_reservation_id<>original.source_reservation_id
                    OR reverse.release_entitlement_event_id<>original.release_entitlement_event_id OR reverse.qty_base<>original.qty_base)
                """,fixture.analysis())).isZero();
    }

    @Test void financePendingArrivalKeepsTheExactQualifiedLeafLotAndLaterHandoffDoesNotBuyItAgain() {
        SalesFixture fixture=salesFixture();
        var changed=new OrderChangeQtyRequest.Line();changed.setOrderItemId(fixture.salesItem());changed.setNewQty(new BigDecimal("12"));
        var change=new OrderChangeQtyRequest();change.setItems(List.of(changed));sales.changeQty(fixture.salesOrder(),change);
        assertThat(db.queryForObject("SELECT finance_confirmed FROM sales_orders WHERE id=?",Boolean.class,fixture.salesOrder())).isFalse();
        UUID inspection=shelve(fixture);
        inspections.dispose("PURCHASE",fixture.receipt(),inspection,new InspectionDispositionRequest("PASS",null,"改单期间原采购仍真实入库","root-sale-pending-"+inspection));
        assertThat(number("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE root_material_id=?",fixture.root())).isZero();
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",fixture.leaf(),fixture.goods())).isEqualByComparingTo("10");
        assertThat(number("""
                SELECT COALESCE(SUM(entitlement.effective_qty),0) FROM v_preplan_stock_entitlement_beneficiary_balance entitlement
                JOIN stock_reservations reservation ON reservation.id=entitlement.stock_reservation_id
                WHERE entitlement.beneficiary_analysis_id=? AND entitlement.beneficiary_analysis_material_id=?
                  AND reservation.warehouse_id=? AND fn_preplan_reservation_has_qualified_origin(reservation.id)
                """,fixture.analysis(),fixture.root(),fixture.leaf())).isEqualByComparingTo("10");
        var held=analyses.detail(fixture.analysis()).flatMaterials().stream().filter(row->row.materialLineId().equals(fixture.root())).findFirst().orElseThrow();
        assertThat(held.shortageQty()).isZero();assertThat(held.allocatedAvailableQty()).isEqualByComparingTo("10");
        var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",fixture.salesOrder().toString());
        Long revision=db.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,fixture.salesOrder());
        salesFinance.confirm(fixture.salesOrder(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision,claim.claimId()));
        var approved=analyses.detail(fixture.analysis());
        var request=new NotifyRequest(approved.version(),approved.fingerprint(),"root-sale-resumed-"+fixture.analysis(),"BUY",List.of(fixture.root()),null,null);
        commands.notifySupply(fixture.analysis(),request);commands.notifySupply(fixture.analysis(),request);
        assertSalesAndPhysical(fixture,"10","500");
        assertThat(number("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY'",fixture.analysis())).isEqualByComparingTo("1");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL'",fixture.analysis())).isEqualByComparingTo("1");
    }

    @Test void shippedActualLeafRootCannotBeReversedAndLeavesAllReceiptFactsUntouched() {
        SalesFixture fixture=salesFixture();UUID inspection=shelve(fixture);
        inspections.dispose("PURCHASE",fixture.receipt(),inspection,new InspectionDispositionRequest("PASS",null,"合格后真实发货","root-sale-ship-"+inspection));
        var actualWorld=WarehouseIqcScaleFixture.withWarehouse(fixture.world(),fixture.leaf());
        com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(harness,
                "shipmentRequest",actualWorld,fixture.salesItem(),fixture.goods(),"10");
        request.setBillDate(BusinessTime.today());
        UUID shipment=beans.getBean(com.uten.imp.features.sales.shipment.SalesShipmentService.class).create(request).getId();
        ReflectionTestUtils.invokeMethod(harness,"shipThroughWarehouse",shipment);
        harness.loginAs(fixture.world().superAdminUserId());
        BigDecimal movements=number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",fixture.receipt());
        assertThatThrownBy(()->receipts.reverse(fixture.receipt())).isInstanceOf(ApiException.class).hasMessageContaining("已发货");
        assertThat(number("SELECT status FROM purchase_receipts WHERE id=?",fixture.receipt())).isEqualByComparingTo("1");
        assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",fixture.receipt())).isEqualByComparingTo(movements);
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='REVERSE'",fixture.analysis())).isZero();
        assertThat(number("SELECT count(*) FROM stock_value_events WHERE source_doc_id=? AND operation='POSITION_STORE_REVERSE'",fixture.receipt())).isZero();
    }

    @Test void publicRootStockUsesRealLeavesAndSubtractsGlobalReservationsOnceAcrossTheWholeScope() {
        String tag="root-public-"+UUID.randomUUID();var world=harness.seedWorld(tag);harness.loginAs(world.superAdminUserId());
        UUID scope=world.warehouseId(),first=leaf(scope),second=leaf(scope);
        db.update("UPDATE goods SET default_supplier_id=?,owning_warehouse_id=? WHERE id=?",world.supplierId(),first,world.goodsD());
        UUID order=ReflectionTestUtils.invokeMethod(harness,"createApprovedOrder",world,world.goodsD(),"10","100");
        UUID salesItem=ReflectionTestUtils.invokeMethod(harness,"orderItemId",order);harness.loginAs(world.superAdminUserId());
        receivePublic(world,first,"3");receivePublic(world,second,"7");
        UUID otherOrder=ReflectionTestUtils.invokeMethod(harness,"createApprovedOrder",world,world.goodsD(),"2","100");
        UUID otherItem=ReflectionTestUtils.invokeMethod(harness,"orderItemId",otherOrder);harness.loginAs(world.superAdminUserId());
        assertThat(number("SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE order_item_id=? AND warehouse_id IS NULL AND status=0",otherItem)).isEqualByComparingTo("2");
        var preview=analyses.preview(new PreviewRequest(null,null,null,scope,"root-public-preview-"+tag,
                List.of(new PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,BusinessTime.today(),BigDecimal.TEN))));
        var selected=preview.flatMaterials().stream().filter(row->"ROOT_SUPPLY".equals(row.nodeRole())).findFirst().orElseThrow();
        var routed=analyses.saveRoutes(preview.analysisId(),new RouteRequest(preview.version(),preview.fingerprint(),
                "root-public-route-"+tag,List.of(new RouteDecision(selected.materialLineId(),selected.actionGroupKey(),"BUY",null))));
        var root=routed.flatMaterials().stream().filter(row->row.materialLineId().equals(selected.materialLineId())).findFirst().orElseThrow();
        assertThat(root.allocatedAvailableQty()).isEqualByComparingTo("8");assertThat(root.shortageQty()).isEqualByComparingTo("2");
        var command=new NotifyRequest(routed.version(),routed.fingerprint(),"root-public-notify-"+tag,"BUY",List.of(root.materialLineId()),List.of(),null);
        commands.notifySupply(preview.analysisId(),command);commands.notifySupply(preview.analysisId(),command);
        assertThat(number("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE root_material_id=?",root.materialLineId())).isEqualByComparingTo("8");
        assertThat(number("SELECT reserved_qty FROM sales_order_items WHERE id=?",salesItem)).isEqualByComparingTo("8");
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM purchase_request_items WHERE request_id IN(SELECT external_document_id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY') AND NOT is_deleted",preview.analysisId())).isEqualByComparingTo("2");
        assertThat(number("""
                SELECT COALESCE(SUM(output.qty_base),0) FROM preplan_root_output_events output
                JOIN stock_reservations sale ON sale.id=output.sales_reservation_id
                WHERE output.analysis_id=? AND output.source_receipt_id IS NULL
                  AND output.warehouse_id=sale.warehouse_id AND output.warehouse_id IN(?,?)
                """,preview.analysisId(),first,second)).isEqualByComparingTo("8");
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",world.goodsD())).isEqualByComparingTo("10");
        assertThat(number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",world.goodsD())).isEqualByComparingTo("100");
        List<UUID> outputs=db.queryForList("SELECT id FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL' ORDER BY id",UUID.class,preview.analysisId());
        assertThat(outputs).hasSize(2);
        transactions.executeWithoutResult(ignored->{for(UUID output:outputs)roots.revokeExistingOutput(preview.analysisId(),output,"按原实际分仓撤回现货交接");});
        assertThat(number("SELECT reserved_qty FROM sales_order_items WHERE id=?",salesItem)).isZero();
        assertThat(number("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE root_material_id=?",root.materialLineId())).isZero();
        assertThat(number("SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE order_item_id=? AND status=0",otherItem)).isEqualByComparingTo("2");
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",world.goodsD())).isEqualByComparingTo("10");
        assertThat(number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",world.goodsD())).isEqualByComparingTo("100");
    }

    @Test void rawRootReversalCannotChangeOriginalWarehouseQuantityOrExactReleaseIdentity() {
        Fixture fixture=manualFixture();passManual(fixture);
        UUID original=db.queryForObject("SELECT id FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL' ORDER BY id LIMIT 1",UUID.class,fixture.analysis());
        UUID otherRelease=db.queryForObject("SELECT release_entitlement_event_id FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='FULFILL' AND id<>?",UUID.class,fixture.analysis(),original);
        String insert="""
                INSERT INTO preplan_root_output_events(id,analysis_id,analysis_item_id,root_material_id,route,event_kind,reversed_event_id,
                    warehouse_id,goods_id,color_id,qty_base,source_reservation_id,release_entitlement_event_id,sales_order_item_id,
                    sales_reservation_id,source_receipt_type,source_receipt_id,idempotency_key,created_by)
                SELECT ?,analysis_id,analysis_item_id,root_material_id,route,'REVERSE',id,%s,goods_id,color_id,%s,source_reservation_id,%s,
                    sales_order_item_id,sales_reservation_id,source_receipt_type,source_receipt_id,?,created_by
                FROM preplan_root_output_events WHERE id=?
                """;
        assertThatThrownBy(()->db.update(insert.formatted("CAST('"+fixture.scope()+"' AS uuid)","qty_base","release_entitlement_event_id"),
                UUID.randomUUID(),"fake-root-warehouse-"+UUID.randomUUID(),original)).hasMessageContaining("root output reversal must match its original slice");
        assertThatThrownBy(()->db.update(insert.formatted("warehouse_id","qty_base-1","release_entitlement_event_id"),
                UUID.randomUUID(),"fake-root-quantity-"+UUID.randomUUID(),original)).hasMessageContaining("root output reversal must match its original slice");
        assertThatThrownBy(()->db.update(insert.formatted("warehouse_id","qty_base","CAST('"+otherRelease+"' AS uuid)"),
                UUID.randomUUID(),"fake-root-release-"+UUID.randomUUID(),original)).hasMessageContaining("root output reversal must match its original slice");
        assertThat(number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='REVERSE'",fixture.analysis())).isZero();
        assertRootsAndPhysical(fixture,"500","25000");
    }

    private UUID leaf(UUID scope) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                id,scope,"ROOT-LEAF-"+id,"根供给实物叶仓");return id;
    }

    private void receivePublic(FullChainEndToEndTest.World world,UUID leaf,String qty) {
        var request=new com.uten.imp.features.stock.dto.StockDocSaveRequest();request.setBillDate(BusinessTime.today());request.setDocType("OTHER_IN");request.setWarehouseId(leaf);
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();line.setGoodsId(world.goodsD());line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("10"));
        line.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal("10")));line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));stock.approve(stock.create(request).getId());
    }

    void passManual(Fixture fixture) {
        List<UUID> inspectionsIds=db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=? ORDER BY id",UUID.class,fixture.receipt());
        preStock.preStockIn("PURCHASE",fixture.receipt(),new PreStockInRequest(inspectionsIds.stream().map(id->new PreStockInItem(id,fixture.leaf(),"11")).toList()));
        inspections.passBatch("PURCHASE",fixture.receipt(),new BatchInspectionPassRequest(inspectionsIds.stream().map(id->new BatchInspectionPassRequest.Item(id,new BigDecimal("500"),"root-manual-pass-"+id)).toList(),"实际叶仓同库位合格"));
    }

    private SalesFixture salesFixture() {
        String tag="root-sale-"+UUID.randomUUID();var world=harness.seedWorld(tag);harness.loginAs(world.superAdminUserId());
        UUID scope=world.warehouseId(),leaf=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",leaf,scope,"ROOT-SALE-"+leaf,"实际销售入库叶仓");
        db.update("UPDATE goods SET default_supplier_id=?,owning_warehouse_id=? WHERE id=?",world.supplierId(),leaf,world.goodsD());
        UUID order=ReflectionTestUtils.invokeMethod(harness,"createApprovedOrder",world,world.goodsD(),"10","100");
        UUID salesItem=ReflectionTestUtils.invokeMethod(harness,"orderItemId",order);harness.loginAs(world.superAdminUserId());
        var preview=analyses.preview(new PreviewRequest(null,null,null,scope,"root-sale-preview-"+tag,
                List.of(new PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,BusinessTime.today(),BigDecimal.TEN))));
        UUID root=preview.products().getFirst().rootMaterialLineId();
        UUID purchaseItem=ReflectionTestUtils.invokeMethod(harness,"approvePurchaseForAnalysis",WarehouseIqcScaleFixture.withWarehouse(world,leaf),preview,world.goodsD());
        UUID purchase=db.queryForObject("SELECT order_id FROM purchase_order_items WHERE id=?",UUID.class,purchaseItem);
        UUID receipt=receiptForOrder(world,leaf,purchase);
        return new SalesFixture(world,scope,leaf,preview.analysisId(),root,order,salesItem,receipt,world.goodsD());
    }

    private UUID shelve(SalesFixture fixture) {
        UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,fixture.receipt());
        preStock.preStockIn("PURCHASE",fixture.receipt(),new PreStockInRequest(List.of(new PreStockInItem(inspection,fixture.leaf(),"11"))));
        return inspection;
    }

    private void assertSalesAndPhysical(SalesFixture fixture,String qty,String amount) {
        assertThat(number("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE root_material_id=?",fixture.root())).isEqualByComparingTo(qty);
        assertThat(number("SELECT reserved_qty FROM sales_order_items WHERE id=?",fixture.salesItem())).isEqualByComparingTo(qty);
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",fixture.leaf(),fixture.goods())).isEqualByComparingTo(qty);
        assertThat(number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",fixture.leaf(),fixture.goods())).isEqualByComparingTo(amount);
    }

    private record SalesFixture(FullChainEndToEndTest.World world,UUID scope,UUID leaf,UUID analysis,UUID root,
                                UUID salesOrder,UUID salesItem,UUID receipt,UUID goods) { }

    private Fixture manualFixture() { return manualFixture(true); }
    Fixture manualFixture(boolean mainScope) { return manualFixture(mainScope,false); }
    Fixture manualFixture(boolean mainScope, boolean skipAutoClaim) {
        String tag="root-actual-"+UUID.randomUUID();
        var world=harness.seedWorld(tag);harness.loginAs(world.superAdminUserId());
        UUID main=world.warehouseId();
        UUID leaf=UUID.randomUUID();UUID scope=mainScope?main:leaf;
        db.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                leaf,main,"ROOT-LEAF-"+leaf,"根供给实际包材叶仓");
        UUID second=UUID.randomUUID();
        harness.insertGoods(second,"ROOT-GOODS-"+second,"第二种根供给包材","采购",world.unitId(),world.unitLegacy());
        List<UUID> goods=List.of(world.goodsD(),second);
        db.update("UPDATE goods SET default_supplier_id=?,owning_warehouse_id=? WHERE id IN (?,?)",
                world.supplierId(),leaf,goods.get(0),goods.get(1));
        var preview=analyses.preview(new PreviewRequest(null,null,null,scope,"root-actual-preview-"+tag,
                goods.stream().map(id->new PreviewItem("STOCK",null,id,null,world.unitId(),"ROOT-"+id,
                        "主仓范围备库，实物落实际叶仓",BusinessTime.today(),new BigDecimal("500"))).toList()));
        var roots=preview.flatMaterials().stream().filter(row->"ROOT_SUPPLY".equals(row.nodeRole())).toList();
        assertThat(roots).hasSize(2);
        var routed=analyses.saveRoutes(preview.analysisId(),new RouteRequest(preview.version(),preview.fingerprint(),
                "root-actual-route-"+tag,roots.stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),"BUY",null)).toList()));
        commands.notifySupply(routed.analysisId(),new NotifyRequest(routed.version(),routed.fingerprint(),
                "root-actual-notify-"+tag,"BUY",roots.stream().map(MaterialView::materialLineId).toList(),List.of(),null,skipAutoClaim));
        List<Map<String,Object>> sources=db.queryForList("""
                SELECT item.id,item.goods_id,item.qty FROM preplan_supply_actions action
                JOIN purchase_requests request ON request.id=action.external_document_id
                JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                JOIN purchase_request_items item ON item.id=allocation.external_item_id AND item.request_id=request.id AND NOT item.is_deleted
                WHERE action.analysis_id=? AND action.route='BUY' AND action.status='CREATED' ORDER BY item.id
                """,preview.analysisId());
        assertThat(sources).hasSize(2);
        var order=new OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(world.supplierId());
        order.setWarehouseId(leaf);order.setCurrencyId(world.currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(ReflectionTestUtils.invokeMethod(harness,"activeSettlementMethodId"));
        order.setItems(sources.stream().map(source->{var line=new OrderItemLine();line.setGoodsId((UUID)source.get("goods_id"));
            line.setRequestItemId((UUID)source.get("id"));line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);
            line.setQty((BigDecimal)source.get("qty"));line.setPrice(new BigDecimal("50"));return line;}).toList());
        var purchased=orders.createBatch(order);assertThat(purchased).hasSize(1);UUID orderId=purchased.getFirst().getId();
        UUID reviewer=ReflectionTestUtils.invokeMethod(harness,"createApprover",world);finance.submit("PURCHASE",orderId);
        harness.loginAs(reviewer);harness.approvePendingFinance("PURCHASE",orderId);harness.loginAs(world.superAdminUserId());
        UUID receiptId=receiptForOrder(world,leaf,orderId);
        assertThat(db.queryForObject("SELECT warehouse_id FROM production_material_analyses WHERE id=?",UUID.class,preview.analysisId())).isEqualTo(scope);
        return new Fixture(world,scope,leaf,preview.analysisId(),receiptId,goods);
    }

    private UUID receiptForOrder(FullChainEndToEndTest.World world,UUID leaf,UUID orderId) {
        var receipt=new ReceiptSaveRequest();receipt.setBillDate(BusinessTime.today());receipt.setSupplierId(world.supplierId());
        receipt.setWarehouseId(leaf);receipt.setCurrencyId(world.currencyId());receipt.setExchangeRate(BigDecimal.ONE);receipt.setTaxRate(BigDecimal.ZERO);
        receipt.setSettlementMethodId(orders.detail(orderId).getSettlementMethodId());
        receipt.setItems(orders.detail(orderId).getItems().stream().map(source->{var line=new ReceiptItemLine();line.setGoodsId(source.getGoodsId());
            line.setOrderItemId(source.getId());line.setUnitId(source.getUnitId());line.setUnitRate(source.getUnitRate());line.setQty(source.getQty());
            line.setPrice(source.getPrice());return line;}).toList());
        UUID receiptId=receipts.create(receipt).getId();receipts.approve(receiptId);
        return receiptId;
    }

    private void assertRootsAndPhysical(Fixture fixture,String qty,String amount) {
        for(UUID goods:fixture.goods()) {
            assertThat(number("SELECT item.root_fulfilled_qty FROM production_material_analysis_items item WHERE item.analysis_id=? AND item.goods_id=?",
                    fixture.analysis(),goods)).isEqualByComparingTo(qty);
            assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",fixture.leaf(),goods)).isEqualByComparingTo(qty);
            assertThat(number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",fixture.leaf(),goods)).isEqualByComparingTo(amount);
        }
    }
    private BigDecimal number(String sql,Object...arguments) { return db.queryForObject(sql,BigDecimal.class,arguments); }
    record Fixture(FullChainEndToEndTest.World world,UUID scope,UUID leaf,UUID analysis,UUID receipt,List<UUID> goods) { }
}
