package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemLine;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.production.mrp.MrpRow;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.mrp.ExecutionSegmentPreview;
import com.uten.imp.features.production.mrp.ExecutionSegmentResult;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.PlanningPackageResult;
import com.uten.imp.features.production.mrp.PlanningPreviewResult;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.execution.ExecutionSegmentView;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentAssignmentRequest;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDetail;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.features.attachment.AttachmentService;
import com.uten.imp.features.attachment.AttachmentUploadGrantService;
import com.uten.imp.features.attachment.dto.AttachmentConfirmRequest;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.features.attachment.dto.AttachmentPresignRequest;
import com.uten.imp.features.attachment.dto.AttachmentPresignResponse;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Map;
import java.util.Base64;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;
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
                "uten.storage.uploads-enabled=true",
                "uten.storage.malware-scan.provider=test-only",
                "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
                "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
                "uten.bootstrap.admin-password=HarnessAdminPass-1!"
        })
class FullChainEndToEndTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    /** 附件本地存储测试目录（隔离，避免污染工程目录）。 */
    private static java.nio.file.Path ATTACH_TEST_DIR;

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        try {
            ATTACH_TEST_DIR = java.nio.file.Files.createTempDirectory("uten-attach-test-");
        } catch (java.io.IOException e) {
            throw new IllegalStateException("无法创建附件测试临时目录", e);
        }
        registry.add("uten.storage.local-dir", () -> ATTACH_TEST_DIR.toString());
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    /** Monotonic legacy ids remain useful for migration-shaped fixtures, while all current
     *  MRP/stock writes use the seeded unit UUID directly. Unique per world to respect the
     *  historical units.legacy_id constraint. */
    private static final java.util.concurrent.atomic.AtomicInteger LEGACY_SEQ =
            new java.util.concurrent.atomic.AtomicInteger(9000);

    @Autowired private JdbcTemplate jdbc;
    @Autowired private PermissionResolver permissionResolver;
    @Autowired private SalesOrderService salesOrderService;
    @Autowired private com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService financeConfirmService;
    @Autowired private ProductionScheduleService scheduleService;
    @Autowired private ProductionPlanService planService;
    @Autowired private MrpService mrpService;
    @Autowired private ProductionPlanningPackageService planningPackageService;
    @Autowired private ProductionExecutionSegmentService executionSegmentService;
    @Autowired private com.uten.imp.features.purchase.order.PurchaseOrderService purchaseOrderService;
    @Autowired private com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrderService;
    @Autowired private com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService subcontractMaterialIssueService;
    @Autowired private com.uten.imp.features.subcontract.receipt.SubcontractReceiptService subcontractReceiptService;
    @Autowired private com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService financeApproval;
    @Autowired private com.uten.imp.features.purchase.receipt.PurchaseReceiptService purchaseReceiptService;
    @Autowired private com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspectionService;
    @Autowired private ProductionDailyReportService reportService;
    @Autowired private ProductionFqcInspectionService fqcService;
    @Autowired private StockDocService stockDocService;
    @Autowired private SalesShipmentService shipmentService;
    @Autowired private GlPostingService glPostingService;
    @Autowired private com.uten.imp.features.admin.UserAccountAdminService userAccountAdmin;
    @Autowired private com.uten.imp.features.admin.PermissionOverrideAdminService permissionOverrideAdmin;
    @Autowired private com.uten.imp.features.production.mrp.BottomUpPlanOrchestrator orchestrator;
    @Autowired private com.uten.imp.features.production.analysis.MaterialAnalysisService analysisService;
    @Autowired private com.uten.imp.features.production.analysis.MaterialAnalysisCommandService analysisCommandService;
    @Autowired private com.uten.imp.features.production.analysis.MaterialStockReallocationService
            materialStockReallocationService;
    @Autowired private com.uten.imp.features.finance.receipt.FinanceReceiptService receiptService;
    @Autowired private com.uten.imp.features.attachment.AttachmentService attachmentService;
    @Autowired private AttachmentUploadGrantService attachmentUploadGrants;
    @Autowired private com.uten.imp.features.attachment.AttachmentObjectOutboxProcessor attachmentOutbox;
    @Autowired private com.uten.imp.features.notice.outbox.BusinessOutboxProcessor businessOutboxProcessor;
    @Autowired private com.uten.imp.features.master.client.ClientService clientService;
    @Autowired private com.uten.imp.features.master.client.ClientAccessService clientAccessService;
    @Autowired private com.uten.imp.features.admin.DataScopeAdminService dataScopeAdminService;
    @Autowired private com.uten.imp.features.sales.SalesDocumentAccessPolicy salesAccessPolicy;
    @Autowired private com.uten.imp.common.docnumber.DocNumberService docNumberService;

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

    @Test
    void customerVisibility_scopeCountsStubsCapabilitiesAndOwnerChangeStayConsistent() {
        World w = seedWorld("client-scope");
        assertEquals(0L, count("""
                select count(*) from department_permissions assignment
                join permissions permission on permission.id=assignment.permission_id
                where permission.code='client:assign'
                """), "client:assign must not be a department default");
        assertEquals(0L, count("""
                select count(*) from role_permissions assignment
                join permissions permission on permission.id=assignment.permission_id
                where permission.code='client:assign'
                """), "client:assign must not be a role default");
        UUID userA = createUserWithPerms(
                w, "client-a", "client:view", "client:edit");
        UUID userB = createUserWithPerms(
                w, "client-b", "client:view", "client:edit");
        UUID manager = createUserWithPerms(
                w, "client-manager", "client:view", "client:edit",
                "client:view:all", "client:assign");
        UUID assignOnly = createUserWithPerms(
                w, "assign-only", "client:assign");
        UUID employeeA = jdbc.queryForObject(
                "select employee_id from users where id=?", UUID.class, userA);
        UUID employeeB = jdbc.queryForObject(
                "select employee_id from users where id=?", UUID.class, userB);
        UUID categoryId = UUID.randomUUID();
        jdbc.update("insert into client_categories(id,code,name,level) values (?,?,?,0)",
                categoryId, "CAT-client-scope", "客户权限真库分类");

        UUID ownA = insertScopedClient(categoryId, employeeA, "A-REAL", false);
        UUID ownB = insertScopedClient(categoryId, employeeB, "B-REAL", false);
        UUID sharedB = insertScopedClient(categoryId, employeeB, "B-SHARED", false);
        UUID pending = insertScopedClient(categoryId, null, "PENDING", false);
        UUID stubA = insertScopedClient(
                categoryId, employeeA, "LEGACY-FIN-CL-A", false);
        insertScopedClient(categoryId, employeeA, "A-DELETED", true);
        jdbc.update("""
                insert into client_visibility_grants(
                    client_id,grantee_employee_id,active,row_version,granted_by_user_id)
                values (?,?,true,1,?)
                """, sharedB, employeeA, w.superAdminUserId());

        loginAs(assignOnly);
        var candidatePage = clientAccessService.candidates("员工-client-a", 1, 10);
        assertEquals(1L, candidatePage.getTotal());
        assertEquals(employeeA, candidatePage.getItems().getFirst().employeeId());
        assertTrue(candidatePage.getItems().getFirst().activeAccount());

        loginAs(userA);
        var ownAndShared = clientService.list(
                clientFilter(categoryId, true), 1, 20, null, null);
        assertEquals(2L, ownAndShared.getTotal());
        assertEquals(2, ownAndShared.getItems().size());
        assertEquals(
                java.util.Set.of(ownA, sharedB),
                ownAndShared.getItems().stream()
                        .map(com.uten.imp.features.master.client.dto.ClientListItem::getId)
                        .collect(java.util.stream.Collectors.toSet()));
        assertTrue(ownAndShared.getItems().stream()
                .filter(item -> item.getId().equals(ownA)).findFirst().orElseThrow()
                .isWritable());
        assertFalse(ownAndShared.getItems().stream()
                .filter(item -> item.getId().equals(sharedB)).findFirst().orElseThrow()
                .isWritable());
        assertTrue(ownAndShared.getItems().stream()
                .noneMatch(com.uten.imp.features.master.client.dto.ClientListItem::isAccessManageable));
        assertEquals(2, clientService.dict(true).size());
        assertEquals(2L, clientService.facets(categoryId, true)
                .getNullCounts().get("phone"));
        ApiException hidden = assertThrows(ApiException.class, () -> clientService.detail(ownB));
        assertEquals(ErrorCode.NOT_FOUND, hidden.getCode());

        // Explicit compatibility mode includes the finance placeholder in every
        // collection/count surface; normal UI defaults stay at the two real rows.
        assertEquals(3L, clientService.list(
                clientFilter(categoryId, false), 1, 20, null, null).getTotal());
        assertEquals(3, clientService.dict(false).size());
        assertEquals(3L, clientService.facets(categoryId, false)
                .getNullCounts().get("phone"));
        assertFalse(clientService.dict(true).stream()
                .anyMatch(item -> item.id().equals(stubA)));

        grantDataScope(userA, "client", employeeB);
        loginAs(userA);
        var manualScope = clientService.list(
                clientFilter(categoryId, true), 1, 20, null, null);
        assertEquals(3L, manualScope.getTotal());
        assertEquals(3, manualScope.getItems().size());
        assertTrue(manualScope.getItems().stream()
                .filter(item -> item.getId().equals(ownB)).findFirst().orElseThrow()
                .isWritable() == false);
        jdbc.update("delete from user_data_scopes where user_id=? and scope='client'", userA);

        loginAs(manager);
        var companyWide = clientService.list(
                clientFilter(categoryId, true), 1, 20, null, null);
        assertEquals(4L, companyWide.getTotal());
        assertTrue(companyWide.getItems().stream()
                .allMatch(com.uten.imp.features.master.client.dto.ClientListItem::isWritable));
        assertTrue(companyWide.getItems().stream()
                .allMatch(com.uten.imp.features.master.client.dto.ClientListItem::isAccessManageable));
        assertTrue(companyWide.getItems().stream().anyMatch(item -> item.getId().equals(pending)));

        loginAs(w.superAdminUserId());
        List<Map<String, Object>> candidates = dataScopeAdminService.ownerCandidates("client");
        assertEquals(1L, candidates.stream()
                .filter(row -> employeeA.equals(row.get("employeeId")))
                .map(row -> ((Number) row.get("count")).longValue())
                .findFirst().orElseThrow());
        assertEquals(2L, candidates.stream()
                .filter(row -> employeeB.equals(row.get("employeeId")))
                .map(row -> ((Number) row.get("count")).longValue())
                .findFirst().orElseThrow());

        loginAs(manager);
        var before = clientAccessService.get(ownA);
        var transferred = clientAccessService.update(
                ownA,
                new com.uten.imp.features.master.client.dto.ClientAccessUpdateRequest(
                        employeeB, List.of(), before.accessVersion(), "客户负责人调整"));
        assertEquals(employeeB, transferred.ownerEmployeeId());
        assertTrue(transferred.viewers().stream()
                .anyMatch(viewer -> viewer.employeeId().equals(employeeA)),
                "current previous owner must stay a read-only viewer for existing drafts");

        loginAs(userA);
        var retained = clientService.detail(ownA);
        assertFalse(retained.isWritable());

        loginAs(manager);
        var removedPrevious = clientAccessService.update(
                ownA,
                new com.uten.imp.features.master.client.dto.ClientAccessUpdateRequest(
                        employeeB, List.of(), transferred.accessVersion(),
                        "确认已无在途单据，移除前负责人查看"));
        assertTrue(removedPrevious.viewers().stream()
                .noneMatch(viewer -> viewer.employeeId().equals(employeeA)));
        loginAs(userA);
        ApiException removed = assertThrows(ApiException.class, () -> clientService.detail(ownA));
        assertEquals(ErrorCode.NOT_FOUND, removed.getCode());
    }

    @Test
    void resignedRawOwnerRemainsSelectableForExactHistoricalReadOnlyScope() {
        World w = seedWorld("historical-scope");
        UUID historicalUser = createUserWithPerms(w, "historical-owner", "sales_order:view");
        UUID unrelatedUser = createUserWithPerms(w, "unrelated-owner", "sales_order:view");
        UUID viewerUser = createUserWithPerms(w, "historical-viewer", "sales_order:view");
        UUID historicalEmployee = jdbc.queryForObject(
                "select employee_id from users where id=?", UUID.class, historicalUser);
        UUID unrelatedEmployee = jdbc.queryForObject(
                "select employee_id from users where id=?", UUID.class, unrelatedUser);
        jdbc.update("""
                insert into sales_quotes(id,bill_no,bill_date,maker_id,status)
                values (?,?,current_date,?,0)
                """, UUID.randomUUID(),
                docNumberService.nextNumber(
                        com.uten.imp.common.docnumber.DocNumberPrefix.SALES_QUOTE), historicalEmployee);
        jdbc.update("""
                insert into sales_quotes(id,bill_no,bill_date,maker_id,status)
                values (?,?,current_date,?,0)
                """, UUID.randomUUID(),
                docNumberService.nextNumber(
                        com.uten.imp.common.docnumber.DocNumberPrefix.SALES_QUOTE), unrelatedEmployee);
        jdbc.update("update employees set status='resigned' where id=?", historicalEmployee);
        jdbc.update("update users set status='disabled' where id=?", historicalUser);

        loginAs(w.superAdminUserId());
        List<Map<String, Object>> candidates = dataScopeAdminService.ownerCandidates("sales");
        Map<String, Object> historical = candidates.stream()
                .filter(row -> historicalEmployee.equals(row.get("employeeId")))
                .findFirst().orElseThrow();
        assertEquals("resigned", historical.get("status"));
        assertEquals(Boolean.TRUE, historical.get("historicalOnly"));
        assertEquals(1L, ((Number) historical.get("count")).longValue());
        dataScopeAdminService.setDataScopes(
                viewerUser, "sales", List.of(historicalEmployee), List.of());

        loginAs(viewerUser);
        assertTrue(salesAccessPolicy.canRead(historicalEmployee));
        assertFalse(salesAccessPolicy.canWrite(historicalEmployee));
        assertFalse(salesAccessPolicy.canRead(unrelatedEmployee),
                "raw historical grant A must not widen to unrelated owner B");
    }

    // ---------------------------------------------------------------------------------------------
    // Regression: 待排产 /pending 改 Excel 表格后加了 sort/order/status + /pending/facets。
    // Hibernate 6 原生查询 setParameter 会校验参数是否存在——status=null 时 SQL 不含 :warn，
    // 误绑会抛 UnknownParameterException（曾导致一打开生产页就 500）。用真实 SQL 守住。
    // ---------------------------------------------------------------------------------------------
    @Test
    void schedulePending_sortAndStatusFiltersBindParamsWithoutError() {
        World w = seedWorld("sched");
        loginAs(w.superAdminUserId());
        createApprovedOrder(w, w.goodsA(), "10", "100"); // 产生一条 chain_status=2 待排产行

        // 默认调用（status=null, sort=deliverDate）——正是线上崩溃的那次
        assertDoesNotThrow(() -> scheduleService.pending(
                1, 20, null, null, null, "deliverDate", "asc", null));
        // 两种状态筛选：urgent/normal 进 :warn
        for (String status : List.of("urgent", "normal")) {
            assertDoesNotThrow(() -> scheduleService.pending(
                    1, 20, null, null, null, "deliverDate", "asc", status));
        }
        // 各可排序列 + 降序
        for (String sort : List.of("deliverDate", "qty", "needQty", "orderBillNo")) {
            assertDoesNotThrow(() -> scheduleService.pending(
                    1, 20, null, null, null, sort, "desc", null));
        }
        // facets 聚合（恒含 :warn）
        assertDoesNotThrow(() -> scheduleService.pendingFacets(null, null, null));
        // 组合：keyword + 交货日期范围 + 状态 + 排序同时存在（验多条件 SQL 拼装 + 全参数绑定）
        assertDoesNotThrow(() -> scheduleService.pending(
                1, 20, "A",
                LocalDate.of(2020, 1, 1), LocalDate.of(2099, 12, 31),
                "qty", "desc", "urgent"));
        assertDoesNotThrow(() -> scheduleService.pendingFacets(
                "A", LocalDate.of(2020, 1, 1), LocalDate.of(2099, 12, 31)));

        // 基本正确性：刚创建的待排产行确实出现在默认列表里
        var page = scheduleService.pending(1, 20, null, null, null, "deliverDate", "asc", null);
        assertNotNull(page);
        assertFalse(page.getItems().isEmpty(),
                "approved out-of-stock order line should appear in pending list");
        // facets 返回 status 两桶（紧急/正常）
        var facets = scheduleService.pendingFacets(null, null, null);
        assertNotNull(facets.get("status"));
        assertEquals(2, facets.get("status").size(), "status facets should have 2 buckets");
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
        // Super-admin must hold EVERY active permission code
        // (PermissionResolver.allPermissionCodes；V328 保留的 inactive 历史码不参与授权)。
        Integer permissionCount = jdbc.queryForObject(
                "select count(*) from permissions where active", Integer.class);
        assertEquals(permissionCount, principal.getPermissions().size(),
                "super-admin effective permission set must equal the active permissions table");
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
    // #19b V294 finance-confirmation gate: an approved order stays INVISIBLE to planning
    // (pending list + material-analysis candidates) until an eligible finance confirmer
    // confirms; an account granted the permission through a NON-finance department matrix
    // passes @PreAuthorize but must still fail the eligibility layer (department-tree check).
    // ---------------------------------------------------------------------------------------------
    @Test
    void financeConfirmGate_planningInvisibleUntilConfirmedAndEligibilityEnforced() {
        World w = seedWorld("s19b");
        loginAs(w.superAdminUserId());
        OrderDetail d = salesOrderService.create(orderRequest(w, w.goodsA(), "10", "100"));
        UUID orderId = d.getId();
        salesOrderService.approve(orderId);

        // 未财务确认：订单侧回写照旧（chain_status=2），但计划侧两处取单口径都必须看不到它。
        // 断言用订单号关键字限定范围——测试库内各 world 的单据共存，不能断言整表为空。
        assertEquals(2, itemChainStatus(orderId));
        String orderNo = billNo(orderId).toLowerCase();
        assertTrue(scheduleService.pending(1, 20, orderNo, null, null, "deliverDate", "asc", null)
                        .getItems().isEmpty(),
                "unconfirmed order must not appear in the planning pending list");
        assertTrue(analysisService.salesCandidates(orderNo, 1, 20).items().isEmpty(),
                "unconfirmed order must not appear in material-analysis candidates");

        // 非财务部门的账号经部门矩阵拿到 confirm 权限：权限层通过，资格层（财务部门树）仍拒绝。
        UUID outsider = createUserWithPerms(w, "fin-outsider-s19b",
                "sales_order_finance:view");
        jdbc.update("""
                insert into department_permissions(department_id, permission_id)
                select ?, p.id from permissions p
                where p.code = 'sales_order_finance:confirm'
                """, w.departmentId());
        loginAs(outsider);
        ApiException denied = assertThrows(ApiException.class,
                () -> financeConfirmService.confirm(orderId, null));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode(),
                "non-finance-department account must fail the confirmer eligibility layer");

        // 合格确认人（个人加授）确认后，计划部立即可见。
        loginAs(w.superAdminUserId());
        financeConfirmService.confirm(orderId, null);
        assertFalse(scheduleService.pending(1, 20, orderNo, null, null, "deliverDate", "asc", null)
                        .getItems().isEmpty(),
                "confirmed order appears in the planning pending list");
        assertFalse(analysisService.salesCandidates(orderNo, 1, 20).items().isEmpty(),
                "confirmed order appears in material-analysis candidates");
    }

    // ---------------------------------------------------------------------------------------------
    // #20 Planner picks the schedulable order line, creates a production plan that references it,
    // and approves. The plan must peg the batch to the sales order (plan_order_item_links) and
    // write back planned_qty, advancing chain_status out of 待排产(2) into 待物料(3)/已排产(4).
    // ---------------------------------------------------------------------------------------------
    @Test
    void planner_createDraftAndApprove_writesPlannedQtyAndPegsOrder() {
        World w = seedWorld("s20");
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100"); // A has a BOM; out-of-stock
        UUID orderItemId = orderItemId(orderId);

        UUID planId = createLegacyTestDraft(orderItemId, w.goodsA(), "10");
        assertEquals(0, planStatus(planId), "new plan is DRAFT (status=0)");
        assertEquals(0, planLinkCount(orderItemId),
                "legacy test fixture does not pre-build sales links");

        planService.approve(planId);
        assertEquals(1, planStatus(planId), "approved plan is status=1");
        assertTrue(planLinkCount(orderItemId) >= 1,
                "approval pegs the plan batch to the sales order");
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
        // V294：审核后须经财务确认，计划部（待排产/物料分析/MRP/计划关联）才可见。
        financeConfirmService.confirm(d.getId(), null);
        return d.getId();
    }

    private UUID orderItemId(UUID orderId) {
        return jdbc.queryForObject(
                "select id from sales_order_items where order_id = ?", UUID.class, orderId);
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
        UUID planId = createLegacyTestDraft(orderItemId, goodsId, planQty);
        planService.approve(planId);
        return planId;
    }

    /**
     * Test-only fixture for downstream legacy scenarios. Production HTTP writes are intentionally
     * closed; new functional tests must use the material-analysis generate flow.
     */
    private UUID createLegacyTestDraft(UUID orderItemId, UUID goodsId, String qty) {
        Map<String, Object> source = jdbc.queryForMap("""
                SELECT i.color_id,i.unit_id,COALESCE(i.unit_rate,1) AS unit_rate,
                       o.bill_no,COALESCE(i.qty,0) AS order_qty
                FROM sales_order_items i
                JOIN sales_orders o ON o.id=i.order_id
                WHERE i.id=?
                """, orderItemId);
        PlanItemLine line = new PlanItemLine();
        line.setProductNo("TEST-" + UUID.randomUUID());
        line.setGoodsId(goodsId);
        line.setColorId((UUID) source.get("color_id"));
        line.setUnitId((UUID) source.get("unit_id"));
        line.setUnitRate((BigDecimal) source.get("unit_rate"));
        line.setSalesOrderItemId(orderItemId);
        line.setSalesOrderNo((String) source.get("bill_no"));
        line.setOqty((BigDecimal) source.get("order_qty"));
        line.setQty(new BigDecimal(qty));

        PlanSaveRequest request = new PlanSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 8));
        request.setItems(List.of(line));
        return planService.create(request).getId();
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
                "D 采购是 B 的下层件；当前一层架构下 A 这层不开采购申请(待 #13 全树展开)");
        // direct-layer execution-segment material demands are established (B + E)
        assertTrue(count(
                "select count(*) from production_material_demands dmd "
                        + "where exists (select 1 from production_planning_packages pkg "
                        + "where pkg.plan_id = ? and pkg.id = dmd.package_id)",
                planId) >= 2,
                "直层物料需求建立 (B + E)");
    }

    @Test
    void planningPackage_nonLinearBomFreezesExactDemandReservationAndDraw() {
        World w = seedWorld("sExactPack");
        jdbc.update("""
                update goods_bom_items
                set qty = 1,
                    consumption_basis = 'PER_PACKAGE',
                    basis_output_qty = 4000,
                    allow_partial_package = false,
                    control_stage = 'START',
                    hard_gate = true
                where goods_id = ? and component_goods_id = ?
                """, w.goodsA(), w.goodsB());
        jdbc.update("""
                update goods_bom_items
                set hard_gate = false
                where goods_id = ? and component_goods_id = ?
                """, w.goodsA(), w.goodsE());
        jdbc.update("""
                insert into stock_balances(
                    warehouse_id, goods_id, color_id, qty)
                values (?, ?, null, 3)
                """, w.warehouseId(), w.goodsB());
        UUID planId = approvedPlan(w, w.goodsA(), "9999", "9999");

        PlanningPreviewResult preview = planningPackageService.preview(
                planId, w.warehouseId());

        assertEquals(1, preview.executionSegments().size());
        assertEquals(
                0,
                new BigDecimal("9999").compareTo(
                        preview.executionSegments().getFirst().plannedQty()));
        assertEquals(1, preview.executionSegments().getFirst()
                .materials().size());
        assertEquals(
                0,
                new BigDecimal("3").compareTo(
                        preview.executionSegments().getFirst()
                                .materials().getFirst().requiredQty()));
        assertEquals(
                "EXACT_SNAPSHOT",
                preview.executionSegments().getFirst()
                        .materials().getFirst().requirementMode());

        GeneratePlanningPackageRequest request =
                new GeneratePlanningPackageRequest();
        request.setWarehouseId(w.warehouseId());
        request.setIdempotencyKey("idem-exact-pack-" + planId);
        request.setPreviewFingerprint(preview.fingerprint());
        request.setGeneratePurchaseRequest(false);
        PlanningPackageResult first = planningPackageService.confirm(
                planId, request);
        assertEquals(
                "EXACT_SNAPSHOT",
                first.executionSegments().getFirst()
                        .materials().getFirst().requirementMode());
        assertEquals(
                0,
                new BigDecimal("0.000301").compareTo(
                        first.executionSegments().getFirst()
                                .materials().getFirst().perProductQty()));

        Map<String, Object> demand = jdbc.queryForMap("""
                select d.id, d.requirement_mode, d.per_product_qty,
                       d.required_for_product_qty,
                       d.required_qty,
                       d.requirement_fingerprint
                from production_material_demands d
                join production_planning_packages p on p.id = d.package_id
                where p.plan_id = ?
                  and p.status = 'CONFIRMED'
                  and d.goods_id = ?
                  and d.is_deleted = false
                """, planId, w.goodsB());
        UUID demandId = (UUID) demand.get("id");
        assertEquals("EXACT_SNAPSHOT", demand.get("requirement_mode"));
        assertEquals(
                0,
                new BigDecimal("0.000301").compareTo(
                        (BigDecimal) demand.get("per_product_qty")),
                "exact display rate is this segment's rounded average; required_qty stays authoritative");
        assertEquals(
                0,
                new BigDecimal("9999").compareTo(
                        (BigDecimal) demand.get("required_for_product_qty")));
        assertEquals(
                0,
                new BigDecimal("3").compareTo(
                        (BigDecimal) demand.get("required_qty")));
        assertEquals(
                64,
                demand.get("requirement_fingerprint")
                        .toString().strip().length());
        assertEquals(
                0,
                new BigDecimal("3").compareTo(jdbc.queryForObject("""
                        select sum(qty - released_qty)
                        from stock_reservations
                        where demand_id = ? and is_deleted = false
                        """, BigDecimal.class, demandId)));

        PlanningPackageResult replay = planningPackageService.confirm(
                planId, request);
        assertTrue(replay.replayed());
        assertEquals(first.packageId(), replay.packageId());
        assertEquals(1, count("""
                select count(*)
                from production_material_demands
                where id = ? and is_deleted = false
                """, demandId));
        assertEquals(1, count("""
                select count(*)
                from stock_reservations
                where demand_id = ? and is_deleted = false
                """, demandId));
        assertEquals(1, count("""
                select count(*)
                from production_planning_package_document_items
                where demand_id = ? and document_type = 'DRAW'
                """, demandId));
        assertEquals(
                0,
                new BigDecimal("3").compareTo(jdbc.queryForObject("""
                        select sum(i.base_qty)
                        from production_planning_package_document_items m
                        join stock_document_items i
                          on i.id = m.document_item_id
                        where m.demand_id = ? and m.document_type = 'DRAW'
                        """, BigDecimal.class, demandId)));
    }

    @Test
    void planningPackage_manualExactSegmentsChargeEveryIndependentTailPackage() {
        World w = seedWorld("sExactTails");
        jdbc.update("""
                update goods_bom_items
                set qty = 2,
                    consumption_basis = 'PER_PACKAGE',
                    basis_output_qty = 6,
                    allow_partial_package = false,
                    control_stage = 'START',
                    hard_gate = true
                where goods_id = ? and component_goods_id = ?
                """, w.goodsA(), w.goodsB());
        jdbc.update("""
                update goods_bom_items
                set hard_gate = false
                where goods_id = ? and component_goods_id = ?
                """, w.goodsA(), w.goodsE());
        jdbc.update("""
                insert into stock_balances(
                    warehouse_id, goods_id, color_id, qty)
                values (?, ?, null, 6)
                """, w.warehouseId(), w.goodsB());
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        PlanningPreviewResult preview = planningPackageService.preview(
                planId, w.warehouseId());
        ExecutionSegmentPreview source = preview.executionSegments().getFirst();

        GeneratePlanningPackageRequest request =
                new GeneratePlanningPackageRequest();
        request.setWarehouseId(w.warehouseId());
        request.setIdempotencyKey("idem-exact-tails-" + planId);
        request.setPreviewFingerprint(preview.fingerprint());
        request.setGeneratePurchaseRequest(false);
        List<GeneratePlanningPackageRequest.ExecutionSegment> segments =
                new java.util.ArrayList<>();
        int index = 0;
        for (String qty : List.of("3", "3", "4")) {
            index++;
            GeneratePlanningPackageRequest.ExecutionSegment segment =
                    new GeneratePlanningPackageRequest.ExecutionSegment();
            segment.setClientSegmentKey("exact-tail-" + index);
            segment.setSourcePlanItemId(source.sourcePlanItemId());
            segment.setRequestedStatus("READY");
            segment.setPlannedQty(new BigDecimal(qty));
            segment.setWorkshopDepartmentId(source.workshopDepartmentId());
            segment.setTeamDepartmentId(source.teamDepartmentId());
            segment.setResponsibleEmployeeId(source.responsibleEmployeeId());
            segment.setPlanBeginDate(source.planBeginDate());
            segment.setPlanEndDate(source.planEndDate());
            segment.setBomFingerprint(source.bomFingerprint());
            segments.add(segment);
        }
        request.setSegments(List.copyOf(segments));

        planningPackageService.confirm(planId, request);

        Map<String, Object> totals = jdbc.queryForMap("""
                select count(*) as demand_count,
                       sum(d.required_qty) as required_qty,
                       sum(r.qty - r.released_qty) as reserved_qty,
                       sum(i.base_qty) as draw_qty
                from production_material_demands d
                join stock_reservations r
                  on r.demand_id = d.id and r.is_deleted = false
                join production_planning_package_document_items mapping
                  on mapping.demand_id = d.id
                 and mapping.document_type = 'DRAW'
                join stock_document_items i on i.id = mapping.document_item_id
                join production_planning_packages package
                  on package.id = d.package_id
                where package.plan_id = ?
                  and d.goods_id = ?
                  and d.is_deleted = false
                """, planId, w.goodsB());
        assertEquals(3L, ((Number) totals.get("demand_count")).longValue());
        assertEquals(
                0,
                new BigDecimal("6").compareTo(
                        (BigDecimal) totals.get("required_qty")));
        assertEquals(
                0,
                new BigDecimal("6").compareTo(
                        (BigDecimal) totals.get("reserved_qty")));
        assertEquals(
                0,
                new BigDecimal("6").compareTo(
                        (BigDecimal) totals.get("draw_qty")));
    }

    @Test
    void planningPackage_zeroMaterialSegmentIsReadyAuditedAndDrawFree() {
        World w = seedWorld("sZeroMaterial");
        jdbc.update("""
                update goods_bom_items
                set control_stage = 'SHIP', hard_gate = false
                where goods_id = ?
                """, w.goodsA());
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        PlanningPreviewResult preview = planningPackageService.preview(
                planId, w.warehouseId());
        assertEquals(1, preview.executionSegments().size());
        assertTrue(preview.executionSegments().getFirst().materials().isEmpty());

        GeneratePlanningPackageRequest request =
                new GeneratePlanningPackageRequest();
        request.setWarehouseId(w.warehouseId());
        request.setIdempotencyKey("idem-zero-material-" + planId);
        request.setPreviewFingerprint(preview.fingerprint());
        request.setGeneratePurchaseRequest(false);
        PlanningPackageResult result = planningPackageService.confirm(
                planId, request);
        ExecutionSegmentResult zeroSegment =
                result.executionSegments().getFirst();
        UUID segmentId = zeroSegment.segmentId();
        assertEquals("ZERO_MATERIAL", zeroSegment.materialRequirementMode());
        assertEquals(
                "NO_PRODUCTION_HARD_GATE",
                zeroSegment.zeroMaterialReason());

        assertEquals(
                "READY|ZERO_MATERIAL|NO_PRODUCTION_HARD_GATE",
                jdbc.queryForObject("""
                        select concat_ws(
                            '|', status, material_requirement_mode,
                            zero_material_reason)
                        from production_execution_segments
                        where id = ?
                        """, String.class, segmentId));
        assertEquals(0, count("""
                select count(*)
                from production_material_demands
                where execution_segment_id = ? and is_deleted = false
                """, segmentId));
        assertEquals(0, count("""
                select count(*)
                from stock_reservations reservation
                join production_material_demands demand
                  on demand.id = reservation.demand_id
                where demand.execution_segment_id = ?
                  and reservation.is_deleted = false
                """, segmentId));
        assertEquals(0, count("""
                select count(*)
                from production_planning_package_documents
                where execution_segment_id = ? and document_type = 'DRAW'
                """, segmentId));

        String frozenFingerprint = jdbc.queryForObject("""
                select bom_fingerprint
                from production_execution_segments
                where id = ?
                """, String.class, segmentId);
        jdbc.update("""
                update goods_bom_items
                set control_stage = 'START', hard_gate = true
                where goods_id = ?
                """, w.goodsA());
        assertEquals(
                frozenFingerprint,
                jdbc.queryForObject("""
                        select bom_fingerprint
                        from production_execution_segments
                        where id = ?
                        """, String.class, segmentId));
    }

    // ---------------------------------------------------------------------------------------------
    // V234 material-analysis path (analysis-first, the NEW pre-plan flow). Drives the real
    // Controller→Service→DB chain: preview builds the full BOM tree with shortages, routes are
    // confirmed, MAKE delegation is blocked until the node's lower-level materials are kitted,
    // and the root plan remains blocked until its direct components are kitted. The plan-first
    // confirm path is s21w above.
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_previewBuildsTreeNotifySpawnsMakeChildAndBlocksUntilKitted() {
        World w = seedWorld("sMA1");
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma1",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify",
                "production_material_analysis:generate", "production_plan:approve");
        loginAs(planner);

        // (1) preview a NEW analysis from the approved sales line. For a SALES_ORDER_ITEM source
        //     the server resolves goods/color/unit from the order line, so only the item id + qty
        //     (+ optional delivery date) may be submitted.
        PreviewItem src = new PreviewItem("SALES_ORDER_ITEM", orderItemId,
                null, null, null, null, null, LocalDate.of(2026, 9, 1), new BigDecimal("10"));
        AnalysisView view = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-ma1-" + orderItemId, List.of(src)));
        UUID analysisId = view.analysisId();
        UUID productLineId = view.products().getFirst().analysisLineId();

        // (2) flat tree: B (自制→MAKE) and E (委外→SUBCONTRACT) are A's direct nodes;
        //     B's activated C/D descendants are independent lower-level material tasks.
        MaterialView b = view.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(w.goodsB()) && m.actionable()).findFirst().orElse(null);
        MaterialView e = view.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(w.goodsE()) && m.actionable()).findFirst().orElse(null);
        assertNotNull(b, "自制半成品 B 是 A 的直接层组件，应在分析树中可操作");
        assertNotNull(e, "委外件 E 是 A 的直接层组件，应在分析树中可操作");
        assertEquals("MAKE", b.sourceSuggestion(), "B 自制 → 建议路线 MAKE");
        assertEquals("SUBCONTRACT", e.sourceSuggestion(), "E 委外 → 建议路线 SUBCONTRACT");
        assertTrue(b.shortageQty().signum() > 0, "无库存 → B 缺料");

        // (3) confirm routes (B=MAKE, E=SUBCONTRACT) — matching the suggestion, no override reason
        analysisService.saveRoutes(analysisId, new RouteRequest(view.version(), view.fingerprint(),
                "routes-ma1-" + analysisId, List.of(
                        new RouteDecision(b.materialLineId(), b.actionGroupKey(), "MAKE", null),
                        new RouteDecision(e.materialLineId(), e.actionGroupKey(), "SUBCONTRACT", null))));
        AnalysisView routed = analysisService.detail(analysisId);
        assertTrue(routed.flatMaterials().stream().anyMatch(m ->
                m.goodsId().equals(w.goodsB()) && m.routeConfirmed()), "B 路线已确认");

        // (4) ADR-033: B cannot be delegated while its direct C/D materials are unready.
        ApiException makeBlocked = assertThrows(ApiException.class, () ->
                analysisCommandService.notifySupply(analysisId, new NotifyRequest(routed.version(),
                        routed.fingerprint(), "notify-make-blocked-" + analysisId, "MAKE",
                        List.of(b.materialLineId()), List.of(), null)));
        assertTrue(makeBlocked.getMessage().contains("下层物料尚未齐套"),
                "MAKE 下层未齐套应拒绝委派(实际：" + makeBlocked.getMessage() + ")");
        assertEquals(0, count("select count(*) from production_material_analysis_items "
                        + "where analysis_id = ? and source_type = 'MAKE_COMPONENT' and is_deleted = false",
                analysisId), "门禁失败不能留下 MAKE_COMPONENT 子需求");

        // B=20; its BOM requires C=60 and D=100. Once both are qualified stock, the same
        // server-authoritative notify path may create B's MAKE_COMPONENT child analysis.
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsC(), new BigDecimal("60"));
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsD(), new BigDecimal("100"));
        analysisCommandService.notifySupply(analysisId, new NotifyRequest(routed.version(),
                routed.fingerprint(), "notify-make-ready-" + analysisId, "MAKE",
                List.of(b.materialLineId()), List.of(), null));
        assertTrue(count("select count(*) from production_material_analysis_items "
                        + "where analysis_id = ? and source_type = 'MAKE_COMPONENT' and is_deleted = false",
                analysisId) >= 1, "MAKE 下层齐套后通知 → 生成 MAKE_COMPONENT 子需求");

        // (5) plan preview reports NOT ready (direct components B & E have no stock); generation refuses.
        //     planPreview refreshes the snapshot (bumping version/fingerprint), so re-read the header
        //     before generate-plan to satisfy requireCurrent.
        AnalysisView afterMake = analysisService.detail(analysisId);
        PlanPreview plan = analysisService.planPreview(analysisId, new PlanPreviewRequest(
                afterMake.version(), afterMake.fingerprint(), w.warehouseId(),
                List.of(new PlanQuantity(productLineId, new BigDecimal("10"))), null));
        assertFalse(plan.allReady(), "无库存 → 不可立即生产");
        AnalysisView refreshed = analysisService.detail(analysisId);
        ApiException blocked = assertThrows(ApiException.class, () -> analysisCommandService.generatePlan(
                analysisId, new GeneratePlanRequest(refreshed.version(), refreshed.fingerprint(),
                        plan.previewFingerprint(), "gen-ma1-" + analysisId, w.warehouseId(),
                        LocalDate.of(2026, 8, 8), null, w.departmentId(), null, null, true,
                        List.of(new PlanQuantity(productLineId, new BigDecimal("10"))), null)));
        assertTrue(blocked.getMessage().contains("齐套"),
                "未齐套生成应被拒(实际：" + blocked.getMessage() + ")");
    }

    // ---------------------------------------------------------------------------------------------
    // V234 material-analysis HAPPY PATH (analysis-first → one-step generate+approve). Seeds stock for
    // A's direct components (B 自制 sitting in stock as a sub-assembly, E 委外 in stock) so the batch is
    // fully kitted, then generate-plan with approveNow=true must ATOMICALLY produce an APPROVED/READY
    // plan + DRAW picking slip + sales planned_qty. This is the core generation chain, never exercised
    // against real data before (Test A above covers the not-ready rejection path).
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_readyBatchGenerateAndApproveAtomicallyProducesReadyPlanAndDraw() {
        World w = seedWorld("sMA2");
        // A's DIRECT components are B (自制, 2/A) and E (委外, 1/A). 10 A needs B=20, E=10. Colorless
        // (the sales line carries no color), so stock is seeded with color_id NULL.
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsB(), new BigDecimal("20"));
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsE(), new BigDecimal("10"));
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma2",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:generate", "production_plan:approve");
        loginAs(planner);

        AnalysisView view = analysisService.preview(new PreviewRequest(null, null, null,
                w.warehouseId(), "idem-ma2-" + orderItemId, List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId, null, null, null, null, null,
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID productLineId = view.products().getFirst().analysisLineId();
        assertEquals(0, new BigDecimal("10").compareTo(view.products().getFirst().readyNowQty()),
                "B=20 + E=10 在库 → 可立即生产 10(实际：" + view.products().getFirst().readyNowQty() + ")");

        AnalysisView refreshed = analysisService.detail(analysisId);
        PlanPreview plan = analysisService.planPreview(analysisId, new PlanPreviewRequest(
                refreshed.version(), refreshed.fingerprint(), w.warehouseId(),
                List.of(new PlanQuantity(productLineId, new BigDecimal("10"))), null));
        assertTrue(plan.allReady(), "齐套 → 计划预览通过");
        AnalysisView preGen = analysisService.detail(analysisId);

        GenerateResult result = analysisCommandService.generatePlan(analysisId, new GeneratePlanRequest(
                preGen.version(), preGen.fingerprint(), plan.previewFingerprint(),
                "gen-ma2-" + analysisId, w.warehouseId(), LocalDate.of(2026, 8, 8), null,
                null, null, null, true,
                List.of(new PlanQuantity(productLineId, new BigDecimal("10"))), null));
        assertFalse(result.plans().isEmpty(), "生成了一张生产计划");
        GeneratedPlan g = result.plans().getFirst();
        assertEquals("APPROVED", g.status(), "approveNow=true → 计划已批准");
        assertEquals(1, planStatus(g.planId()), "production_plans.status=1(已审核)");
        assertTrue(hasSegmentStatus(g.planId(), "READY"), "生成 READY 执行分段");
        assertFalse(g.drawIds().isEmpty(), "approveNow → 同事务生成 DRAW 领料单");
        assertEquals(0, new BigDecimal("10").compareTo(plannedQty(orderId)),
                "销售订单行 planned_qty=10");
        assertEquals("COMPLETED",
                strFor("select status from production_material_analyses where id=?", analysisId),
                "全量分批下达 → 分析头 COMPLETED");
    }

    @Test
    void materialAnalysis_directMakeLeafRunsFromAnalysisThroughFqcAndFinishedInbound() {
        World w = seedWorld("sMADirectMake");
        assertEquals(0, count(
                "select count(*) from goods_bom_items where goods_id = ? and is_deleted = false",
                w.goodsC()), "C 是没有下层物料的自制叶子件");
        UUID orderId = createApprovedOrder(w, w.goodsC(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma-direct",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:generate", "production_plan:approve");
        loginAs(planner);

        AnalysisView view = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(),
                "idem-ma-direct-" + orderItemId,
                List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId, null, null, null,
                        null, null, LocalDate.of(2026, 9, 1),
                        new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID productLineId = view.products().getFirst().analysisLineId();
        assertTrue(view.flatMaterials().isEmpty(), "无子层级 → 没有物料需求行");
        assertFalse(view.products().getFirst().hasProductionMaterialChildren(),
                "服务端明确投影为无生产子层级");
        assertEquals(0, new BigDecimal("10").compareTo(
                view.products().getFirst().readyNowQty()),
                "无子层级 → 剩余需求全额可直接自制");

        AnalysisView refreshed = analysisService.detail(analysisId);
        PlanPreview preview = analysisService.planPreview(
                analysisId,
                new PlanPreviewRequest(
                        refreshed.version(), refreshed.fingerprint(),
                        w.warehouseId(),
                        List.of(new PlanQuantity(
                                productLineId, new BigDecimal("10"))),
                        null));
        assertTrue(preview.allReady(), "直接自制计划预览可下达");
        AnalysisView preGenerate = analysisService.detail(analysisId);
        GenerateResult generated = analysisCommandService.generatePlan(
                analysisId,
                new GeneratePlanRequest(
                        preGenerate.version(), preGenerate.fingerprint(),
                        preview.previewFingerprint(),
                        "gen-ma-direct-" + analysisId,
                        w.warehouseId(), LocalDate.of(2026, 8, 29),
                        null, null, null, null, true,
                        List.of(new PlanQuantity(
                                productLineId, new BigDecimal("10"))),
                        null));

        GeneratedPlan plan = generated.plans().getFirst();
        assertEquals("APPROVED", plan.status());
        assertEquals(1, plan.segmentIds().size());
        assertTrue(plan.drawIds().isEmpty(), "无下层物料不得生成空 DRAW");
        UUID segmentId = plan.segmentIds().getFirst();
        assertEquals(
                "READY|ZERO_MATERIAL|DIRECT_MAKE",
                strFor("""
                        select concat_ws(
                            '|', status, material_requirement_mode,
                            zero_material_reason)
                        from production_execution_segments
                        where id = ?
                        """, segmentId));
        assertEquals(0, count("""
                select count(*) from production_material_demands
                where execution_segment_id = ? and is_deleted = false
                """, segmentId));
        assertEquals(0, count("""
                select count(*)
                from stock_reservations reservation
                join production_material_demands demand
                  on demand.id = reservation.demand_id
                where demand.execution_segment_id = ?
                  and reservation.is_deleted = false
                """, segmentId));
        assertEquals(0, count("""
                select count(*)
                from production_planning_package_documents
                where package_id = ? and document_type = 'DRAW'
                """, plan.packageId()));

        loginAs(w.superAdminUserId());
        UUID planItemId = planItemIdFor(plan.planId(), w.goodsC());
        UUID salesAllocationId = jdbc.queryForObject("""
                select id from execution_segment_sales_allocations
                where execution_segment_id = ? and sales_order_item_id = ?
                """, UUID.class, segmentId, orderItemId);
        ProductionAssignment assignment = productionAssignment("sMADirectMake");
        ExecutionSegmentView current = executionSegmentService.list(plan.planId())
                .stream()
                .filter(segment -> segment.id().equals(segmentId))
                .findFirst()
                .orElseThrow();
        ExecutionSegmentView assigned = executionSegmentService.assign(
                plan.planId(), segmentId,
                new SegmentAssignmentRequest(
                        current.lockVersion(),
                        "idem-ma-direct-assign-" + segmentId,
                        assignment.workshopId(), null, assignment.workerId(),
                        LocalDate.of(2026, 8, 29),
                        LocalDate.of(2026, 8, 30)));
        ExecutionSegmentView dispatched = executionSegmentService.dispatch(
                plan.planId(), segmentId,
                new SegmentTransitionRequest(
                        assigned.lockVersion(),
                        "idem-ma-direct-dispatch-" + segmentId));
        executionSegmentService.start(
                plan.planId(), segmentId,
                new SegmentTransitionRequest(
                        dispatched.lockVersion(),
                        "idem-ma-direct-start-" + segmentId));

        UUID reportId = reportAndApproveExecutionSegment(
                w, planItemId, orderItemId, w.goodsC(),
                segmentId, salesAllocationId, "10");
        confirmFinishedInboundFully(finishedInDocForReport(reportId));

        assertEquals(0, new BigDecimal("10").compareTo(
                jdbc.queryForObject(
                        "select iqty from production_plan_items where id = ?",
                        BigDecimal.class, planItemId)),
                "仓库点收后计划入库数量为 10");
        assertEquals(0, new BigDecimal("10").compareTo(
                stockBalance(w.warehouseId(), w.goodsC())),
                "仓库点收后直接自制成品库存增加 10");
    }

    @Test
    void materialAnalysis_draftGenerateReplayKeepsOneDraftAndNoExecutionFacts() {
        World w = seedWorld("sMADraftReplay");
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsB(), new BigDecimal("20"));
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsE(), new BigDecimal("10"));
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma-draft-replay",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:generate");
        loginAs(planner);

        AnalysisView view = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(),
                "idem-ma-draft-replay-" + orderItemId,
                List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId, null, null, null,
                        null, null, LocalDate.of(2026, 9, 1),
                        new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID productLineId = view.products().getFirst().analysisLineId();
        AnalysisView refreshed = analysisService.detail(analysisId);
        PlanPreview preview = analysisService.planPreview(
                analysisId,
                new PlanPreviewRequest(
                        refreshed.version(), refreshed.fingerprint(),
                        w.warehouseId(),
                        List.of(new PlanQuantity(
                                productLineId, new BigDecimal("10"))),
                        null));
        AnalysisView preGenerate = analysisService.detail(analysisId);
        GeneratePlanRequest request = new GeneratePlanRequest(
                preGenerate.version(), preGenerate.fingerprint(),
                preview.previewFingerprint(),
                "gen-ma-draft-replay-" + analysisId,
                w.warehouseId(), LocalDate.of(2026, 8, 8), null,
                null, null, null, false,
                List.of(new PlanQuantity(
                        productLineId, new BigDecimal("10"))),
                null);

        GeneratedPlan first = analysisCommandService
                .generatePlan(analysisId, request).plans().getFirst();
        GeneratedPlan replay = analysisCommandService
                .generatePlan(analysisId, request).plans().getFirst();

        assertEquals("DRAFT", first.status());
        assertEquals(first.planId(), replay.planId());
        assertEquals(first.planningDraftId(), replay.planningDraftId());
        assertNull(replay.packageId());
        assertTrue(replay.segmentIds().isEmpty());
        assertTrue(replay.drawIds().isEmpty());
        assertEquals(0, count("""
                select count(*)
                from production_planning_packages
                where plan_id = ? and is_deleted = false
                """, first.planId()));
        assertEquals(0, count("""
                select count(*)
                from production_execution_segments
                where plan_id = ? and is_deleted = false
                """, first.planId()));
        assertEquals(0, count("""
                select count(*)
                from production_planning_package_documents document
                join production_planning_packages package
                  on package.id = document.package_id
                where package.plan_id = ? and document.document_type = 'DRAW'
                """, first.planId()));
        assertEquals(
                0,
                BigDecimal.ZERO.compareTo(plannedQty(orderId)),
                "草稿生成及幂等重放都不能提前回写销售 planned_qty");
    }

    // ---------------------------------------------------------------------------------------------
    // V234 material-analysis NOTIFY path for BUY + SUBCONTRACT shortages (the "缺料处理" step). MAKE
    // notify is covered by Test A; this proves the BUY and SUBCONTRACT routes really create their
    // authoritative downstream documents (purchase request / subcontract application) — the facades
    // were never exercised against real data, so this catches the same class of bug as createDraftPlan.
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_notifyBuyAndSubcontractCreatesRealDownstreamDocuments() {
        World w = seedWorld("sMA3");
        // 产品 F(自制) 直接组件：Gb(采购) + Gs(委外)，均无库存(缺料)，各挂默认供应商。
        UUID f = UUID.randomUUID(), gb = UUID.randomUUID(), gs = UUID.randomUUID();
        insertGoods(f, "F-sMA3", "成品F-sMA3", "自制", w.unitId(), w.unitLegacy());
        insertGoods(gb, "GB-sMA3", "采购件GB-sMA3", "采购", w.unitId(), w.unitLegacy());
        insertGoods(gs, "GS-sMA3", "委外件GS-sMA3", "委外", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id in (?, ?)",
                w.supplierId(), gb, gs);
        insertBom(f, gb, "2");
        insertBom(f, gs, "1");
        UUID orderId = createApprovedOrder(w, f, "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma3",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify");
        loginAs(planner);

        AnalysisView view = analysisService.preview(new PreviewRequest(null, null, null,
                w.warehouseId(), "idem-ma3-" + orderItemId, List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId, null, null, null, null, null,
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        MaterialView buyRow = view.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(gb) && m.actionable()).findFirst().orElse(null);
        MaterialView subRow = view.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(gs) && m.actionable()).findFirst().orElse(null);
        assertNotNull(buyRow, "采购件 Gb 是 F 的直接层组件");
        assertNotNull(subRow, "委外件 Gs 是 F 的直接层组件");
        assertEquals("BUY", buyRow.sourceSuggestion());
        assertEquals("SUBCONTRACT", subRow.sourceSuggestion());
        assertTrue(buyRow.shortageQty().signum() > 0, "无库存 → Gb 缺料");

        analysisService.saveRoutes(analysisId, new RouteRequest(view.version(), view.fingerprint(),
                "routes-ma3-" + analysisId, List.of(
                        new RouteDecision(buyRow.materialLineId(), buyRow.actionGroupKey(), "BUY", null),
                        new RouteDecision(subRow.materialLineId(), subRow.actionGroupKey(), "SUBCONTRACT", null))));
        AnalysisView routed = analysisService.detail(analysisId);

        analysisCommandService.notifySupply(analysisId, new NotifyRequest(routed.version(),
                routed.fingerprint(), "notify-buy-" + analysisId, "BUY",
                List.of(buyRow.materialLineId()), List.of(), null));
        assertEquals(1, count("select count(*) from preplan_supply_actions "
                        + "where analysis_id = ? and route = 'BUY' and status = 'CREATED' "
                        + "and external_document_type = 'PURCHASE_REQUEST' and external_document_id is not null",
                analysisId), "BUY 通知 → 落真实采购申请");

        AnalysisView afterBuy = analysisService.detail(analysisId);
        analysisCommandService.notifySupply(analysisId, new NotifyRequest(afterBuy.version(),
                afterBuy.fingerprint(), "notify-sub-" + analysisId, "SUBCONTRACT",
                List.of(subRow.materialLineId()), List.of(), null));
        assertEquals(1, count("select count(*) from preplan_supply_actions "
                        + "where analysis_id = ? and route = 'SUBCONTRACT' and status = 'CREATED' "
                        + "and external_document_type = 'SUBCONTRACT_APPLICATION' and external_document_id is not null",
                analysisId), "SUBCONTRACT 通知 → 落真实委外申请");
    }

    // ---------------------------------------------------------------------------------------------
    // V234 material-analysis OBJECT-SCOPE (maker) isolation. @PreAuthorize lives on the Controller
    // (every endpoint has it), so direct service calls bypass it; the service-level guard here is the
    // object scope — a DIFFERENT account that DOES hold :manage cannot write to an analysis it does
    // not own. Proves V233's object-level maker isolation covers the V234 analysis aggregate.
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_objectScopeBlocksNonMaker() {
        World w = seedWorld("sMA4");
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        PreviewItem src = new PreviewItem("SALES_ORDER_ITEM", orderItemId,
                null, null, null, null, null, LocalDate.of(2026, 9, 1), new BigDecimal("10"));
        UUID owner = createUserWithPerms(w, "owner-ma4",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify");
        UUID other = createUserWithPerms(w, "other-ma4",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify");

        // 归属人创建分析
        loginAs(owner);
        AnalysisView view = analysisService.preview(new PreviewRequest(null, null, null,
                w.warehouseId(), "idem-ma4-" + orderItemId, List.of(src)));
        UUID analysisId = view.analysisId();

        // 另一个有同等权限但非归属人的账号 → 写操作被拒（对象级 maker 隔离）
        loginAs(other);
        ApiException denied = assertThrows(ApiException.class, () -> analysisCommandService.cancelAnalysis(
                analysisId, new CancelRequest(view.version(), view.fingerprint(),
                        "cancel-other-" + analysisId, "越权尝试")));
        assertTrue(denied.getMessage().contains("本人") || denied.getMessage().contains("无权"),
                "非归属人不能操作他人物料分析(实际：" + denied.getMessage() + ")");
    }

    // ---------------------------------------------------------------------------------------------
    // V234 material-analysis PARTIAL batch (the headline "需100/齐10产10" scenario). Stock covers 10
    // (readyNow=10) but the planner only generates 5 this batch. Sales planned_qty must advance by 5
    // (not 10), the analysis lands PARTIALLY_PLANNED (remaining 5 still schedulable later). Test B
    // above covers the full-batch edge (required_qty→0); this covers the common partial case.
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_partialBatchLeavesRemainingDemandPartiallyPlanned() {
        World w = seedWorld("sMA5");
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsB(), new BigDecimal("20"));
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsE(), new BigDecimal("10"));
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma5",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:generate", "production_plan:approve");
        loginAs(planner);

        AnalysisView view = analysisService.preview(new PreviewRequest(null, null, null,
                w.warehouseId(), "idem-ma5-" + orderItemId, List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId, null, null, null, null, null,
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID productLineId = view.products().getFirst().analysisLineId();
        // 可立即生产 10，本次只下达 5（分批）
        AnalysisView refreshed = analysisService.detail(analysisId);
        PlanPreview plan = analysisService.planPreview(analysisId, new PlanPreviewRequest(
                refreshed.version(), refreshed.fingerprint(), w.warehouseId(),
                List.of(new PlanQuantity(productLineId, new BigDecimal("5"))), null));
        assertTrue(plan.allReady(), "5 ≤ 可立即生产 10 → 本批齐套");
        AnalysisView preGen = analysisService.detail(analysisId);

        GenerateResult result = analysisCommandService.generatePlan(analysisId, new GeneratePlanRequest(
                preGen.version(), preGen.fingerprint(), plan.previewFingerprint(),
                "gen-ma5-" + analysisId, w.warehouseId(), LocalDate.of(2026, 8, 8), null,
                null, null, null, true,
                List.of(new PlanQuantity(productLineId, new BigDecimal("5"))), null));
        GeneratedPlan g = result.plans().getFirst();
        assertEquals("APPROVED", g.status(), "分批也是 approveNow 一步批准");
        assertEquals(1, planStatus(g.planId()));
        // 销售只回写 5；剩余 5 留待后续分批
        assertEquals(0, new BigDecimal("5").compareTo(plannedQty(orderId)),
                "分批：销售 planned_qty=5(非 10)，剩余可后续下达");
        // 分析头 PARTIALLY_PLANNED（10 中已批 5，未全部下达 → 非 COMPLETED）
        assertEquals("PARTIALLY_PLANNED",
                strFor("select status from production_material_analyses where id=?", analysisId),
                "分批未全量 → PARTIALLY_PLANNED");
    }

    // ---------------------------------------------------------------------------------------------
    // V234 material-analysis SHARED-MATERIAL REALLOCATION ("物料划拨"). Two products in one analysis
    // share one scarce component M (stock 10, 2/unit → only 5 products' worth). Allocating priority
    // to P1 → P1 can produce 5, P2 gets 0; SWAPPING priority to P2 → P2 produces 5, P1 gets 0. This
    // is the "A 缺 X 但把料让给 B 先产" decision the planner makes on the workbench.
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_sharedMaterialReallocationByPriority() {
        World w = seedWorld("sMA6");
        UUID p1 = UUID.randomUUID(), p2 = UUID.randomUUID(), m = UUID.randomUUID();
        insertGoods(p1, "P1-sMA6", "成品P1-sMA6", "自制", w.unitId(), w.unitLegacy());
        insertGoods(p2, "P2-sMA6", "成品P2-sMA6", "自制", w.unitId(), w.unitLegacy());
        insertGoods(m, "M-sMA6", "共用件M-sMA6", "采购", w.unitId(), w.unitLegacy());
        insertBom(p1, m, "2");
        insertBom(p2, m, "2");
        // M 库存 10，每个成品需 2 → 整池只够 5 个成品
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), m, new BigDecimal("10"));
        UUID o1 = createApprovedOrder(w, p1, "10", "100");
        UUID o2 = createApprovedOrder(w, p2, "10", "100");
        UUID planner = createUserWithPerms(w, "planner-ma6",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:reallocate");
        loginAs(planner);

        AnalysisView view = analysisService.preview(new PreviewRequest(null, null, null,
                w.warehouseId(), "idem-ma6-" + o1 + "-" + o2, List.of(
                        new PreviewItem("SALES_ORDER_ITEM", orderItemId(o1), null, null, null, null, null,
                                LocalDate.of(2026, 9, 1), new BigDecimal("10")),
                        new PreviewItem("SALES_ORDER_ITEM", orderItemId(o2), null, null, null, null, null,
                                LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID line1 = view.products().stream().filter(p -> p.goodsId().equals(p1))
                .findFirst().orElseThrow().analysisLineId();
        UUID line2 = view.products().stream().filter(p -> p.goodsId().equals(p2))
                .findFirst().orElseThrow().analysisLineId();

        // 划拨给 P1（优先级 1）：P1 可产 5，P2 可产 0
        AnalysisView p1First = analysisService.saveAllocationPriorities(analysisId, new AllocationPriorityRequest(
                view.version(), view.fingerprint(), "alloc-p1-" + analysisId, List.of(
                        new AllocationPriorityItem(line1, 1),
                        new AllocationPriorityItem(line2, 2))));
        assertEquals(0, new BigDecimal("5").compareTo(productReadyNow(p1First, p1)),
                "M 划拨给 P1 → P1 可产 5(实际 " + productReadyNow(p1First, p1) + ")");
        assertEquals(0, BigDecimal.ZERO.compareTo(productReadyNow(p1First, p2)),
                "P2 无料 → 可产 0(实际 " + productReadyNow(p1First, p2) + ")");

        // 改划拨给 P2（优先级对调）：P2 可产 5，P1 可产 0 —— "让别的产品先生产"
        AnalysisView refreshed = analysisService.detail(analysisId);
        AnalysisView p2First = analysisService.saveAllocationPriorities(analysisId, new AllocationPriorityRequest(
                refreshed.version(), refreshed.fingerprint(), "alloc-p2-" + analysisId, List.of(
                        new AllocationPriorityItem(line1, 2),
                        new AllocationPriorityItem(line2, 1))));
        assertEquals(0, BigDecimal.ZERO.compareTo(productReadyNow(p2First, p1)),
                "改划拨 → P1 可产 0(实际 " + productReadyNow(p2First, p1) + ")");
        assertEquals(0, new BigDecimal("5").compareTo(productReadyNow(p2First, p2)),
                "改划拨 → P2 可产 5(实际 " + productReadyNow(p2First, p2) + ")");
    }

    private BigDecimal productReadyNow(AnalysisView view, UUID goodsId) {
        return view.products().stream()
                .filter(product -> product.goodsId().equals(goodsId))
                .map(ProductView::readyNowQty).findFirst().orElse(BigDecimal.ZERO);
    }

    // ---------------------------------------------------------------------------------------------
    // V240 附件（本地存储后端）两阶段上传：presign → 直传字节 → confirm 校验落库 → 列表 → 下载往返 → 删除。
    // 默认 provider=local，LocalDiskStorageService 写隔离临时目录；验全栈：服务 + 本地盘 + 真实库。
    // ---------------------------------------------------------------------------------------------
    @Test
    void attachmentLocalTwoPhaseUploadConfirmListDownloadDelete() throws Exception {
        World w = seedWorld("sAtt");
        // V328 起 attachment:manage 复合权限已停用，拆分为 upload/delete；
        // 下载走独立 attachment:download。
        UUID user = createUserWithPerms(
                w, "user-att", "attachment:upload", "attachment:download",
                "attachment:view", "attachment:delete", "expense:apply");
        loginAs(user);

        UUID ownerId = UUID.randomUUID();
        jdbc.update("""
                insert into expense_claims(
                    id, applicant_id, applicant_name_snapshot, applicant_department_id,
                    title, total_amount, status)
                values (?, ?, '员工-sAtt', ?, '附件真实链路测试', 1.00, 'DRAFT')
                """, ownerId, employeeIdOf(user), w.departmentId());
        byte[] content = Base64.getDecoder().decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");
        String contentType = "image/png";

        // 1) presign：服务端生成 storageKey + 本地相对直传 URL
        AttachmentPresignResponse pre = attachmentService.presign(new AttachmentPresignRequest(
                "EXPENSE_CLAIM", ownerId, "receipt.png", contentType, (long) content.length));
        assertNotNull(pre.storageKey());
        assertFalse(pre.url().startsWith("http"), "本地后端直传 URL 应为相对路径");
        AttachmentUploadGrantService.Grant signedGrant =
                attachmentUploadGrants.verifySigned(pre.confirmToken());
        Map<String, Object> reservation = jdbc.queryForMap("""
                select storage_key, owner_type, owner_id, user_id, original_name,
                       content_type, expected_size_bytes, expires_at, status
                from attachment_upload_sessions where storage_key = ?
                """, pre.storageKey());
        assertEquals(signedGrant.storageKey(), reservation.get("storage_key"));
        assertEquals(signedGrant.ownerType(), reservation.get("owner_type"));
        assertEquals(signedGrant.ownerId(), reservation.get("owner_id"));
        assertEquals(signedGrant.userId(), reservation.get("user_id"));
        assertEquals(signedGrant.originalName(), reservation.get("original_name"));
        assertEquals(signedGrant.contentType(), reservation.get("content_type"));
        assertEquals(signedGrant.sizeBytes(),
                ((Number) reservation.get("expected_size_bytes")).longValue());
        assertEquals(signedGrant.expiresAt().truncatedTo(ChronoUnit.MICROS),
                ((java.sql.Timestamp) reservation.get("expires_at"))
                        .toInstant().truncatedTo(ChronoUnit.MICROS));
        assertEquals("PENDING", reservation.get("status"));

        // 2) 上传授权不能借给另一个同样持附件权限的人使用。
        UUID other = createUserWithPerms(
                w, "other-att", "attachment:upload", "attachment:view",
                "attachment:download", "attachment:delete", "expense:apply");
        loginAs(other);
        ApiException stolenGrant = assertThrows(ApiException.class, () -> attachmentService.storeRaw(
                pre.storageKey(), pre.confirmToken(), new ByteArrayInputStream(content),
                content.length, contentType));
        assertEquals(ErrorCode.FORBIDDEN, stolenGrant.getCode());
        assertEquals("PENDING", strFor("""
                select status from attachment_upload_sessions where storage_key = ?
                """, pre.storageKey()));

        // 3) 走真实 local raw service：验证当前用户、业务对象、key、大小和类型绑定。
        loginAs(user);
        attachmentService.storeRaw(pre.storageKey(), pre.confirmToken(),
                new ByteArrayInputStream(content), content.length, contentType);

        // 4) confirm：服务端 describe 校验对象已到位 → 落库
        AttachmentDto saved = attachmentService.confirm(new AttachmentConfirmRequest(
                pre.storageKey(), pre.confirmToken(), "EXPENSE_CLAIM", ownerId,
                "receipt.png", contentType, (long) content.length, null, null));
        assertEquals(content.length, saved.sizeBytes());
        assertNull(saved.downloadUrl(), "list/confirm responses must not pre-issue expiring credentials");
        assertNotNull(attachmentService.downloadGrant(saved.id()).url());
        assertEquals(1, count(
                "select count(*) from audit_log where action='attachment_download_grant' and target_id=?",
                saved.id().toString()));
        assertEquals(1, count(
                "select count(*) from attachments where owner_type=? and owner_id=?",
                "EXPENSE_CLAIM", ownerId));
        assertEquals(64, strFor(
                "select sha256 from attachments where storage_key = ?", pre.storageKey()).length());
        assertEquals(1, count("""
                        select count(*) from attachment_object_outbox
                        where operation = 'DELETE_STAGING' and storage_key = ?
                          and available_at >= CAST(? AS timestamptz) - interval '1 second'
                        """,
                pre.storageKey(), java.sql.Timestamp.from(pre.expiresAt())));

        // 响应丢失后相同 confirm 可安全重试，不会多落一行。
        AttachmentDto retried = attachmentService.confirm(new AttachmentConfirmRequest(
                pre.storageKey(), pre.confirmToken(), "EXPENSE_CLAIM", ownerId,
                "receipt.png", contentType, (long) content.length, null, null));
        assertEquals(saved.id(), retried.id());

        // storageKey 已可见后也绝不能覆盖原对象。
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class, () ->
                attachmentService.storeRaw(pre.storageKey(), pre.confirmToken(),
                        new ByteArrayInputStream(content), content.length, contentType)).getCode());

        // 5) list：含下载 URL
        List<AttachmentDto> list = attachmentService.list("EXPENSE_CLAIM", ownerId);
        assertEquals(1, list.size());
        assertEquals(saved.id(), list.get(0).id());

        // 6) 下载往返：字节一致
        try (ByteArrayOutputStream out = new ByteArrayOutputStream();
             var in = attachmentService.openRaw(pre.storageKey()).stream()) {
            in.transferTo(out);
            assertArrayEquals(content, out.toByteArray());
        }

        // 7) 持相同通用权限的其他员工仍不能枚举、下载或删除这张报销单的附件。
        loginAs(other);
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class,
                () -> attachmentService.list("EXPENSE_CLAIM", ownerId)).getCode());
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class,
                () -> attachmentService.openRaw(pre.storageKey())).getCode());
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class,
                () -> attachmentService.delete(saved.id())).getCode());

        // 8) 未上传却 confirm → 对象不存在，应 409 CONFLICT
        loginAs(user);
        AttachmentPresignResponse ghost = attachmentService.presign(new AttachmentPresignRequest(
                "EXPENSE_CLAIM", ownerId, "ghost.png", contentType, (long) content.length));
        ApiException conflict = assertThrows(ApiException.class, () -> attachmentService.confirm(
                new AttachmentConfirmRequest(ghost.storageKey(), ghost.confirmToken(), "EXPENSE_CLAIM", ownerId,
                        "ghost.png", contentType, (long) content.length, null, null)));
        assertEquals(ErrorCode.CONFLICT, conflict.getCode(), conflict.getMessage());

        // 9) delete：删对象 + 删行 + 磁盘文件
        attachmentService.delete(saved.id());
        while (attachmentOutbox.processNext()) {
            // deterministically drain staging and final delete intents
        }
        assertEquals(0, count(
                "select count(*) from attachments where owner_type=? and owner_id=? and lifecycle_state='CLEAN'",
                "EXPENSE_CLAIM", ownerId));
        assertEquals(1, count(
                "select count(*) from attachments where id=? and lifecycle_state='DELETED'",
                saved.id()));
        assertFalse(java.nio.file.Files.exists(
                ATTACH_TEST_DIR.resolve("final").resolve(pre.storageKey())));
    }

    // ---------------------------------------------------------------------------------------------
    // V241 remote_access：开关变更即时 bump auth_version（旧 token 即时失效）；幂等不重复 bump。
    // ---------------------------------------------------------------------------------------------
    @Test
    void remoteAccessToggleBumpsAuthVersion() {
        World w = seedWorld("sRA");
        UUID target = createUserWithPerms(w, "user-ra", "expense:apply");
        loginAs(w.superAdminUserId());

        long before = jdbc.queryForObject(
                "select auth_version from users where id=?", Long.class, target);
        assertFalse(Boolean.TRUE.equals(jdbc.queryForObject(
                "select remote_access from users where id=?", Boolean.class, target)),
                "默认不允许外网访问");

        // 授予云端访问 → 触发器应 bump auth_version（旧 token 即时失效）
        userAccountAdmin.setRemoteAccess(target, true);
        assertTrue(Boolean.TRUE.equals(jdbc.queryForObject(
                "select remote_access from users where id=?", Boolean.class, target)));
        long afterGrant = jdbc.queryForObject(
                "select auth_version from users where id=?", Long.class, target);
        assertEquals(before + 1, afterGrant, "授予 remote_access 应 bump auth_version");

        // 幂等：同值再设不应再 bump
        userAccountAdmin.setRemoteAccess(target, true);
        assertEquals(afterGrant, jdbc.queryForObject(
                "select auth_version from users where id=?", Long.class, target));

        // 回收 → 再 bump
        userAccountAdmin.setRemoteAccess(target, false);
        assertFalse(Boolean.TRUE.equals(jdbc.queryForObject(
                "select remote_access from users where id=?", Boolean.class, target)));
        assertEquals(afterGrant + 1, jdbc.queryForObject(
                "select auth_version from users where id=?", Long.class, target));
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
        // 送审 fail-closed 前置还要求至少一名持有对应 :approve 的在职财务；
        // 种子同时授予成对批准权限，保持审核员即可批。
        jdbc.update("""
                insert into user_permission_overrides(user_id, permission_id, effect)
                select ?, p.id, 'grant' from permissions p
                where p.code = replace(?, ':review', ':approve')
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
        orderReq.setSettlementMethodId(activeSettlementMethodId());
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
        assertNotNull(reviewer, "财务审核人就位(submit 需至少一名合格审核人)");

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
        orderReq.setSettlementMethodId(activeSettlementMethodId());
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

    /**
     * Turns one BUY shortage from the plan-before-production analysis into an
     * approved PO without creating a formal production demand or reservation.
     * The later IQC PASS can therefore prove that genuinely free qualified
     * stock wakes the original analysis.
     */
    private UUID approvePurchaseForAnalysis(
            World w,
            AnalysisView analysis,
            UUID buyGoodsId) {
        MaterialView buyRow = analysis.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(buyGoodsId)
                        && material.actionable())
                .findFirst()
                .orElseThrow();
        AnalysisView routed = analysisService.saveRoutes(
                analysis.analysisId(),
                new RouteRequest(
                        analysis.version(),
                        analysis.fingerprint(),
                        "route-wakeup-buy-" + analysis.analysisId(),
                        List.of(new RouteDecision(
                                buyRow.materialLineId(),
                                buyRow.actionGroupKey(),
                                "BUY",
                                null))));
        analysisCommandService.notifySupply(
                analysis.analysisId(),
                new NotifyRequest(
                        routed.version(),
                        routed.fingerprint(),
                        "notify-wakeup-buy-" + analysis.analysisId(),
                        "BUY",
                        List.of(buyRow.materialLineId()),
                        List.of(), null));

        Map<String, Object> requestItem = jdbc.queryForMap("""
                select item.id, item.qty
                from preplan_supply_actions action
                join purchase_requests request
                  on request.id = action.external_document_id
                join purchase_request_items item
                  on item.request_id = request.id
                 and item.is_deleted = false
                where action.analysis_id = ?
                  and action.route = 'BUY'
                  and action.status = 'CREATED'
                  and item.goods_id = ?
                """, analysis.analysisId(), buyGoodsId);
        UUID requestItemId = (UUID) requestItem.get("id");
        BigDecimal quantity = (BigDecimal) requestItem.get("qty");

        com.uten.imp.features.purchase.order.dto.OrderSaveRequest order =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setSettlementMethodId(activeSettlementMethodId());
        order.setBillDate(LocalDate.of(2026, 1, 15));
        order.setSupplierId(w.supplierId());
        order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(w.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line =
                new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(buyGoodsId);
        line.setRequestItemId(requestItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(quantity);
        line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(quantity.multiply(new BigDecimal("50")));
        line.setAmountLocal(quantity.multiply(new BigDecimal("50")));
        order.setItems(List.of(line));
        // 订货拆单 + 送审是采购岗/超管动作（planner 无 purchase_order:* 权限），
        // 与其他链路辅助一致由超管驱动；随后审核员独立批。
        loginAs(w.superAdminUserId());
        purchaseOrderService.createBatch(order);

        UUID orderId = jdbc.queryForObject("""
                select purchase_order.id
                from purchase_orders purchase_order
                join purchase_order_items item
                  on item.order_id = purchase_order.id
                where item.request_item_id = ?
                  and purchase_order.is_deleted = false
                  and item.is_deleted = false
                """, UUID.class, requestItemId);
        UUID reviewer = createReviewer(
                w, "finance_order_approval:review");
        financeApproval.submit("PURCHASE", orderId);
        loginAs(reviewer);
        long version = jdbc.queryForObject("""
                select version
                from procurement_order_approval_cases
                where order_type = 'PURCHASE' and order_id = ?
                """, Long.class, orderId);
        financeApproval.approve("PURCHASE", orderId, version);
        loginAs(w.superAdminUserId());
        return jdbc.queryForObject("""
                select id
                from purchase_order_items
                where order_id = ? and request_item_id = ?
                """, UUID.class, orderId, requestItemId);
    }

    private UUID receiveAndPassPurchase(
            World w, UUID orderItemId, UUID goodsId,
            BigDecimal qty, String idempotencySuffix) {
        loginAs(w.superAdminUserId());
        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest request =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(LocalDate.of(2026, 1, 20));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(purchaseOrderSettlementMethodOf(orderItemId));
        com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine line =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        line.setGoodsId(goodsId);
        line.setOrderItemId(orderItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(qty);
        line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(qty.multiply(new BigDecimal("50")));
        line.setAmountLocal(qty.multiply(new BigDecimal("50")));
        request.setItems(List.of(line));
        purchaseReceiptService.create(request);
        UUID receiptId = jdbc.queryForObject("""
                select receipt.id
                from purchase_receipts receipt
                join purchase_receipt_items item on item.receipt_id = receipt.id
                where item.order_item_id = ? and receipt.is_deleted = false
                  and item.is_deleted = false
                order by receipt.created_at desc limit 1
                """, UUID.class, orderItemId);
        purchaseReceiptService.approve(receiptId);
        UUID inspectionItemId = jdbc.queryForObject("""
                select id from procurement_inspection_items
                where receipt_type = 'PURCHASE' and receipt_id = ? and goods_id = ?
                order by updated_at desc limit 1
                """, UUID.class, receiptId, goodsId);
        inspectionService.dispose(
                "PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto
                        .InspectionDispositionRequest(
                        "PASS", null, "让料优先补齐真链验收",
                        "idem-cross-priority-" + idempotencySuffix));
        return receiptId;
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
        rr.setSettlementMethodId(purchaseOrderSettlementMethodOf(orderItemId));
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
    // #23c (arrival → review → IQC → warehouse notice, 全链路 + 进度同步) 仓库「登记实际到货」
    // 只建草稿收货单：库存 / 订货已收 / 品质待检 / 应付都不得提前出现，仅任务中心在途量
    // （registered_qty，已登记待审核）立即反映；审核页点「审核」后才冻结进 IQC 待检、
    // 回写 received_qty 并立应付，在途量随之清零转入已收；品质 PASS 整单结案后合格量放行
    // 入库、唤醒生产（PRODUCTION_WOKEN），并向仓库部门投递「品质检验通过，已入库」通知
    // （PROCUREMENT_IQC_RESOLVED outbox → notices，点击直达收货单详情）。
    // ---------------------------------------------------------------------------------------------
    @Test
    void receiving_draftApproveIqcPassSyncsProgressAndNotifiesWarehouse() {
        World w = seedWorld("s23c");
        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-s23c", "成品G-s23c", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-s23c", "原料H-s23c", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2"); // G -> H ; order 10 -> H demand 20
        UUID orderItemId = procureDirectBuy(w, g, h, "10"); // approved PO for H(20)

        // 仓库部门通知接收人：种子部门树 SUB_WH 下挂一个启用账号。
        UUID warehouseEmpId = UUID.randomUUID(), warehouseUserId = UUID.randomUUID();
        jdbc.update("""
                insert into employees(id, code, full_name, id_type, department_id, hire_date,
                                      status, employment_type)
                values (?, ?, ?, '其他',
                        (select id from departments where code = 'SUB_WH' and is_deleted = false),
                        DATE '2026-01-01', 'active', 'regular')
                """, warehouseEmpId, "EMP-WH-s23c", "仓库员-s23c");
        jdbc.update("""
                insert into users(id, employee_id, login_account, password_hash,
                                  must_change_password, is_super_admin, status)
                values (?, ?, ?, 'x', false, false, 'active')
                """, warehouseUserId, warehouseEmpId, "USR-WH-s23c");

        loginAs(w.superAdminUserId());

        // ① 仓库登记实际到货（= 登记页「保存」：只创建草稿收货单，不审核）
        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest rr =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        rr.setBillDate(LocalDate.of(2026, 1, 20));
        rr.setSupplierId(w.supplierId());
        rr.setWarehouseId(w.warehouseId());
        rr.setCurrencyId(w.currencyId());
        rr.setExchangeRate(BigDecimal.ONE);
        rr.setTaxRate(BigDecimal.ZERO);
        rr.setSettlementMethodId(purchaseOrderSettlementMethodOf(orderItemId));
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

        // 草稿阶段：不产生待检 / 不回写 / 不入库 / 不立应付，仅在途量出现
        assertEquals(0, jdbc.queryForObject(
                "select status from purchase_receipts where id = ?", Integer.class, receiptId),
                "到货登记保存后收货单为草稿(待审核)");
        assertEquals(0, count(
                "select count(*) from procurement_inspection_items where receipt_id = ?",
                receiptId), "未审核不产生品质待检任务");
        assertEquals(0, jdbc.queryForObject(
                        "select received_qty from purchase_order_items where id = ?",
                        BigDecimal.class, orderItemId).compareTo(BigDecimal.ZERO),
                "未审核不回写订货已收(采购订货进度不变)");
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "未审核不入库");
        assertEquals(0, count(
                "select count(*) from ar_ap_ledger "
                        + "where source_doc_type = 'PURCHASE_RECEIPT' and source_doc_id = ?",
                receiptId), "未审核不立应付");
        assertEquals(0, inflightRegisteredQty(orderItemId).compareTo(new BigDecimal("20")),
                "任务中心在途量(已登记待审核)= 20");
        assertEquals(0, count(
                "select count(*) from business_outbox "
                        + "where event_type = 'PROCUREMENT_IQC_RESOLVED' and aggregate_id = ?",
                receiptId), "结案前不得投递入库通知");

        // ② 审核页点「审核」→ 转品质待检：IQC 冻结 + 回写订货已收 + 立应付；在途量清零
        purchaseReceiptService.approve(receiptId);
        assertEquals(1, count(
                "select count(*) from procurement_inspection_items "
                        + "where receipt_id = ? and status = 'PENDING'", receiptId),
                "审核后生成品质待检明细(品质任务中心列表与工作台角标同源)");
        assertEquals(0, jdbc.queryForObject(
                        "select received_qty from purchase_order_items where id = ?",
                        BigDecimal.class, orderItemId).compareTo(new BigDecimal("20")),
                "审核后 received_qty += 20(采购订货进度同步)");
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "IQC 待检期间不入可用库存");
        assertEquals(1, count(
                "select count(*) from ar_ap_ledger "
                        + "where source_doc_type = 'PURCHASE_RECEIPT' and source_doc_id = ?",
                receiptId), "审核后立应付");
        assertEquals(0, inflightRegisteredQty(orderItemId).compareTo(BigDecimal.ZERO),
                "审核后在途量清零(转入已收)");

        // ③ 品质部 PASS（整单结案）→ 合格量放行入库 + 唤醒生产 + 投递仓库通知事件
        UUID inspectionItemId = jdbc.queryForObject(
                "select id from procurement_inspection_items where receipt_id = ? and goods_id = ?",
                UUID.class, receiptId, h);
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "质检合格", "idem-s23c-" + inspectionItemId));

        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(new BigDecimal("20")),
                "品质 PASS 后合格量放行入库");
        assertEquals(0, count(
                "select count(*) from procurement_inspection_items "
                        + "where receipt_id = ? and status in ('PENDING','PARTIAL')", receiptId),
                "结案后品质待检角标归零");
        assertEquals(1, count(
                "select count(*) from procurement_inspection_events e "
                        + "join procurement_inspection_items i on i.id = e.inspection_item_id "
                        + "where i.receipt_id = ? and e.action = 'PRODUCTION_WOKEN'", receiptId),
                "整单结案唤醒生产(生产进度同步)");
        assertEquals(1, count(
                "select count(*) from business_outbox "
                        + "where event_type = 'PROCUREMENT_IQC_RESOLVED' "
                        + "and aggregate_id = ? and status = 0", receiptId),
                "结案后向仓库投递入库通知事件");

        // ④ outbox 送达：仓库人员收到「品质检验通过，已入库」通知，点击直达收货单。
        // （测试类共享种子部门 SUB_WH：同批其他用例的结案通知也会送达该用户，
        //   故按本单 action_route 精确过滤。）
        while (businessOutboxProcessor.processNext()) {
            // 排空队列（含本链路早前投递的财务审批等事件）
        }
        List<Map<String, Object>> notices = jdbc.queryForList(
                "select title, action_route from notices "
                        + "where audience_user_id = ? and source_event = 'PROCUREMENT_IQC_RESOLVED'"
                        + " and action_route = ?",
                warehouseUserId, "/purchase/receipts/" + receiptId);
        assertEquals(1, notices.size(), "仓库人员收到本单的「品质检验通过，已入库」通知");
    }

    /** 任务中心在途量口径：草稿（status=0 未删）收货单按订货明细汇总（与服务端查询同口径）。 */
    private BigDecimal inflightRegisteredQty(UUID orderItemId) {
        return jdbc.queryForObject("""
                select coalesce(sum(receipt_item.qty), 0)
                from purchase_receipt_items receipt_item
                join purchase_receipts receipt on receipt.id = receipt_item.receipt_id
                where receipt.status = 0 and receipt.is_deleted = false
                  and receipt_item.order_item_id = ?
                """, BigDecimal.class, orderItemId);
    }

    // ---------------------------------------------------------------------------------------------
    // #23b (V298 preplan pegging) Stock received against a plan-before-analysis BUY order
    // belongs to THAT analysis: the IQC PASS writes a PREPLAN_ANALYSIS reservation that removes
    // the qty from v_stock_available (invisible to other analyses / sales / MRP), the origin
    // analysis gets it added back as its own availability, and red-flushing the receipt
    // releases the peg symmetrically. Guards the production-planning complaint that a NEW
    // analysis counted goods another analysis had already bought and received as its own
    // 备料可用量 (cross-analysis double counting).
    // ---------------------------------------------------------------------------------------------
    @Test
    void preplanPegging_receivedStockStaysWithOriginAnalysis() {
        World w = seedWorld("s23b");
        UUID g = UUID.randomUUID(), h = UUID.randomUUID();
        insertGoods(g, "G-s23b", "成品G-s23b", "自制", w.unitId(), w.unitLegacy());
        insertGoods(h, "H-s23b", "原料H-s23b", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?", w.supplierId(), h);
        insertBom(g, h, "2"); // G -> H ; order 10 -> H demand 20

        UUID planner = createUserWithPerms(w, "planner-s23b",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify",
                "production_material_analysis:generate");
        loginAs(planner);

        // 分析A：订单1（G×10，已审核+财务确认）→ H 缺 20。
        UUID orderA = createApprovedOrder(w, g, "10", "100");
        AnalysisView viewA = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-s23b-a-" + orderA,
                List.of(new PreviewItem("SALES_ORDER_ITEM", orderItemId(orderA),
                        null, null, null, null, null,
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisA = viewA.analysisId();
        MaterialView hA = viewA.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(h)).findFirst().orElseThrow();
        assertEquals(0, hA.availableQty().compareTo(BigDecimal.ZERO), "收货前 H 可用量为 0");
        analysisService.saveRoutes(analysisA, new RouteRequest(
                viewA.version(), viewA.fingerprint(), "routes-s23b-" + analysisA,
                List.of(new RouteDecision(
                        hA.materialLineId(), hA.actionGroupKey(), "BUY", null))));
        // BUY → 采购申请 → 订货 → 财务审批（helper 收尾处于 reviewer 登录态）。
        approvePurchaseForAnalysis(w, analysisService.detail(analysisA), h);

        // 收货 H×20 + IQC PASS（超管）。当期日期：后续红冲受 GL 跨期间守卫限制。
        loginAs(w.superAdminUserId());
        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest rr =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        rr.setBillDate(BusinessTime.today());
        rr.setSupplierId(w.supplierId());
        rr.setWarehouseId(w.warehouseId());
        rr.setCurrencyId(w.currencyId());
        rr.setExchangeRate(BigDecimal.ONE);
        rr.setTaxRate(BigDecimal.ZERO);
        UUID purchasedOrderItemId = jdbc.queryForObject(
                "select item.id from purchase_order_items item "
                        + "join preplan_supply_action_allocations alloc "
                        + "  on alloc.external_item_id = item.request_item_id "
                        + "join preplan_supply_actions act on act.id = alloc.action_id "
                        + "where act.analysis_id = ? and item.goods_id = ? "
                        + "  and item.is_deleted = false",
                UUID.class, analysisA, h);
        rr.setSettlementMethodId(purchaseOrderSettlementMethodOf(purchasedOrderItemId));
        com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine ri =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        ri.setGoodsId(h);
        ri.setOrderItemId(purchasedOrderItemId);
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
        UUID inspectionItemId = jdbc.queryForObject(
                "select id from procurement_inspection_items where receipt_id = ? and goods_id = ? "
                        + "order by updated_at desc limit 1",
                UUID.class, receiptId, h);
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "质检合格", "idem-s23b-" + inspectionItemId));

        // (1) 绑定已写入且从公共现货口径扣除。
        assertEquals(1, count("""
                        select count(*) from stock_reservations
                        where is_deleted = false
                          and owner_type = 'PREPLAN_ANALYSIS'
                          and owner_id = ?
                          and supply_type = 'PURCHASE_REQUEST_ITEM'
                          and status = 0
                          and qty = 20
                          and released_qty = 0
                        """, analysisA),
                "IQC PASS 应写分析归属预留(qty=20，生效中)");
        assertEquals(0, publicAvailable(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "公共可用量不得含其它分析已绑定的收货");

        // (2) 新分析B（订单2）不得把分析A已收货绑定的 20 算成自己的可用量。
        loginAs(planner);
        UUID orderB = createApprovedOrder(w, g, "10", "100");
        AnalysisView viewB = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-s23b-b-" + orderB,
                List.of(new PreviewItem("SALES_ORDER_ITEM", orderItemId(orderB),
                        null, null, null, null, null,
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        MaterialView hB = viewB.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(h)).findFirst().orElseThrow();
        assertEquals(0, hB.availableQty().compareTo(BigDecimal.ZERO),
                "分析B不得计入分析A已收货绑定的 20(跨分析重复计算回归)");
        assertEquals(0, hB.shortageQty().compareTo(new BigDecimal("20")),
                "分析B的 H 缺口仍是 20");

        // (3) 归属分析A自己：绑定量还原为本分析可用（在库 20 = 公共可用 0 + 本分析绑定 20）。
        MaterialView hAAfter = analysisService.detail(analysisA).flatMaterials().stream()
                .filter(m -> m.goodsId().equals(h)).findFirst().orElseThrow();
        WarehouseBreakdown wA = hAAfter.warehouseBreakdown().stream()
                .filter(b -> b.warehouseId().equals(w.warehouseId())).findFirst().orElseThrow();
        assertEquals(0, wA.ownPeggedQty().compareTo(new BigDecimal("20")),
                "分析A应看到本分析备料绑定量 20");
        assertEquals(0, wA.availableQty().compareTo(new BigDecimal("20")),
                "绑定量对归属分析还原为可用");
        assertEquals(0, wA.reservedQty().compareTo(BigDecimal.ZERO),
                "本分析绑定不算他人预留");

        // (4) 红冲收货 → 对称释放回公共池。
        loginAs(w.superAdminUserId());
        purchaseReceiptService.reverse(receiptId);
        assertEquals(0, count("""
                        select count(*) from stock_reservations
                        where is_deleted = false
                          and owner_type = 'PREPLAN_ANALYSIS'
                          and owner_id = ?
                          and status = 0
                        """, analysisA),
                "红冲后分析A生效预留清零(对称释放)");
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),

                "红冲后真实库存回到 0");
    }
    // ---------------------------------------------------------------------------------------------
    // #23d (V309-V313) A explicitly reallocates qualified stock to B. B does not owe A:
    // A becomes the higher-priority unmet demand. B's next exact BUY receipt is re-pegged
    // A-first in the IQC transaction, while the remaining quantity stays with B.
    // ---------------------------------------------------------------------------------------------
    @Test
    void preplanReallocation_nextTargetSupplyPrioritizesSourceAnalysis() {
        World w = seedWorld("s23d");
        UUID product = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(product, "G-s23d", "让料产品G-s23d", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "H-s23d", "让料原料H-s23d", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(product, material, "1");

        UUID planner = createUserWithPerms(
                w, "planner-s23d",
                "production_material_analysis:view",
                "production_material_analysis:manage",
                "production_material_analysis:route",
                "production_material_analysis:notify",
                "production_material_analysis:cross_reallocate",
                "production_material_analysis:generate",
                "production_plan:approve");
        loginAs(planner);

        UUID orderA = createApprovedOrder(w, product, "10", "100");
        loginAs(planner);
        AnalysisView source = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-s23d-a-" + orderA,
                List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId(orderA),
                        null, null, null, null, null,
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        MaterialView sourceMaterial = source.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material))
                .findFirst().orElseThrow();
        UUID sourceOrderItem = approvePurchaseForAnalysis(w, source, material);
        receiveAndPassPurchase(
                w, sourceOrderItem, material, new BigDecimal("10"), "source");

        loginAs(planner);
        AnalysisView sourceQualified = analysisService.detail(source.analysisId());
        sourceMaterial = sourceQualified.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material))
                .findFirst().orElseThrow();
        assertEquals(0, sourceMaterial.exactPeggedQty()
                .compareTo(new BigDecimal("10")));

        UUID orderB = createApprovedOrder(w, product, "14", "100");
        loginAs(planner);
        AnalysisView target = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-s23d-b-" + orderB,
                List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId(orderB),
                        null, null, null, null, null,
                        LocalDate.of(2026, 9, 2), new BigDecimal("14")))));
        MaterialView targetMaterial = target.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material))
                .findFirst().orElseThrow();

        materialStockReallocationService.create(
                sourceQualified.analysisId(),
                new com.uten.imp.features.production.analysis.MaterialAnalysisContracts
                        .CrossReallocationRequest(
                        sourceQualified.version(), sourceQualified.fingerprint(),
                        sourceMaterial.materialLineId(),
                        target.analysisId(), target.version(), target.fingerprint(),
                        targetMaterial.materialLineId(), new BigDecimal("4"),
                        "紧急计划先用，来源计划后续优先补齐",
                        "cross-reallocate-s23d"));

        AnalysisView sourceAfterYield = analysisService.detail(source.analysisId());
        AnalysisView targetAfterYield = analysisService.detail(target.analysisId());
        MaterialView sourceAfterYieldMaterial = sourceAfterYield.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material))
                .findFirst().orElseThrow();
        MaterialView targetAfterYieldMaterial = targetAfterYield.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material))
                .findFirst().orElseThrow();
        assertEquals(0, sourceAfterYieldMaterial.exactPeggedQty()
                .compareTo(new BigDecimal("6")));
        assertEquals(0, sourceAfterYieldMaterial.priorityPendingQty()
                .compareTo(new BigDecimal("4")));
        assertEquals(0, targetAfterYieldMaterial.exactPeggedQty()
                .compareTo(new BigDecimal("4")));
        assertEquals(0, jdbc.queryForObject("""
                select sum(qty-consumed_qty-released_qty)
                from stock_reservations
                where owner_type='PREPLAN_ANALYSIS' and status=0
                  and warehouse_id=? and goods_id=?
                """, BigDecimal.class, w.warehouseId(), material)
                .compareTo(new BigDecimal("10")));

        loginAs(planner);
        UUID targetOrderItem = approvePurchaseForAnalysis(
                w, targetAfterYield, material);
        receiveAndPassPurchase(
                w, targetOrderItem, material, new BigDecimal("10"), "target-next");

        loginAs(planner);
        MaterialView sourceFinal = analysisService.detail(source.analysisId())
                .flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material))
                .findFirst().orElseThrow();
        MaterialView targetFinal = analysisService.detail(target.analysisId())
                .flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material))
                .findFirst().orElseThrow();
        assertEquals(0, sourceFinal.exactPeggedQty()
                .compareTo(new BigDecimal("10")),
                "B下一批10中应先重新挂4给A，A恢复10");
        assertEquals(0, sourceFinal.priorityPendingQty().compareTo(BigDecimal.ZERO));
        assertEquals(0, sourceFinal.priorityFulfilledQty()
                .compareTo(new BigDecimal("4")));
        assertEquals(0, targetFinal.exactPeggedQty()
                .compareTo(new BigDecimal("10")),
                "B保留原让入4和新到货余量6，不存在返还债务");
        assertEquals(0, targetFinal.shortageQty().compareTo(new BigDecimal("4")));
        assertEquals("FULFILLED", jdbc.queryForObject("""
                select status from preplan_material_reallocations
                where from_analysis_id=? and to_analysis_id=?
                """, String.class, source.analysisId(), target.analysisId()));
        assertEquals(0, jdbc.queryForObject("""
                select priority_fulfilled_qty
                from preplan_material_reallocations
                where from_analysis_id=? and to_analysis_id=?
                """, BigDecimal.class, source.analysisId(), target.analysisId())
                .compareTo(new BigDecimal("4")));
        // Source A is fully replenished. Its plan formalizes the mixed A-origin and B-origin
        // entitlement lots into one official demand reservation before any material is issued.
        AnalysisView sourceBeforePlan = analysisService.detail(source.analysisId());
        UUID sourceProductLineId = sourceBeforePlan.products().getFirst().analysisLineId();
        PlanPreview sourcePlanPreview = analysisService.planPreview(
                source.analysisId(),
                new PlanPreviewRequest(
                        sourceBeforePlan.version(), sourceBeforePlan.fingerprint(),
                        w.warehouseId(),
                        List.of(new PlanQuantity(
                                sourceProductLineId, new BigDecimal("10"))),
                        null));
        assertTrue(sourcePlanPreview.allReady(),
                "A 恢复 10 后可以走正式生产计划下达");
        AnalysisView sourceBeforeGenerate = analysisService.detail(source.analysisId());
        GeneratedPlan generated = analysisCommandService.generatePlan(
                source.analysisId(),
                new GeneratePlanRequest(
                        sourceBeforeGenerate.version(), sourceBeforeGenerate.fingerprint(),
                        sourcePlanPreview.previewFingerprint(), "gen-s23d-formalize",
                        w.warehouseId(), LocalDate.of(2026, 9, 3), null,
                        null, null, null, true,
                        List.of(new PlanQuantity(
                                sourceProductLineId, new BigDecimal("10"))),
                        null)).plans().getFirst();
        assertEquals("APPROVED", generated.status(), "approveNow=true 应审核生产计划");
        assertTrue(hasSegmentStatus(generated.planId(), "READY"),
                "正式计划生成 READY 执行段");
        assertFalse(generated.drawIds().isEmpty(),
                "未领料前仍生成可取消的 DRAW 草稿");
        UUID packageId = jdbc.queryForObject("""
                select id from production_planning_packages
                where plan_id = ? and status = 'CONFIRMED' and is_deleted = false
                """, UUID.class, generated.planId());
        assertEquals(0, jdbc.queryForObject("""
                select coalesce(sum(qty), 0)
                from preplan_stock_entitlement_events
                where event_type = 'FORMALIZE' and target_package_id = ?
                """, BigDecimal.class, packageId).compareTo(new BigDecimal("10")),
                "A 的 10 单位权益必须以 FORMALIZE 桥接到正式需求");
        assertEquals(2, count("""
                select count(*)
                from preplan_stock_entitlement_events
                where event_type = 'FORMALIZE' and target_package_id = ?
                """, packageId), "A 的两个权益批次必须各自保留 FORMALIZE 谱系");
        assertEquals(1, count("""
                select count(distinct formal.id)
                from preplan_stock_entitlement_events event
                join stock_reservations formal
                  on formal.id = event.target_stock_reservation_id
                where event.event_type = 'FORMALIZE'
                  and event.target_package_id = ?
                  and formal.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                  and formal.status = 0
                  and formal.qty = 10
                  and formal.consumed_qty = 0
                  and formal.released_qty = 0
                """, packageId), "FORMALIZE 必须桥到一笔生效的正式预留");

        // approveNow creates a draft, unissued DRAW. Cancel is the real permitted lifecycle
        // transition here; no reverse chain is needed before any draw approval or consumption.
        planningPackageService.cancel(generated.planId(), packageId,
                new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest(
                        "cancel-s23d-formalize", "未领料取消，恢复计划前权益"));
        assertEquals(0, jdbc.queryForObject("""
                select coalesce(sum(restore.qty), 0)
                from preplan_stock_entitlement_events restore
                join preplan_stock_entitlement_events formalize
                  on formalize.id = restore.counter_event_id
                where restore.event_type = 'RESTORE'
                  and formalize.event_type = 'FORMALIZE'
                  and formalize.target_package_id = ?
                """, BigDecimal.class, packageId).compareTo(new BigDecimal("10")),
                "取消正式包必须为其全部 FORMALIZE 事件写回 RESTORE");
        // FORMALIZE 的两个批次可能落在不同来源预留（A 自有批次与 B 单上的优先批次），
        // 有效量合计随批次分布变化；稳定的恢复不变量是 released 占用全额归还。
        assertEquals(0, jdbc.queryForObject("""
                select coalesce(sum(reservation.released_qty), 0)
                from stock_reservations reservation
                where reservation.id in (
                    select stock_reservation_id
                    from preplan_stock_entitlement_events
                    where event_type = 'FORMALIZE' and target_package_id = ?)
                """, BigDecimal.class, packageId).compareTo(BigDecimal.ZERO),
                "被正式占用的来源 PREPLAN 预留取消后 released 必须全额归还");
        assertEquals(0, jdbc.queryForObject("""
                select coalesce(sum(released_qty), 0)
                from stock_reservations
                where id in (
                    select target_stock_reservation_id
                    from preplan_stock_entitlement_events
                    where event_type = 'FORMALIZE' and target_package_id = ?)
                """, BigDecimal.class, packageId).compareTo(new BigDecimal("10")),
                "正式需求预留在取消后必须已释放");
        assertEquals(0, publicAvailable(w.warehouseId(), material)
                .compareTo(BigDecimal.ZERO));
    }

    // ---------------------------------------------------------------------------------------------
    // #23c (V298 + V304 subcontract path) The production analysis creates an authoritative
    // subcontract application allocation. The subcontract department decomposes that exact
    // application item into an order; finance approval creates the V304 material-issue draft;
    // warehouse issues the frozen-BOM component before accepting the processed parent; and IQC
    // PASS must retain the application-item lineage when it attributes qualified stock back to
    // the originating analysis. This is deliberately separate from #23b: a purchase-only proof
    // cannot catch a lost subcontract application_item_id or an unexercised material-issue gate.
    // ---------------------------------------------------------------------------------------------
    @Test
    void preplanPegging_subcontractIqcPassRefreshesOnlyOriginAnalysis() {
        World w = seedWorld("s23v307");
        UUID finished = UUID.randomUUID();
        UUID siblingFinished = UUID.randomUUID();
        UUID subcontracted = UUID.randomUUID();
        UUID suppliedMaterial = UUID.randomUUID();
        insertGoods(finished, "F-s23c", "成品F-s23c", "自制", w.unitId(), w.unitLegacy());
        insertGoods(siblingFinished, "F2-s23c", "兄弟成品F2-s23c", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(subcontracted, "S-s23c", "委外件S-s23c", "委外", w.unitId(), w.unitLegacy());
        insertGoods(suppliedMaterial, "R-s23c", "委外发料R-s23c", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), subcontracted);
        insertBom(finished, subcontracted, "1");
        insertBom(siblingFinished, subcontracted, "1");
        insertBom(subcontracted, suppliedMaterial, "2");
        // V304 requires the company-owned component to leave the warehouse before the processed
        // parent can return. The direct balance fixture isolates this test from an unrelated BUY.
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), suppliedMaterial, new BigDecimal("20"));

        UUID planner = createUserWithPerms(w, "planner-s23c",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify");
        UUID siblingOrder = createApprovedOrder(w, siblingFinished, "10", "100");
        UUID orderA = createApprovedOrder(w, finished, "10", "100");
        loginAs(planner);
        AnalysisView initial = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-s23c-a-" + orderA,
                List.of(
                        new PreviewItem("SALES_ORDER_ITEM", orderItemId(siblingOrder),
                                null, null, null, null, null,
                                LocalDate.of(2026, 8, 31), new BigDecimal("10")),
                        new PreviewItem("SALES_ORDER_ITEM", orderItemId(orderA),
                                null, null, null, null, null,
                                LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisA = initial.analysisId();
        UUID targetAnalysisItemId = jdbc.queryForObject("""
                select id from production_material_analysis_items
                where analysis_id = ? and sales_order_item_id = ? and is_deleted = false
                """, UUID.class, analysisA, orderItemId(orderA));
        UUID siblingAnalysisItemId = jdbc.queryForObject("""
                select id from production_material_analysis_items
                where analysis_id = ? and sales_order_item_id = ? and is_deleted = false
                """, UUID.class, analysisA, orderItemId(siblingOrder));
        MaterialView subcontractRow = initial.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(subcontracted)
                        && material.analysisLineId().equals(targetAnalysisItemId)
                        && material.actionable())
                .findFirst().orElseThrow();
        MaterialView siblingSubcontractRow = initial.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(subcontracted)
                        && material.analysisLineId().equals(siblingAnalysisItemId)
                        && material.actionable())
                .findFirst().orElseThrow();
        assertEquals("SUBCONTRACT", subcontractRow.sourceSuggestion());
        assertEquals(0, subcontractRow.availableQty().compareTo(BigDecimal.ZERO));
        assertEquals(0, subcontractRow.shortageQty().compareTo(new BigDecimal("10")));
        assertEquals(0, siblingSubcontractRow.shortageQty().compareTo(new BigDecimal("10")));

        AnalysisView routed = analysisService.saveRoutes(
                analysisA,
                new RouteRequest(
                        initial.version(), initial.fingerprint(),
                        "route-s23c-" + analysisA,
                        List.of(new RouteDecision(
                                subcontractRow.materialLineId(),
                                subcontractRow.actionGroupKey(),
                                "SUBCONTRACT", null))));
        analysisCommandService.notifySupply(
                analysisA,
                new NotifyRequest(
                        routed.version(), routed.fingerprint(),
                        "notify-s23c-" + analysisA,
                        "SUBCONTRACT",
                        List.of(subcontractRow.materialLineId()),
                        List.of(), null));

        Map<String, Object> applicationSource = jdbc.queryForMap("""
                select application.id as application_id,
                       item.id as application_item_id,
                       item.qty as qty
                from preplan_supply_actions action
                join subcontract_applications application
                  on application.id = action.external_document_id
                 and application.is_deleted = false
                join subcontract_application_items item
                  on item.application_id = application.id
                 and item.is_deleted = false
                where action.analysis_id = ?
                  and action.route = 'SUBCONTRACT'
                  and action.status = 'CREATED'
                  and item.goods_id = ?
                """, analysisA, subcontracted);
        UUID applicationItemId = (UUID) applicationSource.get("application_item_id");
        BigDecimal quantity = (BigDecimal) applicationSource.get("qty");
        assertEquals(0, quantity.compareTo(new BigDecimal("10")));
        assertEquals(1, count("""
                        select count(*)
                        from preplan_supply_action_allocations
                        where analysis_id = ?
                          and external_item_id = ?
                          and allocated_qty = 10
                        """, analysisA, applicationItemId),
                "委外通知须把分析分摊精确锚定到 application_item_id");

        // 委外部门据申请明细下单；财务批准后 V304 自动生成冻结 BOM 发料计划/草稿。
        loginAs(w.superAdminUserId());
        com.uten.imp.features.subcontract.order.dto.OrderSaveRequest orderRequest =
                new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        orderRequest.setSettlementMethodId(activeSettlementMethodId());
        orderRequest.setBillDate(LocalDate.of(2026, 1, 15));
        orderRequest.setSupplierId(w.supplierId());
        orderRequest.setWarehouseId(w.warehouseId());
        orderRequest.setCurrencyId(w.currencyId());
        orderRequest.setExchangeRate(BigDecimal.ONE);
        orderRequest.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.subcontract.order.dto.OrderItemLine orderLine =
                new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        orderLine.setGoodsId(subcontracted);
        orderLine.setApplicationItemId(applicationItemId);
        orderLine.setUnitId(w.unitId());
        orderLine.setUnitRate(BigDecimal.ONE);
        orderLine.setQty(quantity);
        orderLine.setPrice(new BigDecimal("30"));
        orderLine.setAmountOriginal(quantity.multiply(new BigDecimal("30")));
        orderLine.setAmountLocal(quantity.multiply(new BigDecimal("30")));
        orderRequest.setItems(List.of(orderLine));
        UUID subcontractOrderId = subcontractOrderService.create(orderRequest).getId();
        UUID subcontractOrderItemId = jdbc.queryForObject("""
                select id
                from subcontract_order_items
                where order_id = ? and is_deleted = false
                """, UUID.class, subcontractOrderId);
        assertEquals(applicationItemId, jdbc.queryForObject("""
                select application_item_id
                from subcontract_order_items
                where id = ?
                """, UUID.class, subcontractOrderItemId),
                "申请分解到委外订货时 application_item_id 不得丢失");

        UUID reviewer = createReviewer(w, "finance_order_approval:review");
        financeApproval.submit("SUBCONTRACT", subcontractOrderId);
        loginAs(reviewer);
        long approvalVersion = jdbc.queryForObject("""
                select version
                from procurement_order_approval_cases
                where order_type = 'SUBCONTRACT' and order_id = ?
                """, Long.class, subcontractOrderId);
        financeApproval.approve("SUBCONTRACT", subcontractOrderId, approvalVersion);

        loginAs(w.superAdminUserId());
        UUID materialIssueId = jdbc.queryForObject("""
                select issue.id
                from subcontract_material_issues issue
                join subcontract_material_issue_items item on item.issue_id = issue.id
                where item.order_item_id = ?
                  and issue.status = 0
                  and issue.is_deleted = false
                  and item.is_deleted = false
                """, UUID.class, subcontractOrderItemId);
        var issueDraft = subcontractMaterialIssueService.detail(materialIssueId);
        com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest issueRequest =
                new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
        issueRequest.setBillDate(issueDraft.getBillDate());
        issueRequest.setSupplierId(issueDraft.getSupplierId());
        issueRequest.setWarehouseId(w.warehouseId());
        issueRequest.setWorkerId(issueDraft.getWorkerId());
        issueRequest.setDeliverDate(issueDraft.getDeliverDate());
        issueRequest.setRemark(issueDraft.getRemark());
        issueRequest.setItems(issueDraft.getItems().stream().map(item -> {
            com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine line =
                    new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();
            line.setLineNo(item.getLineNo());
            line.setGoodsId(item.getGoodsId());
            line.setColorId(item.getColorId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty());
            line.setOrderItemId(item.getOrderItemId());
            line.setPlanItemId(item.getPlanItemId());
            line.setParentGoodsId(item.getParentGoodsId());
            line.setParentColorId(item.getParentColorId());
            line.setWeight(item.getWeight());
            line.setSourceDocNo(item.getSourceDocNo());
            line.setRemark(item.getRemark());
            return line;
        }).toList());
        subcontractMaterialIssueService.update(materialIssueId, issueRequest);
        subcontractMaterialIssueService.approve(materialIssueId);
        assertEquals(0, stockBalance(w.warehouseId(), suppliedMaterial)
                        .compareTo(BigDecimal.ZERO),
                "仓库按冻结 BOM 发出 R×20 后，委外回厂门禁前置完成");

        // 委外商回厂：仓库登记进仓，IQC PASS 才形成合格库存与分析归属。
        com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest receiptRequest =
                new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        receiptRequest.setBillDate(LocalDate.of(2026, 1, 20));
        receiptRequest.setSupplierId(w.supplierId());
        receiptRequest.setWarehouseId(w.warehouseId());
        receiptRequest.setCurrencyId(w.currencyId());
        receiptRequest.setExchangeRate(BigDecimal.ONE);
        receiptRequest.setTaxRate(BigDecimal.ZERO);
        receiptRequest.setSettlementMethodId(
                subcontractOrderSettlementMethodOf(subcontractOrderItemId));
        com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine receiptLine =
                new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
        receiptLine.setGoodsId(subcontracted);
        receiptLine.setOrderItemId(subcontractOrderItemId);
        receiptLine.setUnitId(w.unitId());
        receiptLine.setUnitRate(BigDecimal.ONE);
        receiptLine.setQty(quantity);
        receiptLine.setPrice(new BigDecimal("30"));
        receiptLine.setAmountOriginal(quantity.multiply(new BigDecimal("30")));
        receiptLine.setAmountLocal(quantity.multiply(new BigDecimal("30")));
        receiptRequest.setItems(List.of(receiptLine));
        UUID receiptId = subcontractReceiptService.create(receiptRequest).getId();
        subcontractReceiptService.approve(receiptId);
        assertEquals(0, stockBalance(w.warehouseId(), subcontracted)
                        .compareTo(BigDecimal.ZERO),
                "委外进仓审核只进入 IQC 待检，不得提前形成可用库存");
        UUID inspectionItemId = jdbc.queryForObject("""
                select id
                from procurement_inspection_items
                where receipt_type = 'SUBCONTRACT'
                  and receipt_id = ?
                  and goods_id = ?
                """, UUID.class, receiptId, subcontracted);
        inspectionService.dispose(
                "SUBCONTRACT", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "委外合格验收",
                        "idem-s23c-" + inspectionItemId));

        assertEquals(1, count("""
                        select count(*)
                        from stock_reservations
                        where is_deleted = false
                          and owner_type = 'PREPLAN_ANALYSIS'
                          and owner_id = ?
                          and supply_type = 'SUBCONTRACT_APPLICATION_ITEM'
                          and supply_id = ?
                          and source_doc_type = 'SUBCONTRACT_RECEIPT'
                          and source_doc_id = ?
                          and status = 0
                          and qty = 10
                          and released_qty = 0
                        """, analysisA, applicationItemId, receiptId),
                "委外 IQC PASS 须沿 application_item_id 写回本分析归属预留");
        assertEquals(1, count("""
                        select count(*)
                        from preplan_analysis_stock_exact_pegs peg
                        join preplan_supply_action_allocations allocation
                          on allocation.id = peg.supply_action_allocation_id
                        where peg.origin_analysis_id = ?
                          and peg.origin_analysis_material_id = ?
                          and peg.beneficiary_analysis_id = ?
                          and peg.beneficiary_analysis_material_id = ?
                          and peg.source_receipt_type = 'SUBCONTRACT'
                          and peg.source_receipt_id = ?
                          and peg.qty = 10
                          and allocation.external_item_id = ?
                        """,
                        analysisA, subcontractRow.materialLineId(),
                        analysisA, subcontractRow.materialLineId(),
                        receiptId, applicationItemId),
                "委外合格量还须精确绑定到本次供应分摊对应的物料分析行");
        assertEquals(0, publicAvailable(w.warehouseId(), subcontracted)
                        .compareTo(BigDecimal.ZERO),
                "已绑定分析A的委外合格入库不得泄漏到公共可用量");

        loginAs(planner);
        AnalysisView afterPassView = analysisService.detail(analysisA);
        MaterialView afterPass = afterPassView.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(subcontracted)
                        && material.analysisLineId().equals(targetAnalysisItemId))
                .findFirst().orElseThrow();
        MaterialView siblingAfterPass = afterPassView.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(subcontracted)
                        && material.analysisLineId().equals(siblingAnalysisItemId))
                .findFirst().orElseThrow();
        assertEquals(0, afterPass.availableQty().compareTo(new BigDecimal("10")),
                "来源分析应立即看到合格入库 10");
        assertEquals(0, afterPass.exactPeggedQty().compareTo(new BigDecimal("10")),
                "到货节点应显示精确归属量 10");
        assertEquals(0, afterPass.allocatedAvailableQty().compareTo(new BigDecimal("10")),
                "来源分析应把合格入库分配给对应物料路径");
        assertEquals(0, afterPass.shortageQty().compareTo(BigDecimal.ZERO),
                "来源分析对应委外物料缺口应由 10 清零");
        assertEquals(0, afterPass.warehouseBreakdown().stream()
                        .filter(stock -> stock.warehouseId().equals(w.warehouseId()))
                        .findFirst().orElseThrow().ownPeggedQty()
                        .compareTo(new BigDecimal("10")),
                "仓库分解必须明确展示本分析归属量 10");
        assertEquals(0, siblingAfterPass.availableQty().compareTo(new BigDecimal("10")),
                "availableQty 是分析内同维度可见池，兄弟节点可见但不得据此获得分配");
        assertEquals(0, siblingAfterPass.exactPeggedQty().compareTo(BigDecimal.ZERO),
                "同 SKU 兄弟节点的精确归属显示必须为 0");
        assertEquals(0, siblingAfterPass.allocatedAvailableQty().compareTo(BigDecimal.ZERO),
                "同分析内更早的兄弟产品不得抢占目标节点的合格入库");
        assertEquals(0, siblingAfterPass.shortageQty().compareTo(new BigDecimal("10")),
                "未被供应行动覆盖的兄弟产品仍应缺料 10");

        UUID orderB = createApprovedOrder(w, finished, "10", "100");
        loginAs(planner);
        AnalysisView analysisB = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-s23c-b-" + orderB,
                List.of(new PreviewItem("SALES_ORDER_ITEM", orderItemId(orderB),
                        null, null, null, null, null,
                        LocalDate.of(2026, 9, 2), new BigDecimal("10")))));
        MaterialView otherAnalysisMaterial = analysisB.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(subcontracted))
                .findFirst().orElseThrow();
        assertEquals(0, otherAnalysisMaterial.availableQty().compareTo(BigDecimal.ZERO),
                "分析B不得看到分析A委外合格入库的归属量");
        assertEquals(0, otherAnalysisMaterial.exactPeggedQty().compareTo(BigDecimal.ZERO),
                "其它分析的节点精确归属量必须为 0");
        assertEquals(0, otherAnalysisMaterial.allocatedAvailableQty().compareTo(BigDecimal.ZERO),
                "分析B不得分配分析A的委外合格入库");
        assertEquals(0, otherAnalysisMaterial.shortageQty().compareTo(new BigDecimal("10")),
                "分析B的同物料缺口仍为 10");
    }

    /** v_stock_available 的公共可用量（无仓库行时按 0 处理）。 */
    private BigDecimal publicAvailable(UUID warehouseId, UUID goodsId) {
        return jdbc.query("""
                select GREATEST(available_qty, 0) from v_stock_available
                where warehouse_id = ? and goods_id = ?
                """, (rs, i) -> rs.getBigDecimal(1), warehouseId, goodsId)
                .stream().findFirst().orElse(BigDecimal.ZERO);
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
                "报工只写 fqty；入库前 sales_order_items.produced_qty 仍为 0(进度=入库，非自报)");
        assertEquals(0, bigDecimalFor(
                "select fqty from production_plan_items where id = ?", planItemId)
                .compareTo(new BigDecimal("10")),
                "报工回写 production_plan_items.fqty = 10(自报量，≠ 销售进度)");
        assertEquals(5, itemChainStatusByItem(orderItemId),
                "报工推进订单行 chain_status → 5 生产中");

        // Warehouse approves the auto-generated FINISHED_IN → actual inbound into stock.
        UUID finishedInId = finishedInDocForReport(reportId);
        confirmFinishedInboundFully(finishedInId);

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
                "production_plan_items.iqty = Σ入库 = 10(与 fqty 区分)");
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
        confirmFinishedInboundFully(finishedInDocForReport(report1));
        assertEquals(0, producedQty(orderItemId).compareTo(new BigDecimal("5")),
                "首批入库 5 → produced_qty = 5");
        assertEquals(6, itemChainStatusByItem(orderItemId),
                "部分入库 → chain_status → 6 部分完工");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("5")),
                "首批入库累加到 5");

        // Second batch: report 5 more + inbound 5 → accumulates to 10 (NOT overwrite), chain→7.
        UUID report2 = reportAndApprove(w, planItemId, orderItemId, w.goodsA(), "5");
        confirmFinishedInboundFully(finishedInDocForReport(report2));
        assertEquals(0, producedQty(orderItemId).compareTo(new BigDecimal("10")),
                "二批入库累加 produced_qty 5+5=10(非覆盖)");
        assertEquals(0, reservedQty(orderItemId).compareTo(new BigDecimal("10")),
                "预留累加 reserved_qty = 10");
        assertEquals(7, itemChainStatusByItem(orderItemId),
                "全量入库 → chain_status 6→7 可发货");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(new BigDecimal("10")),
                "二批入库累加到 10(5+5，非覆盖)");
    }

    @Test
    void exactExecutionSegment_partialInboundCanShipWhileSegmentContinuesThenCloses() {
        World w = seedWorld("s24exactpart");
        jdbc.update("""
                UPDATE goods_bom_items
                SET hard_gate = FALSE
                WHERE goods_id = ?
                """, w.goodsA());
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        UUID planItemId = planItemIdFor(planId, w.goodsA());
        UUID orderItemId = orderItemIdOfPlan(planId);
        UUID orderId = orderIdOfItem(orderItemId);

        PlanningPreviewResult preview = planningPackageService.preview(
                planId, w.warehouseId());
        GeneratePlanningPackageRequest confirm =
                new GeneratePlanningPackageRequest();
        confirm.setWarehouseId(w.warehouseId());
        confirm.setIdempotencyKey("idem-s24-exact-part-" + planId);
        confirm.setPreviewFingerprint(preview.fingerprint());
        confirm.setGeneratePurchaseRequest(false);
        PlanningPackageResult confirmed = planningPackageService.confirm(
                planId, confirm);
        UUID segmentId = confirmed.executionSegments().getFirst().segmentId();
        UUID salesAllocationId = jdbc.queryForObject("""
                SELECT id
                FROM execution_segment_sales_allocations
                WHERE execution_segment_id = ?
                  AND sales_order_item_id = ?
                """, UUID.class, segmentId, orderItemId);

        ProductionAssignment assignment = productionAssignment("s24exactpart");
        ExecutionSegmentView current = executionSegmentService.list(planId)
                .stream()
                .filter(segment -> segment.id().equals(segmentId))
                .findFirst()
                .orElseThrow();
        ExecutionSegmentView assigned = executionSegmentService.assign(
                planId,
                segmentId,
                new SegmentAssignmentRequest(
                        current.lockVersion(),
                        "idem-s24-exact-assign",
                        assignment.workshopId(),
                        null,
                        assignment.workerId(),
                        LocalDate.of(2026, 1, 25),
                        LocalDate.of(2026, 1, 31)));
        ExecutionSegmentView dispatched = executionSegmentService.dispatch(
                planId,
                segmentId,
                new SegmentTransitionRequest(
                        assigned.lockVersion(),
                        "idem-s24-exact-dispatch"));
        executionSegmentService.start(
                planId,
                segmentId,
                new SegmentTransitionRequest(
                        dispatched.lockVersion(),
                        "idem-s24-exact-start"));

        UUID report1 = reportAndApproveExecutionSegment(
                w, planItemId, orderItemId, w.goodsA(),
                segmentId, salesAllocationId, "5");
        UUID finishedIn1 = finishedInDocForReport(report1);
        assertTrue(count("""
                SELECT count(*)
                FROM business_outbox
                WHERE event_type = 'PRODUCTION_FINISHED_INBOUND_PENDING'
                  AND aggregate_id = ?
                """, finishedIn1) >= 1,
                "首批报工生成 FINISHED_IN 草稿后形成仓库待审核 outbox 任务");
        UUID residualFinishedIn = confirmFinishedInboundPartially(
                finishedIn1,
                new BigDecimal("1"),
                "首轮实物仅到仓 1 件");
        assertEquals(
                0,
                bigDecimalFor(
                        "SELECT iqty FROM production_plan_items WHERE id = ?",
                        planItemId)
                        .compareTo(BigDecimal.ONE),
                "计划 10、仓库首轮实收 1，权威入库完成率为 10%");
        confirmFinishedInboundFully(residualFinishedIn);

        assertEquals("IN_PROGRESS", strFor("""
                SELECT status
                FROM production_execution_segments
                WHERE id = ?
                """, segmentId),
                "计划 10 的同一执行段首批只入库 5，仍继续生产");
        assertEquals(0, producedQty(orderItemId).compareTo(new BigDecimal("5")));
        assertEquals(0, reservedQty(orderItemId).compareTo(new BigDecimal("5")),
                "首批只增加本批 5 的成品销售预留");
        assertEquals(0, bigDecimalFor("""
                SELECT SUM(qty)
                FROM stock_reservations
                WHERE source_doc_type = 'PRODUCTION_INBOUND'
                  AND source_doc_id = ?
                  AND order_item_id = ?
                  AND is_deleted = FALSE
                """, finishedIn1, orderItemId).compareTo(BigDecimal.ONE),
                "首张入库单只形成实收 1 的预留");
        assertEquals(0, bigDecimalFor("""
                SELECT SUM(qty)
                FROM stock_reservations
                WHERE source_doc_type = 'PRODUCTION_INBOUND'
                  AND source_doc_id = ?
                  AND order_item_id = ?
                  AND is_deleted = FALSE
                """, residualFinishedIn, orderItemId)
                .compareTo(new BigDecimal("4")),
                "短收余量单点收 4 后形成独立精确预留");
        assertEquals("1", strFor("""
                SELECT payload -> 'allocations' -> 0 ->> 'batchQty'
                FROM business_outbox
                WHERE event_type = 'PRODUCTION_FINISHED_INBOUND'
                  AND aggregate_id = ?
                ORDER BY created_at DESC
                LIMIT 1
                """, finishedIn1),
                "首张完工通知冻结实收 1，不在异步投递时重算");
        assertEquals("4", strFor("""
                SELECT payload -> 'allocations' -> 0 ->> 'batchQty'
                FROM business_outbox
                WHERE event_type = 'PRODUCTION_FINISHED_INBOUND'
                  AND aggregate_id = ?
                ORDER BY created_at DESC
                LIMIT 1
                """, residualFinishedIn),
                "余量单完工通知冻结后续实收 4");
        assertFalse(Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT is_closed FROM production_plans WHERE id = ?",
                Boolean.class, planId)),
                "首批入库后原生产计划仍未完成");

        UUID firstShipment = createShipment(
                w, orderItemId, w.goodsA(), "5");
        assertTrue(count("""
                SELECT count(*)
                FROM business_outbox
                WHERE event_type = 'SALES_SHIPMENT_PENDING_PICK'
                  AND aggregate_id = ?
                """, firstShipment) >= 1,
                "部分发货草稿形成仓库待拣货 outbox 任务");
        shipThroughWarehouse(firstShipment);
        assertEquals(0, shippedQty(orderItemId).compareTo(new BigDecimal("5")));
        assertEquals(0, reservedQty(orderItemId).compareTo(BigDecimal.ZERO));
        assertFalse(orderIsClosed(orderId),
                "首批成品发货后订单保留未交 5，不提前关闭");
        assertEquals("IN_PROGRESS", strFor("""
                SELECT status
                FROM production_execution_segments
                WHERE id = ?
                """, segmentId));

        UUID report2 = reportAndApproveExecutionSegment(
                w, planItemId, orderItemId, w.goodsA(),
                segmentId, salesAllocationId, "5");
        UUID finishedIn2 = finishedInDocForReport(report2);
        confirmFinishedInboundFully(finishedIn2);
        assertEquals("COMPLETED", strFor("""
                SELECT status
                FROM production_execution_segments
                WHERE id = ?
                """, segmentId),
                "累计入库达到执行段计划 10 后才完成");
        assertEquals(0, producedQty(orderItemId).compareTo(new BigDecimal("10")));
        assertEquals(0, reservedQty(orderItemId).compareTo(new BigDecimal("5")),
                "第二批入库仅补回尚未发出的本批 5");
        assertTrue(Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT is_closed FROM production_plans WHERE id = ?",
                Boolean.class, planId)),
                "累计成品入库完成后生产计划结案");

        shipThroughWarehouse(createShipment(
                w, orderItemId, w.goodsA(), "5"));
        assertEquals(0, shippedQty(orderItemId).compareTo(new BigDecimal("10")));
        assertEquals(0, reservedQty(orderItemId).compareTo(BigDecimal.ZERO));
        assertTrue(orderIsClosed(orderId),
                "最终未交数量发完后销售订单才关闭");
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
                "SHIPPED 内联过账 AR(ar_ap_ledger)");
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
                "二批发货累加 shipped_qty 5+5=10(非覆盖)");
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
                "事件溯源不变量：stock_balances.qty == Σ(qty×direction)(" + ledger + " vs " + balance + ")");
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
                "超发被拒 → shipped_qty 仍为 0(无副作用)");
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsA()).compareTo(stockBefore),
                "超发被拒 → 库存不变(原子回滚，未穿底)");
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

        stockDocService.reverseFinishedInbound(finishedInId);

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
                "红冲 → chain_status 7→4 已排产(精确回退，非粗重置)");
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
    // #27 (amount correctness — AR) Shipping posts original currency from the shipment snapshot,
    // while SHIPPED revalues local currency using finance's current active master rate. The AR starts
    // wholly outstanding and carries an immutable per-order source snapshot for later receipt/report
    // traceability. BigDecimal NUMERIC arithmetic keeps both currency lanes deterministic.
    // ---------------------------------------------------------------------------------------------
    @Test
    void amounts_arFromShipmentMatchesTotalAndStartsUnsettled() {
        World w = seedWorld("s27ar");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        String orderNo = strFor("select bill_no from sales_orders where id = ?", orderId);
        loginAs(w.superAdminUserId());
        // ship 10 @ price 100, discount 1 → line amount 1000 (set in shipmentRequest)
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        // SHIPPED snapshots current active client defaults when the shipment has no override.
        jdbc.update(
                "update clients set default_settlement_method_id = ?, tday = 30 where id = ?",
                UUID.fromString("27300000-0000-4000-8100-000000000006"),
                w.clientId());
        // Draft snapshots rate 1. Finance changes the maintained master rate before SHIPPED.
        BigDecimal financeRate = new BigDecimal("1.250000");
        jdbc.update("update currencies set exchange_rate = ? where id = ?", financeRate, w.currencyId());
        shipThroughWarehouse(shipmentId);

        BigDecimal expectedOriginal = new BigDecimal("1000.0000");
        BigDecimal expectedLocal = new BigDecimal("1250.0000");
        assertEquals(0, bigDecimalFor(
                "select total_original from sales_shipments where id = ?", shipmentId)
                .compareTo(expectedOriginal),
                "发运原币 = 量×价×折扣 = " + expectedOriginal);
        assertEquals(0, bigDecimalFor(
                "select exchange_rate from sales_shipments where id = ?", shipmentId)
                .compareTo(financeRate),
                "SHIPPED 快照财务维护的有效汇率");
        assertEquals(0, bigDecimalFor(
                "select total_local from sales_shipments where id = ?", shipmentId)
                .compareTo(expectedLocal),
                "SHIPPED 按财务主档汇率重算本币 = 原币×1.25");

        BigDecimal arOriginalLocal = bigDecimalFor(
                "select amount_original_local from ar_ap_ledger "
                        + "where direction = 'AR' and source_doc_type = 'SALES_SHIPMENT' "
                        + "and source_doc_id = ?", shipmentId);
        assertEquals(0, arOriginalLocal.compareTo(expectedLocal),
                "AR 本币金额采用 SHIPPED 时的财务汇率重算结果");
        BigDecimal arOriginal = bigDecimalFor(
                "select amount_original from ar_ap_ledger where source_doc_id = ?", shipmentId);
        assertEquals(0, arOriginal.compareTo(expectedOriginal),
                "AR 原币金额 = shipment.total_original，不回退为本币");
        // unsettled at posting: both local and original balances start wholly outstanding
        assertEquals(0, bigDecimalFor(
                "select amount_balance from ar_ap_ledger where source_doc_id = ?", shipmentId)
                .compareTo(arOriginalLocal),
                "立账时 amount_balance = amount_original_local(未核销)");
        assertEquals(0, bigDecimalFor(
                "select amount_balance_original from ar_ap_ledger where source_doc_id = ?", shipmentId)
                .compareTo(arOriginal),
                "立账时原币未收 = 原币应收");
        assertEquals(0, bigDecimalFor(
                "select amount_settled from ar_ap_ledger where source_doc_id = ?", shipmentId)
                .compareTo(BigDecimal.ZERO),
                "立账时 amount_settled = 0");
        assertEquals(0, bigDecimalFor(
                "select amount_received_original from ar_ap_ledger where source_doc_id = ?", shipmentId)
                .compareTo(BigDecimal.ZERO),
                "立账时原币已收 = 0");
        assertEquals(1, count(
                "select count(*) from ar_ap_source_refs r "
                        + "join ar_ap_ledger l on l.id = r.ledger_id "
                        + "where l.source_doc_id = ? and r.source_type = 'SALES_ORDER' "
                        + "and r.source_id = ? and r.source_no = ?",
                shipmentId, orderId, orderNo),
                "AR 保存对应销售订单 ID/单号来源快照");
        assertEquals(0, bigDecimalFor(
                "select r.amount_original from ar_ap_source_refs r "
                        + "join ar_ap_ledger l on l.id = r.ledger_id where l.source_doc_id = ?",
                shipmentId).compareTo(expectedOriginal),
                "订单来源快照原币金额 = 本次发运该订单原币金额");
        assertEquals(0, bigDecimalFor(
                "select r.amount_local from ar_ap_source_refs r "
                        + "join ar_ap_ledger l on l.id = r.ledger_id where l.source_doc_id = ?",
                shipmentId).compareTo(expectedLocal),
                "订单来源快照本币金额使用相同财务汇率");
        assertEquals(6, intFor(
                "select settlement_style_legacy from ar_ap_ledger where source_doc_id = ?", shipmentId),
                "出货单未覆盖时，AR 结账方式快照取客户 price_style");
        assertEquals(LocalDate.of(2026, 2, 1).plusDays(30), jdbc.queryForObject(
                "select due_date from ar_ap_ledger where source_doc_id = ?",
                LocalDate.class, shipmentId),
                "AR 到期日 = 发运单据日 + 客户正数账期，不使用最后操作日");
        assertEquals(3, intFor(
                "select legacy_bstyle from ar_ap_ledger where source_doc_id = ?", shipmentId),
                "销售出货 AR 的 legacy_bstyle = 3");
    }

    // ---------------------------------------------------------------------------------------------
    // #27 (receivable settlement — V236 收款核销, real DB) Ship posts AR, then a sales receipt
    // references that AR with a cash amount + a fee write-off. Approval must, inside the pessimistic
    // lock, recompute everything server-side and update the AR cumulative received/write-off/original
    // balance, snapshot the line before/after balances, increase the receipt account by the CASH
    // actually received (fees only offset AR, never masquerade as cash), write one reconciliation row,
    // and enforce header fees == Σ line write-off-local. A second receipt settles the remainder
    // (is_settled); red-flushing the first receipt symmetrically restores every cumulative. This is
    // the V236 path the mock FinanceReceiptSettlementTest cannot exercise against a real shipment→AR.
    // ---------------------------------------------------------------------------------------------
    @Test
    void receivableSettlement_appliesCashAndWriteOffUpdatesArAccountAndReconThenReverses() {
        World w = seedWorld("recv");
        // (1) ship 10 @ ¥100 (CNY rate 1) → AR original=1000 / local=1000, wholly outstanding.
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        loginAs(w.superAdminUserId());
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId);
        UUID arId = jdbc.queryForObject(
                "select id from ar_ap_ledger where source_doc_type='SALES_SHIPMENT' and source_doc_id=?",
                UUID.class, shipmentId);
        assertEquals(0, bigDecimalFor("select amount_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("1000")), "AR 原币应收 = 10×100");
        assertEquals(0, bigDecimalFor("select amount_balance_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("1000")), "立账时原币未收 = 原币应收");
        assertEquals(0, bigDecimalFor("select amount_received_original from ar_ap_ledger where id=?", arId)
                .compareTo(BigDecimal.ZERO), "立账时原币已收 = 0");

        // (2) seed a CNY receipt account + an active EXPENSE style for 其它费用.
        UUID accountId = UUID.randomUUID();
        UUID accountStyleId = UUID.randomUUID();
        jdbc.update("insert into payment_styles(id, code, name, category, level, status) "
                        + "values (?, 'TEST-BANK-RECV', '测试收款账户科目', 'ACCOUNT', 0, '使用')",
                accountStyleId);
        jdbc.update("insert into accounts(id, code, name, account_type, currency_id, status, style_id) "
                        + "values (?, 'BANK-recv', '测试收款账户', 'BANK', ?, '使用', ?)",
                accountId, w.currencyId(), accountStyleId);
        UUID expenseStyleId = UUID.randomUUID();
        jdbc.update("insert into payment_styles(id, code, name, category, level, status) "
                        + "values (?, 'TEST-FEE-recv', '测试费用项目', 'EXPENSE', 0, '使用')", expenseStyleId);
        UUID approver = createUserWithPerms(
                w, "fin-approver", "finance_receipt:edit",
                "finance_receipt:approve", "finance_receipt:reverse");

        // (3) receipt #1: customer settles CNY 600 gross; CNY 40 fees are
        //     deducted from proceeds, so the real account posting is CNY 560.
        loginAs(w.superAdminUserId());
        UUID receiptId = receiptService.create(receiptRequest(w, arId, accountId, expenseStyleId,
                "600", "40", "25", "15", BigDecimal.ONE, BusinessTime.today())).getId();
        // (4) A different user with feature permission but no finance object scope cannot discover
        //     or approve the maker's receipt. Delegate the maker explicitly, then approve.
        loginAs(approver);
        assertEquals(ErrorCode.NOT_FOUND,
                assertThrows(ApiException.class, () -> receiptService.detail(receiptId)).getCode(),
                "未授权财务对象不得泄漏单据存在性");
        assertEquals(ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class, () -> receiptService.approve(receiptId)).getCode(),
                "仅有功能权限不得审核他人财务单据");
        grantDataScope(approver, "finance", w.employeeId());
        receiptService.approve(receiptId);

        // AR cash settlement stays gross 600; fees never reduce AR separately.
        assertEquals(0, bigDecimalFor("select amount_received_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("600")), "审核后 AR 原币累计到账 += 600");
        assertEquals(0, bigDecimalFor("select amount_received_local from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("600")), "审核后 AR 本币累计到账 += 600");
        assertEquals(0, bigDecimalFor("select amount_write_off_original from ar_ap_ledger where id=?", arId)
                .compareTo(BigDecimal.ZERO), "审核后 AR 商业冲销仍为 0");
        assertEquals(0, bigDecimalFor("select amount_write_off_local from ar_ap_ledger where id=?", arId)
                .compareTo(BigDecimal.ZERO), "审核后 AR 本币商业冲销仍为 0");
        assertEquals(0, bigDecimalFor("select amount_balance_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("400")), "原币未收 = 1000 − 600 = 400");
        assertEquals(0, bigDecimalFor("select amount_settled from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("600")), "本币累计已核销 = 600×开账汇率1");
        assertFalse(jdbc.queryForObject("select is_settled from ar_ap_ledger where id=?", Boolean.class, arId),
                "未收完 → is_settled=false");
        // line before/after balance snapshots
        assertEquals(0, bigDecimalFor(
                "select balance_before_original from finance_receipt_lines where receipt_id=?", receiptId)
                .compareTo(new BigDecimal("1000")), "明细审核前余额快照 = 1000");
        assertEquals(0, bigDecimalFor(
                "select balance_after_original from finance_receipt_lines where receipt_id=?", receiptId)
                .compareTo(new BigDecimal("400")), "明细审核后余额快照 = 400");
        // account increases only by the bank-posted net amount 600-40=560.
        assertEquals(0, bigDecimalFor("select balance_current from accounts where id=?", accountId)
                .compareTo(new BigDecimal("560")), "账户只增实际净到账 560");
        assertEquals(0, bigDecimalFor("select receipts_total from accounts where id=?", accountId)
                .compareTo(new BigDecimal("560")), "账户 receipts_total += 560");
        // one receipt posting row, in_amount = bank net 560.
        assertEquals(1, count("select count(*) from finance_reconciliations "
                        + "where source_doc_type='RECEIPT' and source_doc_id=?", receiptId),
                "收款审核写 1 条账户流水");
        assertEquals(0, bigDecimalFor("select in_amount from finance_reconciliations where source_doc_id=?", receiptId)
                .compareTo(new BigDecimal("560")), "流水 in_amount = 实际净到账 560");
        assertEquals(1, intFor("select status from finance_receipts where id=?", receiptId), "收款单 status 0→1 已审");
        assertEquals(0, bigDecimalFor("select amount_local from finance_receipts where id=?", receiptId)
                .compareTo(new BigDecimal("600")), "收款单头本币毛额 = 600");
        assertEquals(1,count("""
                select count(*) from gl_vouchers
                where source='AUTO' and source_type='RECEIPT' and source_doc_id=?
                """,receiptId),"审核事务已生成收款AUTO凭证");
        assertEquals(0,bigDecimalFor("""
                select sum(entry.direction*entry.amount)
                from gl_entries entry join gl_vouchers voucher on voucher.id=entry.voucher_id
                where voucher.source_type='RECEIPT' and voucher.source_doc_id=?
                """,receiptId).compareTo(BigDecimal.ZERO),"收款AUTO凭证借贷平衡");
        assertTrue(jdbc.queryForObject(
                "select is_consistent from v_receipt_flow_integrity where receipt_id=?",
                Boolean.class,receiptId),"审核后收款账户流水与冻结金额快照一致");

        UUID receiptVoucherId=jdbc.queryForObject("""
                select id from gl_vouchers
                where source='AUTO' and source_type='RECEIPT' and source_doc_id=?
                """,UUID.class,receiptId);
        UUID receiptStyleId=jdbc.queryForObject("""
                select style_id from gl_entries where voucher_id=? order by line_no limit 1
                """,UUID.class,receiptVoucherId);
        assertThrows(DataAccessException.class,()->jdbc.update("""
                insert into gl_entries(
                  voucher_id,line_no,style_id,direction,amount,entry_date,period,
                  source_doc_type,source_doc_id,source_bill_no,summary)
                values (?,9999,?,1,1,?,?, 'RECEIPT',?,?, '非法追加')
                """,receiptVoucherId,receiptStyleId,BusinessTime.today(),
                BusinessTime.today().toString().substring(0,7),receiptId,
                strFor("select bill_no from finance_receipts where id=?",receiptId)),
                "已终态收款凭证禁止直接追加分录");
        assertThrows(DataAccessException.class,()->jdbc.update(
                "update finance_receipts set is_deleted=true,deleted_at=now() where id=?",
                receiptId),"已审收款禁止直接软删以逃避完整性视图");

        UUID ordinaryVoucher=UUID.randomUUID();
        UUID ordinaryEntry=UUID.randomUUID();
        jdbc.update("""
                insert into gl_vouchers(
                  id,voucher_no,period,voucher_date,source,source_type,remark)
                values (?,?,?,?,'MANUAL','MANUAL','不可变绕过测试')
                """,ordinaryVoucher,"MANUAL-"+ordinaryVoucher,
                BusinessTime.today().toString().substring(0,7),BusinessTime.today());
        jdbc.update("""
                insert into gl_entries(
                  id,voucher_id,line_no,style_id,direction,amount,entry_date,period,summary)
                values (?,?,1,?,1,1,?,?,'普通分录')
                """,ordinaryEntry,ordinaryVoucher,receiptStyleId,BusinessTime.today(),
                BusinessTime.today().toString().substring(0,7));
        assertThrows(DataAccessException.class,()->jdbc.update("""
                update gl_vouchers set source='AUTO',source_type='RECEIPT',source_doc_id=?
                where id=?
                """,receiptId,ordinaryVoucher),"普通凭证禁止 UPDATE 成收款凭证");
        assertThrows(DataAccessException.class,()->jdbc.update(
                "update gl_entries set voucher_id=? where id=?",
                receiptVoucherId,ordinaryEntry),"普通分录禁止搬入已终态收款凭证");
        jdbc.update("delete from gl_vouchers where id=?",ordinaryVoucher);

        // (5) receipt #2: collect the remaining ¥400, no fees → AR fully settled.
        loginAs(w.superAdminUserId());
        UUID receipt2Id = receiptService.create(receiptRequest(w, arId, accountId, null,
                "400", "0", "0", "0", BigDecimal.ONE, BusinessTime.today())).getId();
        loginAs(approver);
        receiptService.approve(receipt2Id);
        assertEquals(0, bigDecimalFor("select amount_balance_original from ar_ap_ledger where id=?", arId)
                .compareTo(BigDecimal.ZERO), "二笔收完 → 原币未收 = 0");
        assertTrue(jdbc.queryForObject("select is_settled from ar_ap_ledger where id=?", Boolean.class, arId),
                "收完 → is_settled=true");
        assertEquals(0, bigDecimalFor("select balance_current from accounts where id=?", accountId)
                .compareTo(new BigDecimal("960")), "账户累加净额 560+400=960");

        // (6) 红冲走后进先出：先反转 receipt2 的 400，再反转 receipt1 的
        //     gross AR 600 / net bank 560；账户流水追加 REVERSAL 而不删除 POSTING。
        receiptService.reverse(receipt2Id);
        assertEquals(0, bigDecimalFor("select amount_received_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("600")), "红冲receipt2 → 原币到账 1000−400=600");
        assertEquals(0, bigDecimalFor("select balance_current from accounts where id=?", accountId)
                .compareTo(new BigDecimal("560")), "红冲receipt2 → 账户 960−400=560");
        assertEquals(-1, intFor("select status from finance_receipts where id=?", receipt2Id),
                "红冲receipt2 → status=−1");
        receiptService.reverse(receiptId);
        assertEquals(0, bigDecimalFor("select amount_received_original from ar_ap_ledger where id=?", arId)
                .compareTo(BigDecimal.ZERO), "红冲receipt1 → 原币到账 600−600=0");
        assertEquals(0, bigDecimalFor("select amount_write_off_original from ar_ap_ledger where id=?", arId)
                .compareTo(BigDecimal.ZERO), "红冲receipt1 → 商业冲销保持0");
        assertEquals(0, bigDecimalFor("select amount_balance_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("1000")), "红冲receipt1 → 原币未收 1000−0=1000");
        assertFalse(jdbc.queryForObject("select is_settled from ar_ap_ledger where id=?", Boolean.class, arId),
                "红冲后未清 → is_settled=false");
        assertEquals(0, bigDecimalFor("select balance_current from accounts where id=?", accountId)
                .compareTo(BigDecimal.ZERO), "红冲receipt1 → 账户 560−560=0");
        assertEquals(-1, intFor("select status from finance_receipts where id=?", receiptId), "红冲 → status=−1");
        assertEquals(2, count("select count(*) from finance_reconciliations "
                        + "where source_doc_type='RECEIPT' and source_doc_id=?", receiptId),
                "红冲receipt1 → 保留POSTING并追加REVERSAL");
        assertEquals(0, bigDecimalFor("""
                        select sum(in_amount-out_amount) from finance_reconciliations
                        where source_doc_type='RECEIPT' and source_doc_id=?
                        """,receiptId).compareTo(BigDecimal.ZERO),
                "原始收款与反向流水净额为0");
        assertEquals(1,count("""
                select count(*) from gl_vouchers
                where source='AUTO' and source_type='RECEIPT'
                  and source_doc_id=? and status=1 and is_deleted=false
                """,receiptId),"红冲后原始收款凭证仍保留");
        assertEquals(1,count("""
                select count(*) from gl_vouchers
                where source='AUTO' and source_type='RECEIPT_REV'
                  and source_doc_id=? and status=1 and is_deleted=false
                """,receiptId),"红冲追加且只追加一张 RECEIPT_REV 凭证");
        assertEquals(count("""
                select count(*) from gl_entries entry
                join gl_vouchers voucher on voucher.id=entry.voucher_id
                where voucher.source_type='RECEIPT' and voucher.source_doc_id=?
                  and entry.is_deleted=false
                """,receiptId),count("""
                select count(*)
                from gl_vouchers original
                join gl_vouchers reversal on reversal.reversal_of_voucher_id=original.id
                join gl_entries original_entry on original_entry.voucher_id=original.id
                join gl_entries reversal_entry
                  on reversal_entry.voucher_id=reversal.id
                 and reversal_entry.line_no=original_entry.line_no
                 and reversal_entry.style_id=original_entry.style_id
                 and reversal_entry.direction=-original_entry.direction
                 and reversal_entry.amount=original_entry.amount
                where original.source_type='RECEIPT' and original.source_doc_id=?
                  and original_entry.is_deleted=false and reversal_entry.is_deleted=false
                """,receiptId),"总账反向凭证逐行镜像原凭证");
        assertTrue(jdbc.queryForObject(
                "select is_consistent from v_receipt_gl_integrity where receipt_id=?",
                Boolean.class,receiptId),"收款、原凭证与反向凭证完整性视图一致");
        assertTrue(jdbc.queryForObject(
                "select is_consistent from v_receipt_flow_integrity where receipt_id=?",
                Boolean.class,receiptId),"红冲后账户原流水与反向流水完整镜像");
    }

    // ---------------------------------------------------------------------------------------------
    // #27 (receivable settlement guards) Cross-currency line, over-collect and
    // fee/write-off mixing must each
    // be rejected at approval (inside the pessimistic lock), leaving the AR untouched. Proves the
    // V407 settlement cannot be abused to collect more than owed, settle in the
    // wrong currency, or disguise fees as an AR commercial write-off.
    // ---------------------------------------------------------------------------------------------
    @Test
    void receivableSettlement_rejectsCrossCurrencyOvercollectAndFeeMismatch() {
        World w = seedWorld("recvguard");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        loginAs(w.superAdminUserId());
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId);
        UUID arId = jdbc.queryForObject(
                "select id from ar_ap_ledger where source_doc_type='SALES_SHIPMENT' and source_doc_id=?",
                UUID.class, shipmentId);
        UUID accountId = UUID.randomUUID();
        UUID accountStyleId = UUID.randomUUID();
        jdbc.update("insert into payment_styles(id, code, name, category, level, status) "
                        + "values (?, 'TEST-BANK-RECVG', '测试收款账户科目-G', 'ACCOUNT', 0, '使用')",
                accountStyleId);
        jdbc.update("insert into accounts(id, code, name, account_type, currency_id, status, style_id) "
                        + "values (?, 'BANK-recvg', '测试收款账户', 'BANK', ?, '使用', ?)",
                accountId, w.currencyId(), accountStyleId);
        UUID expenseStyleId = UUID.randomUUID();
        jdbc.update("insert into payment_styles(id, code, name, category, level, status) "
                        + "values (?, 'TEST-FEE-recvg', '测试费用项目', 'EXPENSE', 0, '使用')", expenseStyleId);
        UUID usdId = UUID.randomUUID();
        jdbc.update("insert into currencies(id, code, name, exchange_rate, status) "
                        + "values (?, 'USD-recvg', '美元', 7, '使用')", usdId);
        UUID approver = createUserWithPerms(
                w, "fin-approver-g", "finance_receipt:edit", "finance_receipt:approve");
        grantDataScope(approver, "finance", w.employeeId());

        // (a) cross-currency: line currency ≠ AR currency → rejected at SAVE (saveLines enforces
        //     same-currency-as-AR before the receipt is even persisted; approve is never reached).
        loginAs(w.superAdminUserId());
        com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest crossReq = receiptRequest(
                w, arId, accountId, null, "100", "0", "0", "0",
                BigDecimal.ONE, BusinessTime.today());
        crossReq.getItems().get(0).setCurrencyId(usdId);
        ApiException cross = assertThrows(ApiException.class, () -> receiptService.create(crossReq));
        assertTrue(cross.getMessage().contains("核销原币必须与应收币种一致"),
                "核销原币与应收币种不一致在保存时即被拒: " + cross.getMessage());

        // (b) over-collect: cash 1100 > 未收 1000 → rejected.
        loginAs(w.superAdminUserId());
        UUID rOver = receiptService.create(receiptRequest(w, arId, accountId, null,
                "1100", "0", "0", "0", BigDecimal.ONE, BusinessTime.today())).getId();
        loginAs(approver);
        ApiException over = assertThrows(ApiException.class, () -> receiptService.approve(rOver));
        assertTrue(over.getMessage().contains("超过应收未收"), "超收被拒: " + over.getMessage());

        // (c) V1 line write-off is rejected before persistence; fees use header snapshots.
        loginAs(w.superAdminUserId());
        var mixed=receiptRequest(w,arId,accountId,null,
                "100","0","0","0",BigDecimal.ONE,BusinessTime.today());
        mixed.getItems().getFirst().setWriteOffAmount(new BigDecimal("50"));
        ApiException mis=assertThrows(ApiException.class,()->receiptService.create(mixed));
        assertTrue(mis.getMessage().contains("不能把手续费"),"费用/write-off混用被拒: "+mis.getMessage());

        // all three rejections left the AR untouched (still wholly outstanding).
        assertEquals(0, bigDecimalFor("select amount_received_original from ar_ap_ledger where id=?", arId)
                .compareTo(BigDecimal.ZERO), "三次拒绝均未改 AR 累计到账");
        assertEquals(0, bigDecimalFor("select amount_balance_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("1000")), "AR 原币未收仍为 1000");
    }

    @Test
    void historicalV0ApprovedReceiptWithoutGlIsVisibleAndBlocksRegeneration() {
        World w=seedWorld("receipt-v0-gl-gap");
        loginAs(w.superAdminUserId());
        UUID receiptId=UUID.randomUUID();
        String billNo=docNumberService.nextNumber(
                com.uten.imp.common.docnumber.DocNumberPrefix.FIN_RECEIPT);
        jdbc.update("""
                insert into finance_receipts(
                  id,bill_no,bill_date,receipt_kind,client_id,currency_id,
                  exchange_rate,amount_original,amount_local,bank_fee,other_fee,
                  status,settlement_authority_version,is_deleted)
                values (?,?,?,'CUSTOMER_PREPAYMENT',?,?,1,100,100,0,0,1,0,false)
                """,receiptId,billNo,BusinessTime.today(),w.clientId(),w.currencyId());

        assertEquals("MISSING",strFor("""
                select reconciliation_state
                from v_receipt_v0_gl_reconciliation where receipt_id=?
                """,receiptId),"历史 V0 已审收款缺凭证必须进入异常队列");
        ApiException blocked=assertThrows(ApiException.class,()->
                glPostingService.generate(BusinessTime.today().toString().substring(0,7)));
        assertTrue(blocked.getMessage().contains("历史 V0 已审收款"),blocked.getMessage());
        assertTrue(blocked.getMessage().contains("禁止按当前科目自动补账"),blocked.getMessage());
    }

    // ---------------------------------------------------------------------------------------------
    // #27 (receivable settlement — V236 外币收款 + 汇兑差, real DB) A foreign-currency AR posted at the
    // 开账汇率 is settled by a receipt whose 到账汇率 differs. The server must keep BOTH currency lanes
    // authoritative and distinct: 累计到账本币 uses the 到账汇率, 累计已核销(账面) uses the 开账汇率, and the
    // row-level 汇兑差额 is their difference. This is the FX path the CNY settlement test above and the
    // mock FinanceReceiptSettlementTest do not exercise against a real shipment→AR chain.
    // ---------------------------------------------------------------------------------------------
    @Test
    void receivableSettlement_foreignCurrencyAppliesArrivalRateAndRecognizesExchangeDiff() {
        World w = seedWorld("recvfx");
        // turn the seeded currency into a foreign currency (USD) at posting rate 7.0
        jdbc.update("update currencies set code='USD-fx', name='美元', exchange_rate=7 where id=?", w.currencyId());
        // ship 10 @ $100 → AR posted at 开账汇率 7.0: original $1000 / local ¥7000
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        loginAs(w.superAdminUserId());
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId); // SHIPPED re-locks the maintained 7.0 rate
        UUID arId = jdbc.queryForObject(
                "select id from ar_ap_ledger where source_doc_type='SALES_SHIPMENT' and source_doc_id=?",
                UUID.class, shipmentId);
        assertEquals(0, bigDecimalFor("select amount_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("1000")), "AR 原币应收 $1000");
        assertEquals(0, bigDecimalFor("select amount_original_local from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("7000")), "AR 本币 = 1000×开账汇率7 = 7000");
        assertEquals(0, bigDecimalFor("select exchange_rate from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("7")), "AR 开账汇率 = 7.0");

        // USD receipt account (same currency → adjustAccount records 原币) + a distinct approver.
        UUID accountId = UUID.randomUUID();
        UUID accountStyleId = UUID.randomUUID();
        jdbc.update("insert into payment_styles(id, code, name, category, level, status) "
                        + "values (?, 'TEST-BANK-FX', '美元账户科目', 'ACCOUNT', 0, '使用')",
                accountStyleId);
        jdbc.update("insert into accounts(id, code, name, account_type, currency_id, status, style_id) "
                        + "values (?, 'BANK-fx', '美元账户', 'BANK', ?, '使用', ?)",
                accountId, w.currencyId(), accountStyleId);
        UUID approver = createUserWithPerms(
                w, "fin-fx", "finance_receipt:edit", "finance_receipt:approve");
        grantDataScope(approver, "finance", w.employeeId());

        // receipt: collect $600 at 到账汇率 7.2 (≠ 开账 7.0) → 汇兑收益 120, no fees.
        loginAs(w.superAdminUserId());
        UUID receiptId = receiptService.create(receiptRequest(w, arId, accountId, null,
                "600", "0", "0", "0", new BigDecimal("7.2"), BusinessTime.today())).getId();
        loginAs(approver);
        receiptService.approve(receiptId);

        // server-authoritative dual-currency settlement:
        //   到账本币 = 600 × 7.2 = 4320 ; 账面冲减 = 600 × 7.0 = 4200 ; 汇兑差额 = 120 (收益)
        assertEquals(0, bigDecimalFor("select amount_received_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("600")), "原币累计到账 $600");
        assertEquals(0, bigDecimalFor("select amount_received_local from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("4320")), "本币累计到账 = 600×到账汇率7.2 = 4320");
        assertEquals(0, bigDecimalFor("select amount_settled from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("4200")), "本币累计已核销(账面) = 600×开账汇率7.0 = 4200");
        assertEquals(0, bigDecimalFor("select amount_balance_original from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("400")), "原币未收 = 1000−600 = $400");
        assertEquals(0, bigDecimalFor("select amount_balance from ar_ap_ledger where id=?", arId)
                .compareTo(new BigDecimal("2800")), "本币未收 = 7000−4200 = 2800");
        // line-level authoritative recomputation matches the ledger
        assertEquals(0, bigDecimalFor("select amount_local from finance_receipt_lines where receipt_id=?", receiptId)
                .compareTo(new BigDecimal("4320")), "明细到账本币 = 4320");
        assertEquals(0, bigDecimalFor("select applied_amount_local from finance_receipt_lines where receipt_id=?", receiptId)
                .compareTo(new BigDecimal("4200")), "明细账面冲减 = 4200");
        assertEquals(0, bigDecimalFor("select exchange_diff from finance_receipt_lines where receipt_id=?", receiptId)
                .compareTo(new BigDecimal("120")), "明细汇兑差额 = 120(收益)");
        assertEquals(0,bigDecimalFor("""
                select sum(entry.direction*entry.amount)
                from gl_entries entry join gl_vouchers voucher on voucher.id=entry.voucher_id
                where voucher.source_type='RECEIPT' and voucher.source_doc_id=?
                """,receiptId).compareTo(BigDecimal.ZERO),"外币收款AUTO凭证借贷平衡");
        assertEquals(0,bigDecimalFor("""
                select amount from gl_entries
                where source_doc_type='RECEIPT' and source_doc_id=?
                  and summary='收款汇兑损益'
                """,receiptId).compareTo(new BigDecimal("120")),
                "外币收款AUTO凭证冻结汇兑收益120");
        // USD account (same currency as 到账) accumulates the 原币 actually received, not the local
        assertEquals(0, bigDecimalFor("select balance_current from accounts where id=?", accountId)
                .compareTo(new BigDecimal("600")), "美元账户按原币累加 $600(非本币4320)");
    }

    /** Build a single-line sales-receipt save request referencing one AR. */
    private com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest receiptRequest(
            World w, UUID arId, UUID accountId, UUID expenseStyleId,
            String cash, String writeOff, String bankFee, String otherFee,
            BigDecimal rate, LocalDate billDate) {
        com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest req =
                new com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest();
        req.setReceiptKind("AR_SETTLEMENT");
        req.setBillDate(billDate);
        req.setClientId(w.clientId());
        req.setAccountId(accountId);
        UUID accountCurrencyId=jdbc.queryForObject(
                "select currency_id from accounts where id=?",UUID.class,accountId);
        req.setAccountCurrencyId(accountCurrencyId);
        req.setCreateIdempotencyKey(UUID.randomUUID().toString());
        req.setSettlementChannel("DIRECT_ACCOUNT");
        req.setExchangeRateSource("BANK_STATEMENT");
        req.setExchangeRateEffectiveAt(
                billDate.atTime(9,0).atOffset(java.time.ZoneOffset.ofHours(8)));
        req.setBankBookedAt(
                billDate.atTime(10,0).atOffset(java.time.ZoneOffset.ofHours(8)));
        req.setBankReference("FULLCHAIN-"+UUID.randomUUID());
        req.setBankFeeAccountAmount(new BigDecimal(bankFee));
        req.setOtherFeeAccountAmount(new BigDecimal(otherFee));
        req.setFeeSettlementMode(
                new BigDecimal(bankFee).add(new BigDecimal(otherFee)).signum()==0
                        ?"NONE":"DEDUCTED_FROM_PROCEEDS");
        req.setFeeBearer(
                new BigDecimal(bankFee).add(new BigDecimal(otherFee)).signum()==0
                        ?"NONE":"COMPANY");
        req.setOtherFeeStyleId(expenseStyleId);
        com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput line =
                new com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput();
        line.setAppliedLedgerId(arId);
        line.setCurrencyId(w.currencyId());
        line.setExchangeRate(rate);
        line.setAmountOriginal(new BigDecimal(cash));
        line.setWriteOffAmount(BigDecimal.ZERO);
        req.setItems(List.of(line));
        return req;
    }

    @Test
    void amounts_discountedApprovedOrderChangeQtyKeepsOnlyOriginalCurrencyFact() {
        World w = seedWorld("s27discount-change");
        loginAs(w.superAdminUserId());
        OrderSaveRequest request = orderRequest(w, w.goodsA(), "10", "100");
        request.getItems().get(0).setDiscount(new BigDecimal("0.8"));
        UUID orderId = salesOrderService.create(request).getId();
        salesOrderService.approve(orderId);
        UUID orderItemId = orderItemId(orderId);

        OrderChangeQtyRequest.Line line = new OrderChangeQtyRequest.Line();
        line.setOrderItemId(orderItemId);
        line.setNewQty(new BigDecimal("20"));
        OrderChangeQtyRequest change = new OrderChangeQtyRequest();
        change.setItems(List.of(line));
        salesOrderService.changeQty(orderId, change);

        assertEquals(0, bigDecimalFor(
                "select amount_original from sales_order_items where id = ?", orderItemId)
                .compareTo(new BigDecimal("1600.0000")),
                "改量原币金额仍为 20×100×0.8");
        assertNull(jdbc.queryForObject(
                "select amount_local from sales_order_items where id = ?",
                BigDecimal.class, orderItemId),
                "订单阶段不形成行本币金额");
        assertNull(jdbc.queryForObject(
                "select exchange_rate from sales_orders where id = ?",
                BigDecimal.class, orderId),
                "订单阶段不形成汇率快照");
        assertNull(jdbc.queryForObject(
                "select total_local from sales_orders where id = ?",
                BigDecimal.class, orderId),
                "订单阶段不形成本币合计");
    }

    @Test
    void salesOrderApprovalRejectsCurrencyDisabledAfterDraftSave() {
        World w = seedWorld("order-currency-audit");
        loginAs(w.superAdminUserId());
        UUID orderId = salesOrderService.create(
                orderRequest(w, w.goodsA(), "10", "100")).getId();
        jdbc.update("update currencies set status = '禁用' where id = ?", w.currencyId());

        ApiException error = assertThrows(
                ApiException.class, () -> salesOrderService.approve(orderId));

        assertTrue(error.getMessage().contains("币种"));
        assertEquals(0, orderStatus(orderId), "币种审核失败后订单仍为草稿");
    }

    @Test
    void salesOrderCreateAndApproveDoNotRequireAPositiveReferenceRate() {
        World w = seedWorld("order-zero-reference-rate");
        loginAs(w.superAdminUserId());
        jdbc.update("update currencies set exchange_rate = 0 where id = ?", w.currencyId());

        UUID orderId = salesOrderService.create(
                orderRequest(w, w.goodsA(), "10", "100")).getId();
        salesOrderService.approve(orderId);

        assertEquals(1, orderStatus(orderId));
        assertEquals(0, bigDecimalFor(
                "select total_original from sales_orders where id = ?", orderId)
                .compareTo(new BigDecimal("1000.0000")));
        assertNull(jdbc.queryForObject(
                "select exchange_rate from sales_orders where id = ?",
                BigDecimal.class, orderId));
        assertNull(jdbc.queryForObject(
                "select total_local from sales_orders where id = ?",
                BigDecimal.class, orderId));
        assertEquals(0, intFor(
                "select count(*) from sales_order_items where order_id = ? and amount_local is not null",
                orderId));
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
                "AR 凭证至少借/贷两行(got " + arEntries + ")");
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
                "全局：所有凭证借贷必平(无不平衡凭证)");
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
        assertNotNull(planId, "H 的物料需求挂在某生产计划的 CONFIRMED 包下(成品计划 → 原料需求)");
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
                "supply peg 链接 H 需求 → 采购订货明细(成品→原料→采购 可溯)");

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
    // #29 (multi-account permissions — role isolation) A sales-only account (sales_shipment:create,
    // NOT warehouse-work) can create a shipment but must be DENIED the warehouse pick transition.
    // A warehouse-only account (warehouse-work, NOT create) can pick but must be DENIED shipment
    // creation. @EnableMethodSecurity enforces @PreAuthorize against the SecurityContextHolder
    // principal even in direct service calls — so a missing authority throws AccessDeniedException.
    // This is the role separation the redesign's "各司其职" depends on.
    // ---------------------------------------------------------------------------------------------
    @Test
    void permissions_roleIsolationAndObjectScope() {
        World w = seedWorld("s29");
        UUID orderItemId = produceFinished(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        UUID salesOwner = createUserWithPerms(w, "sales-owner", "sales_shipment:create");
        UUID salesOther = createUserWithPerms(w, "sales-other", "sales_shipment:create");
        UUID warehouseUser = createUserWithPerms(w, "wh-s29", "sales_shipment:warehouse-work");
        // assign the order to salesOwner — only the owning sales rep can act on it (object scope)
        jdbc.update("update sales_orders set owner_employee_id = ? where id = ?",
                employeeIdOf(salesOwner), orderId);

        // (1) Object scope: a DIFFERENT sales rep cannot reference this order line
        loginAs(salesOther);
        ApiException scopeDenied = assertThrows(ApiException.class,
                () -> createShipment(w, orderItemId, w.goodsA(), "10"));
        assertTrue(scopeDenied.getMessage().contains("无权"),
                "对象隔离：非归属销售不能引用该订单行(" + scopeDenied.getMessage() + ")");

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

        // (5) role isolation: warehouse lacks create → create DENIED (@PreAuthorize fires first)
        loginAs(warehouseUser);
        assertThrows(AccessDeniedException.class,
                () -> createShipment(w, orderItemId, w.goodsA(), "5"),
                "仓库无 sales_shipment:create → 建出货单被拒");
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
                "同 idempotencyKey 重复处置 → 幂等，库存不翻倍(仍 20，非 40)");
    }

    @Test
    void qualifiedReceiptWakesMaterialAnalysisAndReversalLowersReadinessWithoutNotice()
            throws Exception {
        World w = seedWorld("analysis-wakeup");
        UUID finished = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(finished, "WAKE-FG", "唤醒测试成品", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "WAKE-RM", "唤醒测试原料", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(finished, material, "2");
        loginAs(w.superAdminUserId());

        AnalysisView initial = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(),
                "analysis-wakeup-" + finished,
                List.of(new PreviewItem(
                        "OTHER", null, finished, null, w.unitId(),
                        "WAKE-" + finished, "合格入库自动唤醒回归",
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisId = initial.analysisId();
        assertEquals(0, initial.products().getFirst().readyFinishQty()
                        .compareTo(BigDecimal.ZERO),
                "原料未入库时可完工量为 0");

        // Drive the BUY shortage through a real request, formal PO and finance
        // approval. It is still a pre-plan source, so the qualified receipt is
        // free stock for the analysis refresh rather than a formal reservation.
        UUID orderItemId = approvePurchaseForAnalysis(w, initial, material);
        UUID receiptId = receiveIntoQuarantine(
                w, material, orderItemId, "20");
        UUID inspectionItemId = jdbc.queryForObject(
                "select id from procurement_inspection_items "
                        + "where receipt_id = ? and goods_id = ?",
                UUID.class, receiptId, material);
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(BigDecimal.ZERO),
                "待检库存不能提前提高可完工量");

        String partialKey = "analysis-wakeup-partial-" + receiptId;
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", new BigDecimal("10"), "部分合格", partialKey));

        assertEquals(0, stockBalance(w.warehouseId(), material)
                        .compareTo(new BigDecimal("10")),
                "非最终 IQC PASS 后真实库存立即增加 10");
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(new BigDecimal("5")),
                "非最终 IQC PASS 同事务刷新后可完工量由 0 增至 5");
        assertEquals(1, count("""
                select count(*) from business_outbox
                where event_type = 'PRODUCTION_MATERIAL_ANALYSIS_READY'
                  and aggregate_id = ?
                  and payload->>'sourceType' = 'PURCHASE'
                  and payload->>'sourceDocumentId' = ?
                  and payload->>'sourceEventId' is not null
                  and payload->>'readyFinishDelta' = '5'
                  and payload->>'readyFinishQty' = '5'
                """, analysisId, receiptId.toString()),
                "部分 PASS 用 disposition event lineage 产生一条 durable ready 事件");

        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", new BigDecimal("10"), "部分合格", partialKey));
        assertEquals(1, count("""
                select count(*) from business_outbox
                where event_type = 'PRODUCTION_MATERIAL_ANALYSIS_READY'
                  and aggregate_id = ?
                """, analysisId), "IQC replay 不重复发布 ready 事件");

        String finalKey = "analysis-wakeup-final-" + receiptId;
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", new BigDecimal("10"), "最终合格", finalKey));

        assertEquals(0, stockBalance(w.warehouseId(), material)
                        .compareTo(new BigDecimal("20")),
                "最终 PASS 后真实库存累计为 20");
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(new BigDecimal("10")),
                "整单结案仍由正式收货唤醒把可完工量刷新至 10");
        assertEquals(1, count("""
                select count(*) from business_outbox
                where event_type = 'PRODUCTION_MATERIAL_ANALYSIS_READY'
                  and aggregate_id = ?
                  and payload->>'sourceDocumentId' = ?
                  and payload->>'sourceEventId' is null
                  and payload->>'readyFinishDelta' = '5'
                  and payload->>'readyFinishQty' = '10'
                """, analysisId, receiptId.toString()),
                "最终整单结案只走原正式收货唤醒并使用原收货级幂等键");

        purchaseReceiptService.reverse(receiptId);

        assertEquals(0, stockBalance(w.warehouseId(), material)
                        .compareTo(BigDecimal.ZERO),
                "收货红冲后真实库存回到 0");
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(BigDecimal.ZERO),
                "红冲后自动刷新并降低可完工量，不能留下虚高快照");
        assertEquals(2, count("""
                select count(*) from business_outbox
                where event_type = 'PRODUCTION_MATERIAL_ANALYSIS_READY'
                  and aggregate_id = ?
                """, analysisId), "红冲只刷新，不发送齐套增加通知");
    }

    @Test
    void fullyRejectedReceiptReleasesPlanningCoverageAndAllowsReplacementNotification() {
        World w = seedWorld("analysis-full-fail-retry");
        UUID finished = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(finished, "FAIL-FG", "全不合格补采成品", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "FAIL-RM", "全不合格补采原料", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(finished, material, "2");
        loginAs(w.superAdminUserId());

        AnalysisView initial = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(),
                "analysis-full-fail-retry-" + finished,
                List.of(new PreviewItem(
                        "OTHER", null, finished, null, w.unitId(),
                        "FAIL-" + finished, "全 FAIL 后替代需求回归",
                        LocalDate.of(2026, 9, 2), new BigDecimal("10")))));
        UUID analysisId = initial.analysisId();
        UUID orderItemId = approvePurchaseForAnalysis(w, initial, material);
        Map<String, Object> original = jdbc.queryForMap("""
                select action.id as action_id,
                       action.external_document_id as request_id,
                       order_item.order_id
                from preplan_supply_actions action
                join preplan_supply_action_allocations allocation
                  on allocation.action_id = action.id
                 and allocation.external_item_id is not null
                join purchase_order_items order_item
                  on order_item.request_item_id = allocation.external_item_id
                 and order_item.id = ?
                where action.analysis_id = ? and action.route = 'BUY'
                """, orderItemId, analysisId);
        UUID originalActionId = (UUID) original.get("action_id");
        UUID originalRequestId = (UUID) original.get("request_id");
        UUID originalOrderId = (UUID) original.get("order_id");

        UUID receiptId = receiveIntoQuarantine(
                w, material, orderItemId, "20");
        UUID inspectionItemId = jdbc.queryForObject("""
                select id from procurement_inspection_items
                where receipt_type = 'PURCHASE'
                  and receipt_id = ? and goods_id = ?
                """, UUID.class, receiptId, material);

        inspectionService.dispose(
                "PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "FAIL", null, "整批检验不合格",
                        "analysis-full-fail-" + receiptId));

        AnalysisView failed = analysisService.detail(analysisId);
        MaterialView failedMaterial = failed.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.actionable())
                .findFirst().orElseThrow();
        assertEquals(0, failedMaterial.inboundQty().compareTo(BigDecimal.ZERO),
                "全 FAIL 且原订单物理收完结案后，在途必须为 0");
        assertEquals(0, failedMaterial.shortageQty().compareTo(new BigDecimal("20")),
                "不合格量不抵扣缺口，20 个基本单位仍需补采");
        assertEquals(0, stockBalance(w.warehouseId(), material)
                        .compareTo(BigDecimal.ZERO),
                "全 FAIL 不进入合格库存");
        assertEquals("CANCELLED", strFor(
                "select status from preplan_supply_actions where id = ?",
                originalActionId),
                "旧 action 只释放计划占用，避免永久挡住替代通知");
        assertTrue(strFor("select cancellation_reason from preplan_supply_actions where id = ?",
                originalActionId).contains("重新通知补采"));

        // The planning projection is cancelled; all commercial and IQC evidence remains.
        assertEquals(1, count("select count(*) from purchase_requests where id = ?",
                originalRequestId));
        assertEquals(1, count("select count(*) from purchase_orders where id = ?",
                originalOrderId));
        assertEquals(1, count("select count(*) from purchase_receipts where id = ?",
                receiptId));
        assertEquals(1, count("""
                select count(*) from procurement_inspection_items
                where id = ? and status = 'RESOLVED'
                  and passed_base_qty = 0 and failed_base_qty = 20
                """, inspectionItemId));
        assertEquals(1, count("""
                select count(*) from procurement_inspection_events
                where inspection_item_id = ? and action = 'FAIL'
                """, inspectionItemId));

        analysisCommandService.notifySupply(
                analysisId,
                new NotifyRequest(
                        failed.version(), failed.fingerprint(),
                        "notify-full-fail-replacement-" + analysisId,
                        "BUY", List.of(failedMaterial.materialLineId()), List.of(), null));

        Map<String, Object> replacement = jdbc.queryForMap("""
                select action.id, action.generation, action.predecessor_action_id,
                       action.requested_qty, action.external_document_id
                from preplan_supply_actions action
                where action.analysis_id = ? and action.route = 'BUY'
                  and action.id <> ?
                order by action.generation desc limit 1
                """, analysisId, originalActionId);
        assertEquals(2, ((Number) replacement.get("generation")).intValue(),
                "替代通知使用下一代 action");
        assertEquals(originalActionId, replacement.get("predecessor_action_id"),
                "替代 action 明确追溯旧失败 action");
        assertEquals(0, ((BigDecimal) replacement.get("requested_qty"))
                        .compareTo(new BigDecimal("20")),
                "替代需求只覆盖仍存在的真实缺口");
        assertEquals(1, count("""
                select count(*) from purchase_request_items item
                where item.request_id = ? and item.goods_id = ?
                  and item.qty = 20 and item.is_deleted = false
                """, replacement.get("external_document_id"), material));
        assertEquals(1, count("select count(*) from purchase_receipts where id = ?",
                receiptId), "替代通知不得删除原收货事实");
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
                "重复审批同一单 → 拒绝(不重复生效)");
        assertEquals(1, intFor("select status from purchase_orders where id = ?", pc.orderId()),
                "重复审批被拒 → 订单状态不变(仍 1，未重复)");
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
                "sales_shipment:create", "sales_shipment:view");
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
                "purchase_order:view", "purchase_order:edit",
                "purchase_order:create", "purchase_order:decompose",
                "purchase_request:view");
        UUID purchaserB = createUserWithPerms(w, "purchB-pauth",
                "purchase_order:view", "purchase_order:edit", "purchase_order:delete",
                "purchase_request:view");
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
                "owner：A 可改自己的采购单(归属 gate 放行)");

        // (5) NULL-maker legacy order: public-readable but unwritable until an owner is assigned
        jdbc.update("update purchase_orders set maker_id = null where id = ?", orderId);
        loginAs(purchaserB);
        assertDoesNotThrow(() -> purchaseOrderService.detail(orderId),
                "NULL owner：老数据公共可读(B 可读)");
        assertEquals(ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class,
                        () -> purchaseOrderService.update(orderId, headerOnlyOrderReq(w))).getCode(),
                "NULL owner：老数据普通用户不可写(B → FORBIDDEN)");
        loginAs(supervisor);
        assertEquals(ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class,
                        () -> purchaseOrderService.update(orderId, headerOnlyOrderReq(w))).getCode(),
                "NULL owner：view:all 也不可直接写，必须先显式补负责人");
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
        req.setSettlementMethodId(activeSettlementMethodId());
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
        orderReq.setSettlementMethodId(activeSettlementMethodId());
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
                "进度看板 nativeReadScope：非归属者见 0 条(SQL 有效 + 按归属过滤，与 list 同口径)");

        // super-admin — detail ok, progress board includes the plan (seeAll → 1=1, SQL valid)
        loginAs(w.superAdminUserId());
        assertDoesNotThrow(() -> planService.detail(planId));
        assertTrue(planService.progress(false, "billDate", 1, 10, "", "", null, null).getTotal() >= 1,
                "超管进度看板含该计划(seeAll → 1=1，SQL 有效)");
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
        UUID keeperA = createUserWithPerms(w, "keepA-s",
                "stock_doc:view", "stock_doc:edit", "stock_doc:create");
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
                "超管不能取消本人超管身份(防自锁)");
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
                "超管不能修改本人/超管的授权策略(无自我提权路径)");

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

    /** 收货必须与财务批准订单的结算方式一致（V300+ 收货结算一致性校验），从订单行回填。 */
    private UUID purchaseOrderSettlementMethodOf(UUID orderItemId) {
        return jdbc.queryForObject("""
                select o.settlement_method_id
                from purchase_orders o
                join purchase_order_items i on i.order_id = o.id
                where i.id = ?
                """, UUID.class, orderItemId);
    }

    private UUID subcontractOrderSettlementMethodOf(UUID orderItemId) {
        return jdbc.queryForObject("""
                select o.settlement_method_id
                from subcontract_orders o
                join subcontract_order_items i on i.order_id = o.id
                where i.id = ?
                """, UUID.class, orderItemId);
    }

    /** Receive goods against an approved PO and approve the receipt → IQC quarantine (frozen, not in
     *  usable stock). Returns the receipt id (inspection items PENDING). */
    private UUID receiveIntoQuarantine(World w, UUID goodsId, UUID orderItemId, String qty) {
        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest rr =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        // 当期日期：后续红冲受 GL 跨期间守卫限制，不能用历史月份固定日期。
        rr.setBillDate(BusinessTime.today());
        rr.setSupplierId(w.supplierId());
        rr.setWarehouseId(w.warehouseId());
        rr.setCurrencyId(w.currencyId());
        rr.setExchangeRate(BigDecimal.ONE);
        rr.setTaxRate(BigDecimal.ZERO);
        rr.setSettlementMethodId(purchaseOrderSettlementMethodOf(orderItemId));
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
        orderReq.setSettlementMethodId(activeSettlementMethodId());
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

    private void grantDataScope(UUID userId, String scope, UUID ownerEmployeeId) {
        jdbc.update("""
                insert into user_data_scopes(user_id, scope, owner_employee_id)
                values (?, ?, ?)
                """, userId, scope, ownerEmployeeId);
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
        jdbc.update("""
                update system_posting_style_roles role
                set style_id = source.id
                from payment_styles source
                where (role.role_key, source.path) in (
                    ('AR_CONTROL', '/113/'),
                    ('SALES_REVENUE', '/031/'),
                    ('INVENTORY_ASSET', '/123/'),
                    ('AP_CONTROL', '/203/'),
                    ('SALES_COST', '/041/'))
                  and source.status='使用' and coalesce(source.is_deleted,false)=false
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

    private record ProductionAssignment(UUID workshopId, UUID workerId) {}

    private Production produceFinished(World w, UUID goodsId, String orderQty, String planQty) {
        loginAs(w.superAdminUserId());
        UUID planId = approvedPlan(w, goodsId, orderQty, planQty);
        UUID planItemId = planItemIdFor(planId, goodsId);
        UUID orderItemId = orderItemIdOfPlan(planId);
        UUID reportId = reportAndApprove(w, planItemId, orderItemId, goodsId, orderQty);
        UUID finishedInId = finishedInDocForReport(reportId);
        confirmFinishedInboundFully(finishedInId);
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
        req.setIdempotencyKey("e2e-report-" + UUID.randomUUID());
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

    private UUID reportAndApproveExecutionSegment(
            World w,
            UUID planItemId,
            UUID orderItemId,
            UUID goodsId,
            UUID executionSegmentId,
            UUID salesAllocationId,
            String qty) {
        DailyReportSaveRequest req = new DailyReportSaveRequest();
        req.setIdempotencyKey("e2e-report-" + UUID.randomUUID());
        req.setBillDate(LocalDate.of(2026, 1, 25));
        req.setWarehouseId(w.warehouseId());
        DailyReportItemLine line = new DailyReportItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPlanItemId(planItemId);
        line.setSalesOrderItemId(orderItemId);
        line.setExecutionSegmentId(executionSegmentId);
        line.setExecutionSegmentSalesAllocationId(salesAllocationId);
        req.setItems(List.of(line));
        DailyReportDetail report = reportService.create(req);
        reportService.approve(report.getId());
        UUID inspectionId = jdbc.queryForObject("""
                        SELECT id
                        FROM production_fqc_inspections
                        WHERE source_report_id = ?
                          AND source_report_item_id IN (
                              SELECT id
                              FROM production_daily_report_items
                              WHERE report_id = ?)
                        """, UUID.class, report.getId(), report.getId());
        var fqc = fqcService.decide(
                inspectionId,
                new DecisionRequest(
                        "PASS",
                        new BigDecimal(qty),
                        null,
                        null,
                        null,
                        "e2e-fqc-" + UUID.randomUUID()));
        assertFalse(fqc.replay());
        assertEquals(
                0,
                fqc.inspection().authorizedInboundQty()
                        .compareTo(new BigDecimal(qty)));
        return report.getId();
    }

    private ProductionAssignment productionAssignment(String tag) {
        UUID productionDepartmentId = jdbc.queryForObject(
                "SELECT id FROM departments WHERE code = 'DEPT_PROD'",
                UUID.class);
        UUID workshopId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO departments(id, code, name, parent_id, level)
                VALUES (?, ?, ?, ?, '二级班组')
                """,
                workshopId,
                "WORKSHOP-" + tag,
                "测试车间-" + tag,
                productionDepartmentId);
        UUID workerId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(
                    id, code, full_name, id_type, department_id,
                    hire_date, status, employment_type)
                VALUES (?, ?, ?, '其他', ?, DATE '2026-01-01',
                        'active', 'regular')
                """,
                workerId,
                "WORKER-" + tag,
                "测试生产负责人-" + tag,
                workshopId);
        return new ProductionAssignment(workshopId, workerId);
    }

    /** V378 起订货送审必须有启用中的结算方式；E2E 统一取 seed 里的第一行。 */
    private java.util.UUID activeSettlementMethodId() {
        return jdbc.queryForObject(
                "select id from settlement_methods where status = '使用' "
                        + "and coalesce(is_deleted, false) = false "
                        + "order by code limit 1",
                java.util.UUID.class);
    }

    /** FINISHED_IN draft generated by legacy compatibility or FQC PASS (UUID true source). */
    private UUID finishedInDocForReport(UUID reportId) {
        return jdbc.queryForObject(
                "select id from stock_documents where doc_type = 'FINISHED_IN' "
                        + "and source_daily_report_id = ? and is_deleted = false "
                        + "order by created_at desc limit 1",
                UUID.class, reportId);
    }

    /**
     * V338 后生产 FINISHED_IN 草稿必须走仓库逐行实收确认通道；
     * E2E 链按报工量全额点收（accepted = 报工申报量）后自动审核入账。
     */
    private void confirmFinishedInboundFully(UUID finishedInId) {
        var lines = jdbc.queryForList(
                "select id, qty from stock_document_items "
                        + "where doc_id = ? and is_deleted = false order by line_no",
                finishedInId);
        var request = new com.uten.imp.features.stock.dto.FinishedInboundConfirmRequest();
        request.setIdempotencyKey("e2e-confirm-" + finishedInId);
        request.setLines(lines.stream()
                .map(row -> {
                    var line = new com.uten.imp.features.stock.dto
                            .FinishedInboundConfirmRequest.Line();
                    line.setItemId((java.util.UUID) row.get("id"));
                    line.setAcceptedQty((java.math.BigDecimal) row.get("qty"));
                    return line;
                })
                .toList());
        stockDocService.confirmFinishedInbound(finishedInId, request);
    }

    private UUID confirmFinishedInboundPartially(
            UUID finishedInId,
            BigDecimal acceptedQty,
            String reason) {
        var lines = jdbc.queryForList(
                "select id, qty from stock_document_items "
                        + "where doc_id = ? and is_deleted = false order by line_no",
                finishedInId);
        assertEquals(1, lines.size(), "本测试只处理单行 FQC 入库");
        var request = new com.uten.imp.features.stock.dto
                .FinishedInboundConfirmRequest();
        request.setIdempotencyKey(
                "e2e-confirm-partial-" + finishedInId);
        request.setVarianceReason(reason);
        var line = new com.uten.imp.features.stock.dto
                .FinishedInboundConfirmRequest.Line();
        line.setItemId((UUID) lines.getFirst().get("id"));
        line.setAcceptedQty(acceptedQty);
        request.setLines(List.of(line));
        stockDocService.confirmFinishedInbound(finishedInId, request);
        return jdbc.queryForObject("""
                        SELECT residual_stock_document_id
                        FROM production_finished_in_confirmations
                        WHERE stock_document_id = ?
                        """, UUID.class, finishedInId);
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
        // 新单发运策略必选（SalesOrderService.requireSelectableShipmentPolicy）。
        req.setShipmentPolicy(
                com.uten.imp.features.sales.order.SalesOrder.SHIPMENT_POLICY_ALLOW_PARTIAL);
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
        assertNotNull(cPlanId, "B → C 子计划(整树展开，非仅一层)");

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
                "D 采购申请(B 层展开，全树非仅顶层)");
        assertTrue(count(
                "select count(*) from subcontract_applications where is_deleted = false") >= 1,
                "E 委外申请(A 层)");
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
        assertTrue(hasSegmentStatus(planId, "WAITING"), "X 段 WAITING(等 Y 完工)");
        assertTrue(hasSegmentStatus(yPlan, "WAITING"), "Y 段 WAITING(等 Z 完工)");
        assertEquals(0, count(
                "select count(*) from production_execution_segments where plan_id = ? and is_deleted = false",
                zPlan), "Z 是无 BOM 自制叶子件 → 无执行段(直接报工生产)");

        // produce Z (leaf): old-style report + FINISHED_IN (no segment, no sales link)
        loginAs(w.superAdminUserId());
        produceInternal(w, zPlanItem, z, "10");

        // V194 hook: Z inbound → Y's WAITING segment (MAKE demand pegged to Z's plan item) → READY
        assertTrue(hasSegmentStatus(yPlan, "READY"),
                "Z 完工入库 → Y 段自动释放为 READY(自底向上，既有 V194 钩子)");
        assertTrue(hasSegmentStatus(planId, "WAITING"),
                "X 段仍 WAITING(Y 尚未完工)");
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
                "B 包 REVERSED(整树级联)");
        assertEquals(-1, planStatus(bPlan), "B 子计划 status=-1(红冲级联)");
        assertEquals(-1, planStatus(cPlan), "C 子计划 status=-1(红冲到叶子)");
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
                bPlan, cPlan), "本树 MAKE peg(A→B、B→C)全部 REVERSED(整树回退)");
    }

    /** Produce an internal (no-sales-link) MAKE subplan via old-style report + FINISHED_IN. For MAKE
     *  leaves (no BOM, no segment) or unconfirmed plans. Fires the V194 auto-release hook on approval. */
    private void produceInternal(World w, UUID planItemId, UUID goodsId, String qty) {
        DailyReportSaveRequest req = new DailyReportSaveRequest();
        req.setIdempotencyKey("e2e-report-" + UUID.randomUUID());
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
        confirmFinishedInboundFully(finishedInDocForReport(d.getId()));
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
        // V294 财务确认闸门：超管不属 DEPT_FIN 子树，按资格 SQL 的「个人加授」分支授予确认权，
        // 让链路夹具能以超管身份完成「审核 → 财务确认」两步（真实岗位由财务部确认人操作）。
        jdbc.update("""
                insert into user_permission_overrides(user_id, permission_id, effect)
                select ?, p.id, 'grant' from permissions p
                where p.code = 'sales_order_finance:confirm'
                """, superAdminUserId);

        // Masters first (units must exist before goods.unit_id FK). status CHECK: '使用'.
        // Online MRP/stock writes resolve the seeded current unit UUID only.
        // The legacy integer remains historical migration metadata, not a runtime relationship.
        jdbc.update("insert into units(id, legacy_id, code, name, status) values (?, ?, ?, ?, '使用')",
                unitId, unitLegacy, "PCS-" + tag, "个");
        jdbc.update("insert into currencies(id, code, name, exchange_rate, status) "
                        + "values (?, ?, ?, 1, '使用')",
                currencyId, "CNY-" + tag, "人民币");
        jdbc.update("insert into colors(id, code, name, status) values (?, ?, ?, '使用')",
                colorId, "CLR-" + tag, "默认色");
        jdbc.update("insert into warehouses(id, code, name, status) values (?, ?, ?, '使用')",
                warehouseId, "WH-" + tag, "测试仓库-" + tag);
        jdbc.update("insert into clients(id, code, name, status, code_sequence) "
                        + "values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from clients))",
                clientId, "CLI-" + tag, "测试客户-" + tag);
        jdbc.update("insert into suppliers(id, code, name, status, code_sequence) "
                        + "values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from suppliers))",
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
        jdbc.update("insert into goods(id, code, name, source_type, status, unit_id, unit_legacy_id, code_sequence) "
                        + "values (?, ?, ?, ?, '使用', ?, ?, "
                        + "(select coalesce(max(code_sequence), 0) + 1 from goods))",
                id, code, name, sourceType, unitId, unitLegacy);
    }

    private UUID insertScopedClient(
            UUID categoryId, UUID ownerEmployeeId, String code, boolean deleted) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into clients(
                    id,category_id,code,name,status,code_sequence,owner_employee_id,is_deleted)
                values (?,?,?,?,'使用',
                    (select coalesce(max(code_sequence),0)+1 from clients),?,?)
                """, id, categoryId, code, "客户-" + code, ownerEmployeeId, deleted);
        return id;
    }

    private static com.uten.imp.features.master.client.dto.ClientQueryFilter clientFilter(
            UUID categoryId, boolean excludeLegacyFinanceStub) {
        return new com.uten.imp.features.master.client.dto.ClientQueryFilter(
                categoryId,
                null,
                java.util.Set.of(),
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                excludeLegacyFinanceStub,
                false);
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
