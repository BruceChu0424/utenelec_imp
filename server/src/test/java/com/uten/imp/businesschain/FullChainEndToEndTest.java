package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemLine;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.mrp.MrpRow;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.PlanningPackageResult;
import com.uten.imp.features.production.mrp.PlanningPreviewResult;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.production.schedule.dto.MergePlanRequest;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDetail;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real end-to-end chain harness. Boots the FULL application context against a fresh
 * Testcontainers PostgreSQL with every Flyway migration applied, then drives the actual
 * services with real data — unlike the legacy {@code *PostgresTest} classes, which bypass
 * services and hand-write DB state with raw SQL (and are gated off by default).
 *
 * <p>Foundation (this file): seed-data builder (departments / multi-role accounts / a
 * multi-level BOM / warehouses / parties) + {@link #loginAs(UUID)} which faithfully
 * reconstructs the {@code AuthUser} principal the way {@code JwtAuthFilter} does — resolving
 * permissions through {@link PermissionResolver} so super-admin gets every code and a
 * department-attached user gets exactly the V212-granted set. Switching principals between
 * service calls simulates different staff accounts operating on the same data.
 *
 * <p>Gated behind {@code UTEN_RUN_DB_TESTS=true} (needs Docker).
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        // MOCK (the default) keeps the full web/security stack — incl. the HttpSecurity bean
        // that SecurityConfig.filterChain needs — without starting Tomcat. NONE strips the web
        // layer and breaks SecurityConfig.
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
                "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
                "uten.bootstrap.admin-password=HarnessAdminPass-1!"
        })
class FullChainEndToEndTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    /** Monotonic legacy int ids — the MRP/stock layer still resolves units via units.legacy_id
     *  joined to goods.unit_legacy_id (legacy-UUID bridge), so seeded units+goods need matching
     *  legacy ids. Unique per world to respect the units.legacy_id UNIQUE constraint. */
    private static final java.util.concurrent.atomic.AtomicInteger LEGACY_SEQ =
            new java.util.concurrent.atomic.AtomicInteger(9000);

    @Autowired private JdbcTemplate jdbc;
    @Autowired private PermissionResolver permissionResolver;
    @Autowired private SalesOrderService salesOrderService;
    @Autowired private ProductionScheduleService scheduleService;
    @Autowired private ProductionPlanService planService;
    @Autowired private MrpService mrpService;
    @Autowired private ProductionPlanningPackageService planningPackageService;
    @Autowired private com.uten.imp.features.purchase.order.PurchaseOrderService purchaseOrderService;
    @Autowired private com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService financeApproval;
    @Autowired private com.uten.imp.features.purchase.receipt.PurchaseReceiptService purchaseReceiptService;
    @Autowired private com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspectionService;
    @Autowired private ProductionDailyReportService reportService;
    @Autowired private StockDocService stockDocService;
    @Autowired private SalesShipmentService shipmentService;
    @Autowired private GlPostingService glPostingService;
    @Autowired private com.uten.imp.features.admin.UserAccountAdminService userAccountAdmin;
    @Autowired private com.uten.imp.features.admin.PermissionOverrideAdminService permissionOverrideAdmin;
    @Autowired private com.uten.imp.features.production.mrp.BottomUpPlanOrchestrator orchestrator;

    // ---------------------------------------------------------------------------------------------
    // Smoke: full context boots and the entire schema migrates cleanly.
    // ---------------------------------------------------------------------------------------------
    @Test
    void contextBootsAndFullSchemaMigrated() {
        Integer publicTables = jdbc.queryForObject(
                "select count(*) from information_schema.tables where table_schema = 'public'",
                Integer.class);
        assertTrue(publicTables != null && publicTables > 100,
                "full Flyway migration expected >100 public tables, got " + publicTables);
    }

    // ---------------------------------------------------------------------------------------------
    // Foundation: seed a real multi-level-BOM world + a super-admin account, then prove
    // loginAs() resolves ALL permissions (super-admin bypass) and the BOM tree is intact.
    // This is the bedrock every later chain-driving assertion builds on.
    // ---------------------------------------------------------------------------------------------
    @Test
    void seedWorldAndSuperAdminResolvesAllPermissionsAndBomTreeIsIntact() {
        World w = seedWorld("found");

        loginAs(w.superAdminUserId());

        AuthUser principal =
                (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        // Super-admin must hold EVERY permission code (PermissionResolver.allPermissionCodes).
        Integer permissionCount =
                jdbc.queryForObject("select count(*) from permissions", Integer.class);
        assertEquals(permissionCount, principal.getPermissions().size(),
                "super-admin effective permission set must equal the full permissions table");
        // And a concrete known code must be present as a granted authority.
        assertTrue(principal.getAuthorities().stream()
                        .anyMatch(a -> a.getAuthority().equals("sales_order:edit")),
                "super-admin authorities must include sales_order:edit");

        // BOM tree: A(自制) -> { B(自制半成品), E(委外) }; B -> { C(自制叶子), D(采购原料) }.
        assertEquals(2, bomChildCount(w.goodsA), "finished A should have 2 direct components");
        assertEquals(2, bomChildCount(w.goodsB), "sub-assembly B should have 2 direct components");
        assertEquals(0, bomChildCount(w.goodsC), "leaf C has no BOM children");
    }

    // ---------------------------------------------------------------------------------------------
    // #19 Sales order create -> approve. Finished good A has NO stock, so the order must route
    // to planning (chain_status = 2 待排产) with zero reservation. (In-stock currently auto-
    // advances to chain_status 7 可发货 — the "everything must go through planning" gap; making
    // in-stock ALSO route to planning is the outer-flow fix, task #14. Baseline asserts current
    // behavior here.)
    // ---------------------------------------------------------------------------------------------
    @Test
    void salesOrder_createThenApprove_outOfStockRoutesToPlanning() {
        World w = seedWorld("s19");
        loginAs(w.superAdminUserId());

        OrderDetail created = salesOrderService.create(orderRequest(w, w.goodsA(), "10", "100"));
        UUID orderId = created.getId();
        assertEquals(0, orderStatus(orderId), "new order is DRAFT (status=0)");
        assertTrue(billNo(orderId) != null && !billNo(orderId).isBlank(),
                "billNo is server-generated");

        salesOrderService.approve(orderId);
        assertEquals(1, orderStatus(orderId), "approved order is status=1");

        // A has no stock -> routes to planning, nothing reserved.
        assertEquals(2, itemChainStatus(orderId), "out-of-stock line -> chain_status=2 待排产");
        assertEquals(0, itemReservedQty(orderId).compareTo(BigDecimal.ZERO),
                "nothing reserved when there is no stock");
        assertEquals(0, reservationCountForOrder(orderId),
                "no stock_reservations row written when take=0");
    }

    // ---------------------------------------------------------------------------------------------
    // #20 Planner picks the schedulable order line, creates a production plan that references it,
    // and approves. The plan must peg the batch to the sales order (plan_order_item_links) and
    // write back planned_qty, advancing chain_status out of 待排产(2) into 待物料(3)/已排产(4).
    // ---------------------------------------------------------------------------------------------
    @Test
    void planner_createMergePlanAndApprove_writesPlannedQtyAndPegsOrder() {
        World w = seedWorld("s20");
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100"); // A has a BOM; out-of-stock
        UUID orderItemId = orderItemId(orderId);

        UUID planId = scheduleService.createMergePlan(mergePlanRequest(orderItemId, "10"));
        assertEquals(0, planStatus(planId), "new plan is DRAFT (status=0)");
        assertTrue(planLinkCount(orderItemId) >= 1,
                "plan_order_item_links pre-built on create (batch pegged to order)");

        planService.approve(planId);
        assertEquals(1, planStatus(planId), "approved plan is status=1");
        assertEquals(0, plannedQty(orderId).compareTo(new BigDecimal("10")),
                "sales_order_items.planned_qty += allocated 10");
        int chain = itemChainStatus(orderId);
        assertTrue(chain == 3 || chain == 4,
                "chain advanced from 待排产(2) to 待物料(3)/已排产(4), got " + chain);
    }

    private UUID createApprovedOrder(World w, UUID goodsId, String qty, String price) {
        loginAs(w.superAdminUserId());
        OrderDetail d = salesOrderService.create(orderRequest(w, goodsId, qty, price));
        salesOrderService.approve(d.getId());
        return d.getId();
    }

    private UUID orderItemId(UUID orderId) {
        return jdbc.queryForObject(
                "select id from sales_order_items where order_id = ?", UUID.class, orderId);
    }

    private MergePlanRequest mergePlanRequest(UUID orderItemId, String qty) {
        MergePlanRequest req = new MergePlanRequest();
        MergePlanRequest.Line line = new MergePlanRequest.Line();
        line.setOrderItemId(orderItemId);
        line.setQty(new BigDecimal(qty));
        req.setItems(List.of(line));
        return req;
    }

    private int planStatus(UUID planId) {
        Integer s = jdbc.queryForObject(
                "select status from production_plans where id = ?", Integer.class, planId);
        return s == null ? -99 : s;
    }

    private int planLinkCount(UUID orderItemId) {
        Integer c = jdbc.queryForObject(
                "select count(*) from plan_order_item_links "
                        + "where order_item_id = ? and is_deleted = false",
                Integer.class, orderItemId);
        return c == null ? 0 : c;
    }

    private BigDecimal plannedQty(UUID orderId) {
        return jdbc.queryForObject(
                "select planned_qty from sales_order_items where order_id = ?",
                BigDecimal.class, orderId);
    }

    // ---------------------------------------------------------------------------------------------
    // #21 (read side) MRP explodes the multi-level BOM correctly: A(10) -> B(20)+E(10);
    // B(20) -> C(60)+D(100). Routes follow each goods' source_type (自制/采购/委外), components are
    // aggregated/deduped across levels, and with no stock every line is a shortage. This is the
    // decomposition logic the bottom-up planning redesign (#13) builds on. (Write side — planning
    // package confirm producing subplans + purchase requests + pegs — follows next.)
    // ---------------------------------------------------------------------------------------------
    @Test
    void mrp_previewExplodesMultiLevelBomWithCorrectDemandRoutesAndDedup() {
        World w = seedWorld("s21");
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");

        java.util.List<MrpRow> rows = mrpService.preview(planId);
        assertEquals(4, rows.size(), "BOM explodes to 4 deduped components B,C,D,E (A is the root)");

        MrpRow b = rowByGoods(rows, w.goodsB()), c = rowByGoods(rows, w.goodsC());
        MrpRow d = rowByGoods(rows, w.goodsD()), e = rowByGoods(rows, w.goodsE());
        assertDemand(b, "20", "自制");   // A->B qty 2 * 10
        assertDemand(c, "60", "自制");   // B->C qty 3 * 20
        assertDemand(d, "100", "采购");  // B->D qty 5 * 20
        assertDemand(e, "10", "委外");   // A->E qty 1 * 10
        assertEquals(MrpRow.SHORTAGE, d.materialStatus(), "no stock + no PO -> purchase raw is a shortage");
        assertEquals(MrpRow.SHORTAGE, e.materialStatus(), "no stock + no PO -> subcontract item is a shortage");
    }

    private UUID approvedPlan(World w, UUID goodsId, String orderQty, String planQty) {
        UUID orderId = createApprovedOrder(w, goodsId, orderQty, "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planId = scheduleService.createMergePlan(mergePlanRequest(orderItemId, planQty));
        planService.approve(planId);
        return planId;
    }

    private MrpRow rowByGoods(java.util.List<MrpRow> rows, UUID goodsId) {
        return rows.stream().filter(r -> r.goodsId().equals(goodsId)).findFirst().orElse(null);
    }

    private void assertDemand(MrpRow row, String expectedGross, String expectedSourceType) {
        assertNotNull(row, "MRP row must exist for the component");
        assertEquals(0, new BigDecimal(expectedGross).compareTo(row.gross()),
                "gross demand mismatch (expected " + expectedGross + ")");
        assertEquals(expectedSourceType, row.sourceType(), "source route mismatch");
    }

    // ---------------------------------------------------------------------------------------------
    // #21 (write side) Confirm the planning package atomically: the BUY shortage (D) becomes a
    // purchase request, the SUBCONTRACT shortage (E) becomes a subcontract application, the
    // self-made sub-assembly (B) becomes a MAKE child subplan, and execution-segment material
    // demands are created. Pegging binds each demand to its spawned downstream document.
    // ---------------------------------------------------------------------------------------------
    @Test
    void planningPackage_confirmHandlesDirectLayerMakeAndSubcontract() {
        World w = seedWorld("s21w");
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");

        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-s21w-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);

        PlanningPackageResult result = planningPackageService.confirm(planId, req);

        // CURRENT architecture = direct-layer-only (spec decision #16): confirming A's package
        // handles only A's DIRECT components. B (自制) -> MAKE child subplan; E (委外) -> subcontract
        // application.
        assertFalse(result.subplans().isEmpty(),
                "自制半成品 B (direct MAKE) -> 子计划; got " + result.subplans().size());
        assertNotNull(result.subcontractApplication(),
                "委外件 E (direct SUBCONTRACT) -> 委外申请");
        // D (采购) is a component of B, NOT a direct component of A, so under the current one-level
        // architecture it is NOT purchased at this level — its demand only appears when B's subplan
        // is itself planned+confirmed. The bottom-up redesign (#13) will instead explode the full
        // tree so D is purchased from A's confirmation. This documents today's behavior.
        assertNull(result.purchaseRequest(),
                "D 采购是 B 的下层件；当前一层架构下 A 这层不开采购申请（待 #13 全树展开）");
        // direct-layer execution-segment material demands are established (B + E)
        assertTrue(count(
                "select count(*) from production_material_demands dmd "
                        + "where exists (select 1 from production_planning_packages pkg "
                        + "where pkg.plan_id = ? and pkg.id = dmd.package_id)",
                planId) >= 2,
                "直层物料需求建立 (B + E)");
    }

    private int count(String sql, Object... args) {
        Integer c = jdbc.queryForObject(sql, Integer.class, args);
        return c == null ? 0 : c;
    }

    private int intFor(String sql, Object... args) {
        Integer v = jdbc.queryForObject(sql, Integer.class, args);
        return v == null ? -99 : v;
    }

    private String strFor(String sql, Object... args) {
        return jdbc.queryForObject(sql, String.class, args);
    }

    /** Seed a non-super-admin user granted a permission via user_permission_overrides (the V229
     *  reviewer-pool path: an override grant makes them an eligible finance reviewer regardless
     *  of department, and submit is fail-closed until at least one eligible reviewer exists). */
    private UUID createReviewer(World w, String permissionCode) {
        UUID emp = UUID.randomUUID(), usr = UUID.randomUUID();
        jdbc.update("""
                insert into employees(id, code, full_name, id_type, department_id, hire_date,
                                      status, employment_type)
                values (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, emp, "REV-" + emp, "审核员", w.departmentId());
        jdbc.update("""
                insert into users(id, employee_id, login_account, password_hash,
                                  must_change_password, is_super_admin, status)
                values (?, ?, ?, 'x', false, false, 'active')
                """, usr, emp, "REV-" + usr);
        jdbc.update("""
                insert into user_permission_overrides(user_id, permission_id, effect)
                select ?, p.id, 'grant' from permissions p where p.code = ?
                """, usr, permissionCode);
        return usr;
    }

    // ---------------------------------------------------------------------------------------------
    // #22 (procurement side, through finance submission) A direct-BUY finished good G(自制)->H(采购)
    // is planned + confirmed, yielding a purchase request for H. Procurement decomposes it into a
    // purchase order (one supplier, every line tied to its request item) and submits to finance,
    // which opens a PENDING approval case. The approve + supply-peg transfer REQUEST_ITEM->
    // ORDER_ITEM (with this reviewer) is the immediate next step.
    // ---------------------------------------------------------------------------------------------
    @Test
    void procurement_createOrderFromRequestAndSubmitFinance() {
        World w = seedWorld("s22");
        // eligible finance reviewer must exist before submit (submit is fail-closed otherwise)
        UUID reviewer = createReviewer(w, "finance_order_approval:review");

        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-s22", "成品G-s22", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-s22", "原料H-s22", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2"); // G -> H direct BUY; order G qty 10 -> H demand 20

        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, g, "10", "10");
        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-s22-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        assertNotNull(planningPackageService.confirm(planId, req).purchaseRequest(),
                "H 直层采购件 (direct BUY) -> 采购申请");

        String planNo = strFor("select bill_no from production_plans where id = ?", planId);
        UUID requestItemId = jdbc.queryForObject(
                "select pri.id from purchase_request_items pri "
                        + "join purchase_requests pr on pr.id = pri.request_id "
                        + "where pr.source_doc_no = ? and pri.goods_id = ?",
                UUID.class, planNo, h);

        // decompose the request into a purchase order (one supplier; line tied to request item)
        com.uten.imp.features.purchase.order.dto.OrderSaveRequest orderReq =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderReq.setBillDate(LocalDate.of(2026, 1, 15));
        orderReq.setSupplierId(w.supplierId());
        orderReq.setWarehouseId(w.warehouseId());
        orderReq.setCurrencyId(w.currencyId());
        orderReq.setExchangeRate(BigDecimal.ONE);
        orderReq.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line =
                new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(h);
        line.setRequestItemId(requestItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("20"));
        line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(new BigDecimal("1000"));
        line.setAmountLocal(new BigDecimal("1000"));
        orderReq.setItems(List.of(line));
        purchaseOrderService.createBatch(orderReq);

        UUID orderId = jdbc.queryForObject(
                "select id from purchase_orders where is_deleted = false and supplier_id = ? "
                        + "order by created_at desc limit 1",
                UUID.class, w.supplierId());
        assertEquals(0, intFor("select status from purchase_orders where id = ?", orderId),
                "new purchase order is DRAFT (0)");

        // submit to finance -> a PENDING approval case is opened
        financeApproval.submit("PURCHASE", orderId);
        assertEquals("PENDING",
                strFor("select status from procurement_order_approval_cases "
                        + "where order_type = 'PURCHASE' and order_id = ?", orderId),
                "提交财务审核 -> PENDING");
        assertNotNull(reviewer, "财务审核人就位（submit 需至少一名合格审核人）");

        // approve as the eligible finance reviewer (override-granted)
        loginAs(reviewer);
        long version = jdbc.queryForObject(
                "select version from procurement_order_approval_cases "
                        + "where order_type = 'PURCHASE' and order_id = ?",
                Long.class, orderId);
        financeApproval.approve("PURCHASE", orderId, version);

        assertEquals(1, intFor("select status from purchase_orders where id = ?", orderId),
                "财务审核通过 -> 订货单 0->1 生效");
        // supply peg transferred from REQUEST_ITEM to ORDER_ITEM
        assertTrue(count(
                "select count(*) from production_material_supply_pegs "
                        + "where supply_type = 'PURCHASE_ORDER_ITEM' and status <> 'REVERSED'")
                >= 1, "supply peg 由 PURCHASE_REQUEST_ITEM 转移到 PURCHASE_ORDER_ITEM");
        // ordered_qty written back to the originating request item
        assertEquals(0, jdbc.queryForObject(
                "select ordered_qty from purchase_request_items where id = ?",
                BigDecimal.class, requestItemId).compareTo(new BigDecimal("20")),
                "ordered_qty += 20 回写采购申请明细");
        // warehouse notified via the approval outbox event (business_outbox is append-only)
        assertTrue(count(
                "select count(*) from business_outbox "
                        + "where event_type = 'PROCUREMENT_FINANCE_APPROVED'")
                >= 1, "审批通过 -> outbox 通知仓库预计到货");
    }

    /** Drive the full direct-BUY procurement chain (plan -> confirm -> purchase request ->
     *  purchase order -> finance approve) for a finished good with a direct BUY component, and
     *  return the approved order's line id for the buy goods (for receiving to reference). */
    private UUID procureDirectBuy(World w, UUID finished, UUID buy, String orderQty) {
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, finished, orderQty, orderQty);
        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-proc-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        planningPackageService.confirm(planId, req);
        String planNo = strFor("select bill_no from production_plans where id = ?", planId);
        UUID requestItemId = jdbc.queryForObject(
                "select pri.id from purchase_request_items pri "
                        + "join purchase_requests pr on pr.id = pri.request_id "
                        + "where pr.source_doc_no = ? and pri.goods_id = ?",
                UUID.class, planNo, buy);
        BigDecimal reqQty = jdbc.queryForObject(
                "select qty from purchase_request_items where id = ?", BigDecimal.class, requestItemId);

        com.uten.imp.features.purchase.order.dto.OrderSaveRequest orderReq =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderReq.setBillDate(LocalDate.of(2026, 1, 15));
        orderReq.setSupplierId(w.supplierId());
        orderReq.setWarehouseId(w.warehouseId());
        orderReq.setCurrencyId(w.currencyId());
        orderReq.setExchangeRate(BigDecimal.ONE);
        orderReq.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line =
                new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(buy);
        line.setRequestItemId(requestItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(reqQty);
        line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(reqQty.multiply(new BigDecimal("50")));
        line.setAmountLocal(reqQty.multiply(new BigDecimal("50")));
        orderReq.setItems(List.of(line));
        purchaseOrderService.createBatch(orderReq);
        UUID orderId = jdbc.queryForObject(
                "select id from purchase_orders where is_deleted = false and supplier_id = ? "
                        + "order by created_at desc limit 1",
                UUID.class, w.supplierId());
        UUID reviewer = createReviewer(w, "finance_order_approval:review");
        financeApproval.submit("PURCHASE", orderId);
        loginAs(reviewer);
        long version = jdbc.queryForObject(
                "select version from procurement_order_approval_cases "
                        + "where order_type = 'PURCHASE' and order_id = ?",
                Long.class, orderId);
        financeApproval.approve("PURCHASE", orderId, version);
        return jdbc.queryForObject(
                "select id from purchase_order_items where order_id = ? and goods_id = ?",
                UUID.class, orderId, buy);
    }

    // ---------------------------------------------------------------------------------------------
    // #23 (receiving, normal path) Warehouse receives H against the approved order. Approval freezes
    // the goods in IQC (NOT yet in usable stock), writes received_qty, and posts AP. An IQC PASS
    // then releases the goods into stock — accumulating (not overwriting) the balance.
    // ---------------------------------------------------------------------------------------------
    @Test
    void receiving_iqcQuarantineThenPassAccumulatesStock() {
        World w = seedWorld("s23");
        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-s23", "成品G-s23", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-s23", "原料H-s23", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2"); // G -> H ; order 10 -> H demand 20
        UUID orderItemId = procureDirectBuy(w, g, h, "10"); // approved PO for H(20)

        loginAs(w.superAdminUserId());
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "收货前 H 库存为 0");

        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest rr =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        rr.setBillDate(LocalDate.of(2026, 1, 20));
        rr.setSupplierId(w.supplierId());
        rr.setWarehouseId(w.warehouseId());
        rr.setCurrencyId(w.currencyId());
        rr.setExchangeRate(BigDecimal.ONE);
        rr.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine ri =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        ri.setGoodsId(h);
        ri.setOrderItemId(orderItemId);
        ri.setUnitId(w.unitId());
        ri.setUnitRate(BigDecimal.ONE);
        ri.setQty(new BigDecimal("20"));
        ri.setPrice(new BigDecimal("50"));
        ri.setAmountOriginal(new BigDecimal("1000"));
        ri.setAmountLocal(new BigDecimal("1000"));
        rr.setItems(List.of(ri));
        purchaseReceiptService.create(rr);
        UUID receiptId = jdbc.queryForObject(
                "select id from purchase_receipts where is_deleted = false and supplier_id = ? "
                        + "order by created_at desc limit 1",
                UUID.class, w.supplierId());

        purchaseReceiptService.approve(receiptId);
        // IQC freeze: goods NOT yet in usable stock; received_qty written; AP posted
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "IQC 待检期间不入可用库存");
        assertEquals(0, jdbc.queryForObject(
                "select received_qty from purchase_order_items where id = ?",
                BigDecimal.class, orderItemId).compareTo(new BigDecimal("20")),
                "received_qty += 20 回写订货明细");
        assertTrue(count(
                "select count(*) from procurement_inspection_items "
                        + "where receipt_id = ? and status = 'PENDING'", receiptId) >= 1,
                "IQC 待检明细 PENDING");
        assertTrue(count("select count(*) from ar_ap_ledger") >= 1, "收货审核过账 AP");

        // IQC PASS -> stock-in (accumulate)
        UUID inspectionItemId = jdbc.queryForObject(
                "select id from procurement_inspection_items where receipt_id = ? and goods_id = ? "
                        + "order by updated_at desc limit 1",
                UUID.class, receiptId, h);
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "质检合格", "idem-s23-" + inspectionItemId));
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(new BigDecimal("20")),
                "IQC PASS -> 入库累加到 20");
    }

    // ---------------------------------------------------------------------------------------------
    // #24 (finished inbound, FULL completion) Sales progress is NOT the self-reported output
    // (production_plan_items.fqty). produced_qty is written ONLY when warehouse approves the
    // auto-generated FINISHED_IN doc (actual inbound). So after reporting 10 but before any
    // inbound, sales produced_qty must still be 0 — progress = inbound / planned, not fqty.
    // Approving FINISHED_IN then writes produced_qty=10, reserved_qty=10, chain_status 5→7
    // (可发货), creates a PRODUCTION_INBOUND reservation, accumulates stock, writes back
    // plan_items.iqty / links.inbound_qty, and fires the 完工→通知销售 outbox event (decision 2).
    // This is the authoritative progress path the bottom-up redesign (#13) must preserve.
    // ---------------------------------------------------------------------------------------------
    @Test
    void finishedInbound_fullCompletion_progressByInboundNotReportAndNotifiesSales() {
        World w = seedWorld("s24full");
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        UUID planItemId = planItemIdFor(planId, w.goodsA());
        UUID orderItemId = orderItemIdOfPlan(planId);
        loginAs(w.superAdminUserId());

        // Report 10 produced (fqty). Writes fqty + links.produced_qty, advances chain 3/4→5
        // 生产中, and — because a warehouse is set — auto-generates a FINISHED_IN draft linked
        // to the plan via plan_draw_links (warehouse approval is what actually stocks the goods).
        UUID reportId = reportAndApprove(w, planItemId, orderItemId, w.goodsA(), "10");

        // KEY: before any inbound, sales produced_qty is still 0 — progress is inbound, not
        // the self-reported fqty (which is 10 here). This is the invariant the redesign keeps.
        assertEquals(0, producedQty(orderItemId).compareTo(BigDecimal.ZERO),
                "报工只写 fqty；入库前 sales_order_items.produced_qty 仍为 0（进度=入库，非自报）");
        assertEquals(0, bigDecimalFor(
                "select fqty from production_plan_items where id = ?", planItemId)
                .compareTo(new BigDecimal("10")),
                "报工回写 production_plan_items.fqty = 10（自报量，≠ 销售进度）");
        assertEquals(5, itemChainStatusByItem(orderItemId),
                "报工推进订单行 chain_status → 5 生产中");

        // Warehouse approves the auto-generated FINISHED_IN → actual inbound into stock.
        UUID finishedInId = finishedInDocForReport(reportBillNo(reportId));
        stockDocService.approve(finishedInId);

        // produced_qty now equals Σ inbound (10), reserved_qty += 10, chain → 7 可发货.
        assertEquals(0, producedQty(orderItemId).compareTo(new BigDecimal("10")),
                "完工入库审核 → produced_qty = Σ入库 = 10");
        assertEquals(0, reservedQty(orderItemId).compareTo(new BigDecimal("10")),
                "入库补预留 reserved_qty += 10");
        assertEquals(7, itemChainStatusByItem(orderItemId),
                "全量入库 → chain_status 5→7 可发货");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("10")),
                "成品 A 入库累加到 10");
        // reservation backfilled from THIS inbound, bound to the order line (source=PRODUCTION_INBOUND)
        assertTrue(count(
                "select count(*) from stock_reservations "
                        + "where source_doc_type = 'PRODUCTION_INBOUND' and source_doc_id = ? "
                        + "and order_item_id = ? and is_deleted = false",
                finishedInId, orderItemId) >= 1,
                "入库补预留：stock_reservations source=PRODUCTION_INBOUND 绑订单行");
        // plan_items.iqty (inbound累计) written back — distinct from fqty (report累计)
        assertEquals(0, bigDecimalFor(
                "select iqty from production_plan_items where id = ?", planItemId)
                .compareTo(new BigDecimal("10")),
                "production_plan_items.iqty = Σ入库 = 10（与 fqty 区分）");
        assertEquals(0, bigDecimalFor(
                "select inbound_qty from plan_order_item_links where plan_item_id = ? "
                        + "and order_item_id = ? and is_deleted = false",
                planItemId, orderItemId).compareTo(new BigDecimal("10")),
                "plan_order_item_links.inbound_qty = Σ入库 = 10");
        // decision 2: 完工→通知销售 outbox event fired, scoped to THIS inbound doc (chain→7)
        assertTrue(count(
                "select count(*) from business_outbox "
                        + "where event_type = 'PRODUCTION_FINISHED_INBOUND' and aggregate_id = ?",
                finishedInId) >= 1,
                "完工入库(chain→7) → business_outbox 发 PRODUCTION_FINISHED_INBOUND 通知归属销售");
    }

    // ---------------------------------------------------------------------------------------------
    // #24 (finished inbound, PARTIAL then full) Two half-batches must ACCUMULATE (not
    // overwrite): report+inbound 5 → produced_qty=5, chain→6 部分完工; report+inbound 5 more
    // → produced_qty=10, chain→7. Stock also accumulates 5+5=10. Proves the writeback is
    // additive across multiple FINISHED_IN docs against the same order line.
    // ---------------------------------------------------------------------------------------------
    @Test
    void finishedInbound_partialThenFull_accumulatesProgressByInbound() {
        World w = seedWorld("s24part");
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        UUID planItemId = planItemIdFor(planId, w.goodsA());
        UUID orderItemId = orderItemIdOfPlan(planId);
        loginAs(w.superAdminUserId());

        // First batch: report 5 + inbound 5 → partial completion.
        UUID report1 = reportAndApprove(w, planItemId, orderItemId, w.goodsA(), "5");
        stockDocService.approve(finishedInDocForReport(reportBillNo(report1)));
        assertEquals(0, producedQty(orderItemId).compareTo(new BigDecimal("5")),
                "首批入库 5 → produced_qty = 5");
        assertEquals(6, itemChainStatusByItem(orderItemId),
                "部分入库 → chain_status → 6 部分完工");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("5")),
                "首批入库累加到 5");

        // Second batch: report 5 more + inbound 5 → accumulates to 10 (NOT overwrite), chain→7.
        UUID report2 = reportAndApprove(w, planItemId, orderItemId, w.goodsA(), "5");
        stockDocService.approve(finishedInDocForReport(reportBillNo(report2)));
        assertEquals(0, producedQty(orderItemId).compareTo(new BigDecimal("10")),
                "二批入库累加 produced_qty 5+5=10（非覆盖）");
        assertEquals(0, reservedQty(orderItemId).compareTo(new BigDecimal("10")),
                "预留累加 reserved_qty = 10");
        assertEquals(7, itemChainStatusByItem(orderItemId),
                "全量入库 → chain_status 6→7 可发货");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("10")),
                "二批入库累加到 10（5+5，非覆盖）");
    }

    // ---------------------------------------------------------------------------------------------
    // #25 (shipping, FULL) Sales creates a shipment against the produced order line, warehouse
    // drives PENDING_PICK→PICKING→PICKED→SHIPPED. The SHIPPED transition is atomic: it consumes
    // the PRODUCTION_INBOUND reservation FIFO, writes a stock_movement (type=3 sales-out, dir=-1)
    // decrementing stock_balances, accumulates sales_order_items.shipped_qty, decrements
    // reserved_qty, advances chain_status 7→9 全部发货, closes the order, and posts AR inline
    // (ar_ap_ledger direction='AR' source='SALES_SHIPMENT'). Shipment binds one order_item_id
    // (no cross-order mixing). Decision 2: only after production completes (chain=7) can sales ship.
    // ---------------------------------------------------------------------------------------------
    @Test
    void shipment_fullShip_consumesReservationPostsArAndClosesOrder() {
        World w = seedWorld("s25full");
        // Produce A fully first: chain=7 可发货, reserved=10, produced=10, stock=10.
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        loginAs(w.superAdminUserId());
        assertEquals(7, itemChainStatusByItem(orderItemId), "前置: 完工入库后 chain=7 可发货");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("10")),
                "前置: 成品库存 10");

        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId);

        assertEquals(0, shippedQty(orderItemId).compareTo(new BigDecimal("10")),
                "全部发货 → shipped_qty += 10");
        assertEquals(0, reservedQty(orderItemId).compareTo(BigDecimal.ZERO),
                "预留消耗 reserved_qty 10→0");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(BigDecimal.ZERO),
                "出库 → 库存 10→0");
        assertEquals(9, itemChainStatusByItem(orderItemId),
                "全部发货 → chain_status 7→9");
        assertTrue(orderIsClosed(orderId), "全部发货 → 订单结案 is_closed=true");
        // AR posted inline on SHIPPED (one row, positive, source=SALES_SHIPMENT)
        assertTrue(count(
                "select count(*) from ar_ap_ledger "
                        + "where direction = 'AR' and source_doc_type = 'SALES_SHIPMENT' "
                        + "and source_doc_id = ?", shipmentId) >= 1,
                "SHIPPED 内联过账 AR（ar_ap_ledger）");
        // stock movement: sales-out, dir=-1, tied to this shipment
        assertTrue(count(
                "select count(*) from stock_movements "
                        + "where movement_type = 3 and direction = -1 and source_doc_id = ?",
                shipmentId) >= 1,
                "出库流水 movement_type=3 dir=-1");
        assertEquals(1, shipmentStatus(shipmentId), "出货单 status 0→1 已审");
        assertEquals("SHIPPED", shipmentWorkStatus(shipmentId),
                "warehouseWorkStatus → SHIPPED");
        assertTrue(shipmentArPosted(shipmentId), "ar_posted=true");
    }

    // ---------------------------------------------------------------------------------------------
    // #25 (shipping, PARTIAL then full) Two batches accumulate: ship 5 → shipped=5, reserved=5,
    // stock=5, chain→8 部分发货, order NOT closed; ship 5 more → shipped=10, reserved=0, stock=0,
    // chain→9, order closed. Proves shipped_qty accumulates (not overwrite) and reserved/stock
    // decrement in lockstep across separate shipments.
    // ---------------------------------------------------------------------------------------------
    @Test
    void shipment_partialThenFull_accumulatesShippedAndChain() {
        World w = seedWorld("s25part");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        loginAs(w.superAdminUserId());

        UUID ship1 = createShipment(w, orderItemId, w.goodsA(), "5");
        shipThroughWarehouse(ship1);
        assertEquals(0, shippedQty(orderItemId).compareTo(new BigDecimal("5")),
                "首批发货 shipped_qty = 5");
        assertEquals(0, reservedQty(orderItemId).compareTo(new BigDecimal("5")),
                "reserved_qty 10-5=5");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("5")),
                "库存 10-5=5");
        assertEquals(8, itemChainStatusByItem(orderItemId),
                "部分发货 → chain_status → 8");
        assertFalse(orderIsClosed(orderId), "部分发货不结案");

        UUID ship2 = createShipment(w, orderItemId, w.goodsA(), "5");
        shipThroughWarehouse(ship2);
        assertEquals(0, shippedQty(orderItemId).compareTo(new BigDecimal("10")),
                "二批发货累加 shipped_qty 5+5=10（非覆盖）");
        assertEquals(0, reservedQty(orderItemId).compareTo(BigDecimal.ZERO),
                "reserved_qty → 0");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(BigDecimal.ZERO),
                "库存 → 0");
        assertEquals(9, itemChainStatusByItem(orderItemId),
                "全发 → chain_status 8→9");
        assertTrue(orderIsClosed(orderId), "全发 → 结案");
    }

    // ---------------------------------------------------------------------------------------------
    // #25 (REQUIRE_COMPLETE policy) An order flagged shipment_policy='REQUIRE_COMPLETE' must
    // reject a partial shipment at draft creation ("订单要求整单齐套"), while a full shipment is
    // allowed. Verifies the policy gate the agent mapped (checked at create / PICKING / SHIPPED).
    // ---------------------------------------------------------------------------------------------
    @Test
    void shipment_requireCompletePolicy_rejectsPartialAllowsFull() {
        World w = seedWorld("s25policy");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        loginAs(w.superAdminUserId());
        jdbc.update("update sales_orders set shipment_policy = 'REQUIRE_COMPLETE' where id = ?", orderId);

        // Partial (5 of 10) rejected at draft creation.
        ApiException ex = assertThrows(ApiException.class,
                () -> shipmentService.create(shipmentRequest(w, orderItemId, w.goodsA(), "5")));
        assertTrue(ex.getMessage().contains("整单齐套"),
                "REQUIRE_COMPLETE 拒绝部分发货: " + ex.getMessage());

        // Full (10) is allowed under the same policy and ships cleanly.
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId);
        assertEquals(9, itemChainStatusByItem(orderItemId),
                "整单齐套全发 → chain_status → 9");
        assertTrue(orderIsClosed(orderId), "整单齐套全发 → 结案");
    }

    // ---------------------------------------------------------------------------------------------
    // #26 (inventory correctness — event-sourcing invariant) stock_balances is an aggregate of the
    // append-only stock_movements ledger (流水只增不改). For any warehouse+goods the balance MUST
    // equal Σ(qty × direction) of its movements. After produce (+10 FINISHED_IN) then ship 5
    // (-5 SALES_OUT), balance=5 and the signed movement sum is also 5. This is the bedrock
    // invariant every other conservation check rests on.
    // ---------------------------------------------------------------------------------------------
    @Test
    void inventory_balanceEqualsSumOfMovements() {
        World w = seedWorld("s26bal");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        loginAs(w.superAdminUserId());
        // produce → +10 movement; balance 10
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("10")),
                "完工入库后库存 10");
        assertEquals(0, movementSum(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("10")),
                "Σ(qty×direction) = +10");

        // ship 5 → -5 movement; balance 5
        shipThroughWarehouse(createShipment(w, orderItemId, w.goodsA(), "5"));

        BigDecimal balance = stockBalance(w.warehouseId(), w.goodsA());
        BigDecimal ledger = movementSum(w.warehouseId(), w.goodsA());
        assertEquals(0, balance.compareTo(new BigDecimal("5")), "出库 5 后库存 5");
        assertEquals(0, ledger.compareTo(balance),
                "事件溯源不变量：stock_balances.qty == Σ(qty×direction)（" + ledger + " vs " + balance + "）");
    }

    // ---------------------------------------------------------------------------------------------
    // #26 (inventory correctness — overship / negative-stock guard) Shipping more than the order's
    // reserved_qty is rejected (at draft allocation: drafted + requested <= reserved). The rejection
    // is atomic — no partial shipment/draft is left behind and stock is untouched. This prevents
    // overship from ever driving stock negative (穿底).
    // ---------------------------------------------------------------------------------------------
    @Test
    void inventory_overshipBeyondReservedRejectedAndAtomic() {
        World w = seedWorld("s26over");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId(); // reserved=10, stock=10
        loginAs(w.superAdminUserId());
        BigDecimal stockBefore = stockBalance(w.warehouseId(), w.goodsA());

        // 15 > reserved(10) → rejected at draft creation.
        ApiException ex = assertThrows(ApiException.class,
                () -> createShipment(w, orderItemId, w.goodsA(), "15"));
        assertTrue(ex.getMessage().contains("预留") || ex.getMessage().contains("可发"),
                "超发(>预留)被拒: " + ex.getMessage());

        // atomic: nothing shipped, stock untouched.
        assertEquals(0, shippedQty(orderItemId).compareTo(BigDecimal.ZERO),
                "超发被拒 → shipped_qty 仍为 0（无副作用）");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(stockBefore),
                "超发被拒 → 库存不变（原子回滚，未穿底）");
    }

    // ---------------------------------------------------------------------------------------------
    // #26 (inventory correctness — reverse is precise) Red-flushing the FINISHED_IN doc must
    // symmetrically undo every write the approval made: stock 10→0, produced_qty/reserved_qty 10→0,
    // plan_items.iqty 10→0, chain_status 7→4 (back to 已排产), and the PRODUCTION_INBOUND reservation
    // released. Proves the reverse path is an exact inverse, not a coarse reset.
    // ---------------------------------------------------------------------------------------------
    @Test
    void finishedInbound_reverseRollsBackPrecisely() {
        World w = seedWorld("s26rev");
        Production finished = produceFinished(w, w.goodsA(), "10", "10");
        UUID orderItemId = finished.orderItemId();
        UUID planItemId = finished.planItemId();
        UUID finishedInId = finished.finishedInId();
        UUID orderId = orderIdOfItem(orderItemId);
        loginAs(w.superAdminUserId());
        // preconditions after produce
        assertEquals(7, itemChainStatusByItem(orderItemId), "前置 chain=7");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("10")),
                "前置库存 10");

        stockDocService.reverse(finishedInId);

        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(BigDecimal.ZERO),
                "红冲 → 库存 10→0");
        assertEquals(0, producedQty(orderItemId).compareTo(BigDecimal.ZERO),
                "红冲 → produced_qty 10→0");
        assertEquals(0, reservedQty(orderItemId).compareTo(BigDecimal.ZERO),
                "红冲 → reserved_qty 10→0");
        assertEquals(0, bigDecimalFor(
                "select iqty from production_plan_items where id = ?", planItemId)
                .compareTo(BigDecimal.ZERO),
                "红冲 → plan_items.iqty 10→0");
        assertEquals(4, itemChainStatusByItem(orderItemId),
                "红冲 → chain_status 7→4 已排产（精确回退，非粗重置）");
        // PRODUCTION_INBOUND reservation released (no active reservation from this inbound)
        assertEquals(0, count(
                "select count(*) from stock_reservations "
                        + "where source_doc_type = 'PRODUCTION_INBOUND' and source_doc_id = ? "
                        + "and is_deleted = false and status = 0", finishedInId),
                "红冲 → 释放 PRODUCTION_INBOUND 预留");
        // order NOT closed (production undone)
        assertFalse(orderIsClosed(orderId), "红冲完工 → 订单回到未完成");
    }

    // ---------------------------------------------------------------------------------------------
    // #27 (amount correctness — AR) Shipping posts an AR row whose amount equals the shipment's
    // total = Σ(qty × price × discount). BigDecimal NUMERIC(18,4) — no float drift. On posting the
    // row is unsettled: amount_balance = amount_original_local, amount_settled = 0. Exchange rate is
    // persisted but NOT used to derive the amount (caller supplies local amount verbatim — avoids
    // precision drift). The qty×price×discount decomposition is client-asserted; the server treats
    // amount_local as authoritative, so we verify amount_balance arithmetic instead.
    // ---------------------------------------------------------------------------------------------
    @Test
    void amounts_arFromShipmentMatchesTotalAndStartsUnsettled() {
        World w = seedWorld("s27ar");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        loginAs(w.superAdminUserId());
        // ship 10 @ price 100, discount 1 → line amount 1000 (set in shipmentRequest)
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId);

        BigDecimal expected = new BigDecimal("10").multiply(new BigDecimal("100")); // qty × price × discount(1)
        BigDecimal arOriginalLocal = bigDecimalFor(
                "select amount_original_local from ar_ap_ledger "
                        + "where direction = 'AR' and source_doc_type = 'SALES_SHIPMENT' "
                        + "and source_doc_id = ?", shipmentId);
        assertEquals(0, arOriginalLocal.compareTo(expected),
                "AR 金额 = 量×价×折扣 = " + expected + "（BigDecimal 无漂移）");
        // original (foreign) falls back to local when not supplied → equal
        BigDecimal arOriginal = bigDecimalFor(
                "select amount_original from ar_ap_ledger where source_doc_id = ?", shipmentId);
        assertEquals(0, arOriginal.compareTo(arOriginalLocal),
                "未传原币额时 amount_original 回退 = amount_original_local");
        // unsettled at posting: balance = original, settled = 0
        assertEquals(0, bigDecimalFor(
                "select amount_balance from ar_ap_ledger where source_doc_id = ?", shipmentId)
                .compareTo(arOriginalLocal),
                "立账时 amount_balance = amount_original_local（未核销）");
        assertEquals(0, bigDecimalFor(
                "select amount_settled from ar_ap_ledger where source_doc_id = ?", shipmentId)
                .compareTo(BigDecimal.ZERO),
                "立账时 amount_settled = 0");
        assertEquals(3, intFor(
                "select legacy_bstyle from ar_ap_ledger where source_doc_id = ?", shipmentId),
                "销售出货 AR 的 legacy_bstyle = 3");
    }

    // ---------------------------------------------------------------------------------------------
    // #27 (amount correctness — GL balance) GL is regenerated (not inline): generate(period) rebuilds
    // AUTO vouchers from ar_ap_ledger. Each AR/AP voucher is exactly two entries with the SAME amount
    // and OPPOSITE direction (1 借 / -1 贷), so Σ(direction × amount) per voucher == 0. Asserting no
    // unbalanced voucher exists after generation is the 借贷必平 invariant.
    // ---------------------------------------------------------------------------------------------
    @Test
    void amounts_glVouchersBalanceAfterGenerate() {
        World w = seedWorld("s27gl");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        loginAs(w.superAdminUserId());
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId); // posts AR (bill_date 2026-02-01 → period 2026-02)
        String billNo = strFor("select bill_no from sales_shipments where id = ?", shipmentId);

        // GL's postAr/postAp CROSS JOIN payment_styles by path (/113/ /031/ /123/ /203/ /041/).
        // These chart-of-accounts nodes are loaded via data bootstrap, not Flyway — absent in the
        // test container — so seed them here as fixture data before generating GL.
        seedChartOfAccounts();
        glPostingService.generate("2026-02"); // rebuild AUTO vouchers for the period (finance_post:execute)

        // AR voucher for this shipment has a balanced debit+credit pair
        int arEntries = count(
                "select count(*) from gl_entries ge join gl_vouchers gv on gv.id = ge.voucher_id "
                        + "where gv.source_type = 'AR_POST' and gv.voucher_no = ?", billNo);
        assertTrue(arEntries >= 2,
                "AR 凭证至少借/贷两行（got " + arEntries + "）");
        BigDecimal arVoucherBalance = bigDecimalFor(
                "select coalesce(sum(ge.direction * ge.amount), 0) from gl_entries ge "
                        + "join gl_vouchers gv on gv.id = ge.voucher_id "
                        + "where gv.source_type = 'AR_POST' and gv.voucher_no = ?", billNo);
        assertEquals(0, arVoucherBalance.compareTo(BigDecimal.ZERO),
                "AR 凭证借贷必平 Σ(direction×amount) = 0");
        // global invariant: no unbalanced voucher exists after generation
        assertEquals(0, intFor(
                "select count(*) from ("
                        + "  select gv.id from gl_vouchers gv join gl_entries ge on ge.voucher_id = gv.id "
                        + "  group by gv.id having sum(ge.direction * ge.amount) <> 0) unbalanced"),
                "全局：所有凭证借贷必平（无不平衡凭证）");
    }

    // ---------------------------------------------------------------------------------------------
    // #28 (conservation — pegging traceability + qty invariant) The finished good G's plan, when its
    // planning package is confirmed, creates a material DEMAND for the BUY raw material H, and a
    // supply PEG binds that demand to the spawned purchase. After finance approves the purchase order,
    // the peg migrates REQUEST_ITEM→ORDER_ITEM (request peg RELEASED, order peg EFFECTIVE). This is the
    // finished→raw traceability the bottom-up redesign (#13) must extend to semi-finished goods. The
    // DB-CHECK invariant consumed+released ≤ allocated must hold for every peg.
    // ---------------------------------------------------------------------------------------------
    @Test
    void fulfillment_pegLinksDemandToPurchaseAndConservesQty() {
        World w = seedWorld("s28");
        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-s28", "成品G-s28", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-s28", "原料H-s28", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2"); // G -> H ; order 10 -> H demand 20
        loginAs(w.superAdminUserId());
        UUID orderItemId = procureDirectBuy(w, g, h, "10"); // H purchase-order line; pegs created + migrated

        // H demand exists inside G's confirmed planning package (finished→raw link via package)
        UUID planId = jdbc.queryForObject(
                "select pkg.plan_id from production_material_demands dmd "
                        + "join production_planning_packages pkg on pkg.id = dmd.package_id "
                        + "where dmd.goods_id = ?", UUID.class, h);
        assertNotNull(planId, "H 的物料需求挂在某生产计划的 CONFIRMED 包下（成品计划 → 原料需求）");
        UUID demandId = jdbc.queryForObject(
                "select id from production_material_demands where goods_id = ? and package_id in "
                        + "(select id from production_planning_packages where plan_id = ? and status = 'CONFIRMED') "
                        + "order by id limit 1",
                UUID.class, h, planId);

        // supply peg links the H demand → THIS purchase order item (traceable finished→raw→purchase)
        assertEquals(1, count(
                "select count(*) from production_material_supply_pegs "
                        + "where demand_id = ? and supply_type = 'PURCHASE_ORDER_ITEM' and supply_item_id = ? "
                        + "and status = 'EFFECTIVE'",
                demandId, orderItemId),
                "supply peg 链接 H 需求 → 采购订货明细（成品→原料→采购 可溯）");

        // the original REQUEST_ITEM peg was released (released = allocated) after order approval
        assertEquals(1, count(
                "select count(*) from production_material_supply_pegs "
                        + "where demand_id = ? and supply_type = 'PURCHASE_REQUEST_ITEM' and status = 'RELEASED'",
                demandId),
                "申请 peg 转单后转为 RELEASED");

        // order peg allocated = H demand (order 10 × BOM 2 = 20)
        BigDecimal allocated = bigDecimalFor(
                "select allocated_qty from production_material_supply_pegs "
                        + "where demand_id = ? and supply_type = 'PURCHASE_ORDER_ITEM'", demandId);
        assertEquals(0, allocated.compareTo(new BigDecimal("20")),
                "order peg allocated_qty = H 净需求 20");

        // conservation invariant (DB-CHECK enforced, assert holds across all pegs)
        assertEquals(0, intFor(
                "select count(*) from production_material_supply_pegs "
                        + "where consumed_qty + released_qty > allocated_qty"),
                "守恒：所有 peg 满足 consumed + released ≤ allocated");
        // terminal-state strict equality: every RELEASED peg has released = allocated, consumed = 0
        assertEquals(0, intFor(
                "select count(*) from production_material_supply_pegs "
                        + "where status = 'RELEASED' and released_qty <> allocated_qty"),
                "RELEASED peg: released = allocated");
    }

    // ---------------------------------------------------------------------------------------------
    // #29 (multi-account permissions — role isolation) A sales-only account (sales_shipment:edit,
    // NOT warehouse-work) can create a shipment but must be DENIED the warehouse pick transition.
    // A warehouse-only account (warehouse-work, NOT edit) can pick but must be DENIED shipment
    // creation. @EnableMethodSecurity enforces @PreAuthorize against the SecurityContextHolder
    // principal even in direct service calls — so a missing authority throws AccessDeniedException.
    // This is the role separation the redesign's "各司其职" depends on.
    // ---------------------------------------------------------------------------------------------
    @Test
    void permissions_roleIsolationAndObjectScope() {
        World w = seedWorld("s29");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        UUID salesOwner = createUserWithPerms(w, "sales-owner", "sales_shipment:edit");
        UUID salesOther = createUserWithPerms(w, "sales-other", "sales_shipment:edit");
        UUID warehouseUser = createUserWithPerms(w, "wh-s29", "sales_shipment:warehouse-work");
        // assign the order to salesOwner — only the owning sales rep can act on it (object scope)
        jdbc.update("update sales_orders set owner_employee_id = ? where id = ?",
                employeeIdOf(salesOwner), orderId);

        // (1) Object scope: a DIFFERENT sales rep cannot reference this order line
        loginAs(salesOther);
        ApiException scopeDenied = assertThrows(ApiException.class,
                () -> createShipment(w, orderItemId, w.goodsA(), "10"));
        assertTrue(scopeDenied.getMessage().contains("无权"),
                "对象隔离：非归属销售不能引用该订单行（" + scopeDenied.getMessage() + "）");

        // (2) the OWNER sales rep CAN create the shipment
        loginAs(salesOwner);
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");

        // (3) role isolation: owner lacks warehouse-work → pick DENIED (@PreAuthorize)
        WarehouseWorkTransitionRequest picking = new WarehouseWorkTransitionRequest();
        picking.setTargetStatus("PICKING");
        assertThrows(AccessDeniedException.class,
                () -> shipmentService.transitionWarehouseWork(shipmentId, picking),
                "销售无 sales_shipment:warehouse-work → 拣货被拒");

        // (4) warehouse CAN pick (has warehouse-work)
        loginAs(warehouseUser);
        shipmentService.transitionWarehouseWork(shipmentId, picking);

        // (5) role isolation: warehouse lacks edit → create DENIED (@PreAuthorize fires first)
        loginAs(warehouseUser);
        assertThrows(AccessDeniedException.class,
                () -> createShipment(w, orderItemId, w.goodsA(), "5"),
                "仓库无 sales_shipment:edit → 建出货单被拒");
    }

    private UUID employeeIdOf(UUID userId) {
        return jdbc.queryForObject(
                "select employee_id from users where id = ?", UUID.class, userId);
    }

    // ---------------------------------------------------------------------------------------------
    // #30 (concurrency — idempotency) Replaying the same IQC disposition with the SAME idempotency
    // key must NOT double-count stock. The first PASS stocks +20; a retry (network redelivery /
    // double-click) with the identical key is absorbed as a no-op. This is the "会不会对一个事情
    //重复" guard: retries never inflate inventory.
    // ---------------------------------------------------------------------------------------------
    @Test
    void concurrency_idempotentIqcDisposeDoesNotDoubleCountStock() {
        World w = seedWorld("s30idem");
        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-s30i", "成品G-s30i", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-s30i", "原料H-s30i", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2");
        loginAs(w.superAdminUserId());
        UUID orderItemId = procureDirectBuy(w, g, h, "10"); // H PO 20, finance-approved (ends as reviewer)
        loginAs(w.superAdminUserId()); // receipt approve + IQC need super-admin authority
        UUID receiptId = receiveIntoQuarantine(w, h, orderItemId, "20");
        UUID inspectionItemId = jdbc.queryForObject(
                "select id from procurement_inspection_items where receipt_id = ? and goods_id = ? "
                        + "order by updated_at desc limit 1",
                UUID.class, receiptId, h);
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "IQC 待检期间库存为 0");

        String idemKey = "idem-s30i-" + inspectionItemId;
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "合格", idemKey));
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(new BigDecimal("20")),
                "首次 PASS → 入库 20");
        // retry with the SAME idempotency key → idempotent, stock NOT doubled
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "合格", idemKey));
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(new BigDecimal("20")),
                "同 idempotencyKey 重复处置 → 幂等，库存不翻倍（仍 20，非 40）");
    }

    // ---------------------------------------------------------------------------------------------
    // #30 (concurrency — optimistic lock) A PENDING finance case can be approved once (version 0→1).
    // A second approve of the SAME case must be rejected — whether with the now-stale version or the
    // current one — so two concurrent/replicated approvals can never double-approve (the "会不会对一
    // 个事情重复" guard for money flow). The order stays approved exactly once.
    // ---------------------------------------------------------------------------------------------
    @Test
    void concurrency_financeApprovalCannotBeDoubleApproved() {
        World w = seedWorld("s30lock");
        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-s30l", "成品G-s30l", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-s30l", "原料H-s30l", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2");
        loginAs(w.superAdminUserId());
        ProcurementCase pc = submitPurchaseForFinance(w, g, h, "10"); // PENDING case, version 0
        assertEquals("PENDING", strFor(
                "select status from procurement_order_approval_cases where order_type='PURCHASE' and order_id = ?",
                pc.orderId()), "提交后审核案 PENDING");

        loginAs(pc.reviewerUserId());
        long v0 = jdbc.queryForObject(
                "select version from procurement_order_approval_cases where order_type='PURCHASE' and order_id = ?",
                Long.class, pc.orderId());
        financeApproval.approve("PURCHASE", pc.orderId(), v0); // first approve succeeds 0→1
        assertEquals(1, intFor("select status from purchase_orders where id = ?", pc.orderId()),
                "首次审批 → 订单 0→1 生效");

        // second approve (same case) rejected — no double-approval regardless of version
        assertThrows(ApiException.class,
                () -> financeApproval.approve("PURCHASE", pc.orderId(), v0),
                "重复审批同一单 → 拒绝（不重复生效）");
        assertEquals(1, intFor("select status from purchase_orders where id = ?", pc.orderId()),
                "重复审批被拒 → 订单状态不变（仍 1，未重复）");
    }

    // ---------------------------------------------------------------------------------------------
    // #31 (security — anti-ID probing) A sales rep who does NOT own a shipment (and lacks sales:view:all
    // / the operation bypass authorities) must get NOT_FOUND (404) when reading it — never FORBIDDEN
    // (403) — so the mere existence of another rep's document is not leaked. SalesDocumentAccessPolicy
    // .requireReadable intentionally throws NOT_FOUND ("Do not reveal whether an inaccessible document
    // exists"). This is the 反ID探测 guarantee.
    // ---------------------------------------------------------------------------------------------
    @Test
    void security_antiIdProbing_nonOwnerReadReturnsNotFound() {
        World w = seedWorld("s31");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        UUID salesOwner = createUserWithPerms(w, "sales-owner-s31",
                "sales_shipment:edit", "sales_shipment:view");
        UUID salesOther = createUserWithPerms(w, "sales-other-s31", "sales_shipment:view");
        jdbc.update("update sales_orders set owner_employee_id = ? where id = ?",
                employeeIdOf(salesOwner), orderId);
        loginAs(salesOwner);
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10"); // owned by salesOwner

        // salesOther reads the EXISTING shipment → 404, not 403 (no existence leak)
        loginAs(salesOther);
        ApiException ex = assertThrows(ApiException.class,
                () -> shipmentService.detail(shipmentId));
        assertEquals(ErrorCode.NOT_FOUND, ex.getCode(),
                "反ID探测：非归属者读既有出货单 → NOT_FOUND(404)，非 FORBIDDEN(403)");
    }

    // ---------------------------------------------------------------------------------------------
    // #34 (purchase object-level auth — maker_id isolation, V233) A purchase order is isolated by
    // its maker: a DIFFERENT purchaser (no purchase:view:all) cannot list/read/update/delete it
    // (read → NOT_FOUND anti-probing; write → FORBIDDEN). The maker, a view:all supervisor, and
    // super-admin can. A NULL-maker legacy order stays public-readable but ordinary-not-writable.
    // Finance approval is intentionally NOT gated — exercised by #22/#30 where a non-maker reviewer
    // approves the order through the ProcurementOrderApprovalPort.
    // ---------------------------------------------------------------------------------------------
    @Test
    void purchaseObjectScope_isolatesByMakerWithViewAllAndNullOwnerSemantics() {
        World w = seedWorld("pauth");
        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-pauth", "成品G-pauth", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-pauth", "原料H-pauth", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2"); // G -> H direct BUY; order G 10 -> H demand 20

        UUID purchaserA = createUserWithPerms(w, "purchA-pauth",
                "purchase_order:view", "purchase_order:edit", "purchase_request:view");
        UUID purchaserB = createUserWithPerms(w, "purchB-pauth",
                "purchase_order:view", "purchase_order:edit", "purchase_request:view");
        UUID supervisor = createUserWithPerms(w, "sup-pauth",
                "purchase_order:view", "purchase_order:edit", "purchase_request:view", "purchase:view:all");

        // DRAFT purchase order owned by A (maker = A's employee) via the procurement chain
        UUID orderId = draftPurchaseOrderOwnedBy(w, purchaserA, g, h, "10");
        assertEquals(employeeIdOf(purchaserA),
                jdbc.queryForObject("select maker_id from purchase_orders where id = ?", UUID.class, orderId),
                "前置：采购单 maker = A");

        // (1) purchaserB (no view:all) — list excludes, detail NOT_FOUND, write/delete FORBIDDEN
        loginAs(purchaserB);
        var bPage = purchaseOrderService.list(emptyOrderFilter(), 1, 50, null, null);
        assertTrue(bPage.getItems().stream().noneMatch(i -> i.getId().equals(orderId)),
                "对象隔离：B 的列表不含 A 的采购单");
        ApiException nf = assertThrows(ApiException.class,
                () -> purchaseOrderService.detail(orderId));
        assertEquals(ErrorCode.NOT_FOUND, nf.getCode(),
                "反ID探测：B 读 A 的采购单 → NOT_FOUND(404)，不泄露存在性");
        assertEquals(ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class,
                        () -> purchaseOrderService.update(orderId, headerOnlyOrderReq(w))).getCode(),
                "对象隔离：B 改 A 的采购单 → FORBIDDEN(403)");
        assertEquals(ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class,
                        () -> purchaseOrderService.delete(orderId)).getCode(),
                "对象隔离：B 删 A 的采购单 → FORBIDDEN(403)");

        // (2) supervisor (purchase:view:all) — list includes, detail ok
        loginAs(supervisor);
        var sPage = purchaseOrderService.list(emptyOrderFilter(), 1, 50, null, null);
        assertTrue(sPage.getItems().stream().anyMatch(i -> i.getId().equals(orderId)),
                "view:all：主管列表含 A 的采购单");
        assertDoesNotThrow(() -> purchaseOrderService.detail(orderId),
                "view:all：主管可读 A 的采购单");

        // (3) super-admin — detail ok
        loginAs(w.superAdminUserId());
        assertDoesNotThrow(() -> purchaseOrderService.detail(orderId),
                "超管可读任意采购单");

        // (4) owner A — detail ok, write ok (owner gate passes)
        loginAs(purchaserA);
        assertDoesNotThrow(() -> purchaseOrderService.detail(orderId));
        assertDoesNotThrow(() -> purchaseOrderService.update(orderId, headerOnlyOrderReq(w)),
                "owner：A 可改自己的采购单（归属 gate 放行）");

        // (5) NULL-maker legacy order: public-readable, ordinary-not-writable, view:all-writable
        jdbc.update("update purchase_orders set maker_id = null where id = ?", orderId);
        loginAs(purchaserB);
        assertDoesNotThrow(() -> purchaseOrderService.detail(orderId),
                "NULL owner：老数据公共可读（B 可读）");
        assertEquals(ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class,
                        () -> purchaseOrderService.update(orderId, headerOnlyOrderReq(w))).getCode(),
                "NULL owner：老数据普通用户不可写（B → FORBIDDEN）");
        loginAs(supervisor);
        assertDoesNotThrow(() -> purchaseOrderService.update(orderId, headerOnlyOrderReq(w)),
                "NULL owner：持 view:all 可写（管理员兜底/指派）");
    }

    private com.uten.imp.features.purchase.order.dto.OrderQueryFilter emptyOrderFilter() {
        return new com.uten.imp.features.purchase.order.dto.OrderQueryFilter(
                null, null, null, null, null, null);
    }

    /** Header-only purchase-order save request (no item lines) — enough to pass the owner gate and
     *  header apply; used solely to prove the write-gate decision (it clears lines + zeroes totals). */
    private com.uten.imp.features.purchase.order.dto.OrderSaveRequest headerOnlyOrderReq(World w) {
        com.uten.imp.features.purchase.order.dto.OrderSaveRequest req =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        req.setBillDate(LocalDate.of(2026, 1, 15));
        req.setSupplierId(w.supplierId());
        req.setWarehouseId(w.warehouseId());
        req.setCurrencyId(w.currencyId());
        req.setExchangeRate(BigDecimal.ONE);
        req.setTaxRate(BigDecimal.ZERO);
        req.setItems(List.of());
        return req;
    }

    /** Drive plan→confirm→createBatch as ownerUserId so the resulting DRAFT purchase order has
     *  maker_id = ownerUserId's employee (object-level auth fixture). */
    private UUID draftPurchaseOrderOwnedBy(World w, UUID ownerUserId,
                                            UUID finished, UUID buy, String orderQty) {
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, finished, orderQty, orderQty);
        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-pauth-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        planningPackageService.confirm(planId, req);
        String planNo = strFor("select bill_no from production_plans where id = ?", planId);
        UUID requestItemId = jdbc.queryForObject(
                "select pri.id from purchase_request_items pri "
                        + "join purchase_requests pr on pr.id = pri.request_id "
                        + "where pr.source_doc_no = ? and pri.goods_id = ?",
                UUID.class, planNo, buy);
        BigDecimal reqQty = jdbc.queryForObject(
                "select qty from purchase_request_items where id = ?", BigDecimal.class, requestItemId);

        loginAs(ownerUserId); // createBatch as the owner → maker = owner's employee
        com.uten.imp.features.purchase.order.dto.OrderSaveRequest orderReq =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderReq.setBillDate(LocalDate.of(2026, 1, 15));
        orderReq.setSupplierId(w.supplierId());
        orderReq.setWarehouseId(w.warehouseId());
        orderReq.setCurrencyId(w.currencyId());
        orderReq.setExchangeRate(BigDecimal.ONE);
        orderReq.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line =
                new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(buy);
        line.setRequestItemId(requestItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(reqQty);
        line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(reqQty.multiply(new BigDecimal("50")));
        line.setAmountLocal(reqQty.multiply(new BigDecimal("50")));
        orderReq.setItems(List.of(line));
        purchaseOrderService.createBatch(orderReq);
        return jdbc.queryForObject(
                "select id from purchase_orders where is_deleted = false and supplier_id = ? "
                        + "order by created_at desc limit 1",
                UUID.class, w.supplierId());
    }

    // ---------------------------------------------------------------------------------------------
    // #35 (production plan object-level auth + progress board nativeReadScope, V233) A plan is
    // isolated by maker; the read-side progress board (native SQL) MUST apply the same scope so a
    // non-owner cannot see aggregate progress of plans they cannot list. This also proves the
    // progress nativeReadScope SQL is valid in both the seeAll (1=1) and filtered (IN) paths.
    // ---------------------------------------------------------------------------------------------
    @Test
    void productionPlanObjectScope_isolatesByMakerAndProgressBoardRespectsScope() {
        World w = seedWorld("pauthp");
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10"); // maker = super-admin
        UUID plannerA = createUserWithPerms(w, "planA-p", "production_plan:view", "production_plan:edit");
        UUID other = createUserWithPerms(w, "planB-p", "production_plan:view");
        jdbc.update("update production_plans set maker_id = ? where id = ?",
                employeeIdOf(plannerA), planId);

        // non-owner (no view:all) — detail NOT_FOUND, list excludes, progress board empty (filtered)
        loginAs(other);
        assertEquals(ErrorCode.NOT_FOUND,
                assertThrows(ApiException.class, () -> planService.detail(planId)).getCode(),
                "生产计划对象隔离：非归属者 detail → NOT_FOUND");
        assertTrue(planService.list(emptyPlanFilter(), 1, 50, null, null).getItems().stream()
                        .noneMatch(i -> i.getId().equals(planId)),
                "生产计划 list 不含非归属计划");
        assertEquals(0,
                planService.progress(false, "billDate", 1, 10, "", "", null, null).getTotal(),
                "进度看板 nativeReadScope：非归属者见 0 条（SQL 有效 + 按归属过滤，与 list 同口径）");

        // super-admin — detail ok, progress board includes the plan (seeAll → 1=1, SQL valid)
        loginAs(w.superAdminUserId());
        assertDoesNotThrow(() -> planService.detail(planId));
        assertTrue(planService.progress(false, "billDate", 1, 10, "", "", null, null).getTotal() >= 1,
                "超管进度看板含该计划（seeAll → 1=1，SQL 有效）");
    }

    private com.uten.imp.features.production.plan.dto.PlanQueryFilter emptyPlanFilter() {
        return new com.uten.imp.features.production.plan.dto.PlanQueryFilter(
                null, null, null, null, null, null);
    }

    // ---------------------------------------------------------------------------------------------
    // #36 (stock doc object-level auth, V233) A manual stock doc (OTHER_IN) is isolated by maker.
    // (Production-linked DRAW/FINISHED_IN are blocked from generic CRUD by isProductionLinked, so
    // the owner gate is exercised here via a manual doc which IS generic-CRUD-eligible.)
    // ---------------------------------------------------------------------------------------------
    @Test
    void stockDocObjectScope_isolatesByMaker() {
        World w = seedWorld("pauths");
        UUID keeperA = createUserWithPerms(w, "keepA-s", "stock_doc:view", "stock_doc:edit");
        UUID keeperB = createUserWithPerms(w, "keepB-s", "stock_doc:view", "stock_doc:edit");
        UUID supervisor = createUserWithPerms(w, "keepSup-s",
                "stock_doc:view", "stock_doc:edit", "stock_doc:view:all");

        loginAs(keeperA);
        UUID docId = createOtherInDraft(w); // OTHER_IN draft, maker = keeperA
        assertEquals(employeeIdOf(keeperA),
                jdbc.queryForObject("select maker_id from stock_documents where id = ?", UUID.class, docId),
                "前置：仓库单据 maker = keeperA");

        loginAs(keeperB);
        assertEquals(ErrorCode.NOT_FOUND,
                assertThrows(ApiException.class, () -> stockDocService.detail(docId)).getCode(),
                "仓库单据对象隔离：非归属者 detail → NOT_FOUND");
        assertTrue(stockDocService.list(stockDocFilter("OTHER_IN"), 1, 50, null, null).getItems().stream()
                        .noneMatch(i -> i.getId().equals(docId)),
                "仓库单据 list 不含非归属单据");

        loginAs(supervisor);
        assertDoesNotThrow(() -> stockDocService.detail(docId), "view:all：主管可读");
        loginAs(w.superAdminUserId());
        assertDoesNotThrow(() -> stockDocService.detail(docId), "超管可读");
    }

    private com.uten.imp.features.stock.dto.StockDocQueryFilter stockDocFilter(String docType) {
        return new com.uten.imp.features.stock.dto.StockDocQueryFilter(
                docType, null, null, null, null, null, null, null);
    }

    private UUID createOtherInDraft(World w) {
        com.uten.imp.features.stock.dto.StockDocSaveRequest req =
                new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        req.setDocType("OTHER_IN");
        req.setBillDate(LocalDate.of(2026, 1, 15));
        req.setWarehouseId(w.warehouseId());
        com.uten.imp.features.stock.dto.StockDocItemLine line =
                new com.uten.imp.features.stock.dto.StockDocItemLine();
        line.setGoodsId(w.goodsA());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("5"));
        line.setPrice(new BigDecimal("10"));
        line.setAmountOriginal(new BigDecimal("50"));
        line.setAmountLocal(new BigDecimal("50"));
        req.setItems(List.of(line));
        return stockDocService.create(req).getId();
    }

    // ---------------------------------------------------------------------------------------------
    // #32 (security — super-admin grant gate + self-demotion) Granting super-admin requires the caller
    // to BE a super-admin (principal.superAdmin) — an admin who merely holds authorization:manage is
    // denied (AccessDeniedException), closing the self-escalation path. A real super-admin can grant.
    // A super-admin cannot demote THEMSELF (FORBIDDEN). The dangerous management surface is unreachable
    // for ordinary (even privileged) users.
    // ---------------------------------------------------------------------------------------------
    @Test
    void security_superAdminGrantGatedAndSelfDemotionBlocked() {
        World w = seedWorld("s32");
        UUID target = createUserWithPerms(w, "target-s32"); // plain user
        UUID adminNonSuper = createUserWithPerms(w, "admin-s32", "authorization:manage");

        // non-super admin (even with authorization:manage) CANNOT grant super-admin
        loginAs(adminNonSuper);
        assertThrows(AccessDeniedException.class,
                () -> userAccountAdmin.setSuperAdmin(target, true),
                "非超管(纵有 authorization:manage)不能授超管 → principal.superAdmin 门槛防自我提权");

        // real super-admin CAN grant
        loginAs(w.superAdminUserId());
        userAccountAdmin.setSuperAdmin(target, true);
        assertTrue(isSuperAdmin(target), "超管可授予超管身份");

        // super-admin cannot demote SELF
        ApiException selfDemote = assertThrows(ApiException.class,
                () -> userAccountAdmin.setSuperAdmin(w.superAdminUserId(), false));
        assertEquals(ErrorCode.FORBIDDEN, selfDemote.getCode(),
                "超管不能取消本人超管身份（防自锁）");
    }

    // ---------------------------------------------------------------------------------------------
    // #33 (security — no self-escalation via permission overrides) Permission assignment is super-admin
    // only (class-level principal.superAdmin) AND forbids targeting self or another super-admin. So
    // there is no path for a user to grant themselves or anyone super-admin-level authority. A non-super
    // admin is denied entirely; a super-admin can edit OTHERS but not themselves.
    // ---------------------------------------------------------------------------------------------
    @Test
    void security_permissionOverrideSelfGrantBlocked() {
        World w = seedWorld("s33");
        UUID other = createUserWithPerms(w, "other-s33");

        // super-admin cannot modify THEIR OWN authorization
        loginAs(w.superAdminUserId());
        ApiException selfEdit = assertThrows(ApiException.class,
                () -> permissionOverrideAdmin.setPermissionOverrides(
                        w.superAdminUserId(), List.of("sales_order:edit"), List.of()));
        assertEquals(ErrorCode.FORBIDDEN, selfEdit.getCode(),
                "超管不能修改本人/超管的授权策略（无自我提权路径）");

        // super-admin CAN modify another (non-super) user's overrides
        permissionOverrideAdmin.setPermissionOverrides(other, List.of("sales_order:edit"), List.of());
        assertEquals(1, count(
                "select count(*) from user_permission_overrides where user_id = ? and effect = 'grant'",
                other), "超管可改他人授权");

        // non-super admin CANNOT assign permissions at all
        UUID adminNonSuper = createUserWithPerms(w, "admin-s33", "authorization:manage");
        loginAs(adminNonSuper);
        assertThrows(AccessDeniedException.class,
                () -> permissionOverrideAdmin.setPermissionOverrides(
                        other, List.of("sales_shipment:view"), List.of()),
                "非超管不能改授权 → 越权被拒");
    }

    private boolean isSuperAdmin(UUID userId) {
        return Boolean.TRUE.equals(jdbc.queryForObject(
                "select is_super_admin from users where id = ?", Boolean.class, userId));
    }

    /** Receive goods against an approved PO and approve the receipt → IQC quarantine (frozen, not in
     *  usable stock). Returns the receipt id (inspection items PENDING). */
    private UUID receiveIntoQuarantine(World w, UUID goodsId, UUID orderItemId, String qty) {
        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest rr =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        rr.setBillDate(LocalDate.of(2026, 1, 20));
        rr.setSupplierId(w.supplierId());
        rr.setWarehouseId(w.warehouseId());
        rr.setCurrencyId(w.currencyId());
        rr.setExchangeRate(BigDecimal.ONE);
        rr.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine ri =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        ri.setGoodsId(goodsId);
        ri.setOrderItemId(orderItemId);
        ri.setUnitId(w.unitId());
        ri.setUnitRate(BigDecimal.ONE);
        BigDecimal q = new BigDecimal(qty);
        ri.setQty(q);
        ri.setPrice(new BigDecimal("50"));
        ri.setAmountOriginal(q.multiply(new BigDecimal("50")));
        ri.setAmountLocal(q.multiply(new BigDecimal("50")));
        rr.setItems(List.of(ri));
        purchaseReceiptService.create(rr);
        UUID receiptId = jdbc.queryForObject(
                "select id from purchase_receipts where is_deleted = false and supplier_id = ? "
                        + "order by created_at desc limit 1",
                UUID.class, w.supplierId());
        purchaseReceiptService.approve(receiptId); // IQC freeze
        return receiptId;
    }

    /** Drive procurement up to finance SUBMIT (case PENDING, version 0) — everything procureDirectBuy
     *  does EXCEPT the final approve — so a test can exercise the approval lock. */
    private record ProcurementCase(UUID orderId, UUID reviewerUserId) {}

    private ProcurementCase submitPurchaseForFinance(World w, UUID finished, UUID buy, String orderQty) {
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, finished, orderQty, orderQty);
        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-s30f-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        planningPackageService.confirm(planId, req);
        String planNo = strFor("select bill_no from production_plans where id = ?", planId);
        UUID requestItemId = jdbc.queryForObject(
                "select pri.id from purchase_request_items pri "
                        + "join purchase_requests pr on pr.id = pri.request_id "
                        + "where pr.source_doc_no = ? and pri.goods_id = ?",
                UUID.class, planNo, buy);
        BigDecimal reqQty = jdbc.queryForObject(
                "select qty from purchase_request_items where id = ?", BigDecimal.class, requestItemId);

        com.uten.imp.features.purchase.order.dto.OrderSaveRequest orderReq =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderReq.setBillDate(LocalDate.of(2026, 1, 15));
        orderReq.setSupplierId(w.supplierId());
        orderReq.setWarehouseId(w.warehouseId());
        orderReq.setCurrencyId(w.currencyId());
        orderReq.setExchangeRate(BigDecimal.ONE);
        orderReq.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line =
                new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(buy);
        line.setRequestItemId(requestItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(reqQty);
        line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(reqQty.multiply(new BigDecimal("50")));
        line.setAmountLocal(reqQty.multiply(new BigDecimal("50")));
        orderReq.setItems(List.of(line));
        purchaseOrderService.createBatch(orderReq);
        UUID orderId = jdbc.queryForObject(
                "select id from purchase_orders where is_deleted = false and supplier_id = ? "
                        + "order by created_at desc limit 1",
                UUID.class, w.supplierId());
        UUID reviewer = createReviewer(w, "finance_order_approval:review");
        financeApproval.submit("PURCHASE", orderId); // PENDING, version 0
        return new ProcurementCase(orderId, reviewer);
    }

    /** Create a non-super-admin user granted a set of permission codes via user_permission_overrides
     *  (the V229 individual-grant path), so @PreAuthorize sees exactly those authorities. */
    private UUID createUserWithPerms(World w, String tag, String... permCodes) {
        UUID emp = UUID.randomUUID(), usr = UUID.randomUUID();
        jdbc.update("""
                insert into employees(id, code, full_name, id_type, department_id, hire_date,
                                      status, employment_type)
                values (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, emp, "EMP-" + tag, "员工-" + tag, w.departmentId());
        jdbc.update("""
                insert into users(id, employee_id, login_account, password_hash,
                                  must_change_password, is_super_admin, status)
                values (?, ?, ?, 'x', false, false, 'active')
                """, usr, emp, "USR-" + tag);
        for (String code : permCodes) {
            jdbc.update("""
                    insert into user_permission_overrides(user_id, permission_id, effect)
                    select ?, p.id, 'grant' from permissions p where p.code = ?
                    """, usr, code);
        }
        return usr;
    }

    /** Seed the minimal chart-of-accounts (payment_styles) GL posting needs. These root nodes get
     *  path = '/code/' from the trg_payment_style_path trigger; loaded via data bootstrap in prod. */
    private void seedChartOfAccounts() {
        jdbc.update("""
                insert into payment_styles(code, name, category, level)
                select c, n, cat, 0 from (values
                    ('113','应收账款','ACCOUNT'),
                    ('031','销售收入','INCOME'),
                    ('123','库存商品','ACCOUNT'),
                    ('203','应付账款','LIABILITY'),
                    ('041','销售成本','EXPENSE')
                ) v(c, n, cat)
                where not exists (select 1 from payment_styles p where p.path = '/' || v.c || '/')
                """);
    }

    /** Σ(qty × direction) over stock_movements for a warehouse+goods — the event-sourcing ledger
     *  total that stock_balances.qty must always equal. */
    private BigDecimal movementSum(UUID warehouseId, UUID goodsId) {
        return jdbc.queryForObject(
                "select coalesce(sum(qty * direction), 0) from stock_movements "
                        + "where warehouse_id = ? and goods_id = ?",
                BigDecimal.class, warehouseId, goodsId);
    }

    /** Produce a finished good fully (plan→report→FINISHED_IN): chain=7, reserved=produced=qty, stock=qty.
     *  Returns the scoped IDs (decision 2: shipping is only possible after production completes). */
    private record Production(UUID orderItemId, UUID planItemId, UUID finishedInId) {}

    private Production produceFinished(World w, UUID goodsId, String orderQty, String planQty) {
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, goodsId, orderQty, planQty);
        UUID planItemId = planItemIdFor(planId, goodsId);
        UUID orderItemId = orderItemIdOfPlan(planId);
        UUID reportId = reportAndApprove(w, planItemId, orderItemId, goodsId, orderQty);
        UUID finishedInId = finishedInDocForReport(reportBillNo(reportId));
        stockDocService.approve(finishedInId);
        return new Production(orderItemId, planItemId, finishedInId);
    }

    private ShipmentSaveRequest shipmentRequest(World w, UUID orderItemId, UUID goodsId, String qty) {
        ShipmentSaveRequest req = new ShipmentSaveRequest();
        req.setBillDate(LocalDate.of(2026, 2, 1));
        req.setClientId(w.clientId());
        req.setWarehouseId(w.warehouseId());
        req.setCurrencyId(w.currencyId());
        req.setExchangeRate(BigDecimal.ONE);
        req.setTaxRate(BigDecimal.ZERO);
        ShipmentItemLine line = new ShipmentItemLine();
        line.setOrderItemId(orderItemId);
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("100"));
        BigDecimal amt = new BigDecimal(qty).multiply(new BigDecimal("100"));
        line.setAmountOriginal(amt);
        line.setAmountLocal(amt);
        line.setDiscount(BigDecimal.ONE);
        req.setItems(List.of(line));
        return req;
    }

    private UUID createShipment(World w, UUID orderItemId, UUID goodsId, String qty) {
        ShipmentDetail d = shipmentService.create(shipmentRequest(w, orderItemId, goodsId, qty));
        return d.getId();
    }

    /** Warehouse drives the full pick→pack→ship lifecycle (PENDING_PICK→PICKING→PICKED→SHIPPED). */
    private void shipThroughWarehouse(UUID shipmentId) {
        WarehouseWorkTransitionRequest t = new WarehouseWorkTransitionRequest();
        t.setTargetStatus("PICKING");
        shipmentService.transitionWarehouseWork(shipmentId, t);
        t.setTargetStatus("PICKED");
        shipmentService.transitionWarehouseWork(shipmentId, t);
        t.setTargetStatus("SHIPPED");
        shipmentService.transitionWarehouseWork(shipmentId, t);
    }

    private BigDecimal shippedQty(UUID orderItemId) {
        return jdbc.queryForObject(
                "select coalesce(shipped_qty, 0) from sales_order_items where id = ?",
                BigDecimal.class, orderItemId);
    }

    private UUID orderIdOfItem(UUID orderItemId) {
        return jdbc.queryForObject(
                "select order_id from sales_order_items where id = ?", UUID.class, orderItemId);
    }

    private boolean orderIsClosed(UUID orderId) {
        return Boolean.TRUE.equals(jdbc.queryForObject(
                "select is_closed from sales_orders where id = ?", Boolean.class, orderId));
    }

    private short shipmentStatus(UUID shipmentId) {
        return jdbc.queryForObject(
                "select status from sales_shipments where id = ?", Short.class, shipmentId);
    }

    private String shipmentWorkStatus(UUID shipmentId) {
        return jdbc.queryForObject(
                "select warehouse_work_status from sales_shipments where id = ?",
                String.class, shipmentId);
    }

    private boolean shipmentArPosted(UUID shipmentId) {
        return Boolean.TRUE.equals(jdbc.queryForObject(
                "select ar_posted from sales_shipments where id = ?", Boolean.class, shipmentId));
    }

    private UUID planItemIdFor(UUID planId, UUID goodsId) {
        return jdbc.queryForObject(
                "select id from production_plan_items "
                        + "where plan_id = ? and goods_id = ? and is_deleted = false",
                UUID.class, planId, goodsId);
    }

    /** The order line pegged to a plan (via plan_order_item_links). */
    private UUID orderItemIdOfPlan(UUID planId) {
        return jdbc.queryForObject(
                "select l.order_item_id from plan_order_item_links l "
                        + "join production_plan_items i on i.id = l.plan_item_id "
                        + "where i.plan_id = ? and l.is_deleted = false order by l.id limit 1",
                UUID.class, planId);
    }

    /** Create + approve a production daily report for one plan line; returns the report id.
     *  Setting warehouseId makes approve auto-generate a FINISHED_IN draft linked to the plan. */
    private UUID reportAndApprove(World w, UUID planItemId, UUID orderItemId,
                                  UUID goodsId, String qty) {
        DailyReportSaveRequest req = new DailyReportSaveRequest();
        req.setBillDate(LocalDate.of(2026, 1, 25));
        req.setWarehouseId(w.warehouseId());
        DailyReportItemLine line = new DailyReportItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPlanItemId(planItemId);
        line.setSalesOrderItemId(orderItemId);
        req.setItems(List.of(line));
        DailyReportDetail d = reportService.create(req);
        reportService.approve(d.getId());
        return d.getId();
    }

    private String reportBillNo(UUID reportId) {
        return strFor("select bill_no from production_daily_reports where id = ?", reportId);
    }

    /** The FINISHED_IN draft auto-generated by approving a daily report (source_doc_no = report). */
    private UUID finishedInDocForReport(String reportBillNo) {
        return jdbc.queryForObject(
                "select id from stock_documents where doc_type = 'FINISHED_IN' "
                        + "and source_doc_no = ? and is_deleted = false "
                        + "order by created_at desc limit 1",
                UUID.class, reportBillNo);
    }

    private BigDecimal producedQty(UUID orderItemId) {
        return jdbc.queryForObject(
                "select coalesce(produced_qty, 0) from sales_order_items where id = ?",
                BigDecimal.class, orderItemId);
    }

    private BigDecimal reservedQty(UUID orderItemId) {
        return jdbc.queryForObject(
                "select coalesce(reserved_qty, 0) from sales_order_items where id = ?",
                BigDecimal.class, orderItemId);
    }

    private int itemChainStatusByItem(UUID orderItemId) {
        Integer s = jdbc.queryForObject(
                "select chain_status from sales_order_items where id = ?",
                Integer.class, orderItemId);
        return s == null ? -99 : s;
    }

    private BigDecimal bigDecimalFor(String sql, Object... args) {
        return jdbc.queryForObject(sql, BigDecimal.class, args);
    }

    private BigDecimal stockBalance(UUID warehouseId, UUID goodsId) {
        return jdbc.queryForObject(
                "select coalesce(sum(qty), 0) from stock_balances "
                        + "where warehouse_id = ? and goods_id = ?",
                BigDecimal.class, warehouseId, goodsId);
    }

    private OrderSaveRequest orderRequest(World w, UUID goodsId, String qty, String price) {
        OrderSaveRequest req = new OrderSaveRequest();
        req.setBillDate(LocalDate.of(2026, 1, 15));
        req.setClientId(w.clientId());
        req.setCurrencyId(w.currencyId());
        req.setExchangeRate(BigDecimal.ONE);
        req.setTaxRate(BigDecimal.ZERO);
        OrderItemLine line = new OrderItemLine();
        line.setGoodsId(goodsId);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal(price));
        line.setDiscount(BigDecimal.ONE);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        BigDecimal amount = new BigDecimal(qty).multiply(new BigDecimal(price));
        line.setAmountOriginal(amount);
        line.setAmountLocal(amount);
        req.setItems(List.of(line));
        return req;
    }

    private int orderStatus(UUID orderId) {
        Integer s = jdbc.queryForObject(
                "select status from sales_orders where id = ?", Integer.class, orderId);
        return s == null ? -99 : s;
    }

    private String billNo(UUID orderId) {
        return jdbc.queryForObject(
                "select bill_no from sales_orders where id = ?", String.class, orderId);
    }

    private int itemChainStatus(UUID orderId) {
        Integer s = jdbc.queryForObject(
                "select chain_status from sales_order_items where order_id = ?",
                Integer.class, orderId);
        return s == null ? -99 : s;
    }

    private BigDecimal itemReservedQty(UUID orderId) {
        return jdbc.queryForObject(
                "select reserved_qty from sales_order_items where order_id = ?",
                BigDecimal.class, orderId);
    }

    private int reservationCountForOrder(UUID orderId) {
        Integer c = jdbc.queryForObject(
                "select count(*) from stock_reservations "
                        + "where source_doc_id = ? and is_deleted = false",
                Integer.class, orderId);
        return c == null ? 0 : c;
    }

    private long bomChildCount(UUID parentGoodsId) {
        Long n = jdbc.queryForObject(
                "select count(*) from goods_bom_items where goods_id = ? and is_deleted = false",
                Long.class, parentGoodsId);
        return n == null ? 0 : n;
    }

    // ---------------------------------------------------------------------------------------------
    // Auth: act as a given account. Faithful to JwtAuthFilter: read the account row from the
    // DB and resolve the effective permission set through PermissionResolver (so super-admin
    // short-circuits to all codes; a department user gets the real V212-granted set).
    // ---------------------------------------------------------------------------------------------
    private void loginAs(UUID userId) {
        java.util.Map<String, Object> u = jdbc.queryForMap(
                "select employee_id, login_account, is_super_admin, must_change_password, status "
                        + "from users where id = ?",
                userId);
        UUID employeeId = (UUID) u.get("employee_id");
        boolean superAdmin = Boolean.TRUE.equals(u.get("is_super_admin"));
        boolean mustChange = Boolean.TRUE.equals(u.get("must_change_password"));
        PermissionResolver.AuthorizationSnapshot snap =
                permissionResolver.authorizationSnapshot(userId, employeeId, superAdmin);
        AuthUser authUser = new AuthUser(
                userId, employeeId, (String) u.get("login_account"),
                snap.roles(), snap.permissions(), mustChange,
                "active".equals(u.get("status")), superAdmin);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(authUser, null, authUser.getAuthorities()));
    }

    // ---------------------------------------------------------------------------------------------
    // #13 (bottom-up full-tree confirm) One confirmFullTree on the top plan builds the ENTIRE MAKE
    // subplan tree (A→B→C), each auto-generated child approved + depth-stamped, MAKE supply pegs
    // chaining parent→child, and BUY/SUBCONTRACT demands exploded at every level (D purchased via B's
    // confirm, E subcontracted via A's). This is the "傻瓜式整树确认" the redesign delivers — replacing
    // today's manual layer-by-layer. The existing V194 auto-release then executes bottom-up (later tests).
    // ---------------------------------------------------------------------------------------------
    @Test
    void bottomUpConfirm_buildsFullMakeTreeWithDepthAndPegs() {
        World w = seedWorld("s13tree");
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");

        assertEquals(2, mrpService.makeTreeDepth(planId),
                "makeTreeDepth(A) = 2 (B 直层=1, C 下层=2)");

        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-s13tree-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        orchestrator.confirmFullTree(planId, req);

        // B = A's direct MAKE child; C = B's direct MAKE child (full tree, not just one level)
        UUID bPlanId = jdbc.queryForObject(
                "select subplan_id from subplan_links where plan_id = ? and source = 'EXECUTION_V1' and is_deleted = false",
                UUID.class, planId);
        UUID cPlanId = jdbc.queryForObject(
                "select subplan_id from subplan_links where plan_id = ? and source = 'EXECUTION_V1' and is_deleted = false",
                UUID.class, bPlanId);
        assertNotNull(bPlanId, "A → B 子计划 (EXECUTION_V1)");
        assertNotNull(cPlanId, "B → C 子计划（整树展开，非仅一层）");

        // auto-generated + depth + auto-approved
        assertTrue(isAutoGenerated(bPlanId), "B auto_generated=true");
        assertEquals(1, bomDepth(bPlanId), "B bom_depth=1");
        assertEquals(1, planStatus(bPlanId), "B 自动审核 status=1");
        assertTrue(isAutoGenerated(cPlanId), "C auto_generated=true");
        assertEquals(2, bomDepth(cPlanId), "C bom_depth=2");
        assertEquals(1, planStatus(cPlanId), "C 自动审核 status=1");
        assertFalse(isAutoGenerated(planId), "A 是人工审核根计划，非 auto_generated");

        // MAKE supply pegs chain parent→child: A's B-demand→B item, B's C-demand→C item
        assertTrue(count(
                "select count(*) from production_material_supply_pegs "
                        + "where supply_type = 'PRODUCTION_PLAN_ITEM' and status <> 'REVERSED'") >= 2,
                "≥2 MAKE peg (A→B、B→C)");

        // BUY (D) exploded at B's level, SUBCONTRACT (E) at A's level — full tree, not just top
        assertTrue(count(
                "select count(*) from purchase_request_items pri "
                        + "join purchase_requests pr on pr.id = pri.request_id "
                        + "where pri.goods_id = ? and pr.is_deleted = false", w.goodsD()) >= 1,
                "D 采购申请（B 层展开，全树非仅顶层）");
        assertTrue(count(
                "select count(*) from subcontract_applications where is_deleted = false") >= 1,
                "E 委外申请（A 层）");
    }

    private boolean isAutoGenerated(UUID planId) {
        return Boolean.TRUE.equals(jdbc.queryForObject(
                "select auto_generated from production_plans where id = ?", Boolean.class, planId));
    }

    private int bomDepth(UUID planId) {
        Integer d = jdbc.queryForObject(
                "select bom_depth from production_plans where id = ?", Integer.class, planId);
        return d == null ? -1 : d;
    }

    // ---------------------------------------------------------------------------------------------
    // #13 (bottom-up auto-release) With a clean MAKE-only tree X→Y→Z, after confirmFullTree(X) the
    // segments are WAITING (X waits on Y, Y waits on Z; Z is a BOM-less MAKE leaf → no segment, made
    // directly). Producing Z (report + FINISHED_IN) fires the existing V194 hook
    // (onFinishedInboundApproved) which promotes Y's WAITING segment → READY — proving the
    // orchestrator-built tree composes with the existing bottom-up auto-release ("下层完成自动释放上层").
    // ---------------------------------------------------------------------------------------------
    @Test
    void bottomUpConfirm_childFinishedInboundReleasesParentSegment() {
        World w = seedWorld("s13rel");
        UUID x = UUID.randomUUID(), y = UUID.randomUUID(), z = UUID.randomUUID();
        insertGoods(x, "X-s13r", "成品X-s13r", "自制", w.unitId(), w.unitLegacy());
        insertGoods(y, "Y-s13r", "半成品Y-s13r", "自制", w.unitId(), w.unitLegacy());
        insertGoods(z, "Z-s13r", "叶子Z-s13r", "自制", w.unitId(), w.unitLegacy());
        insertBom(x, y, "1"); // X → Y
        insertBom(y, z, "1"); // Y → Z
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, x, "10", "10");
        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-s13rel-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        orchestrator.confirmFullTree(planId, req);

        UUID yPlan = subplanOf(planId);
        UUID zPlan = subplanOf(yPlan);
        UUID zPlanItem = planItemOfPlan(zPlan);
        // before any production: X & Y WAITING on their MAKE child; Z (leaf) has no segment
        assertTrue(hasSegmentStatus(planId, "WAITING"), "X 段 WAITING（等 Y 完工）");
        assertTrue(hasSegmentStatus(yPlan, "WAITING"), "Y 段 WAITING（等 Z 完工）");
        assertEquals(0, count(
                "select count(*) from production_execution_segments where plan_id = ? and is_deleted = false",
                zPlan), "Z 是无 BOM 自制叶子件 → 无执行段（直接报工生产）");

        // produce Z (leaf): old-style report + FINISHED_IN (no segment, no sales link)
        loginAs(w.superAdminUserId());
        produceInternal(w, zPlanItem, z, "10");

        // V194 hook: Z inbound → Y's WAITING segment (MAKE demand pegged to Z's plan item) → READY
        assertTrue(hasSegmentStatus(yPlan, "READY"),
                "Z 完工入库 → Y 段自动释放为 READY（自底向上，既有 V194 钩子）");
        assertTrue(hasSegmentStatus(planId, "WAITING"),
                "X 段仍 WAITING（Y 尚未完工）");
    }

    // ---------------------------------------------------------------------------------------------
    // #13 (idempotency) Replaying confirmFullTree with the same root idempotency key must not rebuild
    // the tree — the top confirm replays, each level's deterministic idemKey replays, autoApprove is
    // idempotent. No new plans / segments / demands.
    // ---------------------------------------------------------------------------------------------
    @Test
    void bottomUpConfirm_idempotentReplayDoesNotRebuild() {
        World w = seedWorld("s13idem");
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-s13idem-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        orchestrator.confirmFullTree(planId, req);
        int plansBefore = count("select count(*) from production_plans where is_deleted = false");
        int segmentsBefore = count("select count(*) from production_execution_segments where is_deleted = false");
        int pegsBefore = count("select count(*) from production_material_supply_pegs where supply_type = 'PRODUCTION_PLAN_ITEM' and status <> 'REVERSED'");

        PlanningPackageResult replay = orchestrator.confirmFullTree(planId, req);
        assertTrue(replay.replayed(), "同 idempotencyKey 重放顶层 confirm → replayed=true");
        assertEquals(plansBefore, count("select count(*) from production_plans where is_deleted = false"),
                "重放不新增生产计划");
        assertEquals(segmentsBefore, count("select count(*) from production_execution_segments where is_deleted = false"),
                "重放不新增执行段");
        assertEquals(pegsBefore, count("select count(*) from production_material_supply_pegs where supply_type = 'PRODUCTION_PLAN_ITEM' and status <> 'REVERSED'"),
                "重放不新增 MAKE peg");
    }

    // ---------------------------------------------------------------------------------------------
    // #13 (cascade reversal) Reversing the top plan's package must cascade down the auto-generated
    // tree: A's package reverse → (cascade) B's package reverse → C reversed (leaf), then B reversed.
    // Without the cascade fix, closeSubplans would reject B (it has its own CONFIRMED package). Reverse
    // (not cancel) is the correct undo because the orchestrator auto-APPROVES subplans (status=1) —
    // cancel requires draft (status=0). Only auto-generated children cascade; the whole tree reverts once.
    // ---------------------------------------------------------------------------------------------
    @Test
    void bottomUpConfirm_cascadeReverseRevertsEntireTree() {
        World w = seedWorld("s13casc");
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        PlanningPreviewResult preview = planningPackageService.preview(planId, w.warehouseId());
        GeneratePlanningPackageRequest req = new GeneratePlanningPackageRequest();
        req.setWarehouseId(w.warehouseId());
        req.setIdempotencyKey("idem-s13casc-" + planId);
        req.setPreviewFingerprint(preview.fingerprint());
        req.setGeneratePurchaseRequest(true);
        orchestrator.confirmFullTree(planId, req);
        UUID bPlan = subplanOf(planId);
        UUID cPlan = subplanOf(bPlan);
        UUID aPkg = jdbc.queryForObject(
                "select id from production_planning_packages "
                        + "where plan_id = ? and status = 'CONFIRMED' and is_deleted = false",
                UUID.class, planId);

        planningPackageService.reverse(planId, aPkg,
                new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest(
                        "idem-reverse-s13casc-" + planId, "整树红冲"));

        // A & B packages no longer CONFIRMED (cascade); B/C subplans status=-1 (reversed, down to leaf C)
        assertEquals(0, count(
                "select count(*) from production_planning_packages "
                        + "where plan_id = ? and status = 'CONFIRMED' and is_deleted = false", planId),
                "A 包 REVERSED");
        assertEquals(0, count(
                "select count(*) from production_planning_packages "
                        + "where plan_id = ? and status = 'CONFIRMED' and is_deleted = false", bPlan),
                "B 包 REVERSED（整树级联）");
        assertEquals(-1, planStatus(bPlan), "B 子计划 status=-1（红冲级联）");
        assertEquals(-1, planStatus(cPlan), "C 子计划 status=-1（红冲到叶子）");
        assertEquals(0, count(
                "select count(*) from subplan_links "
                        + "where source = 'EXECUTION_V1' and is_deleted = false and plan_id in (?, ?)",
                planId, bPlan), "EXECUTION_V1 subplan_links 全部软删");
        // scope to THIS tree's pegs (A→B、B→C) — other tests' pegs persist in the shared container
        assertEquals(0, count(
                "select count(*) from production_material_supply_pegs peg "
                        + "where peg.supply_type = 'PRODUCTION_PLAN_ITEM' and peg.status <> 'REVERSED' "
                        + "and exists (select 1 from production_plan_items i "
                        + "            where i.id = peg.supply_item_id and i.plan_id in (?, ?))",
                bPlan, cPlan), "本树 MAKE peg（A→B、B→C）全部 REVERSED（整树回退）");
    }

    /** Produce an internal (no-sales-link) MAKE subplan via old-style report + FINISHED_IN. For MAKE
     *  leaves (no BOM, no segment) or unconfirmed plans. Fires the V194 auto-release hook on approval. */
    private void produceInternal(World w, UUID planItemId, UUID goodsId, String qty) {
        DailyReportSaveRequest req = new DailyReportSaveRequest();
        req.setBillDate(LocalDate.of(2026, 1, 25));
        req.setWarehouseId(w.warehouseId());
        DailyReportItemLine line = new DailyReportItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPlanItemId(planItemId);
        req.setItems(List.of(line));
        DailyReportDetail d = reportService.create(req);
        reportService.approve(d.getId());
        stockDocService.approve(finishedInDocForReport(reportBillNo(d.getId())));
    }

    private UUID subplanOf(UUID parentPlanId) {
        return jdbc.queryForObject(
                "select subplan_id from subplan_links where plan_id = ? and source = 'EXECUTION_V1' "
                        + "and is_deleted = false order by id limit 1",
                UUID.class, parentPlanId);
    }

    private UUID planItemOfPlan(UUID planId) {
        return jdbc.queryForObject(
                "select id from production_plan_items where plan_id = ? and is_deleted = false "
                        + "order by id limit 1",
                UUID.class, planId);
    }

    private boolean hasSegmentStatus(UUID planId, String status) {
        return count(
                "select count(*) from production_execution_segments "
                        + "where plan_id = ? and status = ? and is_deleted = false",
                planId, status) > 0;
    }

    // ---------------------------------------------------------------------------------------------
    // Seed builder — inserts a coherent master/org world with explicit UUIDs (dependency order:
    // dept -> employee -> user; goods -> bom; parties; uom/currency/color). All NOT-NULL-without-
    // default columns supplied; CHECK/unique constraints satisfied. Returns the created IDs.
    // ---------------------------------------------------------------------------------------------
    private World seedWorld(String tag) {
        UUID deptId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID superAdminUserId = UUID.randomUUID();
        UUID goodsA = UUID.randomUUID(), goodsB = UUID.randomUUID(), goodsC = UUID.randomUUID();
        UUID goodsD = UUID.randomUUID(), goodsE = UUID.randomUUID();
        UUID clientId = UUID.randomUUID(), supplierId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID(), unitId = UUID.randomUUID();
        UUID currencyId = UUID.randomUUID(), colorId = UUID.randomUUID();
        int unitLegacy = LEGACY_SEQ.incrementAndGet();

        // Department (level CHECK; path auto-set by trigger — do not supply).
        jdbc.update("insert into departments(id, code, name, level) values (?, ?, ?, '一级部门')",
                deptId, "DEPT-" + tag, "测试部门-" + tag);
        // Employee (id_type/status/employment_type CHECKs).
        jdbc.update("""
                insert into employees(id, code, full_name, id_type, department_id, hire_date,
                                      status, employment_type)
                values (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employeeId, "EMP-" + tag, "测试员工-" + tag, deptId);
        // Super-admin login account (password_hash unused for direct service calls).
        jdbc.update("""
                insert into users(id, employee_id, login_account, password_hash,
                                  must_change_password, is_super_admin, status)
                values (?, ?, ?, 'argon2-stub-not-used-in-direct-calls', false, true, 'active')
                """, superAdminUserId, employeeId, "SU-" + tag);

        // Masters first (units must exist before goods.unit_id FK). status CHECK: '使用'.
        // units.legacy_id must match goods.unit_legacy_id — the MRP/stock layer resolves units
        // through the legacy int lane (MRP_SQL: units u ON u.legacy_id = g.unit_legacy_id).
        jdbc.update("insert into units(id, legacy_id, code, name, status) values (?, ?, ?, ?, '使用')",
                unitId, unitLegacy, "PCS-" + tag, "个");
        jdbc.update("insert into currencies(id, code, name, status) values (?, ?, ?, '使用')",
                currencyId, "CNY-" + tag, "人民币");
        jdbc.update("insert into colors(id, code, name, status) values (?, ?, ?, '使用')",
                colorId, "CLR-" + tag, "默认色");
        jdbc.update("insert into warehouses(id, code, name, status) values (?, ?, ?, '使用')",
                warehouseId, "WH-" + tag, "测试仓库-" + tag);
        jdbc.update("insert into clients(id, code, name, status) values (?, ?, ?, '使用')",
                clientId, "CLI-" + tag, "测试客户-" + tag);
        jdbc.update("insert into suppliers(id, code, name, status) values (?, ?, ?, '使用')",
                supplierId, "SUP-" + tag, "测试供应商-" + tag);

        // Goods: A(自制成品) B(自制半成品) C(自制叶子) D(采购原料) E(委外件), each with a basic
        // unit (required by SalesMasterReferenceValidator — a goods with no unit can't be ordered).
        // auto_created stays false so the BOM trigger (trg_goods_bom_operational_goods) accepts them.
        insertGoods(goodsA, "A-" + tag, "成品A-" + tag, "自制", unitId, unitLegacy);
        insertGoods(goodsB, "B-" + tag, "半成品B-" + tag, "自制", unitId, unitLegacy);
        insertGoods(goodsC, "C-" + tag, "叶子件C-" + tag, "自制", unitId, unitLegacy);
        insertGoods(goodsD, "D-" + tag, "原料D-" + tag, "采购", unitId, unitLegacy);
        insertGoods(goodsE, "E-" + tag, "委外件E-" + tag, "委外", unitId, unitLegacy);
        // BOM: A -> {B, E}; B -> {C, D}. (parent, component) unique; qty > 0; no self-ref.
        insertBom(goodsA, goodsB, "2");
        insertBom(goodsA, goodsE, "1");
        insertBom(goodsB, goodsC, "3");
        insertBom(goodsB, goodsD, "5");

        return new World(deptId, employeeId, superAdminUserId,
                goodsA, goodsB, goodsC, goodsD, goodsE,
                clientId, supplierId, warehouseId, unitId, currencyId, colorId, unitLegacy);
    }

    private void insertGoods(UUID id, String code, String name, String sourceType,
                             UUID unitId, int unitLegacy) {
        jdbc.update("insert into goods(id, code, name, source_type, status, unit_id, unit_legacy_id) "
                        + "values (?, ?, ?, ?, '使用', ?, ?)",
                id, code, name, sourceType, unitId, unitLegacy);
    }

    private void insertBom(UUID parent, UUID component, String qty) {
        jdbc.update("insert into goods_bom_items(goods_id, component_goods_id, qty) values (?, ?, ?)",
                parent, component, new java.math.BigDecimal(qty));
    }

    /** Holds the IDs of a seeded world so later chain steps can reference them. */
    private record World(
            UUID departmentId,
            UUID employeeId,
            UUID superAdminUserId,
            UUID goodsA, UUID goodsB, UUID goodsC, UUID goodsD, UUID goodsE,
            UUID clientId, UUID supplierId, UUID warehouseId,
            UUID unitId, UUID currencyId, UUID colorId,
            int unitLegacy) {}
}
