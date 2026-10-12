package com.uten.imp.businesschain;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import org.springframework.test.util.ReflectionTestUtils;
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

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.*;

/**
 * The three departments can initiate work without a sales order. Their entry paths must retain
 * the same quantity/default/commercial rules, and undo only their own commitments. All business
 * mutations use domain services against the isolated migrated Testcontainers database.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class StandaloneDepartmentLifecycleConservationEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionPlanService plans;
    @Autowired ProductionPlanningPackageService packages;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    @Autowired PurchaseRequestService purchaseRequests;
    @Autowired PurchaseOrderService purchaseOrders;
    @Autowired SubcontractApplicationService subcontractApplications;
    @Autowired SubcontractOrderService subcontractOrders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired StockDocService stockDocs;
    @Autowired SalesShipmentService shipments;
    private FullChainEndToEndTest harness;

    @BeforeEach
    void prepare() {
        harness = new FullChainEndToEndTest();
        beans.autowireBean(harness);
    }

    @AfterEach
    void clearSecurity() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void independentPlanRejectsLossyQuantityAndInvalidBatchWithoutPersistingAnyDocument() {
        var world = world("independent-precision");
        long before = planCount(world);
        for (BigDecimal invalid : new BigDecimal[] {null, BigDecimal.ZERO, new BigDecimal("-1"),
                new BigDecimal("0.00001"), new BigDecimal("1.00005"), new BigDecimal("100000000000000")}) {
            var request = manualPlan(world, world.goodsC(), "2");
            request.getItems().getFirst().setQty(invalid);
            // The earlier valid row also has to roll back when a later row is invalid.
            PlanItemLine valid = manualPlan(world, world.goodsD(), "3").getItems().getFirst();
            request.setItems(List.of(valid, request.getItems().getFirst()));
            assertThatThrownBy(() -> plans.create(request)).isInstanceOf(ApiException.class)
                    .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
            assertThat(planCount(world)).isEqualTo(before);
        }
        var accepted = plans.create(manualPlan(world, world.goodsC(), "0.0001"));
        assertThat(decimal("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted", accepted.getId()))
                .isEqualByComparingTo("0.0001");
        assertNoSales(world);
    }

    @Test
    void standaloneUnpricedRequestsAndOrdersRejectLossyQuantitiesBeforePersisting() {
        var world = world("independent-unpriced");
        UUID material = harness.addSubcontractDirectMaterial(world, world.goodsE(), "1");
        harness.receiveSubcontractMaterial(world, material, "10");
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setWarehouseId(world.warehouseId());
        request.setDepartmentId(world.departmentId()); request.setApplicantId(world.employeeId());
        var requested = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(world.goodsD()); requested.setUnitId(world.unitId()); requested.setUnitRate(BigDecimal.ONE);
        requested.setQty(new BigDecimal("1.00005")); request.setItems(List.of(requested));
        assertThatThrownBy(() -> purchaseRequests.create(request)).isInstanceOf(ApiException.class)
                .hasMessageContaining("小数最多4位");
        assertThat(db.queryForObject("SELECT count(*) FROM purchase_requests WHERE maker_id=?", Integer.class, world.employeeId())).isZero();

        var application = new com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest();
        application.setBillDate(BusinessTime.today()); application.setWarehouseId(world.warehouseId());
        application.setApplicantId(world.employeeId());
        var applicationLine = new com.uten.imp.features.subcontract.application.dto.ApplicationItemLine();
        applicationLine.setGoodsId(world.goodsE()); applicationLine.setUnitId(world.unitId()); applicationLine.setUnitRate(BigDecimal.ONE);
        applicationLine.setQty(new BigDecimal("1.00005")); application.setItems(List.of(applicationLine));
        assertThatThrownBy(() -> subcontractApplications.create(application)).isInstanceOf(ApiException.class)
                .hasMessageContaining("小数最多4位");
        assertThat(db.queryForObject("SELECT count(*) FROM subcontract_applications WHERE maker_id=?", Integer.class, world.employeeId())).isZero();

        requested.setQty(new BigDecimal("2"));
        var validRequest = purchaseRequests.create(request); purchaseRequests.approve(validRequest.getId());
        assertThatThrownBy(() -> purchaseOrder(world, validRequest.getItems().getFirst().getId(), "1.00005", null))
                .isInstanceOf(ApiException.class).hasMessageContaining("小数最多4位");
        assertThatThrownBy(() -> subcontractOrder(world, null, "1.00005", null))
                .isInstanceOf(ApiException.class).hasMessageContaining("小数最多4位");
        for (String table : List.of("purchase_orders", "subcontract_orders")) {
            assertThat(db.queryForObject("SELECT count(*) FROM " + table + " WHERE maker_id=?", Integer.class, world.employeeId())).isZero();
        }
        assertThat(balance(world, material)).isEqualByComparingTo("10");
        assertNoSales(world);
    }

    @Test
    void stockQuantityInputsRejectLossyFactsButPreserveDeclaredSixDecimalUnitConversion() {
        var world = world("independent-stock-precision");
        var request = new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        request.setDocType("OTHER_IN"); request.setBillDate(BusinessTime.today()); request.setWarehouseId(world.warehouseId());
        var line = new com.uten.imp.features.stock.dto.StockDocItemLine();
        line.setGoodsId(world.goodsD()); line.setUnitId(world.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("1.00005")); request.setItems(List.of(line));
        assertThatThrownBy(() -> stockDocs.create(request)).isInstanceOf(ApiException.class).hasMessageContaining("小数最多4位");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_documents WHERE maker_id=?", Integer.class, world.employeeId())).isZero();

        UUID pack = UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name,status) VALUES (?,?,'六位换算包装','使用')", pack, "SIX-" + pack);
        line.setUnitId(pack); line.setUnitRate(new BigDecimal("0.123456")); line.setQty(new BigDecimal("2"));
        var accepted = stockDocs.create(request);
        assertThat(accepted.getItems().getFirst().getQty()).isEqualByComparingTo("2");
        assertThat(accepted.getItems().getFirst().getBaseQty()).isEqualByComparingTo("0.2469");
        stockDocs.approve(accepted.getId());
        assertThat(balance(world, world.goodsD())).isEqualByComparingTo("0.2469");
        assertThat(decimal("SELECT SUM(direction*qty) FROM stock_movements WHERE goods_id=?", world.goodsD()))
                .isEqualByComparingTo("0.2469");
        stockDocs.reverse(accepted.getId());
        assertThat(balance(world, world.goodsD())).isZero();

        line.setUnitId(world.unitId()); line.setUnitRate(BigDecimal.ONE); line.setQty(BigDecimal.ZERO);
        line.setCountQty(new BigDecimal("1.00005")); request.setDocType("CHECK");
        assertThatThrownBy(() -> stockDocs.create(request)).isInstanceOf(ApiException.class).hasMessageContaining("实盘数量");
    }

    @Test
    void orderLinkedShipmentRejectsLossyQuantityBeforeDraftAmountAndSourceQuantityDiverge() {
        var world = world("linked-shipment-precision");
        harness.receiveSubcontractMaterial(world, world.goodsC(), "5");
        UUID order = ReflectionTestUtils.invokeMethod(harness, "createApprovedOrder", world, world.goodsC(), "5", "100");
        UUID source = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted", UUID.class, order);
        com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest request = ReflectionTestUtils.invokeMethod(
                harness, "shipmentRequest", world, source, world.goodsC(), "1.00005");
        assertThatThrownBy(() -> shipments.create(request)).isInstanceOf(ApiException.class).hasMessageContaining("数量");
        assertThat(db.queryForObject("SELECT count(*) FROM sales_shipments WHERE client_id=?", Integer.class, world.clientId())).isZero();
        assertThat(decimal("SELECT shipped_qty FROM sales_order_items WHERE id=?", source)).isZero();
        assertThat(balance(world, world.goodsC())).isEqualByComparingTo("5");
    }

    @Test
    void manualAndGeneratedPlansShareDefaultsAndReleaseOnlyTheirOwnExactMaterialReservations() {
        var world = world("independent-plan");
        UUID product = product(world, "independent-plan", world.goodsD(), "1.6");
        harness.receiveSubcontractMaterial(world, world.goodsD(), "30");
        var direct = plans.create(manualPlan(world, product, "6.25"));
        AnalysisView analysis = manualAnalysis(world, product, "6.25", "independent-plan");
        MaterialView root = root(analysis);
        analyses.saveRoutes(analysis.analysisId(), new RouteRequest(analysis.version(), analysis.fingerprint(),
                "independent-plan-route-" + analysis.analysisId(),
                List.of(new RouteDecision(root.materialLineId(), root.actionGroupKey(), "MAKE", null))));
        analysis = analyses.detail(analysis.analysisId());
        var command = new IssueWorkshopPlansRequest(analysis.version(), analysis.fingerprint(),
                "independent-plan-issue-" + analysis.analysisId(), world.warehouseId(), BusinessTime.today(),
                null, true, List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        analysis.products().getFirst().analysisLineId(), new BigDecimal("6.25"))));
        var generated = analysisCommands.issueWorkshopPlans(analysis.analysisId(), command);
        UUID generatedPlan = generated.plans().getFirst().planId();
        assertThat(analysisCommands.issueWorkshopPlans(analysis.analysisId(), command).plans().getFirst().planId())
                .isEqualTo(generatedPlan);
        assertPlanDefaultsEqual(direct.getId(), generatedPlan);

        plans.approve(direct.getId());
        var preview = packages.preview(direct.getId(), world.warehouseId());
        var manualPackage = new GeneratePlanningPackageRequest();
        manualPackage.setWarehouseId(world.warehouseId());
        manualPackage.setIdempotencyKey("independent-plan-confirm-" + direct.getId());
        manualPackage.setPreviewFingerprint(preview.fingerprint());
        packages.confirm(direct.getId(), manualPackage);
        assertThat(activeReservations(direct.getId())).isEqualByComparingTo("10");
        assertThat(activeReservations(generatedPlan)).isEqualByComparingTo("10");
        assertThat(balance(world, world.goodsD())).isEqualByComparingTo("30");

        assertThatThrownBy(() -> plans.reverse(generatedPlan)).isInstanceOf(ApiException.class);
        assertThat(activeReservations(generatedPlan)).isEqualByComparingTo("10");
        reversePlanPackage(generatedPlan);
        plans.reverse(generatedPlan);
        assertThat(activeReservations(generatedPlan)).isZero();
        assertThat(activeReservations(direct.getId())).isEqualByComparingTo("10");
        reversePlanPackage(direct.getId());
        plans.reverse(direct.getId());
        assertThat(activeReservations(direct.getId())).isZero();
        assertThat(balance(world, world.goodsD())).isEqualByComparingTo("30");
        assertThat(analyses.detail(analysis.analysisId()).products().getFirst().remainingQty()).isEqualByComparingTo("6.25");
        assertThat(decimal("SELECT COALESCE(SUM(direction*qty),0) FROM stock_movements WHERE warehouse_id=? AND goods_id=?",
                world.warehouseId(), world.goodsD())).isEqualByComparingTo(balance(world, world.goodsD()));
        assertNoSales(world);
    }

    @Test
    void manualAndAnalysisPurchaseRequestsUseTheSameCommercialAmountsAndRestoreTheirOwnOrderedTotals() {
        var world = world("independent-purchase");
        UUID reviewer = reviewer(world, "independent-purchase");
        UUID product = product(world, "independent-purchase", world.goodsD(), "1");
        UUID generatedSource = generatedExternalSource(world, product, world.goodsD(), "BUY", "6.25", "independent-purchase");
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(world.warehouseId());
        request.setDepartmentId(world.departmentId());
        request.setApplicantId(world.employeeId());
        var requestLine = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requestLine.setGoodsId(world.goodsD());
        requestLine.setUnitId(world.unitId());
        requestLine.setUnitRate(BigDecimal.ONE);
        requestLine.setQty(new BigDecimal("6.25"));
        request.setItems(List.of(requestLine));
        var manual = purchaseRequests.create(request);
        purchaseRequests.approve(manual.getId());
        UUID manualSource = manual.getItems().getFirst().getId();

        UUID generatedOrder = purchaseOrder(world, generatedSource, "2.125");
        UUID manualOrder = purchaseOrder(world, manualSource, "2.125");
        assertCommercialEqual("purchase_orders", "purchase_order_items", generatedOrder, manualOrder);
        for (UUID order : List.of(generatedOrder, manualOrder)) approve(world, reviewer, "PURCHASE", order);
        for (UUID source : List.of(generatedSource, manualSource)) assertOrdered("purchase_request_items", source, "2.125");
        purchaseOrders.reverse(generatedOrder);
        assertOrdered("purchase_request_items", generatedSource, "0");
        assertOrdered("purchase_request_items", manualSource, "2.125");
        assertThatThrownBy(() -> purchaseOrders.reverse(generatedOrder)).isInstanceOf(ApiException.class);
        var undo = new DocumentUnapprovalService.UnapproveRequest("standalone-purchase-unapprove-" + manualOrder, "核对后修改草稿再审");
        var editable = (com.uten.imp.features.purchase.order.dto.OrderDetail) unapproval.unapprove("purchaseOrder", manualOrder, undo);
        assertOrdered("purchase_request_items", manualSource, "0");
        var replay = (com.uten.imp.features.purchase.order.dto.OrderDetail) unapproval.unapprove("purchaseOrder", manualOrder, undo);
        assertThat(replay.getId()).isEqualTo(editable.getId());
        assertThat(editable.getItems().getFirst().getRequestItemId()).isEqualTo(manualSource);
        assertThat(editable.getItems().getFirst().getQty()).isEqualByComparingTo("2.125");
        approve(world, reviewer, "PURCHASE", editable.getId());
        assertOrdered("purchase_request_items", manualSource, "2.125");
        purchaseOrders.reverse(editable.getId());
        assertOrdered("purchase_request_items", manualSource, "0");

        UUID pending = purchaseOrder(world, manualSource, "1");
        finance.submit("PURCHASE", pending);
        purchaseOrders.cancel(pending);
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases WHERE order_id=? AND status='PENDING'",
                Integer.class, pending)).isZero();
        assertOrdered("purchase_request_items", manualSource, "0");
        assertThat(decimal("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?", world.goodsD())).isZero();
        assertNoSales(world);
    }

    @Test
    void independentAndApplicationSubcontractOrdersShareDefaultsAndUndoMaterialPlansWithoutPhysicalMovements() {
        var world = world("independent-subcontract");
        UUID reviewer = reviewer(world, "independent-subcontract");
        UUID material = harness.addSubcontractDirectMaterial(world, world.goodsE(), "2");
        harness.receiveSubcontractMaterial(world, material, "20");
        UUID product = product(world, "independent-subcontract", world.goodsE(), "1");
        UUID generatedSource = generatedExternalSource(world, product, world.goodsE(), "SUBCONTRACT", "1.25", "independent-subcontract");
        UUID generatedOrder = subcontractOrder(world, generatedSource, "1.25");
        UUID independentOrder = subcontractOrder(world, null, "1.25");
        assertCommercialEqual("subcontract_orders", "subcontract_order_items", generatedOrder, independentOrder);
        for (UUID order : List.of(generatedOrder, independentOrder)) approve(world, reviewer, "SUBCONTRACT", order);
        assertOrdered("subcontract_application_items", generatedSource, "1.25");
        assertThat(balance(world, material)).isEqualByComparingTo("20");
        for (UUID order : List.of(generatedOrder, independentOrder)) {
            assertThat(db.queryForObject("SELECT count(*) FROM subcontract_material_plans WHERE order_id=? AND status='OPEN'",
                    Integer.class, order)).isEqualTo(1);
            subcontractOrders.reverse(order);
            assertThat(db.queryForObject("SELECT count(*) FROM subcontract_material_plans WHERE order_id=? AND status='OPEN'",
                    Integer.class, order)).isZero();
            assertThatThrownBy(() -> subcontractOrders.reverse(order)).isInstanceOf(ApiException.class);
        }
        assertOrdered("subcontract_application_items", generatedSource, "0");
        assertThat(balance(world, material)).isEqualByComparingTo("20");
        assertThat(decimal("SELECT COALESCE(SUM(direction*qty),0) FROM stock_movements WHERE warehouse_id=? AND goods_id=?",
                world.warehouseId(), material)).isEqualByComparingTo("20");
        assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id IN (?,?)",
                Integer.class, generatedOrder, independentOrder)).isZero();
        assertNoSales(world);
    }

    @Test
    void trueManualPurchaseOrderCreatesNoAnalysisOrRequestAndUnapprovalKeepsNoSource() {
        var world = world("manual-purchase-no-source");
        long requestsBefore=db.queryForObject("SELECT count(*) FROM purchase_requests",Long.class);
        long analysesBefore=db.queryForObject("SELECT count(*) FROM production_material_analyses",Long.class);
        UUID order=purchaseOrder(world,null,"3.1256");
        var draft=purchaseOrders.detail(order);
        assertThat(draft.getItems().getFirst().getRequestItemId()).isNull();
        assertThat(draft.getItems().getFirst().getQty()).isEqualByComparingTo("3.1256");
        assertThat(draft.getTotalOriginal()).isEqualByComparingTo(new BigDecimal("3.1256").multiply(new BigDecimal("12.34567")));
        UUID reviewer=reviewer(world,"manual-purchase");
        approve(world,reviewer,"PURCHASE",order);
        var undone=(com.uten.imp.features.purchase.order.dto.OrderDetail)unapproval.unapprove("purchaseOrder",order,new DocumentUnapprovalService.UnapproveRequest("manual-purchase-undo-"+order,"Independent purchase draft correction"));
        UUID successor=undone.getId();
        assertThat(purchaseOrders.detail(successor).getStatus()).isZero();
        assertThat(purchaseOrders.detail(successor).getItems().getFirst().getRequestItemId()).isNull();
        approve(world,reviewer,"PURCHASE",successor);
        assertThat(db.queryForObject("SELECT count(*) FROM purchase_requests",Long.class)).isEqualTo(requestsBefore);
        assertThat(db.queryForObject("SELECT count(*) FROM production_material_analyses",Long.class)).isEqualTo(analysesBefore);
        assertThat(db.queryForObject("SELECT count(*) FROM purchase_order_item_sources s JOIN purchase_order_items i ON i.id=s.order_item_id WHERE i.order_id IN (?,?)",Long.class,order,successor)).isZero();
        assertThat(balance(world,world.goodsD())).isZero();
        assertNoSales(world);
    }

    @Test
    void mixedManualAndLinkedPurchaseLinesKeepOnlyRealSourceCounters() {
        var world=world("manual-purchase-mixed");
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        req.setBillDate(BusinessTime.today());req.setWarehouseId(world.warehouseId());
        var requested=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(world.goodsD());requested.setUnitId(world.unitId());requested.setUnitRate(BigDecimal.ONE);requested.setQty(new BigDecimal("5"));req.setItems(List.of(requested));
        var sourceDocument=purchaseRequests.create(req);purchaseRequests.approve(sourceDocument.getId());
        UUID source=sourceDocument.getItems().getFirst().getId();
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());order.setSupplierId(world.supplierId());order.setWarehouseId(world.warehouseId());order.setCurrencyId(world.currencyId());order.setExchangeRate(new BigDecimal("7.123456"));order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlementMethod());
        var linked=new com.uten.imp.features.purchase.order.dto.OrderItemLine();linked.setGoodsId(world.goodsD());linked.setUnitId(world.unitId());linked.setUnitRate(BigDecimal.ONE);linked.setQty(new BigDecimal("2"));linked.setPrice(new BigDecimal("1.25"));linked.setRequestItemId(source);
        var manual=new com.uten.imp.features.purchase.order.dto.OrderItemLine();manual.setGoodsId(world.goodsC());manual.setUnitId(world.unitId());manual.setUnitRate(BigDecimal.ONE);manual.setQty(new BigDecimal("3"));manual.setPrice(new BigDecimal(".7"));order.setItems(List.of(linked,manual));
        UUID id=purchaseOrders.create(order).getId();UUID reviewer=reviewer(world,"mixed-purchase");
        approve(world,reviewer,"PURCHASE",id);assertOrdered("purchase_request_items",source,"2");
        assertThat(db.queryForObject("SELECT count(*) FROM purchase_order_item_sources s JOIN purchase_order_items i ON i.id=s.order_item_id WHERE i.order_id=?",Long.class,id)).isEqualTo(1);
        purchaseOrders.reverse(id);assertOrdered("purchase_request_items",source,"0");
    }

    private FullChainEndToEndTest.World world(String tag) {
        var world = harness.seedWorld(tag);
        harness.loginAs(world.superAdminUserId());
        return world;
    }

    private UUID reviewer(FullChainEndToEndTest.World world, String tag) {
        return harness.createUserWithPerms(world, tag + "-reviewer", "finance_order_approval:view",
                "finance_order_approval:approve", "finance_order_approval:reject");
    }

    private UUID product(FullChainEndToEndTest.World world, String tag, UUID component, String perUnit) {
        UUID product = UUID.randomUUID();
        harness.insertGoods(product, "STANDALONE-" + tag, "独立下单对照产品", "自制", world.unitId(), world.unitLegacy());
        harness.insertBom(product, component, perUnit);
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", world.supplierId(), component);
        return product;
    }

    private PlanSaveRequest manualPlan(FullChainEndToEndTest.World world, UUID product, String qty) {
        var request = new PlanSaveRequest();
        request.setBillDate(BusinessTime.today());
        var line = new PlanItemLine();
        line.setGoodsId(product);
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        request.setItems(List.of(line));
        return request;
    }

    private AnalysisView manualAnalysis(FullChainEndToEndTest.World world, UUID product, String qty, String tag) {
        return analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(),
                "standalone-preview-" + UUID.randomUUID(), List.of(new PreviewItem("STOCK", null, product,
                        null, world.unitId(), "STANDALONE-" + tag, "独立部门需求", BusinessTime.today(), new BigDecimal(qty)))));
    }

    private MaterialView root(AnalysisView analysis) {
        UUID root = analysis.products().getFirst().rootMaterialLineId();
        return analysis.flatMaterials().stream().filter(row -> row.materialLineId().equals(root)).findFirst().orElseThrow();
    }

    private UUID generatedExternalSource(FullChainEndToEndTest.World world, UUID product, UUID goods,
            String route, String qty, String tag) {
        AnalysisView analysis = manualAnalysis(world, product, qty, tag);
        MaterialView external = analysis.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(goods) && row.actionable()).findFirst().orElseThrow();
        analyses.saveRoutes(analysis.analysisId(), new RouteRequest(analysis.version(), analysis.fingerprint(),
                "standalone-route-" + analysis.analysisId(), List.of(new RouteDecision(
                        external.materialLineId(), external.actionGroupKey(), route, null))));
        analysis = analyses.detail(analysis.analysisId());
        analysisCommands.notifySupply(analysis.analysisId(), new NotifyRequest(analysis.version(), analysis.fingerprint(),
                "standalone-notify-" + analysis.analysisId(), route, List.of(external.materialLineId()), List.of(), null));
        return db.queryForObject("SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.analysis_id=? AND action.route=? AND action.status='CREATED'",
                UUID.class, analysis.analysisId(), route);
    }

    private UUID settlementMethod() {
        return db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1", UUID.class);
    }

    private UUID purchaseOrder(FullChainEndToEndTest.World world, UUID source, String qty) {
        return purchaseOrder(world, source, qty, new BigDecimal("12.34567"));
    }

    private UUID purchaseOrder(FullChainEndToEndTest.World world, UUID source, String qty, BigDecimal price) {
        var request = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(world.supplierId());
        request.setWarehouseId(world.warehouseId()); request.setCurrencyId(world.currencyId());
        request.setExchangeRate(new BigDecimal("7.123456")); request.setTaxRate(new BigDecimal("13"));
        request.setSettlementMethodId(settlementMethod());
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(world.goodsD()); line.setUnitId(world.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty)); line.setPrice(price); line.setRequestItemId(source);
        request.setItems(List.of(line));
        return purchaseOrders.createBatch(request).getFirst().getId();
    }

    private UUID subcontractOrder(FullChainEndToEndTest.World world, UUID source, String qty) {
        return subcontractOrder(world, source, qty, new BigDecimal("12.34567"));
    }

    private UUID subcontractOrder(FullChainEndToEndTest.World world, UUID source, String qty, BigDecimal price) {
        var request = new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(world.supplierId());
        request.setWarehouseId(world.warehouseId()); request.setCurrencyId(world.currencyId());
        request.setExchangeRate(new BigDecimal("7.123456")); request.setTaxRate(new BigDecimal("13"));
        request.setSettlementMethodId(settlementMethod());
        var line = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setGoodsId(world.goodsE()); line.setUnitId(world.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty)); line.setPrice(price); line.setApplicationItemId(source);
        request.setItems(List.of(line));
        return subcontractOrders.createBatch(request).getFirst().getId();
    }

    private void approve(FullChainEndToEndTest.World world, UUID reviewer, String type, UUID order) {
        harness.loginAs(world.superAdminUserId()); finance.submit(type, order);
        harness.loginAs(reviewer); harness.approvePendingFinance(type, order);
        harness.loginAs(world.superAdminUserId());
    }

    private void assertCommercialEqual(String headerTable, String itemTable, UUID left, UUID right) {
        Map<String, Object> first = db.queryForMap("SELECT supplier_id,warehouse_id,currency_id,exchange_rate,tax_rate,settlement_method_id,total_original,total_local FROM "
                + headerTable + " WHERE id=?", left);
        Map<String, Object> second = db.queryForMap("SELECT supplier_id,warehouse_id,currency_id,exchange_rate,tax_rate,settlement_method_id,total_original,total_local FROM "
                + headerTable + " WHERE id=?", right);
        assertThat(first).isEqualTo(second);
        Map<String, Object> line = db.queryForMap("SELECT qty,price,amount_original,amount_local FROM " + itemTable + " WHERE order_id=? AND NOT is_deleted", left);
        BigDecimal original = MoneyPolicy.exactProduct((BigDecimal) line.get("qty"), (BigDecimal) line.get("price"));
        assertThat((BigDecimal) line.get("amount_original")).isEqualByComparingTo(original);
        assertThat((BigDecimal) line.get("amount_local")).isEqualByComparingTo(MoneyPolicy.local(original, new BigDecimal("7.123456")));
    }

    private void assertPlanDefaultsEqual(UUID first, UUID second) {
        Map<String, Object> left = db.queryForMap("SELECT goods_id,unit_id,unit_rate,qty,allowed_overproduction_rate,allowed_overproduction_rate_source FROM production_plan_items WHERE plan_id=? AND NOT is_deleted", first);
        Map<String, Object> right = db.queryForMap("SELECT goods_id,unit_id,unit_rate,qty,allowed_overproduction_rate,allowed_overproduction_rate_source FROM production_plan_items WHERE plan_id=? AND NOT is_deleted", second);
        assertThat(left).isEqualTo(right);
    }

    private BigDecimal activeReservations(UUID plan) {
        return decimal("SELECT COALESCE(SUM(r.qty-r.consumed_qty-r.released_qty),0) FROM stock_reservations r JOIN production_material_demands d ON d.id=r.demand_id JOIN production_planning_packages p ON p.id=d.package_id WHERE p.plan_id=? AND NOT r.is_deleted", plan);
    }

    private void reversePlanPackage(UUID plan) {
        UUID packageId = db.queryForObject("SELECT id FROM production_planning_packages WHERE plan_id=? AND status='CONFIRMED' AND NOT is_deleted", UUID.class, plan);
        var command = new PlanningPackageLifecycleRequest("standalone-package-reverse-" + plan, "独立下单撤销对账");
        packages.reverse(plan, packageId, command);
        packages.reverse(plan, packageId, command);
    }

    private void assertOrdered(String table, UUID source, String qty) {
        assertThat(decimal("SELECT ordered_qty FROM " + table + " WHERE id=?", source)).isEqualByComparingTo(qty);
    }

    private long planCount(FullChainEndToEndTest.World world) {
        return db.queryForObject("SELECT count(*) FROM production_plans WHERE maker_id=? AND NOT is_deleted", Long.class, world.employeeId());
    }

    private BigDecimal balance(FullChainEndToEndTest.World world, UUID goods) {
        return decimal("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?", world.warehouseId(), goods);
    }

    private BigDecimal decimal(String sql, Object... arguments) {
        return db.queryForObject(sql, BigDecimal.class, arguments);
    }

    private void assertNoSales(FullChainEndToEndTest.World world) {
        assertThat(db.queryForObject("SELECT count(*) FROM sales_orders WHERE client_id=?", Integer.class, world.clientId())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM plan_order_item_links l JOIN production_plan_items i ON i.id=l.plan_item_id JOIN production_plans p ON p.id=i.plan_id WHERE p.maker_id=? AND NOT l.is_deleted", Integer.class, world.employeeId())).isZero();
    }
}
