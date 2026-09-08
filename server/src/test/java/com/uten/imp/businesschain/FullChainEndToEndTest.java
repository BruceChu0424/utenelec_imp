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
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
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
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
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
import java.util.ArrayList;
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
    @Autowired private org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired private PermissionResolver permissionResolver;
    @Autowired private SalesOrderService salesOrderService;
    @Autowired private com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService financeConfirmService;
    @Autowired private ProductionScheduleService scheduleService;
    @Autowired private ProductionPlanService planService;
    @Autowired private MrpService mrpService;
    @Autowired private ProductionPlanningPackageService planningPackageService;
    @Autowired private ProductionExecutionSegmentService executionSegmentService;
    @Autowired private com.uten.imp.features.purchase.order.PurchaseOrderService purchaseOrderService;
    @Autowired private com.uten.imp.features.purchase.request.PurchaseRequestService purchaseRequestService;
    @Autowired private com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrderService;
    @Autowired private com.uten.imp.features.subcontract.order.SubcontractOrderProgressService subcontractOrderProgress;
    @Autowired private com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService subcontractMaterialIssueService;
    @Autowired private com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService subcontractMaterialReturnService;
    @Autowired private com.uten.imp.features.subcontract.ret.SubcontractReturnService supplierSubcontractReturnService;
    @Autowired private com.uten.imp.features.subcontract.receipt.SubcontractReceiptService subcontractReceiptService;
    @Autowired private com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService financeApproval;
    @Autowired private com.uten.imp.features.common.taskclaim.TaskClaimService reviewClaims;
    @Autowired private jakarta.persistence.EntityManager quantityEntityManager;
    @Autowired private com.uten.imp.features.purchase.receipt.PurchaseReceiptService purchaseReceiptService;
    @Autowired private com.uten.imp.features.purchase.ret.PurchaseReturnService supplierPurchaseReturnService;
    @Autowired private com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspectionService;
    @Autowired private com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService arrivalControl;
    @Autowired private com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService
            iqcStockInService;
    @Autowired private ProductionDailyReportService reportService;
    @Autowired private ProductionFqcInspectionService fqcService;
    @Autowired private ProductionFinishedArrivalRegistrationService
            finishedArrivalRegistrationService;
    @Autowired private StockDocService stockDocService;
    @Autowired private com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService materialSettlementService;
    @Autowired private SalesShipmentService shipmentService;
    @Autowired private GlPostingService glPostingService;
    @Autowired private com.uten.imp.features.admin.UserAccountAdminService userAccountAdmin;
    @Autowired private com.uten.imp.features.admin.PermissionOverrideAdminService permissionOverrideAdmin;
    @Autowired private com.uten.imp.features.production.mrp.BottomUpPlanOrchestrator orchestrator;
    @Autowired private com.uten.imp.features.production.analysis.MaterialAnalysisService analysisService;
    @Autowired private com.uten.imp.features.production.analysis.MaterialAnalysisCommandService analysisCommandService;
    @Autowired private com.uten.imp.features.production.analysis.SubcontractPreparationCoordinator
            subcontractPreparationCoordinator;
    @Autowired private com.uten.imp.features.production.analysis.MaterialStockReallocationService
            materialStockReallocationService;
    @Autowired private com.uten.imp.features.finance.receipt.FinanceReceiptService receiptService;
    @Autowired private com.uten.imp.features.finance.receivables.CustomerPrepaymentQueryService salesMoneyQuery;
    @Autowired private com.uten.imp.features.finance.receivables.CustomerPrepaymentOffsetService customerAdvanceOffsets;
    @Autowired private com.uten.imp.features.sales.ret.SalesReturnService customerReturnService;
    @Autowired private com.uten.imp.features.sales.ret.SalesReturnQualityService customerReturnQuality;
    @Autowired private com.uten.imp.features.attachment.AttachmentService attachmentService;
    @Autowired private AttachmentUploadGrantService attachmentUploadGrants;
    @Autowired private com.uten.imp.features.attachment.AttachmentObjectOutboxProcessor attachmentOutbox;
    @Autowired private com.uten.imp.features.notice.outbox.BusinessOutboxProcessor businessOutboxProcessor;
    @Autowired private com.uten.imp.features.notice.NoticeService reviewNoticeService;
    @Autowired private com.uten.imp.features.finance.payables.ProcurementIqcRejectionService rejectionService;
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
        confirmInitialSalesFinance(orderId);
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

    UUID createApprovedOrder(World w, UUID goodsId, String qty, String price) {
        loginAs(w.superAdminUserId());
        OrderDetail d = salesOrderService.create(orderRequest(w, goodsId, qty, price));
        salesOrderService.approve(d.getId());
        // V294：审核后须经财务确认，计划部（待排产/物料分析/MRP/计划关联）才可见。
        confirmInitialSalesFinance(d.getId());
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
    // confirmed, MAKE child ownership is created explicitly even while lower-level materials
    // are short, and both child/root plans may honestly enter WAITING. The plan-first
    // confirm path is s21w above.
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_explicitMakeChildCanScheduleWaitingBeforeLowerLevelKit() {
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

        // 2026-09-05 顶层与子层同构：根供料路线也必须显式确认为 MAKE，根产品
        // 才可排产（canSchedule 口径与子件一致），E2E 走真实用户路径。
        confirmRootMakeRoute(analysisId, routed);
        final AnalysisView routedAfterRoot = analysisService.detail(analysisId);

        // (4) 2026-09-05 简化：单独「创建自制子件任务」退役——notify MAKE 直接
        // fail-closed；子件锚点行由「创建生产计划」单次原子创建（候选行直发）。
        ApiException retiredMake = assertThrows(ApiException.class, () ->
                analysisCommandService.notifySupply(analysisId, new NotifyRequest(
                        routedAfterRoot.version(), routedAfterRoot.fingerprint(),
                        "notify-make-retired-" + analysisId, "MAKE",
                        List.of(b.materialLineId()), List.of(), null)));
        assertTrue(retiredMake.getMessage().contains("创建生产计划"),
                "notify MAKE 必须指引走创建生产计划(实际：" + retiredMake.getMessage() + ")");
        assertEquals(0, count("select count(*) from production_material_analysis_items "
                        + "where analysis_id = ? and source_type = 'MAKE_COMPONENT' and is_deleted = false",
                analysisId), "退役拒绝不能留下 child");

        ProductionAssignment assignment = productionAssignment("sMA1");
        GenerateResult childWaitingResult = analysisCommandService.issueWorkshopPlans(
                analysisId, new IssueWorkshopPlansRequest(
                        routedAfterRoot.version(), routedAfterRoot.fingerprint(),
                        "gen-make-child-waiting-" + analysisId,
                        w.warehouseId(), LocalDate.of(2026, 8, 8), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                b.materialLineId(), null, b.demandSupplyGapQty(),
                                LocalDate.of(2026, 8, 8), null,
                                assignment.workshopId(), null,
                                assignment.workerId(), null, null))));
        assertTrue(hasSegmentStatus(
                childWaitingResult.plans().getFirst().planId(), "WAITING"));
        assertTrue(childWaitingResult.plans().getFirst().drawIds().isEmpty(),
                "子件下层未齐时 WAITING 必须零 DRAW");
        assertEquals(1, count("select count(*) from production_material_analysis_items "
                        + "where analysis_id = ? and source_type = 'MAKE_COMPONENT' and is_deleted = false",
                analysisId), "原子下达恰好创建一个子件锚点行");

        // B=20; its BOM requires C=60 and D=100. Stock arrival may later promote
        // readiness, but it must not create a second child task implicitly.
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsC(), new BigDecimal("60"));
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsD(), new BigDecimal("100"));
        assertEquals(1, count("select count(*) from production_material_analysis_items "
                        + "where analysis_id = ? and source_type = 'MAKE_COMPONENT' and is_deleted = false",
                analysisId), "刷新/到货不得隐式重复创建 MAKE_COMPONENT");

        // (5) Direct components B & E still have no stock. This is not READY, but the
        //     root product may now be scheduled for its whole remaining quantity so the
        //     workshop/owner assignment is frozen early. Approval must create an honest
        //     auto-promotable WAITING segment with no reservation or DRAW.
        AnalysisView afterMake = analysisService.detail(analysisId);
        ProductView rootProduct = afterMake.products().stream()
                .filter(product -> product.analysisLineId().equals(productLineId))
                .findFirst().orElseThrow();
        assertEquals(0, rootProduct.readyNowQty().compareTo(BigDecimal.ZERO),
                "无库存 → 当前齐套为 0");
        assertTrue(rootProduct.canSchedule(), "无库存仍可先排给车间");
        assertEquals(0, new BigDecimal("10").compareTo(rootProduct.maxSchedulableQty()),
                "可排产上限取当前需求剩余量，不取 readyNowQty");
        GenerateResult waitingResult = analysisCommandService.issueWorkshopPlans(
                analysisId, new IssueWorkshopPlansRequest(
                        afterMake.version(), afterMake.fingerprint(),
                        "gen-ma1-" + analysisId, w.warehouseId(),
                        LocalDate.of(2026, 8, 8), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, productLineId, new BigDecimal("10"),
                                LocalDate.of(2026, 8, 8), null,
                                assignment.workshopId(), null,
                                assignment.workerId(), null, null))));
        GeneratedPlan waitingPlan = waitingResult.plans().getFirst();
        assertEquals("APPROVED", waitingPlan.status(), "待料计划也可显式审核下达");
        assertTrue(hasSegmentStatus(waitingPlan.planId(), "WAITING"),
                "未齐套批次必须形成 WAITING 执行段");
        assertFalse(hasSegmentStatus(waitingPlan.planId(), "READY"),
                "未齐套批次不得伪造 READY 分段");
        assertTrue(waitingPlan.drawIds().isEmpty(), "WAITING 不得生成 DRAW");
        assertEquals(0, count("""
                select count(*)
                from stock_reservations reservation
                join production_material_demands demand
                  on demand.id = reservation.owner_id
                 and reservation.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                join production_execution_segments segment
                  on segment.id = demand.execution_segment_id
                where segment.plan_id = ? and reservation.status = 0
                """, waitingPlan.planId()), "WAITING 不得占用零散库存");
        assertEquals("true", strFor("""
                select auto_promote_when_ready::text
                from production_execution_segments
                where plan_id = ? and status = 'WAITING' and is_deleted = false
                """, waitingPlan.planId()), "客观缺料 WAITING 应在合格到仓后自动提升");
        assertEquals(0, new BigDecimal("10").compareTo(plannedQty(orderId)),
                "先排车间也必须按销售来源精确记入已排量");
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
        confirmRootMakeRoute(analysisId, refreshed);
        refreshed = analysisService.detail(analysisId);
        GenerateResult result = analysisCommandService.issueWorkshopPlans(
                analysisId, new IssueWorkshopPlansRequest(
                        refreshed.version(), refreshed.fingerprint(),
                        "gen-ma2-" + analysisId, w.warehouseId(),
                        LocalDate.of(2026, 8, 8), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, productLineId, new BigDecimal("10"),
                                LocalDate.of(2026, 8, 8), null,
                                null, null, null, null, null))));
        assertFalse(result.plans().isEmpty(), "生成了一张生产计划");
        GeneratedPlan g = result.plans().getFirst();
        assertEquals("APPROVED", g.status(), "approveNow=true → 计划已批准");
        assertEquals(1, planStatus(g.planId()), "production_plans.status=1(已审核)");
        assertTrue(hasSegmentStatus(g.planId(), "READY"), "生成 READY 执行分段");
        assertFalse(g.drawIds().isEmpty(), "approveNow → 同事务生成 DRAW 领料单");
        assertEquals(0, new BigDecimal("10").compareTo(plannedQty(orderId)),
                "销售订单行 planned_qty=10");
        assertEquals("PARTIALLY_PLANNED",
                strFor("select status from production_material_analyses where id=?", analysisId),
                "全量下达仍需物料履约和实际完工入库，不能关闭分析");
        AnalysisView issued = analysisService.detail(analysisId);
        var issuedB = issued.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(w.goodsB()) && material.level()==1)
                .findFirst().orElseThrow();
        assertEquals(0,new BigDecimal("20").compareTo(issuedB.requiredQty()));
        assertEquals(0,BigDecimal.ZERO.compareTo(issuedB.shortageQty()));
        assertEquals(0,BigDecimal.ZERO.compareTo(issued.products().getFirst().remainingQty()));
        assertFalse(issued.products().getFirst().canSchedule());
        assertThrows(ApiException.class, () -> analysisCommandService.issueWorkshopPlans(
                analysisId,new IssueWorkshopPlansRequest(issued.version(),issued.fingerprint(),
                        "gen-ma2-duplicate-" + analysisId,w.warehouseId(),
                        LocalDate.of(2026,8,8),null,true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(productLineId,BigDecimal.ONE)))));
        assertEquals(1,count("select count(*) from production_plans where material_analysis_id=?",
                analysisId),"需求保留不能重复排产");
    }

    @Test
    void materialAnalysis_splitFixedBatchesKeepTheSecondBatchWaitingWithoutDuplicateStock() {
        World w=seedWorld("fixed-batch-split");
        UUID product=UUID.randomUUID();
        UUID material=UUID.randomUUID();
        insertGoods(product,"P-fixed-batch-split","固定批次成品","自制",w.unitId(),w.unitLegacy());
        insertGoods(material,"M-fixed-batch-split","固定批次物料","采购",w.unitId(),w.unitLegacy());
        insertBom(product,material,"10");
        jdbc.update("""
                update goods_bom_items set consumption_basis='FIXED_BATCH',
                  basis_output_qty=100,allow_partial_package=false where goods_id=?
                """,product);
        jdbc.update("insert into stock_balances(warehouse_id,goods_id,qty) values (?,?,10)",
                w.warehouseId(),material);
        loginAs(w.superAdminUserId());
        AnalysisView view=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "fixed-batch-preview",List.of(new PreviewItem("OTHER",null,product,null,w.unitId(),
                        "fixed-batch-split","逐批精确耗料",LocalDate.of(2026,9,25),new BigDecimal("100")))));
        UUID analysisId=view.analysisId();
        UUID sourceId=view.products().getFirst().analysisLineId();
        confirmRootMakeRoute(analysisId,view);
        view=analysisService.detail(analysisId);
        GenerateResult first=analysisCommandService.issueWorkshopPlans(analysisId,
                new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"fixed-batch-first",
                        w.warehouseId(),LocalDate.of(2026,9,6),null,true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(sourceId,new BigDecimal("50")))));
        assertTrue(hasSegmentStatus(first.plans().getFirst().planId(),"READY"));
        view=analysisService.detail(analysisId);
        GenerateResult second=analysisCommandService.issueWorkshopPlans(analysisId,
                new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"fixed-batch-second",
                        w.warehouseId(),LocalDate.of(2026,9,6),null,true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(sourceId,new BigDecimal("50")))));
        assertTrue(hasSegmentStatus(second.plans().getFirst().planId(),"WAITING"));
        assertTrue(second.plans().getFirst().drawIds().isEmpty());
        var materialView=second.analysis().flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.level()==1).findFirst().orElseThrow();
        assertEquals(0,new BigDecimal("20").compareTo(materialView.requiredQty()));
        assertEquals(0,new BigDecimal("10").compareTo(materialView.allocatedAvailableQty()));
        assertEquals(0,new BigDecimal("10").compareTo(materialView.shortageQty()));
        assertEquals("PARTIALLY_PLANNED",second.analysis().status());
    }

    @Test
    void materialAnalysis_sameMainWarehouseKitIssuesSeparateDrawsAndCanStart() {
        World w = seedWorld("same-main-kit");
        UUID mainWarehouse = UUID.randomUUID();
        UUID hardwareWarehouse = UUID.randomUUID();
        jdbc.update("insert into warehouses(id,code,name,status) values (?,?,?,'使用')",
                mainWarehouse, "MAIN-kit", "主仓");
        jdbc.update("update warehouses set parent_id=? where id=?",
                mainWarehouse, w.warehouseId());
        jdbc.update("insert into warehouses(id,code,name,status,parent_id) values (?,?,?,'使用',?)",
                hardwareWarehouse, "HW-kit", "五金仓", mainWarehouse);
        jdbc.update("insert into stock_balances(warehouse_id,goods_id,qty) values (?,?,?)",
                w.warehouseId(), w.goodsB(), new BigDecimal("20"));
        jdbc.update("insert into stock_balances(warehouse_id,goods_id,qty) values (?,?,?)",
                hardwareWarehouse, w.goodsE(), new BigDecimal("10"));
        loginAs(w.superAdminUserId());
        AnalysisView view = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "same-main-kit-preview",
                List.of(new PreviewItem("OTHER", null, w.goodsA(), null, w.unitId(),
                        "same-main-kit", "分子仓备料", LocalDate.of(2026, 9, 25),
                        new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID itemId = view.products().getFirst().analysisLineId();
        confirmRootMakeRoute(analysisId, view);
        view = analysisService.detail(analysisId);
        GeneratedPlan plan = analysisCommandService.issueWorkshopPlans(analysisId,
                new IssueWorkshopPlansRequest(view.version(), view.fingerprint(),
                        "same-main-kit-issue", w.warehouseId(),
                        LocalDate.of(2026, 9, 6), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, itemId, new BigDecimal("10"),
                                null, null, null, null, null, null, null))))
                .plans().getFirst();

        assertTrue(hasSegmentStatus(plan.planId(), "READY"));
        assertEquals(2, plan.drawIds().size(), "不同实际子仓各一张领料单");
        assertEquals(2, count("""
                select count(distinct reservation.warehouse_id)
                from stock_reservations reservation
                join production_material_demands demand on demand.id=reservation.demand_id
                where demand.package_id=? and reservation.is_deleted=false
                """, plan.packageId()));
        for (UUID drawId : plan.drawIds()) {
            var drawLines = jdbc.queryForList(
                    "select id,qty from stock_document_items where doc_id=? and is_deleted=false", drawId);
            assertEquals(1, drawLines.size(), "每张领料单只列本子仓分配的物料");
            var issue = new com.uten.imp.features.stock.dto.StockDocIssueRequest();
            issue.setIdempotencyKey("same-main-kit-draw-" + drawId);
            issue.setLines(drawLines.stream().map(row -> {
                var line = new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();
                line.setItemId((UUID) row.get("id"));
                line.setQty((BigDecimal) row.get("qty"));
                return line;
            }).toList());
            stockDocService.approveAndIssue(drawId, issue);
        }
        assertEquals(0, stockBalance(w.warehouseId(), w.goodsB()).signum());
        assertEquals(0, stockBalance(hardwareWarehouse, w.goodsE()).signum());
        var started = startedSegmentFor(w, plan.planId(), planItemOfPlan(plan.planId()), null);
        assertEquals("IN_PROGRESS", strFor(
                "select status from production_execution_segments where id=?", started.segmentId()));
        AnalysisView afterIssue = analysisService.detail(analysisId);
        MaterialView plastic = afterIssue.flatMaterials().stream()
                .filter(material -> w.goodsB().equals(material.goodsId())).findFirst().orElseThrow();
        assertEquals(0, plastic.requiredQty().compareTo(new BigDecimal("20")),
                "下达和领料后仍保留本批物料需求");
        assertEquals(0, plastic.shortageQty().signum(), "已领用的料不能再次形成采购缺口");
    }

    @Test
    void materialAnalysis_plannedWorkshopAssignmentStartsDirectlyAndRequiresStartBeforeReporting() {
        World w = seedWorld("assigned-direct-start");
        ProductionAssignment assignment = productionAssignment("assigned-direct-start");
        LocalDate startDate = BusinessTime.today();
        jdbc.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,20)",
                w.warehouseId(),w.goodsB());
        jdbc.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,10)",
                w.warehouseId(),w.goodsE());
        loginAs(w.superAdminUserId());
        AnalysisView analysis = analysisService.preview(new PreviewRequest(null,null,null,
                w.warehouseId(),"assigned-direct-start-preview",List.of(new PreviewItem(
                        "OTHER",null,w.goodsA(),null,w.unitId(),"assigned-direct-start",
                        "计划已指定车间负责人",startDate.plusDays(7),new BigDecimal("10")))));
        UUID analysisId = analysis.analysisId();
        UUID itemId = analysis.products().getFirst().analysisLineId();
        confirmRootMakeRoute(analysisId,analysis);
        AnalysisView current = analysisService.detail(analysisId);
        GeneratedPlan plan = analysisCommandService.issueWorkshopPlans(analysisId,
                new IssueWorkshopPlansRequest(current.version(),current.fingerprint(),
                        "assigned-direct-start-plan",w.warehouseId(),startDate,null,true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,itemId,
                                new BigDecimal("10"),startDate,null,assignment.workshopId(),
                                null,assignment.workerId(),null,null))))
                .plans().getFirst();
        UUID segmentId = plan.segmentIds().getFirst();
        assertTrue(hasSegmentStatus(plan.planId(),"READY"));
        assertEquals(assignment.workshopId(),jdbc.queryForObject("""
                SELECT workshop_department_id FROM production_execution_segments WHERE id=?
                """,UUID.class,segmentId),"开始日存在且结束日留空时仍必须继承已选车间");
        assertEquals(assignment.workerId(),jdbc.queryForObject("""
                SELECT responsible_employee_id FROM production_execution_segments WHERE id=?
                """,UUID.class,segmentId),"车间任务不能丢失计划已填写的负责人");
        assertEquals(startDate.toString(),strFor("""
                SELECT plan_begin_date::text FROM production_execution_segments WHERE id=?
                """,segmentId));
        for (UUID drawId : plan.drawIds()) {
            stockDocService.approveAndIssue(drawId,drawIssueRequest(
                    drawId,"assigned-direct-start-issue-" + drawId,null,BigDecimal.ZERO));
        }
        UUID workshopUser = createUserWithPerms(w,"assigned-start-worker",
                "production_execution:view","production_execution:start",
                "production_daily_report:create");
        jdbc.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                assignment.workshopId(),workshopUser);
        loginAs(workshopUser);
        DailyReportSaveRequest report = new DailyReportSaveRequest();
        report.setIdempotencyKey("assigned-direct-start-report");
        report.setBillDate(startDate);
        report.setWarehouseId(w.warehouseId());
        report.setDepartmentId(assignment.workshopId());
        report.setWorkerId(assignment.workerId());
        report.setWorkerIds(List.of(assignment.workerId()));
        DailyReportItemLine reportLine = new DailyReportItemLine();
        reportLine.setGoodsId(w.goodsA());
        reportLine.setUnitId(w.unitId());
        reportLine.setUnitRate(BigDecimal.ONE);
        reportLine.setQty(BigDecimal.ONE);
        reportLine.setPlanItemId(planItemOfPlan(plan.planId()));
        reportLine.setExecutionSegmentId(segmentId);
        report.setItems(List.of(reportLine));
        ApiException beforeStart = assertThrows(ApiException.class,() -> reportService.create(report));
        assertTrue(beforeStart.getMessage().contains("开工"));
        assertTrue(hasSegmentStatus(plan.planId(),"READY"),"报工拒绝不能偷偷开工");
        assertEquals(0,count("SELECT count(*) FROM production_daily_report_items WHERE execution_segment_id=?",
                segmentId));
        assertEquals(0,count("""
                SELECT count(*) FROM production_execution_segment_events
                WHERE execution_segment_id=? AND action IN ('DISPATCH','AUTO_START_ON_REPORT')
                """,segmentId));
        Long version = jdbc.queryForObject("""
                SELECT lock_version FROM production_execution_segments WHERE id=?
                """,Long.class,segmentId);
        var startRequest = new com.uten.imp.features.production.execution.BatchStartRequest(List.of(
                new com.uten.imp.features.production.execution.BatchStartRequest.Item(
                        segmentId,version,"assigned-direct-start-command")));
        var started = executionSegmentService.batchStart(plan.planId(),startRequest).getFirst();
        assertEquals("IN_PROGRESS",started.status());
        assertEquals(assignment.workshopId(),started.workshopDepartmentId());
        assertEquals(assignment.workerId(),started.responsibleEmployeeId());
        assertEquals(0,count("""
                SELECT count(*) FROM production_execution_segment_events
                WHERE execution_segment_id=? AND action='DISPATCH'
                """,segmentId),"直接开工不需要重新分配或先派工");
        assertNotNull(reportService.create(report).getId(),"明确开工后才允许登记报工");
    }

    @Test
    void materialAnalysis_sameMaterialTwoWarehousesIssueAndReverseKeepPhysicalOwnership() {
        World w = seedWorld("same-material-leaves");
        UUID main = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name,status) VALUES (?,?,?,'使用')",
                main,"MAIN-same-material","物料主仓");
        jdbc.update("UPDATE warehouses SET parent_id=? WHERE id=?",main,w.warehouseId());
        jdbc.update("INSERT INTO warehouses(id,code,name,status,parent_id) VALUES (?,?,?,'使用',?)",
                second,"SECOND-same-material","物料第二子仓",main);
        UUID product = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(product,"P-same-material","分仓产品","自制",w.unitId(),w.unitLegacy());
        insertGoods(material,"M-same-material","同物料分仓","采购",w.unitId(),w.unitLegacy());
        insertBom(product,material,"2");
        for (UUID warehouse : List.of(w.warehouseId(),second)) {
            jdbc.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,10)",
                    warehouse,material);
        }
        loginAs(w.superAdminUserId());
        AnalysisView view = analysisService.preview(new PreviewRequest(null,null,null,
                w.warehouseId(),"same-material-preview",List.of(new PreviewItem("OTHER",null,
                        product,null,w.unitId(),"same-material","同料分仓",
                        BusinessTime.today(),new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID itemId = view.products().getFirst().analysisLineId();
        confirmRootMakeRoute(analysisId,view);
        view = analysisService.detail(analysisId);
        GeneratedPlan plan = analysisCommandService.issueWorkshopPlans(analysisId,
                new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                        "same-material-plan",w.warehouseId(),BusinessTime.today(),null,true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,itemId,
                                new BigDecimal("10"),null,null,null,null,null,null,null))))
                .plans().getFirst();
        assertEquals(2,plan.drawIds().size());
        UUID draw = plan.drawIds().getFirst();
        UUID actualWarehouse = jdbc.queryForObject(
                "SELECT warehouse_id FROM stock_documents WHERE id=?",UUID.class,draw);
        UUID otherWarehouse = actualWarehouse.equals(second) ? w.warehouseId() : second;
        UUID drawItem = jdbc.queryForObject(
                "SELECT id FROM stock_document_items WHERE doc_id=? AND is_deleted=FALSE",
                UUID.class,draw);
        UUID demand = jdbc.queryForObject("""
                SELECT demand_id FROM production_planning_package_document_items
                WHERE document_item_id=? AND document_type='DRAW'
                """,UUID.class,drawItem);
        var line = new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();
        line.setItemId(drawItem);
        line.setQty(new BigDecimal("10"));
        var issue = new com.uten.imp.features.stock.dto.StockDocIssueRequest();
        issue.setIdempotencyKey("same-material-first-issue");
        issue.setLines(List.of(line));
        stockDocService.approveAndIssue(draw,issue);
        stockDocService.approveAndIssue(draw,issue);
        assertEquals(0,stockBalance(actualWarehouse,material).signum());
        assertEquals(0,stockBalance(otherWarehouse,material).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("""
                SELECT consumed_qty FROM stock_reservations
                WHERE demand_id=? AND warehouse_id=? AND is_deleted=FALSE
                """,demand,actualWarehouse).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("""
                SELECT consumed_qty FROM stock_reservations
                WHERE demand_id=? AND warehouse_id=? AND is_deleted=FALSE
                """,demand,otherWarehouse).signum(),"本仓领料不能消费另一个子仓预留");
        var mismatch = assertThrows(org.springframework.dao.DataAccessException.class,
                () -> jdbc.update("""
                        INSERT INTO production_material_stock_postings(
                            id,event_id,stock_document_item_id,demand_id,reservation_id,
                            posting_type,qty_base,created_by)
                        SELECT gen_random_uuid(),source.event_id,source.stock_document_item_id,
                               source.demand_id,other.id,'ISSUE',1,source.created_by
                        FROM production_material_stock_postings source
                        JOIN stock_reservations other ON other.demand_id=source.demand_id
                        WHERE source.stock_document_item_id=? AND source.posting_type='ISSUE'
                          AND other.warehouse_id=?
                        """,drawItem,otherWarehouse));
        assertTrue(mismatch.getMostSpecificCause().getMessage()
                .contains("material posting must consume or restore the actual document warehouse"));
        var reverse = new com.uten.imp.features.stock.dto.StockDocIssueRequest();
        reverse.setIdempotencyKey("same-material-reverse");
        reverse.setReason("撤回本子仓误发的物料");
        reverse.setLines(List.of(line));
        stockDocService.reverseIssue(draw,reverse);
        stockDocService.reverseIssue(draw,reverse);
        assertEquals(0,stockBalance(actualWarehouse,material).compareTo(new BigDecimal("10")));
        assertEquals(0,stockBalance(otherWarehouse,material).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("""
                SELECT SUM(consumed_qty) FROM stock_reservations
                WHERE demand_id=? AND is_deleted=FALSE
                """,demand).signum());
    }

    @Test
    void materialAnalysis_issuePlansFromCandidateMaterialLineIsAtomic() {
        // ADR-71 车间桶真实路径：候选行按 materialLineId 单次原子下达——一个事务
        // 建子件任务+出计划+审核；覆盖 materialLineId→子件行解析（曾因单列查询
        // 误走 objectArrayRows 抛 ClassCastException）。
        World w = seedWorld("sMA1c");
        UUID orderId = createApprovedOrder(w, w.goodsA(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma1c",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify",
                "production_material_analysis:generate", "production_plan:approve");
        loginAs(planner);
        AnalysisView view = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "idem-ma1c-" + orderItemId,
                List.of(new PreviewItem("SALES_ORDER_ITEM", orderItemId,
                        null, null, null, null, null, LocalDate.of(2026, 9, 1),
                        new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        MaterialView b = view.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(w.goodsB()) && m.actionable())
                .findFirst().orElseThrow();
        analysisService.saveRoutes(analysisId, new RouteRequest(view.version(), view.fingerprint(),
                "routes-ma1c-" + analysisId, List.of(
                        new RouteDecision(b.materialLineId(), b.actionGroupKey(), "MAKE", null))));
        confirmRootMakeRoute(analysisId, analysisService.detail(analysisId));
        AnalysisView routed = analysisService.detail(analysisId);

        ProductionAssignment assignment = productionAssignment("sMA1c");
        GenerateResult result = analysisCommandService.issueWorkshopPlans(analysisId,
                new IssueWorkshopPlansRequest(routed.version(), routed.fingerprint(),
                        "issue-candidate-" + analysisId, w.warehouseId(),
                        LocalDate.of(2026, 8, 8), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                b.materialLineId(), null, b.demandSupplyGapQty(),
                                LocalDate.of(2026, 8, 8), null,
                                assignment.workshopId(), null, assignment.workerId(), null, null))));
        assertEquals(1, result.plans().size());
        assertEquals("APPROVED", result.plans().getFirst().status(),
                "approveNow=true → 子件计划同事务审核下达");
        assertTrue(hasSegmentStatus(result.plans().getFirst().planId(), "WAITING"),
                "下层 C/D 缺料 → 子件计划 WAITING（计划侧不拦截）");
        assertTrue(result.plans().getFirst().drawIds().isEmpty(),
                "未齐套子件必须零 DRAW");
        assertEquals(1, count("select count(*) from production_material_analysis_items "
                        + "where analysis_id = ? and source_type = 'MAKE_COMPONENT' and is_deleted = false",
                analysisId), "原子下达恰好创建一个子件行");
    }

    @Test
    void productionGoodReturnAndReversalBindEachPhysicalMovementToItsExactEvent() {
        World w=seedWorld("material-movement-links");
        receiveOpeningInputsForA(w,"10");
        UUID plan=approvedPlan(w,w.goodsA(),"10","10");
        issueReadyPlanAndMaterials(w,plan);
        UUID originalItem=jdbc.queryForObject("""
                select mapping.document_item_id from production_planning_package_document_items mapping
                join production_material_demands demand on demand.id=mapping.demand_id
                where demand.plan_id=? and demand.goods_id=? and mapping.document_type='DRAW'
                """,UUID.class,plan,w.goodsB());
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).signum());
        var request=new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        request.setDocType("WDRAW");request.setWarehouseId(w.warehouseId());request.setBillDate(BusinessTime.today());
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();
        line.setGoodsId(w.goodsB());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("2"));line.setUpstreamItemId(originalItem);request.setItems(List.of(line));
        UUID returned=stockDocService.create(request).getId();
        stockDocService.approve(returned);
        assertEquals(0,new BigDecimal("2").compareTo(stockBalance(w.warehouseId(),w.goodsB())));
        assertEquals(1,count("""
                select count(*) from production_material_movement_links link
                join production_material_stock_events event on event.id=link.event_id
                join stock_movements movement on movement.id=link.movement_id
                where event.stock_document_id=? and event.event_type='GOOD_RETURN'
                  and movement.source_item_id=link.document_item_id and movement.qty=2 and movement.direction=1
                """,returned));
        assertThrows(ApiException.class,()->stockDocService.approve(returned));
        stockDocService.reverse(returned);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).signum());
        assertEquals(2,count("""
                select count(*) from production_material_movement_links link
                join production_material_stock_events event on event.id=link.event_id
                where event.stock_document_id=?
                """,returned));
        var tamper=assertThrows(org.springframework.dao.DataAccessException.class,()->jdbc.update("""
                update production_material_movement_links set movement_id=movement_id
                where event_id in(select id from production_material_stock_events where stock_document_id=?)
                """,returned));
        Throwable cause=tamper;while(cause.getCause()!=null) cause=cause.getCause();
        assertTrue(cause instanceof java.sql.SQLException);assertEquals("55000",((java.sql.SQLException)cause).getSQLState());
        var orphan=assertThrows(org.springframework.dao.DataAccessException.class,()->jdbc.update("""
                insert into stock_movements(transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,
                    goods_id,color_id,warehouse_id,direction,qty,unit_id,unit_rate)
                select now(),5,'STOCK_DOC',item.doc_id,item.id,item.goods_id,item.color_id,document.warehouse_id,
                    -1,1,item.unit_id,item.unit_rate from stock_document_items item join stock_documents document on document.id=item.doc_id
                where item.id=?
                """,originalItem));
        cause=orphan;while(cause.getCause()!=null) cause=cause.getCause();
        assertTrue(cause instanceof java.sql.SQLException);assertEquals("23514",((java.sql.SQLException)cause).getSQLState());
        assertTrue(cause.getMessage().contains("production physical movement requires its exact material event"));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).signum());
    }

    @Test
    void productionDrawAtomicIssueLifecycleUsesExactSegmentMapping() {
        World w = seedWorld("sDrawLifecycle");
        jdbc.update("""
                insert into stock_balances(
                    warehouse_id, goods_id, color_id, qty)
                values (?,?,NULL,?)
                """, w.warehouseId(), w.goodsB(), new BigDecimal("20"));
        jdbc.update("""
                insert into stock_balances(
                    warehouse_id, goods_id, color_id, qty)
                values (?,?,NULL,?)
                """, w.warehouseId(), w.goodsE(), new BigDecimal("10"));
        UUID orderId = createApprovedOrder(
                w, w.goodsA(), "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(
                w, "draw-life-planner",
                "production_material_analysis:view",
                "production_material_analysis:manage",
                "production_material_analysis:generate",
                "production_plan:approve");
        ProductionAssignment assignment =
                productionAssignment("draw-life");
        UUID workshopUser = createUserWithPerms(
                w, "draw-life-workshop",
                "notice:read", "production_execution:view",
                "production_daily_report:create");
        jdbc.update("""
                update employees
                set department_id = ?
                where id = (
                    select employee_id from users where id = ?)
                """, assignment.workshopId(), workshopUser);
        UUID workshopEmployee = jdbc.queryForObject(
                "select employee_id from users where id = ?",
                UUID.class, workshopUser);
        UUID outsideUser = createUserWithPerms(
                w, "draw-life-outside",
                "notice:read", "production_execution:view");
        loginAs(planner);

        AnalysisView analysis = analysisService.preview(
                new PreviewRequest(
                        null, null, null, w.warehouseId(),
                        "draw-life-analysis-" + orderItemId,
                        List.of(new PreviewItem(
                                "SALES_ORDER_ITEM", orderItemId,
                                null, null, null, null, null,
                                LocalDate.of(2026, 9, 1),
                                new BigDecimal("10")))));
        UUID analysisId = analysis.analysisId();
        UUID analysisLineId =
                analysis.products().getFirst().analysisLineId();
        AnalysisView current = analysisService.detail(analysisId);
        confirmRootMakeRoute(analysisId, current);
        current = analysisService.detail(analysisId);
        GeneratedPlan generated = analysisCommandService.issueWorkshopPlans(
                analysisId, new IssueWorkshopPlansRequest(
                        current.version(), current.fingerprint(),
                        "draw-life-generate-" + analysisId,
                        w.warehouseId(), LocalDate.of(2026, 8, 8), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, analysisLineId, new BigDecimal("10"),
                                LocalDate.of(2026, 8, 8), null,
                                assignment.workshopId(), null,
                                assignment.workerId(), null, null))))
                .plans().getFirst();
        UUID drawId = generated.drawIds().getFirst();
        UUID segmentId = generated.segmentIds().getFirst();
        assertEquals(0, count("""
                select count(*)
                from stock_document_items
                where doc_id = ?
                  and execution_segment_id is not null
                """, drawId),
                "V157 要求 DRAW 行保持 NULL，执行归属只走 demand mapping");
        assertEquals(0, count("""
                select count(*)
                from stock_document_items
                where doc_id = ?
                  and (unit_id is null or unit_rate is distinct from 1)
                """, drawId),
                "正式 DRAW 行必须使用需求基本单位且 unit_rate=1");
        assertEquals(count("""
                        select count(*)
                        from stock_document_items
                        where doc_id = ? and is_deleted = false
                        """, drawId),
                count("""
                        select count(*)
                        from production_planning_package_document_items mapping
                        join production_material_demands demand
                          on demand.id = mapping.demand_id
                        join production_planning_package_documents header
                          on header.package_id = mapping.package_id
                         and header.document_type = mapping.document_type
                         and header.document_id = mapping.document_id
                        where mapping.document_id = ?
                          and mapping.document_type = 'DRAW'
                          and demand.execution_segment_id = ?
                          and header.execution_segment_id =
                              demand.execution_segment_id
                        """, drawId, segmentId),
                "每条 DRAW 行必须精确映射同一执行工单");
        BigDecimal initialPhysicalStock = bigDecimalFor("""
                select coalesce(sum(qty),0)
                from stock_balances
                where warehouse_id = ?
                  and goods_id in (?,?)
                """, w.warehouseId(), w.goodsB(), w.goodsE());
        BigDecimal drawBaseQty = bigDecimalFor("""
                select coalesce(sum(base_qty),0)
                from stock_document_items
                where doc_id = ? and is_deleted = false
                """, drawId);

        loginAs(w.superAdminUserId());
        StockDocIssueRequest tooMuch = drawIssueRequest(
                drawId, "draw-life-too-much", null, BigDecimal.ONE);
        assertThrows(
                ApiException.class,
                () -> stockDocService.approveAndIssue(drawId, tooMuch));
        assertEquals("0|0", strFor("""
                select status::text || '|' || issue_status::text
                from stock_documents where id = ?
                """, drawId), "issue 失败必须回滚审核状态");
        assertEquals(0, count("""
                select count(*) from production_material_stock_events
                where stock_document_id = ?
                """, drawId), "失败不得留下领料事件");
        assertEquals(0, count("""
                select count(*) from stock_movements
                where source_doc_type = 'STOCK_DOC'
                  and source_doc_id = ?
                """, drawId), "失败不得留下物理库存流水");
        assertEquals(0, initialPhysicalStock.compareTo(bigDecimalFor("""
                select coalesce(sum(qty),0)
                from stock_balances
                where warehouse_id = ?
                  and goods_id in (?,?)
                """, w.warehouseId(), w.goodsB(), w.goodsE())),
                "失败不得改变物理库存余额");
        assertEquals(0, bigDecimalFor("""
                select coalesce(sum(reservation.consumed_qty),0)
                from stock_reservations reservation
                join production_material_demands demand
                  on demand.id = reservation.demand_id
                where demand.execution_segment_id = ?
                """, segmentId).compareTo(BigDecimal.ZERO),
                "失败不得消耗正式预留");

        StockDocIssueRequest issue = drawIssueRequest(
                drawId, "draw-life-issue-0001", null, BigDecimal.ZERO);
        stockDocService.approveAndIssue(drawId, issue);
        assertEquals("1|2", strFor("""
                select status::text || '|' || issue_status::text
                from stock_documents where id = ?
                """, drawId), "首次出库原子完成审核与全量实发");
        BigDecimal issuedPhysicalStock =
                initialPhysicalStock.subtract(drawBaseQty);
        assertEquals(0, issuedPhysicalStock.compareTo(bigDecimalFor("""
                select coalesce(sum(qty),0)
                from stock_balances
                where warehouse_id = ?
                  and goods_id in (?,?)
                """, w.warehouseId(), w.goodsB(), w.goodsE())),
                "首次合法出库必须按 DRAW 基本量扣减物理库存");
        long issueEvents = count("""
                select count(*) from production_material_stock_events
                where stock_document_id = ? and event_type = 'ISSUE'
                """, drawId);
        long movementRows = count("""
                select count(*) from stock_movements
                where source_doc_type = 'STOCK_DOC'
                  and source_doc_id = ?
                """, drawId);
        stockDocService.approveAndIssue(drawId, issue);
        assertEquals(issueEvents, count("""
                select count(*) from production_material_stock_events
                where stock_document_id = ? and event_type = 'ISSUE'
                """, drawId), "同 key 重放不得重复写领料事件");
        assertEquals(movementRows, count("""
                select count(*) from stock_movements
                where source_doc_type = 'STOCK_DOC'
                  and source_doc_id = ?
                """, drawId), "同 key 重放不得重复扣库存");
        assertEquals(0, issuedPhysicalStock.compareTo(bigDecimalFor("""
                select coalesce(sum(qty),0)
                from stock_balances
                where warehouse_id = ?
                  and goods_id in (?,?)
                """, w.warehouseId(), w.goodsB(), w.goodsE())),
                "同 key 重放后物理库存必须保持一次扣减");

        while (businessOutboxProcessor.processNext()) {
            // Drain plan/DRAW events so the active workshop card is current.
        }
        assertEquals(1, count("""
                select count(*) from notices
                where audience_user_id = ?
                  and source_event =
                      'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'
                  and aggregate_kind =
                      'PRODUCTION_EXECUTION_SEGMENT'
                  and aggregate_id = ?
                  and resolved_at is null
                """, workshopUser, segmentId),
                "全量实发只通知精确执行工单所属车间");
        assertEquals(0, count("""
                select count(*) from notices
                where audience_user_id = ?
                  and source_event =
                      'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'
                  and aggregate_id = ?
                  and resolved_at is null
                """, outsideUser, segmentId),
                "车间外同权限人员不得收到该工单通知");

        StockDocIssueRequest cancel = drawIssueRequest(
                drawId, "draw-life-cancel-0001",
                "仓库发现本轮发料需撤回", BigDecimal.ZERO);
        stockDocService.reverseIssue(drawId, cancel);
        assertEquals("1|0", strFor("""
                select status::text || '|' || issue_status::text
                from stock_documents where id = ?
                """, drawId), "首次报工前取消出库恢复为待出库");
        assertEquals(0, bigDecimalFor("""
                select coalesce(sum(reservation.consumed_qty),0)
                from stock_reservations reservation
                join production_material_demands demand
                  on demand.id = reservation.demand_id
                where demand.execution_segment_id = ?
                """, segmentId).compareTo(BigDecimal.ZERO),
                "取消出库必须恢复正式预留");
        assertEquals(0, initialPhysicalStock.compareTo(bigDecimalFor("""
                select coalesce(sum(qty),0)
                from stock_balances
                where warehouse_id = ?
                  and goods_id in (?,?)
                """, w.warehouseId(), w.goodsB(), w.goodsE())),
                "取消出库必须把物理库存恢复到首次出库前");
        long cancelEvents = count("""
                select count(*) from production_material_stock_events
                where stock_document_id = ?
                  and event_type = 'ISSUE_REVERSE'
                """, drawId);
        stockDocService.reverseIssue(drawId, cancel);
        assertEquals(cancelEvents, count("""
                select count(*) from production_material_stock_events
                where stock_document_id = ?
                  and event_type = 'ISSUE_REVERSE'
                """, drawId), "取消出库同 key 重放不得重复恢复");

        stockDocService.issue(
                drawId,
                drawIssueRequest(
                        drawId, "draw-life-issue-0002",
                        null, BigDecimal.ZERO));
        UUID planItemId = planItemIdFor(
                generated.planId(), w.goodsA());
        DailyReportSaveRequest reportRequest =
                new DailyReportSaveRequest();
        reportRequest.setIdempotencyKey(
                "draw-life-report-" + segmentId);
        reportRequest.setBillDate(LocalDate.of(2026, 8, 9));
        reportRequest.setWarehouseId(w.warehouseId());
        reportRequest.setDepartmentId(assignment.workshopId());
        reportRequest.setWorkerId(workshopEmployee);
        reportRequest.setWorkerIds(List.of(workshopEmployee));
        DailyReportItemLine reportLine = new DailyReportItemLine();
        reportLine.setGoodsId(w.goodsA());
        reportLine.setUnitId(w.unitId());
        reportLine.setUnitRate(BigDecimal.ONE);
        reportLine.setQty(BigDecimal.ONE);
        reportLine.setPlanItemId(planItemId);
        reportLine.setSalesOrderItemId(orderItemId);
        reportLine.setExecutionSegmentId(segmentId);
        reportLine.setExecutionSegmentSalesAllocationId(
                salesAllocationOf(segmentId, orderItemId));
        reportRequest.setItems(List.of(reportLine));
        loginAs(workshopUser);
        assertThrows(ApiException.class,() -> reportService.create(reportRequest),
                "实际领料并不等于开工，未显式开工不能创建报工");
        loginAs(w.superAdminUserId());
        long startVersion = jdbc.queryForObject(
                "SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segmentId);
        executionSegmentService.start(generated.planId(),segmentId,
                new SegmentTransitionRequest(startVersion,"draw-life-explicit-start-"+segmentId));
        assertTrue(hasSegmentStatus(generated.planId(),"IN_PROGRESS"));
        loginAs(workshopUser);
        reportService.create(reportRequest);

        loginAs(w.superAdminUserId());
        StockDocIssueRequest lateCancel = drawIssueRequest(
                drawId, "draw-life-cancel-after-report",
                "已报工后错误尝试取消", BigDecimal.ZERO);
        assertThrows(
                ApiException.class,
                () -> stockDocService.reverseIssue(drawId, lateCancel));
        assertEquals("1|2", strFor("""
                select status::text || '|' || issue_status::text
                from stock_documents where id = ?
                """, drawId), "存在报工后取消必须失败且保持全量实发");
        assertEquals(0, issuedPhysicalStock.compareTo(bigDecimalFor("""
                select coalesce(sum(qty),0)
                from stock_balances
                where warehouse_id = ?
                  and goods_id in (?,?)
                """, w.warehouseId(), w.goodsB(), w.goodsE())),
                "报工后取消失败不得改变物理库存");
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
        assertTrue(view.flatMaterials().stream().noneMatch(m -> "BOM_COMPONENT".equals(m.nodeRole())),
                "无子层级不生成制造BOM物料需求");
        assertTrue(view.flatMaterials().stream().anyMatch(m -> "ROOT_SUPPLY".equals(m.nodeRole())
                && m.materialLineId().equals(view.products().getFirst().rootMaterialLineId())),
                "根供料节点仍应存在且精确关联来源产品");
        assertFalse(view.products().getFirst().hasProductionMaterialChildren(),
                "服务端明确投影为无生产子层级");
        assertEquals(0, new BigDecimal("10").compareTo(
                view.products().getFirst().readyNowQty()),
                "无子层级 → 剩余需求全额可直接自制");

        AnalysisView refreshed = analysisService.detail(analysisId);
        confirmRootMakeRoute(analysisId, refreshed);
        refreshed = analysisService.detail(analysisId);
        GenerateResult generated = analysisCommandService.issueWorkshopPlans(
                analysisId,
                new IssueWorkshopPlansRequest(
                        refreshed.version(), refreshed.fingerprint(),
                        "gen-ma-direct-" + analysisId,
                        w.warehouseId(), LocalDate.of(2026, 8, 29),
                        null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, productLineId, new BigDecimal("10"),
                                null, null, null, null, null, null, null))));

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
        confirmRootMakeRoute(analysisId, refreshed);
        refreshed = analysisService.detail(analysisId);
        IssueWorkshopPlansRequest request = new IssueWorkshopPlansRequest(
                refreshed.version(), refreshed.fingerprint(),
                "gen-ma-draft-replay-" + analysisId,
                w.warehouseId(), LocalDate.of(2026, 8, 8), null, false,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, productLineId, new BigDecimal("10"),
                        null, null, null, null, null, null, null)));

        GeneratedPlan first = analysisCommandService
                .issueWorkshopPlans(analysisId, request).plans().getFirst();
        GeneratedPlan replay = analysisCommandService
                .issueWorkshopPlans(analysisId, request).plans().getFirst();

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

    @Test
    void rootSupply_makeQueuesWaitingWithoutAChildAndCanConfirmLegacyMake() {
        World w=seedWorld("rootWait");
        UUID order=createApprovedOrder(w,w.goodsA(),"10","100");
        loginAs(w.superAdminUserId());
        AnalysisView view=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-wait-preview-"+order,List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),
                    null,null,null,null,null,LocalDate.of(2026,9,30),new BigDecimal("10")))));
        ProductView product=view.products().getFirst();
        assertNotNull(product.rootMaterialLineId());
        assertTrue(view.flatMaterials().stream().anyMatch(m -> m.materialLineId().equals(product.rootMaterialLineId())
                && "ROOT_SUPPLY".equals(m.nodeRole())));
        ProductionAssignment assignment=productionAssignment("root-wait");
        // V478 双闸：顶层必须显式确认为自制后才能下达车间（与产品行口径一致）。
        AnalysisView routed=analysisService.detail(view.analysisId());
        confirmRootMakeRoute(view.analysisId(), routed);
        AnalysisView confirmedView=analysisService.detail(view.analysisId());
        GeneratedPlan generated=analysisCommandService.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(
                confirmedView.version(),confirmedView.fingerprint(),"root-wait-generate-"+order,
                w.warehouseId(),LocalDate.of(2026,9,5),LocalDate.of(2026,9,30),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null,product.analysisLineId(),new BigDecimal("4"),
                        LocalDate.of(2026,9,5),LocalDate.of(2026,9,30),
                        assignment.workshopId(),null,assignment.workerId(),null,null)))).plans().getFirst();
        assertTrue(generated.drawIds().isEmpty());
        assertEquals(1,count("select count(*) from production_execution_segments where plan_id=? and status='WAITING'",generated.planId()));
        assertEquals(0,count("select count(*) from production_material_analysis_items where analysis_id=? and source_type='MAKE_COMPONENT'",view.analysisId()));
        AnalysisView after=analysisService.detail(view.analysisId());
        AnalysisView confirmed=analysisService.saveRoutes(view.analysisId(),new RouteRequest(
                after.version(),after.fingerprint(),"root-wait-confirm-"+order,
                List.of(new RouteDecision(product.rootMaterialLineId(),null,"MAKE",null))));
        ProductView remainder=confirmed.products().stream().filter(p -> p.analysisLineId().equals(product.analysisLineId())).findFirst().orElseThrow();
        assertTrue(remainder.canSchedule());
        assertEquals(0,remainder.remainingQty().compareTo(new BigDecimal("6")));
    }

    @Test
    void rootSupply_buyReceiptTransfersToSalesAndReceiptReverseRestoresRootDemand() {
        World w=seedWorld("rootBuy");
        UUID order=createApprovedOrder(w,w.goodsA(),"10","100");
        loginAs(w.superAdminUserId());
        AnalysisView initial=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-buy-preview-"+order,List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),
                    null,null,null,null,null,LocalDate.of(2026,9,30),new BigDecimal("10")))));
        UUID root=initial.products().getFirst().rootMaterialLineId();
        UUID purchaseLine=approvePurchaseForAnalysis(w,initial,w.goodsA());
        AnalysisView external=analysisService.detail(initial.analysisId());
        assertFalse(external.products().getFirst().canSchedule());
        assertTrue(external.flatMaterials().stream().allMatch(m -> m.level()==0));
        UUID receipt=receiveAndPassPurchase(w,purchaseLine,w.goodsA(),new BigDecimal("10"),"root-buy-"+order);
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(order)).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("select coalesce(sum(qty-consumed_qty-released_qty),0) from stock_reservations where owner_type='PREPLAN_ANALYSIS' and source_doc_id=?",receipt).compareTo(BigDecimal.ZERO));
        loginAs(w.superAdminUserId());
        AnalysisView completed=analysisService.detail(initial.analysisId());
        assertEquals("COMPLETED",completed.status());
        assertTrue(completed.flatMaterials().stream().filter(m -> m.materialLineId().equals(root))
                .flatMap(m -> m.downstreamReferences().stream()).anyMatch(ref -> "ROOT_OUTPUT_FULFILLMENT".equals(ref.documentType())));
        loginAs(w.superAdminUserId());
        purchaseReceiptService.reverse(receipt);
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(BigDecimal.ZERO));
        assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(order)).compareTo(BigDecimal.ZERO));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
        assertEquals(0,analysisService.detail(initial.analysisId()).products().getFirst().remainingQty().compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
        assertEquals(0,bigDecimalFor("select sum(known_value_local) from stock_value_events where operation='POSITION_STORE_REVERSE' and source_doc_id=?",receipt).compareTo(new BigDecimal("500")));
    }

    @Test
    void rootSupply_partiallyStockedPurchaseReversalRestoresStockedAndUnstockedQuality(){
        rootPurchaseReversalBoundary(List.of(new BigDecimal("5")),false);
    }

    @Test
    void rootSupply_splitStockedPurchaseReversalKeepsEveryOriginalPartAndCost(){
        rootPurchaseReversalBoundary(List.of(new BigDecimal("3"),new BigDecimal("7")),false);
    }

    @Test
    void rootSupply_shippedPurchaseReceiptCannotBeReversedOrLeavePartialValueFacts(){
        rootPurchaseReversalBoundary(List.of(BigDecimal.TEN),true);
    }

    private void rootPurchaseReversalBoundary(List<BigDecimal> batches,boolean ship){
        World w=seedWorld(ship?"rootRevUsed":batches.size()>1?"rootRevSplit":"rootRevPartial");
        UUID order=createApprovedOrder(w,w.goodsA(),"10","100");loginAs(w.superAdminUserId());
        AnalysisView analysis=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-reverse-boundary-"+order,List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),
                    null,null,null,null,null,LocalDate.of(2026,9,30),BigDecimal.TEN))));
        UUID root=analysis.products().getFirst().rootMaterialLineId();
        UUID purchase=approvePurchaseForAnalysis(w,analysis,w.goodsA());
        UUID receipt=receiveAndPassPurchase(w,purchase,w.goodsA(),BigDecimal.TEN,"root-reverse-"+order,batches);
        loginAs(w.superAdminUserId());
        if(ship){
            var shipmentRequest=shipmentRequest(w,orderItemId(order),w.goodsA(),"10");
            shipmentRequest.setBillDate(BusinessTime.today());
            UUID shipment=shipmentService.create(shipmentRequest).getId();shipThroughWarehouse(shipment);
            long movements=count("select count(*) from stock_movements where source_doc_id=?",receipt);
            assertThrows(ApiException.class,()->purchaseReceiptService.reverse(receipt));
            assertEquals(1,intFor("select status from purchase_receipts where id=?",receipt));
            assertEquals(movements,count("select count(*) from stock_movements where source_doc_id=?",receipt));
            assertEquals(0,count("select count(*) from stock_value_events where operation='POSITION_STORE_REVERSE' and source_doc_id=?",receipt));
            assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(BigDecimal.TEN));
            assertEquals("SHIPPED",shipmentWorkStatus(shipment));
            return;
        }
        purchaseReceiptService.reverse(receipt);
        assertEquals(-1,intFor("select status from purchase_receipts where id=?",receipt));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(BigDecimal.ZERO));
        assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(order)).compareTo(BigDecimal.ZERO));
        assertEquals(batches.size(),count("select count(*) from stock_value_events where operation='POSITION_STORE_REVERSE' and source_doc_id=?",receipt));
        BigDecimal stocked=batches.stream().reduce(BigDecimal.ZERO,BigDecimal::add);
        assertEquals(0,bigDecimalFor("select sum(known_value_local) from stock_value_events where operation='POSITION_STORE_REVERSE' and source_doc_id=?",receipt).compareTo(stocked.multiply(new BigDecimal("50"))));
        assertEquals(0,count("select count(*) from stock_value_nodes node join stock_value_pools pool on pool.id=node.pool_id where pool.goods_id=? and (select count(*) from stock_value_edges edge where edge.parent_node_id=node.id)>2",w.goodsA()));
    }

    @Test
    void rootSupply_existingOnlyIsIdempotentAndHasAReachableCompletedAnalysisRevoke() {
        World w=seedWorld("rootStock");
        UUID order=createApprovedOrder(w,w.goodsC(),"10","100");
        loginAs(w.superAdminUserId());
        AnalysisView initial=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-stock-preview-"+order,List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),
                    null,null,null,null,null,LocalDate.of(2026,9,30),new BigDecimal("10")))));
        UUID root=initial.products().getFirst().rootMaterialLineId();
        jdbc.update("insert into stock_balances(warehouse_id,goods_id,color_id,qty) values (?,?,null,10)",w.warehouseId(),w.goodsC());
        AnalysisView routed=analysisService.saveRoutes(initial.analysisId(),new RouteRequest(initial.version(),
                initial.fingerprint(),"root-stock-route-"+order,List.of(new RouteDecision(root,null,"BUY",null))));
        MaterialView material=routed.flatMaterials().stream().filter(m -> m.materialLineId().equals(root)).findFirst().orElseThrow();
        assertEquals(0,material.allocatedAvailableQty().compareTo(new BigDecimal("10")));
        NotifyRequest request=new NotifyRequest(routed.version(),routed.fingerprint(),"root-stock-notify-"+order,
                "BUY",List.of(root),List.of(),List.of(new SupplyQuantityInput(material.actionGroupKey(),null,
                    BigDecimal.ZERO,BigDecimal.ZERO)));
        AnalysisView completed=analysisCommandService.notifySupply(initial.analysisId(),request);
        assertEquals("COMPLETED",completed.status());
        assertEquals("COMPLETED",analysisCommandService.notifySupply(initial.analysisId(),request).status());
        assertEquals(0,count("select count(*) from preplan_supply_actions where analysis_id=?",initial.analysisId()));
        assertEquals(1,count("select count(*) from preplan_root_output_events where analysis_id=? and event_kind='FULFILL'",initial.analysisId()));
        assertTrue(completed.allowedActions().contains("ROOT_OUTPUT_REVOKE"));
        DownstreamReference allocation=completed.flatMaterials().stream().filter(m -> m.materialLineId().equals(root))
                .flatMap(m -> m.downstreamReferences().stream()).filter(ref -> "ROOT_STOCK_ALLOCATION".equals(ref.documentType())).findFirst().orElseThrow();
        assertNull(allocation.actionId());
        CancelRequest cancel=new CancelRequest(completed.version(),completed.fingerprint(),"root-stock-revoke-"+order,"撤回错误交接");
        AnalysisView restored=analysisCommandService.revokeRootOutput(initial.analysisId(),allocation.documentId(),cancel);
        analysisCommandService.revokeRootOutput(initial.analysisId(),allocation.documentId(),cancel);
        assertEquals("ACTIVE",restored.status());
        assertEquals(0,restored.products().getFirst().remainingQty().compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(order)).compareTo(BigDecimal.ZERO));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsC()).compareTo(new BigDecimal("10")));
        assertEquals(1,count("select count(*) from preplan_root_output_events where analysis_id=? and event_kind='REVERSE'",initial.analysisId()));
    }

    @Test
    void rootSupply_manualRequiresNewReceiptAndDoesNotReusePublicStock() {
        World w=seedWorld("rootManual");
        loginAs(w.superAdminUserId());
        jdbc.update("insert into stock_balances(warehouse_id,goods_id,color_id,qty) values (?,?,null,1)",w.warehouseId(),w.goodsC());
        AnalysisView initial=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-manual-preview-"+w.goodsC(),List.of(new PreviewItem("STOCK",null,w.goodsC(),null,w.unitId(),
                    "root-manual-"+w.goodsC(),"新增备库",LocalDate.of(2026,9,30),new BigDecimal("10")))));
        UUID root=initial.products().getFirst().rootMaterialLineId();
        UUID purchaseLine=approvePurchaseForAnalysis(w,initial,w.goodsC());
        assertEquals(0,bigDecimalFor("select qty from purchase_order_items where id=?",purchaseLine).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(BigDecimal.ZERO));
        UUID receipt=receiveAndPassPurchase(w,purchaseLine,w.goodsC(),new BigDecimal("10"),"root-manual-"+w.goodsC());
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsC()).compareTo(new BigDecimal("11")));
        assertEquals(0,publicAvailable(w.warehouseId(),w.goodsC()).compareTo(new BigDecimal("11")));
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(new BigDecimal("10")));
        loginAs(w.superAdminUserId());
        purchaseReceiptService.reverse(receipt);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsC()).compareTo(BigDecimal.ONE));
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(BigDecimal.ZERO));
    }


    @Test
    void rootSupply_existingStockCannotConsumeAlreadyIssuedFutureDemand() {
        World w=seedWorld("rootFuture");
        UUID order=createApprovedOrder(w,w.goodsC(),"10","100");
        loginAs(w.superAdminUserId());
        PreviewItem source=new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),null,null,null,null,null,
                LocalDate.of(2026,9,30),new BigDecimal("10"));
        AnalysisView initial=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-future-preview-"+order,List.of(source)));
        UUID root=initial.products().getFirst().rootMaterialLineId();
        AnalysisView routed=analysisService.saveRoutes(initial.analysisId(),new RouteRequest(initial.version(),
                initial.fingerprint(),"root-future-route-"+order,List.of(new RouteDecision(root,null,"BUY",null))));
        MaterialView rootMaterial=routed.flatMaterials().stream().filter(m -> m.materialLineId().equals(root)).findFirst().orElseThrow();
        analysisCommandService.notifySupply(initial.analysisId(),new NotifyRequest(routed.version(),routed.fingerprint(),
                "root-future-supply-"+order,"BUY",List.of(root),List.of(),
                List.of(new SupplyQuantityInput(rootMaterial.actionGroupKey(),null,new BigDecimal("5"),BigDecimal.ZERO))));
        jdbc.update("insert into stock_balances(warehouse_id,goods_id,color_id,qty) values (?,?,null,8)",w.warehouseId(),w.goodsC());
        AnalysisView current=analysisService.detail(initial.analysisId());
        AnalysisView refreshed=analysisService.preview(new PreviewRequest(initial.analysisId(),current.version(),current.fingerprint(),
                w.warehouseId(),"root-future-refresh-"+order,List.of(source)));
        MaterialView available=refreshed.flatMaterials().stream().filter(m -> m.materialLineId().equals(root)).findFirst().orElseThrow();
        assertEquals(0,available.allocatedAvailableQty().compareTo(new BigDecimal("5")));
        analysisCommandService.notifySupply(initial.analysisId(),new NotifyRequest(refreshed.version(),refreshed.fingerprint(),
                "root-future-stock-"+order,"BUY",List.of(root),List.of(),
                List.of(new SupplyQuantityInput(available.actionGroupKey(),null,BigDecimal.ZERO,BigDecimal.ZERO))));
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(new BigDecimal("5")));
        UUID purchaseLine=approveExistingAnalysisPurchase(w,initial.analysisId(),w.goodsC());
        receiveAndPassPurchase(w,purchaseLine,w.goodsC(),new BigDecimal("5"),"root-future-"+order);
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(order)).compareTo(new BigDecimal("10")));
        assertEquals(0,publicAvailable(w.warehouseId(),w.goodsC()).compareTo(new BigDecimal("3")));
    }


    @Test
    void rootSupply_existingRevokeRejectsOtherOwnerPickingPickedAndShipped() {
        World w=seedWorld("rootGuard");
        UUID order=createApprovedOrder(w,w.goodsC(),"10","100");
        loginAs(w.superAdminUserId());
        AnalysisView initial=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-guard-preview-"+order,List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),
                    null,null,null,null,null,LocalDate.of(2026,9,30),new BigDecimal("10")))));
        UUID root=initial.products().getFirst().rootMaterialLineId();
        jdbc.update("insert into stock_balances(warehouse_id,goods_id,color_id,qty) values (?,?,null,10)",w.warehouseId(),w.goodsC());
        AnalysisView routed=analysisService.saveRoutes(initial.analysisId(),new RouteRequest(initial.version(),
                initial.fingerprint(),"root-guard-route-"+order,List.of(new RouteDecision(root,null,"BUY",null))));
        AnalysisView completed=analysisCommandService.notifySupply(initial.analysisId(),new NotifyRequest(
                routed.version(),routed.fingerprint(),"root-guard-notify-"+order,"BUY",List.of(root),List.of(),null));
        UUID output=jdbc.queryForObject("select id from preplan_root_output_events where analysis_id=? and event_kind='FULFILL'",UUID.class,initial.analysisId());
        UUID outsider=createUserWithPerms(w,"root-guard-outsider",
                "production_material_analysis:view","production_material_analysis:notify");
        loginAs(outsider);
        assertThrows(ApiException.class,() -> analysisCommandService.revokeRootOutput(initial.analysisId(),output,
                new CancelRequest(completed.version(),completed.fingerprint(),"root-guard-other-"+order,"越权负向验证")));
        loginAs(w.superAdminUserId());
        ShipmentSaveRequest shipment=shipmentRequest(w,orderItemId(order),w.goodsC(),"10");
        shipment.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        UUID shipmentId=shipmentService.create(shipment).getId();
        confirmShipmentFinance(shipmentId);
        WarehouseWorkTransitionRequest transition=new WarehouseWorkTransitionRequest();
        for (String phase:List.of("PICKING","PICKED","SHIPPED")) {
            transition.setTargetStatus(phase);
            shipmentService.transitionWarehouseWork(shipmentId,transition);
            AnalysisView current=analysisService.detail(initial.analysisId());
            ApiException blocked=assertThrows(ApiException.class,() -> analysisCommandService.revokeRootOutput(
                    initial.analysisId(),output,new CancelRequest(current.version(),current.fingerprint(),
                        "root-guard-"+phase+"-"+order,"已进入仓库执行")));
            assertEquals(ErrorCode.CONFLICT,blocked.getCode());
            assertEquals(0,count("select count(*) from preplan_root_output_events where reversed_event_id=?",output));
        }
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where root_material_id=?",root).compareTo(new BigDecimal("10")));
        assertEquals(0,shippedQty(orderItemId(order)).compareTo(new BigDecimal("10")));
    }

    @Test
    void rootSupply_missingBasicUnitFailsBeforeWritingAnInvalidRootSnapshot() {
        World w=seedWorld("rootUnit");
        UUID order=createApprovedOrder(w,w.goodsC(),"1","100");
        loginAs(w.superAdminUserId());
        PreviewItem source=new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),null,null,null,null,null,
                LocalDate.of(2026,9,30),BigDecimal.ONE);
        AnalysisView initial=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-unit-preview-"+order,List.of(source)));
        assertThrows(org.springframework.dao.DataIntegrityViolationException.class,
                ()->jdbc.update("update goods set unit_id=null where id=?",w.goodsC()),
                "已使用货品必须保留原基本单位，不能为分析测试破坏真实数量历史");
        assertEquals(w.unitId(),jdbc.queryForObject("select unit_id from goods where id=?",UUID.class,w.goodsC()));
        assertEquals(initial.fingerprint(),analysisService.detail(initial.analysisId()).fingerprint());
        UUID unused=UUID.randomUUID();
        jdbc.update("""
                insert into goods(id,code,name,source_type,status,code_sequence)
                values(?,?,'未使用且缺基本单位的主档','自制','使用',(select coalesce(max(code_sequence),0)+1 from goods))
                """,unused,"ROOT-NO-UNIT-"+unused);
        assertEquals(0,count("select count(*) from goods where id=? and quantity_unit_locked",unused));
        String invalidKey="root-unit-missing-"+unused;
        ApiException blocked=assertThrows(ApiException.class,() -> analysisService.preview(new PreviewRequest(
                null,null,null,w.warehouseId(),invalidKey,
                List.of(new PreviewItem("OTHER",null,unused,null,w.unitId(),invalidKey,
                        "核对缺少基本单位的新主档是否原子拒绝",LocalDate.of(2026,9,30),BigDecimal.ONE)))));
        assertEquals(ErrorCode.VALIDATION_FAILED,blocked.getCode());
        assertTrue(blocked.getMessage().contains("单位"));
        assertEquals(0,count("select count(*) from production_material_analyses where initial_idempotency_key=?",invalidKey));
        assertEquals(0,count("select count(*) from production_material_analysis_items where goods_id=?",unused));
        assertEquals(0,count("select count(*) from production_material_analysis_materials where goods_id=?",unused));
        assertEquals(0,count("select count(*) from goods where id=? and quantity_unit_locked",unused),"失败分析不得留下首次数量使用标记");
    }


    @Test
    void rootSupply_oneBoxTransfersTwentyBaseUnitsWithoutDoubleCounting() {
        World w=seedWorld("rootTwenty");
        loginAs(w.superAdminUserId());
        UUID box=UUID.randomUUID();
        jdbc.update("insert into units(id,code,name) values (?,?,'box')",box,"ROOT-BOX-"+box);
        var request=orderRequest(w,w.goodsC(),"1","100");
        request.getItems().getFirst().setUnitId(box);
        request.getItems().getFirst().setUnitRate(new BigDecimal("20"));
        UUID order=salesOrderService.create(request).getId();
        salesOrderService.approve(order);
        confirmInitialSalesFinance(order);
        AnalysisView initial=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "root-twenty-preview-"+order,List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(order),
                    null,null,null,null,null,LocalDate.of(2026,9,30),BigDecimal.ONE))));
        ProductView product=initial.products().getFirst();
        MaterialView material=initial.flatMaterials().stream().filter(m -> m.materialLineId().equals(product.rootMaterialLineId())).findFirst().orElseThrow();
        assertEquals(box,product.unitId());
        assertEquals(w.unitId(),material.unitId());
        assertEquals(0,material.requiredQty().compareTo(new BigDecimal("20")));
        UUID purchaseLine=approvePurchaseForAnalysis(w,initial,w.goodsC());
        assertEquals(0,bigDecimalFor("select qty from purchase_order_items where id=?",purchaseLine).compareTo(new BigDecimal("20")));
        receiveAndPassPurchase(w,purchaseLine,w.goodsC(),new BigDecimal("20"),"root-twenty-"+order);
        assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where id=?",product.analysisLineId()).compareTo(BigDecimal.ONE));
        assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(order)).compareTo(BigDecimal.ONE));
        assertEquals(0,bigDecimalFor("select sum(qty-consumed_qty-released_qty) from stock_reservations where order_item_id=? and status=0",orderItemId(order)).compareTo(new BigDecimal("20")));
    }

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
    // ADR-065 备料下达同批合并：一次通知里的多条 BUY 缺口必须合并为「一张」采购申请（多货品
    // 明细），多条无子层 SUBCONTRACT 合并为一张委外申请；明细行仍逐 action 锚定。订货侧照旧
    // 按供应商分组（同一张申请的两行在一张订货单）。撤回共享单据的任务时整批一并撤回、单据
    // 只红冲一次，且不影响另一张（采购）申请。
    // ---------------------------------------------------------------------------------------------
    @Test
    void materialAnalysis_bulkNotifyMergesOneRequestPerRouteAndBatchCancel() {
        World w = seedWorld("sMA65");
        // 产品 F(自制) 直接组件：两件采购(b1/b2) + 两件无子层委外(s1/s2)，均无库存。
        UUID f = UUID.randomUUID(), b1 = UUID.randomUUID(), b2 = UUID.randomUUID(),
                s1 = UUID.randomUUID(), s2 = UUID.randomUUID();
        insertGoods(f, "F-sMA65", "成品F-sMA65", "自制", w.unitId(), w.unitLegacy());
        insertGoods(b1, "B1-sMA65", "采购件B1-sMA65", "采购", w.unitId(), w.unitLegacy());
        insertGoods(b2, "B2-sMA65", "采购件B2-sMA65", "采购", w.unitId(), w.unitLegacy());
        insertGoods(s1, "S1-sMA65", "委外件S1-sMA65", "委外", w.unitId(), w.unitLegacy());
        insertGoods(s2, "S2-sMA65", "委外件S2-sMA65", "委外", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id in (?, ?, ?, ?)",
                w.supplierId(), b1, b2, s1, s2);
        insertBom(f, b1, "2");
        insertBom(f, b2, "3");
        insertBom(f, s1, "1");
        insertBom(f, s2, "1");
        UUID orderId = createApprovedOrder(w, f, "10", "100");
        UUID orderItemId = orderItemId(orderId);
        UUID planner = createUserWithPerms(w, "planner-ma65",
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify");
        loginAs(planner);

        AnalysisView view = analysisService.preview(new PreviewRequest(null, null, null,
                w.warehouseId(), "idem-ma65-" + orderItemId, List.of(new PreviewItem(
                        "SALES_ORDER_ITEM", orderItemId, null, null, null, null, null,
                        LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        List<MaterialView> buyRows = view.flatMaterials().stream()
                .filter(m -> (m.goodsId().equals(b1) || m.goodsId().equals(b2)) && m.actionable())
                .toList();
        List<MaterialView> subRows = view.flatMaterials().stream()
                .filter(m -> (m.goodsId().equals(s1) || m.goodsId().equals(s2)) && m.actionable())
                .toList();
        assertEquals(2, buyRows.size(), "两件采购均为 F 直接层可操作缺料");
        assertEquals(2, subRows.size(), "两件无子层委外均为 F 直接层可操作缺料");

        List<RouteDecision> routeDecisions = new java.util.ArrayList<>();
        for (MaterialView row : buyRows) {
            routeDecisions.add(new RouteDecision(
                    row.materialLineId(), row.actionGroupKey(), row.sourceSuggestion(), null));
        }
        for (MaterialView row : subRows) {
            routeDecisions.add(new RouteDecision(
                    row.materialLineId(), row.actionGroupKey(), row.sourceSuggestion(), null));
        }
        analysisService.saveRoutes(analysisId, new RouteRequest(view.version(), view.fingerprint(),
                "routes-ma65-" + analysisId, routeDecisions));
        AnalysisView routed = analysisService.detail(analysisId);

        // 一次通知同时下达两件采购 → 必须只有一张采购申请、两条明细、两条任务各自锚定。
        analysisCommandService.notifySupply(analysisId, new NotifyRequest(routed.version(),
                routed.fingerprint(), "notify-ma65-buy-" + analysisId, "BUY",
                buyRows.stream().map(MaterialView::materialLineId).toList(), List.of(), null));
        assertEquals(2, count("select count(*) from preplan_supply_actions "
                        + "where analysis_id = ? and route = 'BUY' and status = 'CREATED'",
                analysisId), "两条采购任务各自落 action（明细锚定粒度不变）");
        assertEquals(1, count("""
                        select count(distinct action.external_document_id)
                        from preplan_supply_actions action
                        where action.analysis_id = ?
                          and action.route = 'BUY'
                          and action.status = 'CREATED'
                        """, analysisId), "ADR-065：两条 BUY 任务共享同一张采购申请");
        Map<String, Object> purchaseDoc = jdbc.queryForMap("""
                select request.id as request_id, count(distinct item.id) as item_count
                from purchase_requests request
                join purchase_request_items item on item.request_id = request.id
                 and item.is_deleted = false
                join preplan_supply_actions action
                  on action.external_document_id = request.id
                 and action.analysis_id = ?
                where request.is_deleted = false
                group by request.id
                """, analysisId);
        assertEquals(((Number) purchaseDoc.get("item_count")).intValue(), 2,
                "合并后的采购申请包含两条货品明细");
        UUID requestId = (UUID) purchaseDoc.get("request_id");

        // 一次通知同时下达两件无子层委外 → 一张委外申请、两条明细。
        AnalysisView afterBuy = analysisService.detail(analysisId);
        analysisCommandService.notifySupply(analysisId, new NotifyRequest(afterBuy.version(),
                afterBuy.fingerprint(), "notify-ma65-sub-" + analysisId, "SUBCONTRACT",
                subRows.stream().map(MaterialView::materialLineId).toList(), List.of(), null));
        assertEquals(1, count("""
                        select count(distinct action.external_document_id)
                        from preplan_supply_actions action
                        where action.analysis_id = ?
                          and action.route = 'SUBCONTRACT'
                          and action.status = 'CREATED'
                        """, analysisId), "ADR-065：两条无子层委外任务共享同一张委外申请");

        // 采购侧照旧按供应商分解：同一张申请的两条明细可在一张订货单下单。
        // 申请明细按维度稳定排序，行号顺序与货品插入顺序无关——按货品直查各自明细。
        UUID itemForB1 = jdbc.queryForObject(
                "select id from purchase_request_items where request_id = ? "
                        + "and goods_id = ? and is_deleted = false",
                UUID.class, requestId, b1);
        UUID itemForB2 = jdbc.queryForObject(
                "select id from purchase_request_items where request_id = ? "
                        + "and goods_id = ? and is_deleted = false",
                UUID.class, requestId, b2);
        assertNotNull(itemForB1, "b1 在合并申请中有独立明细行");
        assertNotNull(itemForB2, "b2 在合并申请中有独立明细行");
        loginAs(w.superAdminUserId());
        com.uten.imp.features.purchase.order.dto.OrderSaveRequest orderReq =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderReq.setSettlementMethodId(activeSettlementMethodId());
        orderReq.setBillDate(LocalDate.of(2026, 9, 2));
        orderReq.setSupplierId(w.supplierId());
        orderReq.setWarehouseId(w.warehouseId());
        orderReq.setCurrencyId(w.currencyId());
        orderReq.setExchangeRate(BigDecimal.ONE);
        orderReq.setTaxRate(BigDecimal.ZERO);
        orderReq.setItems(List.of(
                ma65OrderLine(w, itemForB1, b1, "20"),
                ma65OrderLine(w, itemForB2, b2, "30")));
        purchaseOrderService.createBatch(orderReq);
        assertEquals(2, count("""
                        select count(*) from purchase_order_items item
                        join purchase_orders o on o.id = item.order_id
                        where o.supplier_id = ?
                          and o.is_deleted = false
                          and item.is_deleted = false
                          and item.goods_id in (?, ?)
                        """, w.supplierId(), b1, b2),
                "一张订货单（同一供应商）承载合并申请的两条明细");

        // 撤回共享委外申请的一个任务 → 整批两条一并撤回、申请红冲一次；采购申请不受影响。
        UUID subActionId = jdbc.queryForObject("""
                select id from preplan_supply_actions
                where analysis_id = ? and route = 'SUBCONTRACT' and status = 'CREATED'
                order by created_at limit 1
                """, UUID.class, analysisId);
        UUID applicationId = jdbc.queryForObject(
                "select external_document_id from preplan_supply_actions where id = ?",
                UUID.class, subActionId);
        loginAs(planner);
        AnalysisView beforeCancel = analysisService.detail(analysisId);
        analysisCommandService.cancelAction(analysisId, subActionId, new CancelRequest(
                beforeCancel.version(), beforeCancel.fingerprint(),
                "cancel-ma65-" + subActionId, "整批撤回共享委外申请"));
        assertEquals(0, count("select count(*) from preplan_supply_actions "
                        + "where analysis_id = ? and route = 'SUBCONTRACT' "
                        + "and status in ('OPEN','CREATED','IN_PROGRESS')",
                analysisId), "撤回一个共享任务 → 同批两条委外任务全部撤回");
        assertEquals(-1, intFor("select status from subcontract_applications where id = ?",
                applicationId), "共享委外申请整批红冲一次");
        assertEquals(2, count("select count(*) from preplan_supply_actions "
                        + "where analysis_id = ? and route = 'BUY' and status = 'CREATED'",
                analysisId), "采购侧两条任务不受委外整批撤回影响");
        assertEquals(1, intFor("select status from purchase_requests where id = ?",
                requestId), "采购申请保持已审核，未被连带红冲");
    }

    /** ADR-065 用例的订货明细行：引用合并申请的明细 + 供应商价格。 */
    private com.uten.imp.features.purchase.order.dto.OrderItemLine ma65OrderLine(
            World w, UUID requestItemId, UUID goodsId, String qty) {
        com.uten.imp.features.purchase.order.dto.OrderItemLine line =
                new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(goodsId);
        line.setRequestItemId(requestItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal("50")));
        line.setAmountLocal(new BigDecimal(qty).multiply(new BigDecimal("50")));
        return line;
    }

    // ---------------------------------------------------------------------------------------------
    // ADR-069 / V463 order-item source merge: two analyses' BUY shortages for the SAME
    // goods collapse into ONE order line (requestItemIds merge). Proves end to end:
    // FIFO source split (last absorbs the overbooked remainder), per-source pending
    // occupation in the workbench view + decomposition preview, per-source ordered_qty
    // write-back on finance approval (V465: exceeding a source's request qty no longer
    // trips the retired DB cap), and IQC stock-in exact-pegging BOTH analyses with the
    // overbooked tail left as public stock.
    // ---------------------------------------------------------------------------------------------
    @Test
    void orderSourceMerge_ordersApprovalAccountingAndPegsBothAnalyses() {
        World w = seedWorld("sMA69");
        // 两个自制产品共用同一采购件 M：PA×2（10 只 → M 缺 20）、PB×3（10 只 → M 缺 30）。
        UUID productA = UUID.randomUUID(), productB = UUID.randomUUID(),
                material = UUID.randomUUID();
        insertGoods(productA, "PA-sMA69", "合并测试成品A", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(productB, "PB-sMA69", "合并测试成品B", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "M-sMA69", "共用采购件M", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(productA, material, "2");
        insertBom(productB, material, "3");
        loginAs(w.superAdminUserId());

        // 两个独立分析（OTHER 预览），各自对 M 有一条可操作 BUY 缺口；
        // A 需求日更早（FIFO 首来源），B 靠后（末位吸收超采）。
        java.util.List<LocalDate> needDates = List.of(
                LocalDate.of(2026, 9, 1), LocalDate.of(2026, 9, 5));
        java.util.List<UUID> analyses = new java.util.ArrayList<>();
        for (int index = 0; index < 2; index++) {
            UUID product = index == 0 ? productA : productB;
            AnalysisView view = analysisService.preview(new PreviewRequest(
                    null, null, null, w.warehouseId(),
                    "sma69-" + product,
                    List.of(new PreviewItem(
                            "OTHER", null, product, null, w.unitId(),
                            "sMA69-" + product, "合并订货行回归",
                            needDates.get(index), new BigDecimal("10")))));
            MaterialView buyRow = view.flatMaterials().stream()
                    .filter(m -> m.goodsId().equals(material) && m.actionable())
                    .findFirst().orElseThrow();
            AnalysisView routed = analysisService.saveRoutes(
                    view.analysisId(),
                    new RouteRequest(view.version(), view.fingerprint(),
                            "route-sma69-" + view.analysisId(),
                            List.of(new RouteDecision(
                                    buyRow.materialLineId(),
                                    buyRow.actionGroupKey(), "BUY", null))));
            analysisCommandService.notifySupply(view.analysisId(), new NotifyRequest(
                    routed.version(), routed.fingerprint(),
                    "notify-sma69-" + view.analysisId(), "BUY",
                    List.of(buyRow.materialLineId()), List.of(), null));
            analyses.add(view.analysisId());
        }
        UUID analysisA = analyses.get(0), analysisB = analyses.get(1);

        // 两张采购申请（各自一条 M 明细）：按分析定位。
        UUID itemA = jdbc.queryForObject("""
                select item.id from preplan_supply_actions action
                join purchase_request_items item
                  on item.request_id = action.external_document_id
                 and item.is_deleted = false
                where action.analysis_id = ? and action.route = 'BUY'
                  and action.status = 'CREATED' and item.goods_id = ?
                """, UUID.class, analysisA, material);
        UUID itemB = jdbc.queryForObject("""
                select item.id from preplan_supply_actions action
                join purchase_request_items item
                  on item.request_id = action.external_document_id
                 and item.is_deleted = false
                where action.analysis_id = ? and action.route = 'BUY'
                  and action.status = 'CREATED' and item.goods_id = ?
                """, UUID.class, analysisB, material);
        BigDecimal qtyA = jdbc.queryForObject(
                "select qty from purchase_request_items where id = ?",
                BigDecimal.class, itemA);
        BigDecimal qtyB = jdbc.queryForObject(
                "select qty from purchase_request_items where id = ?",
                BigDecimal.class, itemB);
        assertEquals(0, qtyA.compareTo(new BigDecimal("20")), "分析A的 M 申请量 20");
        assertEquals(0, qtyB.compareTo(new BigDecimal("30")), "分析B的 M 申请量 30");

        // 一行合并下单 55（超采 5）：数量超两张申请剩余之和，末位来源吸收超额。
        com.uten.imp.features.purchase.order.dto.OrderSaveRequest order =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setSettlementMethodId(activeSettlementMethodId());
        order.setBillDate(LocalDate.of(2026, 9, 2));
        order.setSupplierId(w.supplierId());
        order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(w.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line =
                ma65OrderLine(w, itemA, material, "55");
        line.setRequestItemIds(List.of(itemA, itemB));
        order.setItems(List.of(line));
        purchaseOrderService.createBatch(order);

        UUID orderItemId = jdbc.queryForObject("""
                select item.id from purchase_order_items item
                join purchase_orders o on o.id = item.order_id
                where o.is_deleted = false and item.is_deleted = false
                  and item.goods_id = ? and o.supplier_id = ?
                """, UUID.class, material, w.supplierId());
        assertEquals(1, count("""
                        select count(*) from purchase_order_items item
                        join purchase_orders o on o.id = item.order_id
                        where o.is_deleted = false and item.is_deleted = false
                          and o.supplier_id = ?
                          and item.goods_id = ?
                        """, w.supplierId(), material),
                "同货品合并后订货单只有一行 M");
        Map<UUID, BigDecimal> allocByItem = new java.util.HashMap<>();
        jdbc.query("""
                select request_item_id, alloc_qty from purchase_order_item_sources
                where order_item_id = ?
                """, rs -> {
            allocByItem.put(rs.getObject(1, UUID.class), rs.getBigDecimal(2));
        }, orderItemId);
        assertEquals(2, allocByItem.size(), "合并行落两条来源分配");
        // 首来源吃满剩余 20、末位吸收超额 35（次序无关：两组份额 {20, 35} 且总和 55）。
        assertEquals(0, allocByItem.get(itemA).add(allocByItem.get(itemB))
                        .compareTo(new BigDecimal("55")),
                "来源份额总和 = 行数量 55");
        java.util.List<BigDecimal> shares = new java.util.ArrayList<>(
                allocByItem.values());
        shares.sort(BigDecimal::compareTo);
        assertEquals(0, shares.get(0).compareTo(new BigDecimal("20")),
                "较小份额 = 首来源剩余量 20");
        assertEquals(0, shares.get(1).compareTo(new BigDecimal("35")),
                "较大份额 = 末位吸收超额 30+5");

        // 送审后任务台/预览按来源份额占用（不再串占首来源）。
        // 送审 fail-closed 要求审核员池非空：先建审核员再 submit（与既有链路一致）。
        UUID orderId = jdbc.queryForObject(
                "select order_id from purchase_order_items where id = ?",
                UUID.class, orderItemId);
        UUID reviewer = createApprover(w);
        financeApproval.submit("PURCHASE", orderId);
        assertEquals(1, count("""
                        select count(*) from v_procurement_decomposition_tasks
                        where action_doc_id = ?
                          and task_status = 'ORDER_PENDING_APPROVAL'
                        """, orderId), "合并行在等待财务档只有一行（数量 55）");
        assertEquals(0, count("""
                        select count(*) from v_procurement_decomposition_tasks
                        where action_item_id in (?, ?)
                          and task_status = 'WAITING_ORDER'
                        """, itemA, itemB), "两张申请的剩余量都被来源份额占满");
        com.uten.imp.common.web.ApiException consumed = assertThrows(
                com.uten.imp.common.web.ApiException.class,
                () -> purchaseRequestService.decompositionPreview(List.of(itemA, itemB)),
                "分解预览按来源份额计占用：两行剩余量都为 0 → 拒绝");
        assertTrue(consumed.getMessage().contains("已全部分解")
                        || consumed.getMessage().contains("无可分解"),
                "预览拒绝原因指向无可分解数量");

        // 财务批准：ordered_qty 按来源份额回写（V465：末位 35 > 申请 30 不再被 DB 拒绝）。
        loginAs(reviewer);
        approvePendingFinance("PURCHASE", orderId);
        loginAs(w.superAdminUserId());

        assertEquals(0, jdbc.queryForObject(
                        "select ordered_qty from purchase_request_items where id = ?",
                        BigDecimal.class, itemA)
                .compareTo(allocByItem.get(itemA)),
                "分析A申请行 ordered_qty = 其来源份额");
        assertEquals(0, jdbc.queryForObject(
                        "select ordered_qty from purchase_request_items where id = ?",
                        BigDecimal.class, itemB)
                .compareTo(allocByItem.get(itemB)),
                "分析B申请行 ordered_qty = 其来源份额（含超采，不再 23514）");
        assertEquals(2, count("select count(*) from purchase_requests r "
                        + "join purchase_request_items i on i.request_id = r.id "
                        + "where i.id in (?, ?) and r.is_closed", itemA, itemB),
                "两张申请都因覆盖（含超采）结案");

        // 收货 55 → IQC PASS → 仓库确认入库：exact-peg 把两个分析的缺口各自补上，
        // 超采尾巴 5 不绑定（公共现货）。
        receiveAndPassPurchase(w, orderItemId, material, new BigDecimal("55"),
                "sma69-merge");
        assertEquals(0, stockBalance(w.warehouseId(), material)
                        .compareTo(new BigDecimal("55")),
                "仓库确认后 M 真实库存 55");
        Map<UUID, BigDecimal> peggedByAnalysis = new java.util.HashMap<>();
        jdbc.query("""
                        select owner_id, sum(qty) from stock_reservations
                        where owner_type = 'PREPLAN_ANALYSIS'
                          and is_deleted = false and status = 0
                        group by owner_id
                        """, rs -> {
            peggedByAnalysis.put(rs.getObject(1, UUID.class),
                    rs.getBigDecimal(2));
        });
        assertEquals(0, peggedByAnalysis.getOrDefault(analysisA, BigDecimal.ZERO)
                        .compareTo(new BigDecimal("20")),
                "分析A 入库归属 20（FIFO 首来源）");
        assertEquals(0, peggedByAnalysis.getOrDefault(analysisB, BigDecimal.ZERO)
                        .compareTo(new BigDecimal("30")),
                "分析B 入库归属 30（其 action 分摊容量）；超采 5 为公共现货");
        assertEquals(2, count("""
                        select count(*) from preplan_analysis_stock_exact_pegs peg
                        join stock_reservations r on r.id = peg.stock_reservation_id
                        where r.is_deleted = false
                          and r.owner_id in (?, ?)
                        """, analysisA, analysisB),
                "两个分析各得一条 exact-peg（合并行不串归属）");
    }

    @Test
    void publicSurplus_claimAcrossAnalyses_partialStockInKeepsDemandFirst() {
        World w = seedWorld("sMA72");
        UUID productA = UUID.randomUUID();
        UUID productB = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(productA, "PA-sMA72", "公共余量成品A", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(productB, "PB-sMA72", "公共余量成品B", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "M-sMA72", "公共余量采购件", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(productA, material, "1");
        insertBom(productB, material, "1");
        loginAs(w.superAdminUserId());

        AnalysisView a = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "sma72-analysis-a",
                List.of(new PreviewItem("OTHER", null, productA, null, w.unitId(),
                        "sMA72-A", "A需求500并公共备货1500",
                        LocalDate.of(2026, 9, 15), new BigDecimal("500")))));
        MaterialView aMaterial = a.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.actionable())
                .findFirst().orElseThrow();
        AnalysisView aRouted = analysisService.saveRoutes(a.analysisId(),
                new RouteRequest(a.version(), a.fingerprint(), "route-sma72-a",
                        List.of(new RouteDecision(aMaterial.materialLineId(),
                                aMaterial.actionGroupKey(), "BUY", null))));
        AnalysisView aNotified = analysisCommandService.notifySupply(a.analysisId(),
                new NotifyRequest(aRouted.version(), aRouted.fingerprint(),
                        "notify-sma72-a", "BUY",
                        List.of(aMaterial.materialLineId()), List.of(),
                        List.of(new SupplyQuantityInput(
                                aMaterial.actionGroupKey(), null,
                                new BigDecimal("500"), BigDecimal.ZERO,
                                new BigDecimal("1500")))));

        Object[] source = jdbc.queryForObject("""
                select action.id, allocation.external_item_id,
                       action.public_surplus_external_item_id
                from preplan_supply_actions action
                join preplan_supply_action_allocations allocation
                  on allocation.action_id = action.id
                where action.analysis_id = ? and action.operation_type = 'SUPPLY'
                  and action.route = 'BUY' and action.status = 'CREATED'
                """, (rs, rowNum) -> new Object[]{
                rs.getObject(1, UUID.class), rs.getObject(2, UUID.class),
                rs.getObject(3, UUID.class)}, a.analysisId());
        UUID sourceActionId = (UUID) source[0];
        UUID demandItemId = (UUID) source[1];
        UUID publicItemId = (UUID) source[2];
        assertNotNull(publicItemId);
        assertEquals(0, jdbc.queryForObject(
                        "select requested_qty from preplan_supply_actions where id = ?",
                        BigDecimal.class, sourceActionId)
                .compareTo(new BigDecimal("500")));
        assertEquals(0, jdbc.queryForObject(
                        "select public_surplus_qty from preplan_supply_actions where id = ?",
                        BigDecimal.class, sourceActionId)
                .compareTo(new BigDecimal("1500")));
        assertEquals(0, jdbc.queryForObject(
                        "select sum(allocated_qty) from preplan_supply_action_allocations where action_id = ?",
                        BigDecimal.class, sourceActionId)
                .compareTo(new BigDecimal("500")),
                "公共1500绝不能进入A的需求allocation");

        com.uten.imp.features.purchase.order.dto.OrderSaveRequest order =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setSettlementMethodId(activeSettlementMethodId());
        order.setBillDate(LocalDate.of(2026, 9, 2));
        order.setSupplierId(w.supplierId());
        order.setWarehouseId(null);
        order.setCurrencyId(w.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine orderLine =
                ma65OrderLine(w, demandItemId, material, "2000");
        orderLine.setRequestItemIds(List.of(demandItemId, publicItemId));
        orderLine.setDeliverDate(LocalDate.of(2026, 9, 10));
        order.setItems(List.of(orderLine));
        purchaseOrderService.createBatch(order);
        UUID orderItemId = jdbc.queryForObject("""
                select item.id from purchase_order_items item
                join purchase_order_item_sources source on source.order_item_id = item.id
                where source.request_item_id = ? and item.is_deleted = false
                """, UUID.class, demandItemId);
        UUID orderId = jdbc.queryForObject(
                "select order_id from purchase_order_items where id = ?",
                UUID.class, orderItemId);
        assertNull(jdbc.queryForObject(
                "select warehouse_id from purchase_orders where id = ?",
                UUID.class, orderId), "订货仓为空，预计仓必须回到source action意图");
        UUID reviewer = createApprover(w);
        financeApproval.submit("PURCHASE", orderId);
        loginAs(reviewer);
        approvePendingFinance("PURCHASE", orderId);
        loginAs(w.superAdminUserId());

        AnalysisView aRefreshed = analysisService.preview(new PreviewRequest(
                a.analysisId(), aNotified.version(), aNotified.fingerprint(),
                w.warehouseId(), "sma72-analysis-a-refresh",
                List.of(new PreviewItem("OTHER", null, productA, null, w.unitId(),
                        "sMA72-A", "A需求500并公共备货1500",
                        LocalDate.of(2026, 9, 15), new BigDecimal("500")))));
        MaterialView aAfterOrder = aRefreshed.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow();
        assertEquals(0, aAfterOrder.inboundQty().compareTo(new BigDecimal("500")));
        assertEquals(0, aAfterOrder.publicSurplusApprovedInboundQty()
                .compareTo(new BigDecimal("1500")));
        assertEquals(0, aAfterOrder.publicSurplusRemainingQty()
                .compareTo(BigDecimal.ZERO), "本分析自己的公共备货只展示，不自我claim");
        assertEquals(0, aAfterOrder.additionalSupplyRecommendedQty()
                .compareTo(BigDecimal.ZERO));
        assertTrue(aAfterOrder.sharedFutureSupplyRefs().stream()
                .anyMatch(ref -> ref.sourceIsCurrentAnalysis()
                        && "BUY".equals(ref.route())
                        && LocalDate.of(2026, 9, 10).equals(ref.expectedDate())));

        AnalysisView b = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "sma72-analysis-b",
                List.of(new PreviewItem("OTHER", null, productB, null, w.unitId(),
                        "sMA72-B", "B需求1000采用A公共在途",
                        LocalDate.of(2026, 9, 15), new BigDecimal("1000")))));
        MaterialView bMaterial = b.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.actionable())
                .findFirst().orElseThrow();
        AnalysisView bRouted = analysisService.saveRoutes(b.analysisId(),
                new RouteRequest(b.version(), b.fingerprint(), "route-sma72-b",
                        List.of(new RouteDecision(bMaterial.materialLineId(),
                                bMaterial.actionGroupKey(), "BUY", null))));
        MaterialView beforeClaim = bRouted.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow();
        assertEquals(0, beforeClaim.publicSurplusRemainingQty()
                .compareTo(new BigDecimal("1500")));
        assertTrue(beforeClaim.sharedFutureSupplyRefs().stream()
                .anyMatch(ref -> !ref.sourceIsCurrentAnalysis()
                        && "BUY".equals(ref.route())
                        && LocalDate.of(2026, 9, 10).equals(ref.expectedDate())));

        AnalysisView claimed = analysisCommandService.claimSharedFuture(
                b.analysisId(), new ClaimSharedFutureRequest(
                        bRouted.version(), bRouted.fingerprint(),
                        "claim-sma72-b", List.of(bMaterial.actionGroupKey())));
        MaterialView claimedMaterial = claimed.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow();
        assertEquals(0, claimedMaterial.sharedFutureClaimedQty()
                .compareTo(new BigDecimal("1000")));
        assertEquals(0, claimedMaterial.additionalSupplyRecommendedQty()
                .compareTo(BigDecimal.ZERO));
        assertEquals(0, claimedMaterial.publicSurplusRemainingQty()
                .compareTo(new BigDecimal("500")));

        receiveAndPassPurchase(w, orderItemId, material,
                new BigDecimal("800"), "sma72-partial");
        // Warehouse confirmation helper intentionally switches to a scoped
        // warehouse employee. Restore the analysis owner before reading B.
        loginAs(w.superAdminUserId());
        assertEquals(0, jdbc.queryForObject("""
                        select coalesce(sum(r.qty-r.consumed_qty-r.released_qty),0)
                        from stock_reservations r
                        where r.owner_type='PREPLAN_ANALYSIS' and r.owner_id=?
                          and r.goods_id=? and r.status=0 and r.is_deleted=false
                        """, BigDecimal.class, a.analysisId(), material)
                .compareTo(new BigDecimal("500")));
        assertEquals(0, jdbc.queryForObject("""
                        select coalesce(sum(r.qty-r.consumed_qty-r.released_qty),0)
                        from stock_reservations r
                        where r.owner_type='PREPLAN_ANALYSIS' and r.owner_id=?
                          and r.goods_id=? and r.status=0 and r.is_deleted=false
                        """, BigDecimal.class, b.analysisId(), material)
                .compareTo(new BigDecimal("300")));

        MaterialView afterPartial = analysisService.detail(b.analysisId())
                .flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow();
        assertEquals(0, afterPartial.inboundQty().compareTo(new BigDecimal("700")),
                "B采用1000，部分入库exact 300后仍有700在途");
        assertEquals(0, afterPartial.publicSurplusRemainingQty()
                .compareTo(new BigDecimal("500")),
                "公共未认领500不被A/B重复占用");
        assertEquals(0, afterPartial.additionalSupplyRecommendedQty()
                .compareTo(BigDecimal.ZERO));
        assertEquals(0, jdbc.queryForObject(
                        "select available_to_claim_qty from v_preplan_public_surplus_source_state where source_action_id = ?",
                        BigDecimal.class, sourceActionId)
                .compareTo(new BigDecimal("500")));
        assertEquals(aNotified.analysisId(), a.analysisId());
    }

    @Test
    void runtimeDirectOverorder_becomesClaimableWithoutMutatingExactDemand() {
        World w = seedWorld("sMA74");
        UUID productA = UUID.randomUUID();
        UUID productB = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(productA, "PA-sMA74", "运行时超采成品A", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(productB, "PB-sMA74", "运行时超采成品B", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "M-sMA74", "运行时超采件", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(productA, material, "1");
        insertBom(productB, material, "1");
        loginAs(w.superAdminUserId());

        AnalysisView a = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "sma74-analysis-a",
                List.of(new PreviewItem("OTHER", null, productA, null, w.unitId(),
                        "sMA74-A", "A需求500直接订2000",
                        LocalDate.of(2026, 9, 20), new BigDecimal("500")))));
        MaterialView aMaterial = a.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.actionable())
                .findFirst().orElseThrow();
        AnalysisView routedA = analysisService.saveRoutes(a.analysisId(),
                new RouteRequest(a.version(), a.fingerprint(), "route-sma74-a",
                        List.of(new RouteDecision(aMaterial.materialLineId(),
                                aMaterial.actionGroupKey(), "BUY", null))));
        AnalysisView notifiedA = analysisCommandService.notifySupply(a.analysisId(),
                new NotifyRequest(routedA.version(), routedA.fingerprint(),
                        "notify-sma74-a", "BUY",
                        List.of(aMaterial.materialLineId()), List.of(),
                        List.of(new SupplyQuantityInput(
                                aMaterial.actionGroupKey(), null,
                                new BigDecimal("500"), BigDecimal.ZERO,
                                BigDecimal.ZERO))));
        Object[] source = jdbc.queryForObject("""
                select action.id, allocation.external_item_id
                from preplan_supply_actions action
                join preplan_supply_action_allocations allocation
                  on allocation.action_id=action.id
                where action.analysis_id=? and action.operation_type='SUPPLY'
                  and action.route='BUY' and action.status='CREATED'
                """, (rs, rowNum) -> new Object[]{
                rs.getObject(1, UUID.class), rs.getObject(2, UUID.class)},
                a.analysisId());
        UUID sourceActionId = (UUID) source[0];
        UUID demandItemId = (UUID) source[1];

        com.uten.imp.features.purchase.order.dto.OrderSaveRequest order =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setSettlementMethodId(activeSettlementMethodId());
        order.setBillDate(LocalDate.of(2026, 9, 4));
        order.setSupplierId(w.supplierId());
        order.setCurrencyId(w.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        var orderLine = ma65OrderLine(w, demandItemId, material, "2000");
        orderLine.setDeliverDate(LocalDate.of(2026, 9, 12));
        order.setItems(List.of(orderLine));
        purchaseOrderService.createBatch(order);
        UUID orderId = jdbc.queryForObject("""
                select item.order_id from purchase_order_items item
                join purchase_order_item_sources source
                  on source.order_item_id=item.id
                where source.request_item_id=? and item.is_deleted=false
                order by item.created_at desc limit 1
                """, UUID.class, demandItemId);
        UUID reviewer = createApprover(w);
        financeApproval.submit("PURCHASE", orderId);
        loginAs(reviewer);
        approvePendingFinance("PURCHASE", orderId);
        loginAs(w.superAdminUserId());

        assertEquals(0, jdbc.queryForObject(
                        "select requested_qty from preplan_supply_actions where id=?",
                        BigDecimal.class, sourceActionId)
                .compareTo(new BigDecimal("500")));
        assertEquals(0, jdbc.queryForObject(
                        "select public_surplus_qty from preplan_supply_actions where id=?",
                        BigDecimal.class, sourceActionId).compareTo(BigDecimal.ZERO),
                "运行时超采不得改写已外部化action的冻结字段");
        assertEquals(0, jdbc.queryForObject("""
                        select sum(case event_type when 'GRANT' then qty else -qty end)
                        from preplan_public_supply_events
                        where source_action_id=? and source_external_item_id=?
                        """, BigDecimal.class, sourceActionId, demandItemId)
                .compareTo(new BigDecimal("1500")));
        assertEquals(orderId, jdbc.queryForObject("""
                select trigger_order_id from preplan_public_supply_events
                where source_action_id=? and event_type='GRANT'
                """, UUID.class, sourceActionId));

        AnalysisView b = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "sma74-analysis-b",
                List.of(new PreviewItem("OTHER", null, productB, null, w.unitId(),
                        "sMA74-B", "B采用A运行时公共在途",
                        LocalDate.of(2026, 9, 20), new BigDecimal("1000")))));
        MaterialView bMaterial = b.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.actionable())
                .findFirst().orElseThrow();
        AnalysisView routedB = analysisService.saveRoutes(b.analysisId(),
                new RouteRequest(b.version(), b.fingerprint(), "route-sma74-b",
                        List.of(new RouteDecision(bMaterial.materialLineId(),
                                bMaterial.actionGroupKey(), "BUY", null))));
        assertEquals(0, routedB.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow()
                .publicSurplusRemainingQty().compareTo(new BigDecimal("1500")));
        AnalysisView claimed = analysisCommandService.claimSharedFuture(
                b.analysisId(), new ClaimSharedFutureRequest(
                        routedB.version(), routedB.fingerprint(),
                        "claim-sma74-b", List.of(bMaterial.actionGroupKey())));
        assertEquals(0, claimed.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow()
                .sharedFutureClaimedQty().compareTo(new BigDecimal("1000")));
        assertEquals(notifiedA.analysisId(), a.analysisId());
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
    // covers full issuance while retaining batch material demand; this covers partial issuance.
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
        confirmRootMakeRoute(analysisId, refreshed);
        refreshed = analysisService.detail(analysisId);
        GenerateResult result = analysisCommandService.issueWorkshopPlans(
                analysisId, new IssueWorkshopPlansRequest(
                        refreshed.version(), refreshed.fingerprint(),
                        "gen-ma5-" + analysisId, w.warehouseId(),
                        LocalDate.of(2026, 8, 8), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, productLineId, new BigDecimal("5"),
                                null, null, null, null, null, null, null))));
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
        Map<String,Object> ready = jdbc.queryForMap("""
                SELECT requested_qty,submitted_qty,approved_qty,ready_start_qty,ready_finish_qty,ready_ship_qty
                FROM production_material_analysis_items WHERE id=?
                """,productLineId);
        assertEquals(0,((BigDecimal)ready.get("requested_qty")).compareTo(new BigDecimal("10")));
        for (String field : List.of("approved_qty","ready_start_qty","ready_finish_qty","ready_ship_qty")) {
            assertEquals(0,((BigDecimal)ready.get(field)).compareTo(new BigDecimal("5")),field);
        }
        AnalysisView remaining = analysisService.detail(analysisId);
        assertEquals(0,remaining.products().getFirst().remainingQty().compareTo(new BigDecimal("5")));
        var secondRequest = new IssueWorkshopPlansRequest(remaining.version(),remaining.fingerprint(),
                "gen-ma5-second-"+analysisId,w.warehouseId(),LocalDate.of(2026,8,8),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,productLineId,new BigDecimal("5"),
                        null,null,null,null,null,null,null)));
        var second = analysisCommandService.issueWorkshopPlans(analysisId,secondRequest);
        var replay = analysisCommandService.issueWorkshopPlans(analysisId,secondRequest);
        assertEquals(second.plans().getFirst().planId(),replay.plans().getFirst().planId());
        assertEquals(0,plannedQty(orderId).compareTo(new BigDecimal("10")));
        assertEquals(0,bigDecimalFor("SELECT ready_start_qty+ready_finish_qty+ready_ship_qty FROM production_material_analysis_items WHERE id=?",
                productLineId).signum());
        assertEquals(0,bigDecimalFor("""
                SELECT SUM(reservation.qty-reservation.released_qty) FROM stock_reservations reservation
                JOIN production_material_demands demand ON demand.id=reservation.demand_id
                JOIN production_plans plan ON plan.id=demand.plan_id
                WHERE plan.material_analysis_id=? AND reservation.is_deleted=FALSE
                """,analysisId).compareTo(new BigDecimal("30")),
                "两批5仅预留B20+E10，重放不能追加第三份预留");
    }

    @Test
    void materialAnalysis_fullPlanKeepsReadyAndWaitingSegments() {
        World w = seedWorld("sMA74split");
        UUID product = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(product, "P-sMA74split", "分批成品", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "M-sMA74split", "分批物料", "采购",
                w.unitId(), w.unitLegacy());
        insertBom(product, material, "1");
        jdbc.update("""
                insert into stock_balances(warehouse_id,goods_id,color_id,qty)
                values (?,?,NULL,?)
                """, w.warehouseId(), material, new BigDecimal("50"));
        loginAs(w.superAdminUserId());
        AnalysisView view = analysisService.preview(new PreviewRequest(
                null,null,null,w.warehouseId(),"sma74-split-analysis",
                List.of(new PreviewItem("OTHER",null,product,null,w.unitId(),
                        "sMA74-split","计划100现货先做50",
                        LocalDate.of(2026,9,25),new BigDecimal("100")))));
        UUID analysisId = view.analysisId();
        UUID productLineId = view.products().getFirst().analysisLineId();
        assertEquals(0, view.products().getFirst().readyNowQty()
                .compareTo(new BigDecimal("50")));
        // V478 双闸：先确认为自制根供料，再统一下达车间。
        confirmRootMakeRoute(analysisId, analysisService.detail(analysisId));
        view = analysisService.detail(analysisId);
        GenerateResult generated = analysisCommandService.issueWorkshopPlans(
                analysisId,new IssueWorkshopPlansRequest(
                        view.version(),view.fingerprint(),"sma74-split-generate",
                        w.warehouseId(),LocalDate.of(2026,9,4),null,true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null,productLineId,new BigDecimal("100"),
                                null,null,null,null,null,null,null))));
        UUID planId = generated.plans().getFirst().planId();
        Map<String, BigDecimal> segmentQty = new java.util.HashMap<>();
        jdbc.query("""
                select status,sum(planned_qty)
                from production_execution_segments
                where plan_id=? and is_deleted=false
                group by status
                """, rs -> {
                    segmentQty.put(rs.getString(1),rs.getBigDecimal(2));
                }, planId);
        assertEquals(0, segmentQty.get("READY").compareTo(new BigDecimal("50")));
        assertEquals(0, segmentQty.get("WAITING").compareTo(new BigDecimal("50")));
        assertEquals(0, jdbc.queryForObject("""
                select coalesce(sum(reservation.qty),0)
                from stock_reservations reservation
                join production_material_demands demand
                  on demand.id=reservation.demand_id
                join production_execution_segments segment
                  on segment.id=demand.execution_segment_id
                where segment.plan_id=? and segment.status='READY'
                  and reservation.is_deleted=false
                """, BigDecimal.class, planId).compareTo(new BigDecimal("50")));
        assertEquals(0, jdbc.queryForObject("""
                select coalesce(sum(reservation.qty),0)
                from stock_reservations reservation
                join production_material_demands demand
                  on demand.id=reservation.demand_id
                join production_execution_segments segment
                  on segment.id=demand.execution_segment_id
                where segment.plan_id=? and segment.status='WAITING'
                  and reservation.is_deleted=false
                """, BigDecimal.class, planId).compareTo(BigDecimal.ZERO));
        assertEquals(1, count("""
                select count(distinct document.id)
                from production_planning_package_documents link
                join stock_documents document on document.id=link.document_id
                join production_execution_segments segment
                  on segment.id=link.execution_segment_id
                where segment.plan_id=? and segment.status='READY'
                  and link.document_type='DRAW' and document.is_deleted=false
                """, planId));
        AnalysisView afterIssue = analysisService.detail(analysisId);
        assertEquals("PARTIALLY_PLANNED",afterIssue.status());
        var remainingMaterial = afterIssue.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.level()==1)
                .findFirst().orElseThrow();
        assertEquals(0,new BigDecimal("100").compareTo(remainingMaterial.requiredQty()));
        assertEquals(0,new BigDecimal("50").compareTo(remainingMaterial.allocatedAvailableQty()));
        assertEquals(0,new BigDecimal("50").compareTo(remainingMaterial.shortageQty()),
                "下达100只预留50，剩余50未到货前仍是真实缺口");
        assertFalse(afterIssue.products().getFirst().canSchedule());
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

    private StockDocIssueRequest drawIssueRequest(
            UUID drawId,
            String idempotencyKey,
            String reason,
            BigDecimal firstLineExtra) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                select id, qty
                from stock_document_items
                where doc_id = ? and is_deleted = false
                order by line_no nulls last, id
                """, drawId);
        StockDocIssueRequest request = new StockDocIssueRequest();
        request.setIdempotencyKey(idempotencyKey);
        request.setReason(reason);
        List<StockDocIssueRequest.Line> lines = new ArrayList<>();
        boolean first = true;
        for (Map<String, Object> row : rows) {
            StockDocIssueRequest.Line line =
                    new StockDocIssueRequest.Line();
            line.setItemId((UUID) row.get("id"));
            BigDecimal quantity = (BigDecimal) row.get("qty");
            if (first && firstLineExtra != null) {
                quantity = quantity.add(firstLineExtra);
            }
            line.setQty(quantity);
            lines.add(line);
            first = false;
        }
        request.setLines(List.copyOf(lines));
        return request;
    }

    /** Seed a non-super-admin explicitly granted the finance page and current approve action. */
    private UUID createApprover(World w) {
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
                select ?, p.id, 'grant' from permissions p where p.code IN ('finance_order_approval:view','finance_order_approval:approve')
                """, usr);
        return usr;
    }

    private BatchDecisionItem pendingFinanceDecision(
            String orderType, UUID orderId) {
        return jdbc.queryForObject("""
                select id, version
                from procurement_order_approval_cases
                where order_type = ? and order_id = ? and status = 'PENDING'
                """, (rs, rowNum) -> new BatchDecisionItem(
                rs.getObject("id", UUID.class), rs.getLong("version")),
                orderType, orderId);
    }

    void approvePendingFinance(String orderType, UUID orderId) {
        financeApproval.approveBatch(List.of(
                claimFinanceDecision(pendingFinanceDecision(orderType,orderId))), null);
    }

    private BatchDecisionItem claimFinanceDecision(BatchDecisionItem original) {
        var claim=reviewClaims.claim("PROCUREMENT_FINANCE_APPROVE",original.caseId().toString());
        return new BatchDecisionItem(original.caseId(),original.expectedVersion(),claim.claimId());
    }

    /** Explicit initial-review fixture: never substitutes a newer commercial revision for a caller's old snapshot. */
    private void confirmInitialSalesFinance(UUID orderId) {
        var claim=reviewClaims.claim("SALES_ORDER_FINANCE_CONFIRM",orderId.toString());
        financeConfirmService.confirm(orderId,new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,claim.claimId()));
    }

    private UUID createIqcWarehouseConfirmer(World w, String tag) {
        return createUserWithPerms(
                w, tag,
                "warehouse_iqc_stock_in:view",
                "warehouse_iqc_stock_in:confirm");
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
        UUID reviewer = createApprover(w);

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
        approvePendingFinance("PURCHASE", orderId);

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
        UUID reviewer = createApprover(w);
        financeApproval.submit("PURCHASE", orderId);
        loginAs(reviewer);
        approvePendingFinance("PURCHASE", orderId);
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
    @Test
    void preplanReceiptSiblingWarehouseKeepsExactMaterialOwnership() {
        verifyPreplanReceiptWarehouseBoundary(true);
    }

    @Test
    void preplanReceiptOtherMainWarehouseRemainsPublic() {
        verifyPreplanReceiptWarehouseBoundary(false);
    }

    @Test
    void preplanWaitingAnchorBecomesReadyAfterSiblingWarehouseQualifiedStockIn() {
        verifyWaitingAnchorAfterSiblingStockIn(false, false);
    }

    @Test
    void rootSubcontractWaitingAnchorUsesOriginalDirectMaterialsAfterQualifiedStockIn() {
        verifyWaitingAnchorAfterSiblingStockIn(true, true);
    }

    @Test
    void nestedSubcontractWaitingAnchorUsesOriginalChildMaterialsAfterQualifiedStockIn() {
        verifyWaitingAnchorAfterSiblingStockIn(true, false);
    }

    private void verifyWaitingAnchorAfterSiblingStockIn(boolean subcontract, boolean root) {
        String suffix = "waiting-anchor-" + subcontract + "-" + root;
        World w = seedWorld(suffix);
        UUID main = UUID.randomUUID();
        UUID inboundWarehouse = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name,status) VALUES (?,?,?,'使用')",
                main,"MAIN-"+suffix,"车间物料主仓");
        jdbc.update("UPDATE warehouses SET parent_id=? WHERE id=?",main,w.warehouseId());
        jdbc.update("INSERT INTO warehouses(id,code,name,status,parent_id) VALUES (?,?,?,'使用',?)",
                inboundWarehouse,"LEAF-"+suffix,"组件到货子仓",main);
        UUID product = UUID.randomUUID();
        UUID component = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(product,"P-"+suffix,"总装产品","自制",w.unitId(),w.unitLegacy());
        insertGoods(component,"COMPONENT-"+suffix,"先排车间的子件","自制",w.unitId(),w.unitLegacy());
        insertGoods(material,"RAW-"+suffix,"子件底层采购料","采购",w.unitId(),w.unitLegacy());
        jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),material);
        insertBom(product,component,"1");
        insertBom(component,material,"2");
        UUID salesOrder = createApprovedOrder(w,root ? component : product,"10","100");
        loginAs(w.superAdminUserId());
        AnalysisView analysis = analysisService.preview(new PreviewRequest(null,null,null,
                w.warehouseId(),suffix+"-preview",List.of(new PreviewItem(
                        "SALES_ORDER_ITEM",orderItemId(salesOrder),null,null,null,null,null,
                        BusinessTime.today(),new BigDecimal("10")))));
        UUID analysisId = analysis.analysisId();
        MaterialView componentRow = analysis.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(component)).findFirst().orElseThrow();
        analysisService.saveRoutes(analysisId,new RouteRequest(analysis.version(),analysis.fingerprint(),
                suffix+"-route",List.of(new RouteDecision(componentRow.materialLineId(),
                        componentRow.actionGroupKey(),subcontract ? "SUBCONTRACT" : "MAKE",null))));
        if (!root) confirmRootMakeRoute(analysisId,analysisService.detail(analysisId));
        UUID anchorItem = null;
        if (subcontract) {
            AnalysisView routed = analysisService.detail(analysisId);
            analysisCommandService.notifySupply(analysisId,new NotifyRequest(
                    routed.version(),routed.fingerprint(),suffix+"-notify","SUBCONTRACT",
                    List.of(componentRow.materialLineId()),List.of(),null));
            anchorItem = jdbc.queryForObject("""
                    SELECT preparation_item_id FROM preplan_subcontract_make_tasks
                    WHERE analysis_id=? AND analysis_material_id=? AND status='ACTIVE'
                    """,UUID.class,analysisId,componentRow.materialLineId());
        }
        AnalysisView beforePlan = analysisService.detail(analysisId);
        GeneratedPlan plan = analysisCommandService.issueWorkshopPlans(analysisId,
                new IssueWorkshopPlansRequest(beforePlan.version(),beforePlan.fingerprint(),
                        suffix+"-plan",w.warehouseId(),BusinessTime.today(),null,true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                subcontract ? null : componentRow.materialLineId(),
                                anchorItem,new BigDecimal("10"),null,null,null,null,null,null,null))))
                .plans().getFirst();
        assertTrue(hasSegmentStatus(plan.planId(),"WAITING"));
        AnalysisView awaiting = analysisService.detail(analysisId);
        MaterialView originalMaterial = awaiting.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material) && row.actionable())
                .findFirst().orElseThrow();
        UUID purchaseLine = approvePurchaseForAnalysis(w,awaiting,material);
        World receiptWorld = new World(w.departmentId(),w.employeeId(),w.superAdminUserId(),
                w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),
                inboundWarehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
        UUID receipt = receiveAndPassPurchase(receiptWorld,purchaseLine,material,
                new BigDecimal("20"),suffix+"-receipt");
        loginAs(w.superAdminUserId());
        assertTrue(hasSegmentStatus(plan.planId(),"READY"),
                "原树底层料足量合格入库后应自动解除车间等待");
        assertEquals(1,count("""
                SELECT count(*) FROM stock_reservations reservation
                JOIN production_material_demands demand ON demand.id=reservation.demand_id
                WHERE demand.plan_id=? AND demand.goods_id=?
                  AND reservation.warehouse_id=? AND reservation.qty=20
                  AND reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
                  AND reservation.status=0 AND reservation.is_deleted=FALSE
                """,plan.planId(),material,inboundWarehouse));
        assertEquals(1,count("""
                SELECT count(*) FROM production_planning_package_documents link
                JOIN stock_documents document ON document.id=link.document_id
                WHERE link.package_id=? AND link.document_type='DRAW'
                  AND document.warehouse_id=? AND document.is_deleted=FALSE
                """,plan.packageId(),inboundWarehouse));
        assertEquals(1,count("""
                SELECT count(*) FROM preplan_analysis_stock_exact_pegs exact
                WHERE exact.source_receipt_id=? AND exact.origin_analysis_material_id=?
                """,receipt,originalMaterial.materialLineId()),
                "正式化不得改写到货的原树物料UUID");
        assertEquals(0,publicAvailable(inboundWarehouse,material).signum());
        assertEquals(0,stockBalance(w.warehouseId(),material).signum());
    }

    private void verifyPreplanReceiptWarehouseBoundary(boolean sameMain) {
        String suffix = sameMain ? "same-main-receipt" : "other-main-receipt";
        World w = seedWorld(suffix);
        UUID main = UUID.randomUUID();
        UUID receiptWarehouse = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO warehouses(id,code,name,status,is_accountable)
                VALUES (?,?,?,'使用',TRUE)
                """,main,"MAIN-" + suffix,"同主仓到货测试");
        jdbc.update("UPDATE warehouses SET parent_id=? WHERE id=?",main,w.warehouseId());
        jdbc.update("""
                INSERT INTO warehouses(id,code,name,status,is_accountable,parent_id)
                VALUES (?,?,?,'使用',TRUE,?)
                """,receiptWarehouse,"LEAF-" + suffix,"实际到货子仓",sameMain ? main : null);
        UUID product = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(product,"G-" + suffix,"入库归属产品","自制",w.unitId(),w.unitLegacy());
        insertGoods(material,"M-" + suffix,"入库归属原料","采购",w.unitId(),w.unitLegacy());
        jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),material);
        insertBom(product,material,"1");
        UUID orderId = createApprovedOrder(w,product,"10","100");
        loginAs(w.superAdminUserId());
        AnalysisView analysis = analysisService.preview(new PreviewRequest(
                null,null,null,w.warehouseId(),"analysis-" + suffix,
                List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(orderId),
                        null,null,null,null,null,BusinessTime.today(),new BigDecimal("10")))));
        MaterialView original = analysis.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow();
        UUID orderItemId = approvePurchaseForAnalysis(w,analysis,material);
        World receiptWorld = new World(w.departmentId(),w.employeeId(),w.superAdminUserId(),
                w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),
                w.supplierId(),receiptWarehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
        UUID receiptId = receiveAndPassPurchase(receiptWorld,orderItemId,material,
                new BigDecimal("5"),"root-" + suffix);
        assertEquals(0,stockBalance(receiptWarehouse,material).compareTo(new BigDecimal("5")));
        assertEquals(0,stockBalance(w.warehouseId(),material).compareTo(BigDecimal.ZERO),
                "逻辑分析仓不得虚增物理库存");
        assertEquals(sameMain ? 1 : 0,count("""
                SELECT count(*) FROM preplan_analysis_stock_exact_pegs peg
                JOIN stock_reservations reservation ON reservation.id=peg.stock_reservation_id
                WHERE peg.source_receipt_id=? AND peg.origin_analysis_material_id=?
                  AND reservation.warehouse_id=? AND reservation.qty=5 AND reservation.status=0
                """,receiptId,original.materialLineId(),receiptWarehouse));
        assertEquals(0,publicAvailable(receiptWarehouse,material)
                .compareTo(sameMain ? BigDecimal.ZERO : new BigDecimal("5")));
        loginAs(w.superAdminUserId());
        MaterialView current = analysisService.detail(analysis.analysisId()).flatMaterials().stream()
                .filter(row -> row.materialLineId().equals(original.materialLineId()))
                .findFirst().orElseThrow();
        assertEquals(0,current.exactPeggedQty()
                .compareTo(sameMain ? new BigDecimal("5") : BigDecimal.ZERO));
        assertEquals(0,current.shortageQty()
                .compareTo(sameMain ? new BigDecimal("5") : new BigDecimal("10")));
        var pendingItem = arrivalControl.expectations(1,50,"PURCHASE","M-" + suffix)
                .getItems().stream().flatMap(task -> task.items().stream())
                .filter(item -> item.orderItemId().equals(orderItemId))
                .findFirst().orElseThrow();
        assertEquals(sameMain ? receiptWarehouse : null,pendingItem.lastReceiptWarehouseId(),
                "成功收货学习当前主仓的物料子仓，跨另一个主仓不能污染下次默认");
    }

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

        return approveExistingAnalysisPurchase(w,analysis.analysisId(),buyGoodsId);
    }

    private UUID approveExistingAnalysisPurchase(World w,UUID analysisId,UUID buyGoodsId) {
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
                """, analysisId, buyGoodsId);
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
        UUID reviewer = createApprover(w);
        financeApproval.submit("PURCHASE", orderId);
        loginAs(reviewer);
        approvePendingFinance("PURCHASE", orderId);
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
        return receiveAndPassPurchase(w,orderItemId,goodsId,qty,idempotencySuffix,List.of(qty));
    }

    private UUID receiveAndPassPurchase(World w,UUID orderItemId,UUID goodsId,BigDecimal qty,
            String idempotencySuffix,List<BigDecimal> stockBatches) {
        loginAs(w.superAdminUserId());
        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest request =
                new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(idempotencySuffix.startsWith("root-")
                ? com.uten.imp.common.time.BusinessTime.today() : LocalDate.of(2026,1,20));
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
        // V446 后分析归属 peg 在仓库确认入库事务写入（attributeInspectionStockIn），
        // 仅 IQC PASS 不再形成 exactPegged——补确认步骤与真实作业一致。
        loginAs(createIqcWarehouseConfirmer(w, "iqc-stock-" + idempotencySuffix));
        for(int batch=0;batch<stockBatches.size();batch++)iqcStockInService.confirm(
                "PURCHASE", receiptId,
                latestIqcStockInRequest(
                        "PURCHASE", receiptId, inspectionItemId, stockBatches.get(batch),
                        "stock-in-" + idempotencySuffix + "-" + inspectionItemId+(stockBatches.size()==1?"":":"+batch),
                        "AUTO-A01"));
        return receiptId;
    }

    // ---------------------------------------------------------------------------------------------
    // #23 (receiving, normal path) Warehouse receives H against the approved order. Approval freezes
    // the goods in IQC (NOT yet in usable stock), writes received_qty, and posts AP. An IQC PASS
    // queues the qualified slice; warehouse confirmation then accumulates the stock balance.
    // ---------------------------------------------------------------------------------------------
    @Test
    void receiving_iqcQuarantineThenWarehouseConfirmationAccumulatesStock() {
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

        // IQC PASS only releases the slice; warehouse confirmation owns stock-in.
        UUID inspectionItemId = jdbc.queryForObject(
                "select id from procurement_inspection_items where receipt_id = ? and goods_id = ? "
                        + "order by updated_at desc limit 1",
                UUID.class, receiptId, h);
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "质检合格", "idem-s23-" + inspectionItemId));
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "IQC PASS 仅进入仓库待入库，不得提前增加库存");
        loginAs(createIqcWarehouseConfirmer(w, "iqc-stock-s23"));
        iqcStockInService.confirm(
                "PURCHASE", receiptId,
                latestIqcStockInRequest(
                        "PURCHASE", receiptId, inspectionItemId,
                        new BigDecimal("20"),
                        "stock-s23-" + inspectionItemId,
                        "S23-A01"));
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(new BigDecimal("20")),
                "仓库确认 IQC 合格品后库存累加到 20");
    }

    // ---------------------------------------------------------------------------------------------
    // #23c (arrival → review → IQC → warehouse notice, 全链路 + 进度同步) 仓库「登记实际到货」
    // 只建草稿收货单：库存 / 订货已收 / 品质待检 / 应付都不得提前出现，仅任务中心在途量
    // （registered_qty，已登记待审核）立即反映；审核页点「审核」后才冻结进 IQC 待检、
    // 回写 received_qty 并立应付，在途量随之清零转入已收；品质 PASS 只生成仓库待入库
    // 任务与可靠通知，仓库确认数量和库位后才增加库存并推进生产供给。
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

        // ③ 品质部 PASS（整单结案）→ 只放行到仓库待入库任务并投递可靠提醒
        UUID inspectionItemId = jdbc.queryForObject(
                "select id from procurement_inspection_items where receipt_id = ? and goods_id = ?",
                UUID.class, receiptId, h);
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "质检合格", "idem-s23c-" + inspectionItemId));

        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "品质 PASS 后仍不得增加可用库存");
        assertEquals(0, count(
                "select count(*) from procurement_inspection_items "
                        + "where receipt_id = ? and status in ('PENDING','PARTIAL')", receiptId),
                "结案后品质待检角标归零");
        assertEquals(0, count(
                "select count(*) from procurement_inspection_events e "
                        + "join procurement_inspection_items i on i.id = e.inspection_item_id "
                        + "where i.receipt_id = ? and e.action = 'PRODUCTION_WOKEN'", receiptId),
                "品质结案不等于生产供给已入库");
        assertEquals(1, count(
                "select count(*) from business_outbox "
                        + "where event_type = 'PROCUREMENT_IQC_STOCK_IN_PENDING' "
                        + "and payload->>'receiptId' = ?", receiptId.toString()),
                "PASS 后按放行切片向仓库投递待入库通知事件");

        // ④ outbox 送达：仓库人员收到待入库通知，点击直达仓库专用任务。
        // （测试类共享种子部门 SUB_WH：同批其他用例的结案通知也会送达该用户，
        //   故按本单 action_route 精确过滤。）
        while (businessOutboxProcessor.processNext()) {
            // 排空队列（含本链路早前投递的财务审批等事件）
        }
        List<Map<String, Object>> notices = jdbc.queryForList(
                "select title, action_route from notices "
                        + "where audience_user_id = ? "
                        + "and source_event = 'PROCUREMENT_IQC_STOCK_IN_PENDING'"
                        + " and action_route = ?",
                warehouseUserId, "/warehouse/iqc-stock-ins/PURCHASE/" + receiptId);
        assertEquals(1, notices.size(), "仓库人员收到本单的品质放行待入库通知");

        // ⑤ 仓库核对实物与库位并确认，库存才真正增加。
        loginAs(createIqcWarehouseConfirmer(w, "iqc-stock-s23c"));
        iqcStockInService.confirm(
                "PURCHASE", receiptId,
                latestIqcStockInRequest(
                        "PURCHASE", receiptId, inspectionItemId,
                        new BigDecimal("20"),
                        "stock-s23c-" + inspectionItemId,
                        "S23C-A01"));
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(new BigDecimal("20")),
                "仓库确认后可用库存才增加 20");
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

    private com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest
            latestIqcStockInRequest(
                    String receiptType,
                    UUID receiptId,
                    UUID inspectionItemId,
                    BigDecimal quantity,
                    String idempotencyKey,
                    String place) {
        Map<String, Object> release = jdbc.queryForMap("""
                select event.id as pass_event_id,
                       event.base_qty - coalesce(stocked.qty, 0) as remaining_qty
                from procurement_inspection_events event
                join procurement_inspection_items inspection
                  on inspection.id = event.inspection_item_id
                left join lateral (
                    select sum(item.base_qty) as qty
                    from procurement_iqc_stock_in_batch_items item
                    where item.pass_event_id = event.id
                ) stocked on true
                where inspection.id = ?
                  and inspection.receipt_type = ?
                  and inspection.receipt_id = ?
                  and inspection.status <> 'REVERSED'
                  and event.action = 'PASS'
                  and event.requires_warehouse_stock_in = true
                  and event.base_qty > coalesce(stocked.qty, 0)
                order by event.occurred_at desc, event.id desc
                limit 1
                """, inspectionItemId, receiptType, receiptId);
        return new com.uten.imp.features.warehouse.inbound
                .ProcurementIqcStockInContracts.ConfirmRequest(
                idempotencyKey,
                List.of(new com.uten.imp.features.warehouse.inbound
                        .ProcurementIqcStockInContracts.ConfirmItem(
                        (UUID) release.get("pass_event_id"),
                        quantity,
                        (BigDecimal) release.get("remaining_qty"),
                        place)));
    }

    // ---------------------------------------------------------------------------------------------
    // #23b (V298 preplan pegging) Stock received against a plan-before-analysis BUY order
    // belongs to THAT analysis: warehouse confirmation of an IQC PASS writes a PREPLAN_ANALYSIS
    // reservation that removes
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

        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "品质 PASS 只形成分析来源待入库切片");
        loginAs(createIqcWarehouseConfirmer(w, "iqc-stock-s23b"));
        iqcStockInService.confirm(
                "PURCHASE", receiptId,
                latestIqcStockInRequest(
                        "PURCHASE", receiptId, inspectionItemId,
                        new BigDecimal("20"),
                        "stock-s23b-" + inspectionItemId,
                        "S23B-A01"));

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
                "仓库确认 IQC 合格品后应写分析归属预留(qty=20，生效中)");
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
    void preplanReallocation_nextTargetSupplyPrioritizesSourceAnalysis() throws Exception {
        runReallocationPrefixScenario(false);
    }

    @Test
    void preplanReallocation_revokeAndReplayDoNotLockUnrelatedSameGoodsAnalysis() throws Exception {
        runReallocationPrefixScenario(true);
    }

    private void runReallocationPrefixScenario(boolean revokeAfterCreate) throws Exception {
        String scenario=revokeAfterCreate?"s23d-revoke":"s23d";
        World w = seedWorld(scenario);
        UUID product = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(product, "G-"+scenario, "让料产品G-"+scenario, "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "H-"+scenario, "让料原料H-"+scenario, "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(product, material, "1");

        UUID planner = createUserWithPerms(
                w, "planner-"+scenario,
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
                w, sourceOrderItem, material, new BigDecimal("10"), "source-"+scenario);

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

        var reallocationRequest=new com.uten.imp.features.production.analysis.MaterialAnalysisContracts
                        .CrossReallocationRequest(
                        sourceQualified.version(), sourceQualified.fingerprint(),
                        sourceMaterial.materialLineId(),
                        target.analysisId(), target.version(), target.fingerprint(),
                        targetMaterial.materialLineId(), new BigDecimal("4"),
                        "紧急计划先用，来源计划后续优先补齐",
                        "cross-reallocate-"+scenario);
        if(revokeAfterCreate){
            UUID unrelatedOrder=createApprovedOrder(w,product,"3","100");loginAs(planner);
            var unrelated=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),"unrelated-"+unrelatedOrder,
                    List.of(new PreviewItem("SALES_ORDER_ITEM",orderItemId(unrelatedOrder),null,null,null,null,null,LocalDate.of(2026,9,3),new BigDecimal("3")))));
            // A separate real transaction holds C's analysis row. A->B must complete
            // while this lock is held: using every same-SKU analysis would block here.
            var worker=java.util.concurrent.Executors.newSingleThreadExecutor();
            try(var blocker=jdbc.getDataSource().getConnection()){
                blocker.setAutoCommit(false);
                try(var statement=blocker.prepareStatement("select id from production_material_analyses where id=? for update")){
                    statement.setObject(1,unrelated.analysisId());try(var rows=statement.executeQuery()){assertTrue(rows.next());}
                }
                var command=worker.submit(()->{
                    loginAs(planner);
                    try{return materialStockReallocationService.create(sourceQualified.analysisId(),reallocationRequest);}
                    finally{SecurityContextHolder.clearContext();}
                });
                try{assertNotNull(command.get(15,java.util.concurrent.TimeUnit.SECONDS));}
                finally{blocker.rollback();}
            }finally{worker.shutdown();assertTrue(worker.awaitTermination(20,java.util.concurrent.TimeUnit.SECONDS));}
            assertEquals(unrelated.version(),analysisService.detail(unrelated.analysisId()).version(),"同货无关分析C未被更新或扩大锁入");
        }else materialStockReallocationService.create(sourceQualified.analysisId(),reallocationRequest);

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

        if(revokeAfterCreate){
            materialStockReallocationService.create(sourceQualified.analysisId(),reallocationRequest);
            assertEquals(1,count("select count(*) from preplan_material_reallocations where from_analysis_id=? and to_analysis_id=?",source.analysisId(),target.analysisId()));
            UUID reallocation=jdbc.queryForObject("select id from preplan_material_reallocations where from_analysis_id=? and to_analysis_id=?",UUID.class,source.analysisId(),target.analysisId());
            var beforeSource=analysisService.detail(source.analysisId());var beforeTarget=analysisService.detail(target.analysisId());
            var reverse=new CrossReallocationRevokeRequest(beforeSource.version(),beforeSource.fingerprint(),beforeTarget.version(),beforeTarget.fingerprint(),"撤销尚未使用的让料","revoke-"+scenario);
            materialStockReallocationService.revoke(source.analysisId(),reallocation,reverse);
            int events=count("select count(*) from preplan_stock_entitlement_events where beneficiary_analysis_id in (?,?)",source.analysisId(),target.analysisId());
            materialStockReallocationService.revoke(source.analysisId(),reallocation,reverse);
            assertEquals(events,count("select count(*) from preplan_stock_entitlement_events where beneficiary_analysis_id in (?,?)",source.analysisId(),target.analysisId()),"重复撤销不再追加权益变化");
            assertEquals("REVERSED",strFor("select status from preplan_material_reallocations where id=?",reallocation));
            assertEquals(0,analysisService.detail(source.analysisId()).flatMaterials().stream().filter(row->row.goodsId().equals(material)).findFirst().orElseThrow().exactPeggedQty().compareTo(BigDecimal.TEN));
            assertEquals(0,analysisService.detail(target.analysisId()).flatMaterials().stream().filter(row->row.goodsId().equals(material)).findFirst().orElseThrow().exactPeggedQty().signum());
            assertEquals(0,stockBalance(w.warehouseId(),material).compareTo(BigDecimal.TEN),"让料与撤销只变精确归属，不重做实物入出库");
            return;
        }

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
        confirmRootMakeRoute(source.analysisId(), sourceBeforePlan);
        sourceBeforePlan = analysisService.detail(source.analysisId());
        UUID sourceProductLineId = sourceBeforePlan.products().getFirst().analysisLineId();
        GeneratedPlan generated = analysisCommandService.issueWorkshopPlans(
                source.analysisId(),
                new IssueWorkshopPlansRequest(
                        sourceBeforePlan.version(), sourceBeforePlan.fingerprint(),
                        "gen-s23d-formalize", w.warehouseId(),
                        LocalDate.of(2026, 9, 3), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, sourceProductLineId, new BigDecimal("10"),
                                null, null, null, null, null, null, null))))
                .plans().getFirst();
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
    // warehouse issues the frozen-BOM component before accepting the processed parent; and warehouse
    // confirmation of the PASS slice must retain the application-item lineage when it attributes
    // qualified stock back to the originating analysis. This is deliberately separate from #23b: a purchase-only proof
    // cannot catch a lost subcontract application_item_id or an unexercised material-issue gate.
    // ---------------------------------------------------------------------------------------------
    @Test
    void preplanPegging_subcontractWarehouseStockInRefreshesOnlyOriginAnalysis() {
        runSubcontractSupplyChain(false);
    }

    @Test
    void rootSupply_subcontractPreparationAndQualifiedReturnTransferToSales() {
        runSubcontractSupplyChain(true);
    }

    @Test
    void subcontractNotificationReversalRestoresPartialPreparedReservationsBeforeInboundReverse() {
        runSubcontractSupplyChain(false, true);
    }

    @Test
    void historicalCancelledNotificationCanReconcileWithoutRewritingTheOriginalBatch() {
        runSubcontractSupplyChain(false, true, true);
    }

    private void runSubcontractSupplyChain(boolean rootSupplyMode) {
        runSubcontractSupplyChain(rootSupplyMode, false);
    }

    private void runSubcontractSupplyChain(boolean rootSupplyMode, boolean reversePreparation) {
        runSubcontractSupplyChain(rootSupplyMode, reversePreparation, false);
    }

    private void runSubcontractSupplyChain(
            boolean rootSupplyMode, boolean reversePreparation, boolean legacyCancellation) {
        World w = seedWorld(legacyCancellation ? "s23reverseLegacy"
                : reversePreparation ? "s23reverse" : rootSupplyMode ? "rootSc" : "s23v307");
        UUID finished = UUID.randomUUID();
        UUID siblingFinished = UUID.randomUUID();
        UUID subcontracted = UUID.randomUUID();
        UUID suppliedMaterial = UUID.randomUUID();
        insertGoods(finished, "F-s23c-" + w.goodsA(), "成品F-s23c", "自制", w.unitId(), w.unitLegacy());
        insertGoods(siblingFinished, "F2-s23c-" + w.goodsA(), "兄弟成品F2-s23c", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(subcontracted, "S-s23c-" + w.goodsA(), "委外件S-s23c", "委外", w.unitId(), w.unitLegacy());
        insertGoods(suppliedMaterial, "R-s23c-" + w.goodsA(), "委外发料R-s23c", "采购", w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), subcontracted);
        insertBom(finished, subcontracted, "1");
        insertBom(siblingFinished, subcontracted, "1");
        insertBom(subcontracted, suppliedMaterial, "2");
        // These full return-chain tests start with enough raw material for both paths.
        // Separate WAITING-anchor tests prove issuance before material arrival.
        jdbc.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), suppliedMaterial, new BigDecimal("40"));

        UUID planner = createUserWithPerms(w, "planner-s23c-" + w.goodsA(),
                "production_material_analysis:view", "production_material_analysis:manage",
                "production_material_analysis:route", "production_material_analysis:notify");
        UUID siblingOrder = createApprovedOrder(w, siblingFinished, "10", "100");
        UUID orderA = createApprovedOrder(w, rootSupplyMode ? subcontracted : finished, "10", "100");
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
        assertEquals(rootSupplyMode ? "MAKE" : "SUBCONTRACT", subcontractRow.sourceSuggestion());
        assertEquals(0, subcontractRow.availableQty().compareTo(BigDecimal.ZERO));
        assertEquals(0, subcontractRow.shortageQty().compareTo(new BigDecimal("10")));
        assertEquals(0, siblingSubcontractRow.shortageQty().compareTo(new BigDecimal("10")));
        UUID originalInputId = initial.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(suppliedMaterial)
                        && material.analysisLineId().equals(targetAnalysisItemId))
                .findFirst().orElseThrow().materialLineId();

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

        // V458/ADR-062 修订一：有子层级委外件通知后不再立即生成委外申请，而是在
        // 原分析内建 SUBCONTRACT_MAKE 前置自制任务（先自制、入库满批后才通知委外部）。
        assertEquals(1, count("""
                        select count(*)
                        from preplan_supply_actions action
                        where action.analysis_id = ?
                          and action.route = 'SUBCONTRACT'
                          and action.status = 'CREATED'
                          and action.external_document_type = 'SUBCONTRACT_MAKE_TASK'
                        """, analysisA),
                "有子层委外通知必须外部化为前置自制任务而非委外申请");
        Map<String, Object> makeTask = jdbc.queryForMap("""
                select item.id as make_item_id
                from preplan_subcontract_make_tasks task
                join production_material_analysis_items item
                  on item.id = task.preparation_item_id
                where task.analysis_id = ? and task.goods_id = ?
                  and task.status = 'ACTIVE'
                """, analysisA, subcontracted);
        UUID makeItemId = (UUID) makeTask.get("make_item_id");

        // 原分析内前置自制：对 SUBCONTRACT_MAKE 行排产 → DRAW 领料 → 报工 → 实收入仓。
        loginAs(planner);
        AnalysisView afterTask = analysisService.detail(analysisA);
        ProductView makeProduct = afterTask.products().stream()
                .filter(product -> "SUBCONTRACT_MAKE".equals(product.sourceType()))
                .findFirst().orElseThrow();
        assertEquals(1, afterTask.flatMaterials().stream()
                .filter(material -> originalInputId.equals(material.materialLineId())).count(),
                "根层和中层委外下达后都保留原子件 UUID");
        assertEquals(0, count("""
                SELECT count(*) FROM production_material_analysis_materials
                WHERE analysis_item_id=? AND active=TRUE
                """, makeProduct.analysisLineId()), "前置自制锚点不重复展开已在原树的子件");
        // 与旧链一致：生成并自动审核正式计划需独立审核权限，由超管执行。
        loginAs(w.superAdminUserId());
        GeneratedPlan makeGenerated = analysisCommandService.issueWorkshopPlans(
                analysisA,
                new IssueWorkshopPlansRequest(
                        afterTask.version(), afterTask.fingerprint(),
                        "gen-s23c-make-" + analysisA,
                        w.warehouseId(), LocalDate.of(2026, 1, 16), null, true,
                        List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                                null, makeProduct.analysisLineId(),
                                new BigDecimal("10"),
                                null, null, null, null, null, null, null))))
                .plans().getFirst();
        for (UUID drawId : makeGenerated.drawIds()) {
            var drawLines = jdbc.queryForList(
                    "select id, qty from stock_document_items where doc_id = ? and is_deleted = false",
                    drawId);
            assertEquals(0, count("""
                    select count(*) from stock_document_items
                    where doc_id = ? and execution_segment_id is not null
                    """, drawId), "DRAW 行的执行归属必须走 demand mapping，V157 禁止直接写行列");
            var issueReq = new com.uten.imp.features.stock.dto.StockDocIssueRequest();
            issueReq.setIdempotencyKey("make-draw-issue-" + drawId);
            issueReq.setLines(drawLines.stream().map(row -> {
                var line = new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();
                line.setItemId((UUID) row.get("id"));
                line.setQty((BigDecimal) row.get("qty"));
                return line;
            }).toList());
            stockDocService.approveAndIssue(drawId, issueReq);
        }
        UUID makeProductionPlanItem = planItemOfPlan(makeGenerated.planId());
        StartedSegment makeSegment = startedSegmentFor(
                w, makeGenerated.planId(), makeProductionPlanItem, null);
        UUID makeWorkshopId = jdbc.queryForObject("""
                select workshop_department_id
                from production_execution_segments
                where id = ? and is_deleted = false
                """, UUID.class, makeSegment.segmentId());
        UUID superAdminEmployeeId = employeeIdOf(w.superAdminUserId());
        jdbc.update("""
                insert into employee_secondary_departments(
                    employee_id, department_id, note, created_by, updated_by)
                select ?, ?, 's23c production report fixture', ?, ?
                where (select department_id from employees where id = ?)
                      is distinct from ?
                on conflict (employee_id, department_id) do nothing
                """, superAdminEmployeeId, makeWorkshopId,
                w.superAdminUserId(), w.superAdminUserId(),
                superAdminEmployeeId, makeWorkshopId);
        UUID makeReportId = reportAndApproveExecutionSegment(
                w, makeProductionPlanItem, null, subcontracted,
                makeSegment.segmentId(), makeSegment.salesAllocationId(), "10");
        UUID preparedInboundId = finishedInDocForReport(makeReportId);
        confirmFinishedInboundFully(preparedInboundId);
        MaterialView inputAfterPreparation = analysisService.detail(analysisA).flatMaterials().stream()
                .filter(material -> originalInputId.equals(material.materialLineId()))
                .findFirst().orElseThrow();
        assertEquals(0, inputAfterPreparation.shortageQty().signum(),
                "前置自制已领用的原材料继续覆盖本批需求，等待委外回厂不能再补一遍");

        // 满批实收入仓 → 账本 produced=10 → 入库事务内自动生成委外申请并通知委外部。
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
                "满批自动通知须把分析分摊精确锚定到 application_item_id");

        // 委外部据满批自动生成的申请明细下单；财务批准后按 V458 谱系即时待出仓。
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
        BigDecimal orderQuantity = reversePreparation ? new BigDecimal("4") : quantity;
        orderLine.setQty(orderQuantity);
        orderLine.setPrice(new BigDecimal("30"));
        orderLine.setAmountOriginal(orderQuantity.multiply(new BigDecimal("30")));
        orderLine.setAmountLocal(orderQuantity.multiply(new BigDecimal("30")));
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

        UUID reviewer = createApprover(w);
        financeApproval.submit("SUBCONTRACT", subcontractOrderId);
        loginAs(reviewer);
        approvePendingFinance("SUBCONTRACT", subcontractOrderId);

        // V458 谱系：订货行能追溯到前置自制账本批次（produced ≥ notified ≥ planned），
        // 批准即 PREPARED_OUTBOUND 待出仓——不再有 MAKE 行与二次前置链。
        loginAs(w.superAdminUserId());
        if (reversePreparation) {
            UUID notificationAction = jdbc.queryForObject("""
                    SELECT id FROM preplan_supply_actions
                    WHERE analysis_id=? AND external_document_type='SUBCONTRACT_APPLICATION'
                      AND external_document_id=?
                    """,UUID.class,analysisA,applicationSource.get("application_id"));
            UUID taskId = jdbc.queryForObject("SELECT id FROM preplan_subcontract_make_tasks WHERE preparation_item_id=?",
                    UUID.class,makeItemId);
            assertEquals(0,publicAvailable(w.warehouseId(),subcontracted).signum(),
                    "部分订货占用4后剩余6仍是任务专属库存");
            DataAccessException overReserved = assertThrows(DataAccessException.class,()->jdbc.update("""
                    INSERT INTO stock_reservations(id,goods_id,color_id,warehouse_id,qty,consumed_qty,released_qty,
                        status,source,source_doc_type,source_doc_id,owner_type,owner_id,purpose,
                        supply_type,supply_id,idempotency_key,created_by,updated_by)
                    SELECT ?,goods_id,color_id,warehouse_id,1,0,0,0,source,source_doc_type,source_doc_id,
                        owner_type,owner_id,purpose,supply_type,supply_id,?,created_by,updated_by
                    FROM stock_reservations WHERE owner_type='SUBCONTRACT_PREPARE_TASK' AND owner_id=?
                      AND status=0 AND is_deleted=FALSE LIMIT 1
                    """,UUID.randomUUID(),"excess-prepared-source-"+taskId,taskId));
            assertTrue(overReserved.getMessage().contains("prepared reservations exceed their finished receipt source"),
                    "同一前置实收的PREP与OUTBOUND合计不得超额，不能只逐片判断上限");
            assertThrows(ApiException.class,()->stockDocService.reverseFinishedInbound(preparedInboundId),
                    "已通知且订货未反向时不能直接撤销前置产出");
            AnalysisView beforeBlockedCancel = analysisService.detail(analysisA);
            assertThrows(ApiException.class,()->analysisCommandService.cancelAction(analysisA,notificationAction,
                    new CancelRequest(beforeBlockedCancel.version(),beforeBlockedCancel.fingerprint(),
                            "blocked-sc-notification-"+analysisA,"先核对下游")));
            subcontractOrderService.reverse(subcontractOrderId);
            assertEquals(2,count("""
                    SELECT count(*) FROM stock_reservations WHERE owner_type='SUBCONTRACT_PREPARE_TASK'
                      AND owner_id=? AND status=0 AND qty-consumed_qty-released_qty>0
                    """,taskId),"部分订货反向后保留原预留6和恢复预留4两份来源切片");
            if (legacyCancellation) {
                // Seed the old committed shape: application/action reversed while
                // the notification ledger still retains its original quantity.
                new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                        .executeWithoutResult(unused -> {
                            jdbc.update("UPDATE subcontract_applications SET status=-1,is_closed=TRUE WHERE id=?",
                                    applicationSource.get("application_id"));
                            jdbc.update("""
                                    UPDATE preplan_supply_actions SET status='CANCELLED',cancelled_by=?,cancelled_at=now(),
                                        cancellation_reason='Historical application reversal' WHERE id=?
                                    """,w.superAdminUserId(),notificationAction);
                        });
            }
            AnalysisView beforeCancel = analysisService.detail(analysisA);
            if (legacyCancellation) {
                assertTrue(beforeCancel.allowedActions().contains("CANCEL_ACTION"));
                assertTrue(beforeCancel.flatMaterials().stream().flatMap(material -> material.downstreamReferences().stream())
                        .anyMatch(ref -> notificationAction.equals(ref.actionId()) && ref.notificationReversalPending()));
                assertThrows(ApiException.class,()->analysisCommandService.notifySupply(analysisA,
                        new NotifyRequest(beforeCancel.version(),beforeCancel.fingerprint(),
                                "blocked-legacy-renotify-"+analysisA,"SUBCONTRACT",
                                List.of(subcontractRow.materialLineId()),List.of(),null)),
                        "历史通知未同步前不得把缺口再下达成第二个前置任务");
            }
            analysisCommandService.cancelAction(analysisA,notificationAction,new CancelRequest(
                    beforeCancel.version(),beforeCancel.fingerprint(),"reverse-sc-notification-"+analysisA,"撤回已解除订货的通知"));
            assertFalse(analysisService.detail(analysisA).flatMaterials().stream()
                    .flatMap(material -> material.downstreamReferences().stream())
                    .anyMatch(ref -> notificationAction.equals(ref.actionId()) && ref.notificationReversalPending()));
            assertEquals(0,bigDecimalFor("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",taskId).signum());
            assertEquals(0,bigDecimalFor("SELECT SUM(notify_qty) FROM preplan_subcontract_make_task_batches WHERE task_id=?",taskId)
                    .compareTo(new BigDecimal("10")),"原通知批次仍完整保留");
            assertEquals(0,bigDecimalFor("SELECT SUM(qty) FROM preplan_subcontract_make_batch_reversals WHERE task_id=?",taskId)
                    .compareTo(new BigDecimal("10")),"冲销以追加事实释放通知占用");
            stockDocService.reverseFinishedInbound(preparedInboundId);
            assertEquals(0,bigDecimalFor("SELECT produced_qty FROM preplan_subcontract_make_tasks WHERE id=?",taskId).signum(),
                    "6+4两份有效切片只回减10，不得回减原qty10再加恢复qty4");
            assertEquals(0,stockBalance(w.warehouseId(),subcontracted).signum());
            assertEquals(0,count("""
                    SELECT count(*) FROM stock_reservations WHERE owner_type='SUBCONTRACT_PREPARE_TASK'
                      AND owner_id=? AND status=0 AND qty-consumed_qty-released_qty>0
                    """,taskId));
            return;
        }
        assertEquals(1, count("""
                        select count(*)
                        from subcontract_material_plan_items plan_item
                        join subcontract_material_plans plan on plan.id = plan_item.plan_id
                        where plan.order_id = ?
                          and plan_item.flow_mode = 'PREPARED_OUTBOUND'
                          and plan_item.preparation_status = 'READY_OUTBOUND'
                          and plan_item.prepared_qty = 10
                          and plan_item.is_deleted = false
                        """, subcontractOrderId),
                "满批前置自制的订货行批准后必须即时待出仓");

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
        assertEquals(0, stockBalance(w.warehouseId(), subcontracted)
                        .compareTo(BigDecimal.ZERO),
                "前置自制产出 10 出仓发给委外部后，目标件库存归零，回厂门禁前置完成");

        // 委外商回厂：仓库登记进仓，IQC PASS 只放行；仓库确认后才形成库存与分析归属。
        com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest receiptRequest =
                new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        receiptRequest.setBillDate(rootSupplyMode ? com.uten.imp.common.time.BusinessTime.today() : LocalDate.of(2026,1,20));
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

        assertEquals(0, stockBalance(w.warehouseId(), subcontracted)
                        .compareTo(BigDecimal.ZERO),
                "委外 IQC PASS 仅形成仓库待入库，不得提前形成库存");
        assertEquals(0, count("""
                        select count(*)
                        from stock_reservations
                        where owner_type = 'PREPLAN_ANALYSIS'
                          and source_doc_id = ?
                          and is_deleted = false
                        """, receiptId),
                "仓库确认前不得建立分析库存归属");
        loginAs(createIqcWarehouseConfirmer(w, "iqc-stock-subcontract-" + w.goodsA()));
        iqcStockInService.confirm(
                "SUBCONTRACT", receiptId,
                latestIqcStockInRequest(
                        "SUBCONTRACT", receiptId, inspectionItemId,
                        quantity,
                        "stock-subcontract-" + inspectionItemId,
                        "SUB-A01"));


        if (rootSupplyMode) {
            assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where id=?",targetAnalysisItemId).compareTo(new BigDecimal("10")));
            assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(orderA)).compareTo(new BigDecimal("10")));
            assertEquals(0,publicAvailable(w.warehouseId(),subcontracted).compareTo(BigDecimal.ZERO));
            loginAs(w.superAdminUserId());
            MaterialView completedRoot=analysisService.detail(analysisA).flatMaterials().stream()
                    .filter(m -> m.materialLineId().equals(subcontractRow.materialLineId())).findFirst().orElseThrow();
            assertEquals(0,completedRoot.requiredQty().compareTo(new BigDecimal("10")),
                    "完成后仍保留本批原始需求，不能把入库完成表现成需求消失");
            assertEquals(0,completedRoot.shortageQty().signum());
            assertEquals(0,completedRoot.allocatedAvailableQty().compareTo(new BigDecimal("10")));
            assertTrue(completedRoot.downstreamReferences().stream()
                    .anyMatch(ref -> "ROOT_OUTPUT_FULFILLMENT".equals(ref.documentType())));
            subcontractReceiptService.reverse(receiptId);
            assertEquals(0,bigDecimalFor("select root_fulfilled_qty from production_material_analysis_items where id=?",targetAnalysisItemId).compareTo(BigDecimal.ZERO));
            assertEquals(0,bigDecimalFor("select reserved_qty from sales_order_items where id=?",orderItemId(orderA)).compareTo(BigDecimal.ZERO));
            assertEquals(0,stockBalance(w.warehouseId(),subcontracted).compareTo(BigDecimal.ZERO));
            return;
        }

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
                "仓库确认后须沿 application_item_id 写回本分析归属预留");
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

    @Test
    // V458/ADR-064 后「有子层级委外=先自制」由两条入口承担：分析链（SUBCONTRACT_MAKE
    // 任务，见 preplanPegging_subcontractWarehouseStockInRefreshesOnlyOriginAnalysis）与
    // 直下单缺口行。按ADR-072/V529，草稿保存即交计划，未完成前置生产不能送审。
    // 保留本例独有的单一BOM精确20件需求、独立来源/无V447接管及取消未排产准备的验证。
    void subcontractPreparationStartCreatesIndependentDirectOrderAnalysis() {
        World w = seedWorld("v447-start");
        UUID subcontracted = UUID.randomUUID();
        UUID childMaterial = UUID.randomUUID();
        insertGoods(subcontracted, "V447-S", "V447 subcontract target", "委外",
                w.unitId(), w.unitLegacy());
        insertGoods(childMaterial, "V447-C", "V447 internal child", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id=? where id=?",
                w.supplierId(), subcontracted);
        insertBom(subcontracted, childMaterial, "2");

        UUID planner = createUserWithPerms(w, "planner-v447-start",
                "production_material_analysis:view",
                "production_material_analysis:manage",
                "production_material_analysis:route",
                "production_material_analysis:notify");
        jdbc.update("update employees set department_id=(select id from departments where code='SUB_PLAN') where id=(select employee_id from users where id=?)",planner);
        // 直下单：手工新建委外订货单（不经物料分析与申请），目标件无库存。
        loginAs(w.superAdminUserId());
        com.uten.imp.features.subcontract.order.dto.OrderSaveRequest orderRequest =
                new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        orderRequest.setSettlementMethodId(activeSettlementMethodId());
        orderRequest.setBillDate(LocalDate.of(2026, 8, 31));
        orderRequest.setDeliverDate(LocalDate.of(2026, 9, 5));
        orderRequest.setSupplierId(w.supplierId());
        orderRequest.setWarehouseId(w.warehouseId());
        orderRequest.setCurrencyId(w.currencyId());
        orderRequest.setExchangeRate(BigDecimal.ONE);
        orderRequest.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.subcontract.order.dto.OrderItemLine line =
                new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setGoodsId(subcontracted);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("10"));
        line.setDeliverDate(LocalDate.of(2026, 9, 5));
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(new BigDecimal("10"));
        line.setAmountLocal(new BigDecimal("10"));
        orderRequest.setItems(List.of(line));
        UUID subcontractOrderId = subcontractOrderService.create(orderRequest).getId();
        UUID orderItemId=jdbc.queryForObject("select id from subcontract_order_items where order_id=? and is_deleted=false",UUID.class,subcontractOrderId);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,
                ()->financeApproval.submit("SUBCONTRACT",subcontractOrderId)).getCode());
        assertEquals(0,intFor("select status from subcontract_orders where id=?",subcontractOrderId));
        assertEquals(0,count("select count(*) from procurement_order_approval_cases where order_type='SUBCONTRACT' and order_id=?",subcontractOrderId));
        assertEquals(0, count("""
                SELECT count(*)
                FROM subcontract_material_plan_items plan_item
                JOIN subcontract_material_plans plan ON plan.id=plan_item.plan_id
                WHERE plan.order_id=?
                """, subcontractOrderId),
                "准备尚未实收时不得先财审生成出仓计划");

        loginAs(planner);
        UUID startedAnalysisId = jdbc.queryForObject("""
                SELECT analysis_id FROM production_material_analysis_items
                WHERE subcontract_order_item_id=? AND is_deleted=false
                """, UUID.class, orderItemId);
        assertNotNull(startedAnalysisId,
                "直下单草稿必须已建立可由计划经办打开的独立分析");
        assertEquals("ACTIVE",analysisService.detail(startedAnalysisId).status());
        assertEquals(1, count("""
                SELECT count(*)
                FROM production_material_analysis_items item
                WHERE item.subcontract_order_item_id=?
                  AND item.source_ref='SC-ORDER:' || item.subcontract_order_item_id::text
                  AND item.analysis_id=? AND item.is_deleted=FALSE
                  AND item.source_type='SUBCONTRACT_PREPARATION'
                """, orderItemId, startedAnalysisId),
                "前置分析必须以SC-ORDER及真实订货行UUID绑定草稿新增需求");
        // 子件需求整体落在独立分析内（父件×10、单耗 2 → 子件 20）。
        assertEquals(0, jdbc.queryForObject("""
                SELECT required_qty
                FROM production_material_analysis_materials
                WHERE analysis_id=? AND goods_id=? AND active=TRUE
                """, BigDecimal.class, startedAnalysisId, childMaterial)
                .compareTo(new BigDecimal("20")),
                "the independent preparation analysis owns the full child demand");
        // 直下单没有源分析可接管：不得残留任何 V447 跨分析 handoff 记录。
        assertEquals(0, count("""
                SELECT count(*)
                FROM preplan_subcontract_requirement_handoffs handoff
                WHERE handoff.target_analysis_id=?
                """, startedAnalysisId),
                "direct-order preparation must not fabricate cross-analysis handoffs");

        loginAs(w.superAdminUserId());
        subcontractOrderService.delete(subcontractOrderId);
        assertEquals("CANCELLED",strFor("select status from production_material_analyses where id=?",startedAnalysisId),
                "取消原草稿必须同步取消尚未排产准备，不能残留无需求任务");
        assertEquals(1,count("select count(*) from subcontract_orders where id=? and is_deleted",subcontractOrderId));
    }


    @Test
    void directCustomerShipment_confirmClaimEditUnpickAndShipPreserveRealSources() {
        World w=seedWorld("direct-customer-v511");
        receiveOpeningInputsForA(w,"5"); // Actual warehouse receipt: B10 and E5, with nonzero input value.
        loginAs(w.superAdminUserId());
        var request=directCustomerShipmentRequest(w,"CHARGED","3");
        var draft=shipmentService.create(request);
        UUID id=draft.getId(),itemId=draft.getItems().getFirst().getId();
        assertFalse(draft.getWorkflow().isSalesConfirmed());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->reviewClaims.claim("SALES_SHIPMENT_FINANCE_AUDIT",id.toString())).getCode());
        var picking=new WarehouseWorkTransitionRequest();picking.setTargetStatus("PICKING");
        assertThrows(ApiException.class,()->shipmentService.transitionWarehouseWork(id,picking));
        shipmentService.confirmSales(id,0L);
        var claim=reviewClaims.claim("SALES_SHIPMENT_FINANCE_AUDIT",id.toString());
        var revised=directCustomerShipmentRequest(w,"CHARGED","4");
        revised.setExpectedRevision(0L);revised.getItems().getFirst().setId(itemId);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->shipmentService.update(id,revised)).getCode(),
                "the same account in another sales window cannot edit its live financial claim");
        reviewClaims.release("SALES_SHIPMENT_FINANCE_AUDIT",id.toString(),claim.claimId());
        var edited=shipmentService.update(id,revised);
        assertEquals(itemId,edited.getItems().getFirst().getId());
        assertEquals(1,edited.getWorkflow().getReviewRevision());
        shipmentService.confirmSales(id,1L);
        confirmShipmentFinance(id);
        var approvedChange=directCustomerShipmentRequest(w,"CHARGED","5");
        approvedChange.setExpectedRevision(1L);approvedChange.getItems().getFirst().setId(itemId);
        var changed=shipmentService.update(id,approvedChange);
        assertEquals(0,changed.getFinanceAudit().intValue());
        assertFalse(changed.getWorkflow().isSalesConfirmed());
        assertEquals(1,count("SELECT count(*) FROM sales_shipment_finance_release_events WHERE shipment_id=? AND event_type='REVOKED'",id));
        shipmentService.confirmSales(id,2L);confirmShipmentFinance(id);
        shipmentService.transitionWarehouseWork(id,picking);
        assertEquals(0,bigDecimalFor("SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations WHERE owner_type='CUSTOMER_SHIPMENT_ITEM' AND source_doc_id=? AND status=0",id).compareTo(new BigDecimal("5")));
        var exception=new WarehouseWorkTransitionRequest();exception.setTargetStatus("EXCEPTION");exception.setReason("实际退拣核对");
        shipmentService.transitionWarehouseWork(id,exception);
        var unpick=new WarehouseWorkTransitionRequest();unpick.setTargetStatus("PENDING_PICK");unpick.setReason("货物已退回原库位");
        shipmentService.transitionWarehouseWork(id,unpick);
        assertEquals(0,count("SELECT count(*) FROM stock_reservations WHERE owner_type='CUSTOMER_SHIPMENT_ITEM' AND source_doc_id=? AND status=0",id));
        shipmentService.transitionWarehouseWork(id,picking);
        var work=new WarehouseWorkTransitionRequest();work.setTargetStatus("PICKED");shipmentService.transitionWarehouseWork(id,work);
        work.setTargetStatus("SHIPPED");var shipped=shipmentService.transitionWarehouseWork(id,work);
        assertTrue(shipped.isArPosted());
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).compareTo(new BigDecimal("5")));
        assertEquals(0,shipped.getTotalOriginal().compareTo(new BigDecimal("61.7280")));
        assertThrows(ApiException.class,()->shipmentService.transitionWarehouseWork(id,work));
        assertEquals(1,count("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",id));
        assertEquals(1,count("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",id));
        assertEquals(0,count("SELECT count(*) FROM ar_ap_source_refs ref JOIN ar_ap_ledger ledger ON ledger.id=ref.ledger_id WHERE ledger.source_doc_id=?",id));
        assertEquals(2,count("SELECT count(*) FROM stock_reservations WHERE owner_type='CUSTOMER_SHIPMENT_ITEM' AND source_doc_id=?",id),"unpick keeps the released reservation and creates a fresh picking fact");
        var free=shipmentService.create(directCustomerShipmentRequest(w,"FREE","5"));
        assertEquals(0,free.getTotalOriginal().signum());
        shipmentService.confirmSales(free.getId(),0L);shipThroughWarehouse(free.getId());
        assertFalse(shipmentService.detail(free.getId()).isArPosted());
        assertEquals(0,count("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",free.getId()));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).signum());
        assertEquals(1,count("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",free.getId()),"FREE is a real physical issue, never inferred as zero cost");
        var freeFact=shipmentService.detail(free.getId());
        var returned=new com.uten.imp.features.sales.ret.dto.ReturnSaveRequest();
        returned.setBillDate(BusinessTime.today());returned.setClientId(w.clientId());returned.setWarehouseId(w.warehouseId());
        returned.setCurrencyId(freeFact.getCurrencyId());returned.setReturnReason("实际收到退回的免费样品");
        var returnLine=new com.uten.imp.features.sales.ret.dto.ReturnItemLine();returnLine.setOutItemId(freeFact.getItems().getFirst().getId());
        returnLine.setGoodsId(w.goodsB());returnLine.setUnitId(w.unitId());returnLine.setUnitRate(BigDecimal.ONE);returnLine.setQty(new BigDecimal("2"));returned.setItems(List.of(returnLine));
        UUID returnId=customerReturnService.create(returned).getId();var freeReturn=customerReturnService.approve(returnId);
        assertFalse(freeReturn.isArPosted());assertEquals(0,freeReturn.getTotalOriginal().signum());
        assertEquals(0,count("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_type='SALES_RETURN' AND source_doc_id=?",returnId));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).signum(),"uninspected returned samples stay outside saleable stock");
        customerReturnService.reverse(returnId);
        assertEquals(0,bigDecimalFor("SELECT returned_qty FROM sales_shipment_items WHERE id=?",freeFact.getItems().getFirst().getId()).signum());
    }

    @Test
    void directCustomerShipment_partialReceiptsAndOrderedReversalsUseShipWithoutInventedOrder() {
        World w=seedWorld("direct-customer-cash-v511");receiveOpeningInputsForA(w,"5");loginAs(w.superAdminUserId());seedChartOfAccounts();
        var requested=directCustomerShipmentRequest(w,"CHARGED","10");requested.getItems().getFirst().setPrice(new BigDecimal("123.4567"));
        UUID shipment=shipmentService.create(requested).getId();shipmentService.confirmSales(shipment,0L);shipThroughWarehouse(shipment);
        UUID ledger=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,shipment);
        UUID style=UUID.randomUUID(),account=UUID.randomUUID();String token=UUID.randomUUID().toString();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'ACCOUNT',0,'使用')",style,"DIRECT-STYLE-"+token,"直发真实收款账户科目");
        jdbc.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id) VALUES(?,?,?,'BANK',?,'使用',?)",account,"DIRECT-BANK-"+token,"直发收款验证账户",w.currencyId(),style);
        UUID reviewer=createUserWithPerms(w,"direct-receipt-checker","finance_receipt:view","finance_receipt:approve","finance_receipt:reverse","finance:view:all");
        UUID first=receiptService.create(receiptRequest(w,ledger,account,null,"200","199","1","0",BigDecimal.ONE,BusinessTime.today())).getId();
        loginAs(reviewer);receiptService.approve(first);assertNonemptySourceVoucher("RECEIPT",first);
        assertEquals(0,bigDecimalFor("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger).compareTo(new BigDecimal("1034.5670")));
        assertEquals(0,bigDecimalFor("SELECT balance_current FROM accounts WHERE id=?",account).compareTo(new BigDecimal("199")),"customer paid200; actual bank receipt199 after fee1");
        loginAs(w.superAdminUserId());UUID second=receiptService.create(receiptRequest(w,ledger,account,null,"1034.5670","1034.5670","0","0",BigDecimal.ONE,BusinessTime.today())).getId();
        loginAs(reviewer);receiptService.approve(second);assertNonemptySourceVoucher("RECEIPT",second);
        assertEquals(0,bigDecimalFor("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger).signum());
        assertEquals(0,bigDecimalFor("SELECT balance_current FROM accounts WHERE id=?",account).compareTo(new BigDecimal("1233.5670")));
        assertThrows(ApiException.class,()->receiptService.reverse(first));
        assertThrows(ApiException.class,()->receiptService.approve(second));
        receiptService.reverse(second);receiptService.reverse(first);
        assertEquals(0,bigDecimalFor("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger).compareTo(new BigDecimal("1234.5670")));
        assertEquals(0,bigDecimalFor("SELECT amount_balance FROM ar_ap_ledger WHERE id=?",ledger).compareTo(new BigDecimal("1234.5670")));
        assertEquals(0,bigDecimalFor("SELECT balance_current FROM accounts WHERE id=?",account).signum());
        assertEquals(0,count("SELECT count(*) FROM finance_receipt_source_allocations WHERE receipt_id IN (?,?)",first,second));
        assertEquals(0,count("SELECT count(*) FROM ar_ap_source_refs WHERE ledger_id=?",ledger));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).signum(),"financial reversals never create returned physical goods");
    }

    @Test
    void directCustomerShipment_respectsGlobalOrderReservationsAndKindPermissions() {
        World w=seedWorld("direct-reservation-v511");receiveOpeningInputsForA(w,"5");loginAs(w.superAdminUserId());
        UUID order=salesOrderService.create(orderRequest(w,w.goodsB(),"8","100")).getId();salesOrderService.approve(order);
        assertEquals(0,bigDecimalFor("SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations WHERE order_item_id=? AND warehouse_id IS NULL AND status=0",orderItemId(order)).compareTo(new BigDecimal("8")));
        var direct=shipmentService.create(directCustomerShipmentRequest(w,"FREE","3"));shipmentService.confirmSales(direct.getId(),0L);confirmShipmentFinance(direct.getId());
        var pick=new WarehouseWorkTransitionRequest();pick.setTargetStatus("PICKING");
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->shipmentService.transitionWarehouseWork(direct.getId(),pick)).getCode());
        assertEquals(0,count("SELECT count(*) FROM stock_reservations WHERE source_doc_id=?",direct.getId()));
        var reduced=directCustomerShipmentRequest(w,"FREE","2");reduced.setExpectedRevision(0L);reduced.getItems().getFirst().setId(direct.getItems().getFirst().getId());
        shipmentService.update(direct.getId(),reduced);shipmentService.confirmSales(direct.getId(),1L);shipThroughWarehouse(direct.getId());
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).compareTo(new BigDecimal("8")));
        assertEquals(0,reservedQty(orderItemId(order)).compareTo(new BigDecimal("8")));
        var onlyNormal=createUserWithPerms(w,"only-normal-shipment-view","sales_shipment:view","sales:view:all");loginAs(onlyNormal);
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,()->shipmentService.detail(direct.getId())).getCode());
        var onlyDirect=createUserWithPerms(w,"only-direct-shipment-view","sales_other_shipment:view","sales:view:all");loginAs(onlyDirect);
        assertEquals(direct.getId(),shipmentService.detail(direct.getId()).getId());
    }

    @Test
    void directCustomerShipment_twoWarehousePicksSerializeOneFinitePool() throws Exception {
        World w=seedWorld("direct-competing-picks-v511");receiveOpeningInputsForA(w,"5");loginAs(w.superAdminUserId());
        UUID first=shipmentService.create(directCustomerShipmentRequest(w,"FREE","6")).getId();shipmentService.confirmSales(first,0L);confirmShipmentFinance(first);
        UUID second=shipmentService.create(directCustomerShipmentRequest(w,"FREE","6")).getId();shipmentService.confirmSales(second,0L);confirmShipmentFinance(second);
        var pick=new WarehouseWorkTransitionRequest();pick.setTargetStatus("PICKING");
        var held=new java.util.concurrent.CountDownLatch(1);var release=new java.util.concurrent.CountDownLatch(1);var waiterPid=new java.util.concurrent.atomic.AtomicInteger();
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var leader=workers.submit(()->{loginAs(w.superAdminUserId());try {
                return new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(tx->{
                    var value=shipmentService.transitionWarehouseWork(first,pick);held.countDown();
                    try {if(!release.await(10,java.util.concurrent.TimeUnit.SECONDS))throw new AssertionError("direct pick test timeout");}
                    catch(InterruptedException e){Thread.currentThread().interrupt();throw new AssertionError(e);}return value;
                });}finally{SecurityContextHolder.clearContext();}});
            assertTrue(held.await(10,java.util.concurrent.TimeUnit.SECONDS));
            var contender=workers.submit(()->{loginAs(w.superAdminUserId());try {
                return assertThrows(ApiException.class,()->new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(tx->{
                    waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()",Integer.class));return shipmentService.transitionWarehouseWork(second,pick);
                }));}finally{SecurityContextHolder.clearContext();}});
            long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(8);boolean waiting=false;
            while(System.nanoTime()<deadline&&!waiting){if(waiterPid.get()!=0)waiting=Boolean.TRUE.equals(jdbc.queryForObject("SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=?",Boolean.class,waiterPid.get()));if(!waiting)Thread.sleep(20);}
            assertTrue(waiting,"the second dispatch must wait on the same real inventory mutex");release.countDown();leader.get(15,java.util.concurrent.TimeUnit.SECONDS);
            assertEquals(ErrorCode.CONFLICT,contender.get(15,java.util.concurrent.TimeUnit.SECONDS).getCode());
        }finally{release.countDown();}
        assertEquals(0,bigDecimalFor("SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations WHERE source_doc_id IN (?,?) AND status=0",first,second).compareTo(new BigDecimal("6")));
        assertEquals("PENDING_PICK",shipmentWorkStatus(second));assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).compareTo(BigDecimal.TEN));
    }

    @Test
    void directCustomerShipment_financeRejectionRevisionNoticesAndCountsUseCurrentTask() throws Exception {
        World w=seedWorld("direct-review-notice-v511");loginAs(w.superAdminUserId());
        UUID seller=createUserWithPerms(w,"direct-notice-seller","sales_other_shipment:view","sales_other_shipment:create",
                "sales_other_shipment:edit","sales_other_shipment:approve","sales_other_shipment:delete","sales_order:price:view","client:view","notice:read");
        UUID finance=createUserWithPerms(w,"direct-notice-finance","finance_shipment_audit","notice:read");
        jdbc.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='DEPT_SALES' AND NOT is_deleted) WHERE id=?",employeeIdOf(seller));
        jdbc.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='DEPT_FIN' AND NOT is_deleted) WHERE id=?",employeeIdOf(finance));
        loginAs(seller);
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,()->shipmentService.create(directCustomerShipmentRequest(w,"FREE","1"))).getCode(),"unassigned customer is not an implicit grant to any salesperson");
        loginAs(w.superAdminUserId());
        jdbc.update("UPDATE clients SET owner_employee_id=? WHERE id=?",employeeIdOf(seller),w.clientId());
        loginAs(finance);long baseline=shipmentService.countPendingFinanceAudit();
        loginAs(seller);var draft=shipmentService.create(directCustomerShipmentRequest(w,"FREE","1"));UUID id=draft.getId();
        loginAs(finance);assertEquals(baseline,shipmentService.countPendingFinanceAudit());
        loginAs(seller);shipmentService.confirmSales(id,0L);
        loginAs(finance);assertEquals(baseline+1,shipmentService.countPendingFinanceAudit());
        for(int attempt=0;attempt<100&&count("SELECT count(*) FROM notices WHERE aggregate_id=? AND source_event='SALES_SHIPMENT_PENDING_FINANCE_AUDIT' AND audience_user_id=?",id,finance)==0;attempt++) {
            while(businessOutboxProcessor.processNext()) { } Thread.sleep(20);
        }
        UUID firstNotice=jdbc.queryForObject("SELECT id FROM notices WHERE aggregate_id=? AND source_event='SALES_SHIPMENT_PENDING_FINANCE_AUDIT' AND audience_user_id=?",UUID.class,id,finance);
        assertFalse(reviewNoticeService.pendingReviewStatus(List.of(firstNotice)).getFirst().resolved());
        var claim=reviewClaims.claim("SALES_SHIPMENT_FINANCE_AUDIT",id.toString());var info=shipmentService.financeAuditInfo(id);
        var rejected=new com.uten.imp.features.sales.shipment.dto.ShipmentFinanceDecisionRequest(0L,info.get("contentHash").toString(),claim.claimId(),"请补充准确收货地址");
        shipmentService.financeAuditReject(id,rejected);
        assertEquals(baseline,shipmentService.countPendingFinanceAudit());assertTrue(reviewNoticeService.pendingReviewStatus(List.of(firstNotice)).getFirst().resolved());
        loginAs(seller);var corrected=directCustomerShipmentRequest(w,"FREE","1");corrected.setExpectedRevision(0L);
        corrected.getItems().getFirst().setId(draft.getItems().getFirst().getId());corrected.setShipAddr("重新核对后的客户收货处");
        shipmentService.update(id,corrected);shipmentService.confirmSales(id,1L);
        loginAs(finance);assertEquals(baseline+1,shipmentService.countPendingFinanceAudit());
        for(int attempt=0;attempt<100&&count("SELECT count(*) FROM notices WHERE aggregate_id=? AND source_event='SALES_SHIPMENT_PENDING_FINANCE_AUDIT' AND audience_user_id=?",id,finance)<2;attempt++) {
            while(businessOutboxProcessor.processNext()) { } Thread.sleep(20);
        }
        assertEquals(2,count("SELECT count(*) FROM notices WHERE aggregate_id=? AND source_event='SALES_SHIPMENT_PENDING_FINANCE_AUDIT' AND audience_user_id=?",id,finance),"new revision must not reuse the first-submission dedupe key");
        var nextReview=shipmentService.financeAuditInfo(id);
        var json=new com.fasterxml.jackson.databind.ObjectMapper();
        assertEquals("1",json.readTree(nextReview.get("commercialSnapshot").toString()).path("items").get(0).path("qty").asText(),"canonical review values ignore storage-only trailing zeros before future precision expansion");
        assertTrue(json.readTree(nextReview.get("previousCommercialSnapshot").toString()).path("header").path("shipAddr").isNull());
        assertEquals("重新核对后的客户收货处",json.readTree(nextReview.get("commercialSnapshot").toString()).path("header").path("shipAddr").asText());
        loginAs(seller);shipmentService.delete(id);
        loginAs(finance);assertEquals(baseline,shipmentService.countPendingFinanceAudit());
        assertEquals(0,count("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",id));
        assertEquals(0,count("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",id));
    }

    @Test
    void directCustomerShipment_unrepresentableLocalMoneyDoesNotShipOrCreateAr() {
        World w=seedWorld("direct-money-exact-v511");receiveOpeningInputsForA(w,"1");loginAs(w.superAdminUserId());
        var request=directCustomerShipmentRequest(w,"CHARGED","1");request.getItems().getFirst().setPrice(new BigDecimal("0.0001"));
        UUID id=shipmentService.create(request).getId();shipmentService.confirmSales(id,0L);confirmShipmentFinance(id);
        var work=new WarehouseWorkTransitionRequest();work.setTargetStatus("PICKING");shipmentService.transitionWarehouseWork(id,work);
        work.setTargetStatus("PICKED");shipmentService.transitionWarehouseWork(id,work);
        jdbc.update("UPDATE currencies SET exchange_rate=0.0001 WHERE id=?",w.currencyId());work.setTargetStatus("SHIPPED");
        assertEquals(ErrorCode.VALIDATION_FAILED,assertThrows(ApiException.class,()->shipmentService.transitionWarehouseWork(id,work)).getCode());
        assertEquals("PICKED",shipmentWorkStatus(id));assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).compareTo(new BigDecimal("2")));
        assertEquals(0,count("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",id));
        assertEquals(0,count("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",id));
        assertEquals(0,count("SELECT count(*) FROM sales_shipment_warehouse_events WHERE shipment_id=? AND to_status='SHIPPED'",id));
        assertEquals(0,bigDecimalFor("SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations WHERE source_doc_id=? AND status=0",id).compareTo(BigDecimal.ONE));
    }

    private ShipmentSaveRequest directCustomerShipmentRequest(World w,String billing,String qty) {
        var req=new ShipmentSaveRequest();req.setShipmentKind("DIRECT_CUSTOMER");req.setBillingMode(billing);
        req.setDirectPurpose("SAMPLE");req.setFreeReason("已确认的客户样品约定");req.setClientId(w.clientId());
        req.setWarehouseId(w.warehouseId());req.setCurrencyId(w.currencyId());req.setBillDate(BusinessTime.today());
        var line=new ShipmentItemLine();line.setGoodsId(w.goodsB());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("12.3456"));line.setDiscount(BigDecimal.ONE);
        req.setItems(List.of(line));return req;
    }

    @Autowired private com.uten.imp.application.concurrency.FulfillmentMutationLocks fulfillmentMutationLocks;
    @Autowired private com.uten.imp.application.port.ProductionMutationFootprintPort productionMutationFootprint;
    @Autowired private com.uten.imp.features.sales.SalesMutationFootprintService salesMutationFootprint;
    @Autowired private com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService planMutationFootprint;
    @Autowired private com.uten.imp.features.production.quality.ProductionQualityMutationFootprintService qualityMutationFootprint;
    @Autowired private com.uten.imp.features.production.quality.ProductionFqcReplenishmentService fqcReplenishmentService;
    @Autowired private com.uten.imp.features.production.quality.ProductionFqcReplenishmentMaterialService fqcReplenishmentMaterials;

    @Test
    void fulfillmentLockPrefix_salesChangeAndFinishedInboundPreserveBothWaitingDirections() throws Exception {
        for (boolean salesFirst : List.of(true, false)) {
            World w = seedWorld(salesFirst ? "lock-sales-first" : "lock-inbound-first");
            receiveOpeningInputsForA(w,"10");
            UUID planId = approvedPlan(w,w.goodsA(),"10","10");
            issueReadyPlanAndMaterials(w,planId);
            UUID planItemId=planItemIdFor(planId,w.goodsA());
            UUID orderItemId=orderItemIdOfPlan(planId);
            UUID orderId=jdbc.queryForObject("SELECT order_id FROM sales_order_items WHERE id=?",UUID.class,orderItemId);
            loginAs(w.superAdminUserId());
            UUID reportId=reportAndApprove(w,planItemId,orderItemId,w.goodsA(),"10");
            UUID inboundId=finishedInDocForReport(reportId);
            var line=new OrderChangeQtyRequest.Line(); line.setOrderItemId(orderItemId); line.setNewQty(new BigDecimal("12"));
            var change=new OrderChangeQtyRequest(); change.setItems(List.of(line));
            var held=new java.util.concurrent.CountDownLatch(1);
            var release=new java.util.concurrent.CountDownLatch(1);
            var waiterPid=new java.util.concurrent.atomic.AtomicInteger();
            try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
                var holder=workers.submit(() -> {
                    loginAs(w.superAdminUserId());
                    try {
                        new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(tx -> {
                            if(salesFirst) salesMutationFootprint.lockOrder(orderId,List.of());
                            else fulfillmentMutationLocks.acquire(() -> productionMutationFootprint.forStockDocuments(List.of(inboundId))).verifyUnchanged();
                            held.countDown();
                            try { if(!release.await(10,java.util.concurrent.TimeUnit.SECONDS)) throw new AssertionError("prefix holder timeout"); }
                            catch(InterruptedException error) {Thread.currentThread().interrupt();throw new AssertionError(error);}
                            if(salesFirst) salesOrderService.changeQty(orderId,change);
                            else confirmFinishedInboundFully(inboundId);
                        });
                    } finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
                });
                assertTrue(held.await(10,java.util.concurrent.TimeUnit.SECONDS));
                var waiter=workers.submit(() -> {
                    loginAs(w.superAdminUserId());
                    try {
                        new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(tx -> {
                            waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()",Integer.class));
                            if(salesFirst) confirmFinishedInboundFully(inboundId);
                            else salesOrderService.changeQty(orderId,change);
                        });
                    } finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
                });
                long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(8);
                boolean waiting=false;
                while(System.nanoTime()<deadline && !waiting) {
                    if(waiterPid.get()!=0) waiting=Boolean.TRUE.equals(jdbc.queryForObject(
                            "SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=?",Boolean.class,waiterPid.get()));
                    if(!waiting) Thread.sleep(20);
                }
                assertTrue(waiting,"second real service must wait on PostgreSQL, not an artificial test mutex");
                release.countDown(); holder.get(15,java.util.concurrent.TimeUnit.SECONDS);
                if(salesFirst) waiter.get(15,java.util.concurrent.TimeUnit.SECONDS);
                else {
                    var stale=assertThrows(java.util.concurrent.ExecutionException.class,
                            () -> waiter.get(15,java.util.concurrent.TimeUnit.SECONDS));
                    assertEquals(ErrorCode.CONFLICT,org.junit.jupiter.api.Assertions.assertInstanceOf(ApiException.class,stale.getCause()).getCode());
                    assertEquals(0,bigDecimalFor("SELECT qty FROM sales_order_items WHERE id=?",orderItemId).compareTo(new BigDecimal("10")),
                            "stale sales command must not partially change order quantity");
                    loginAs(w.superAdminUserId()); salesOrderService.changeQty(orderId,change);
                }
            } finally {release.countDown();}
            assertEquals(0,bigDecimalFor("SELECT qty FROM sales_order_items WHERE id=?",orderItemId).compareTo(new BigDecimal("12")));
            assertEquals(0,producedQty(orderItemId).compareTo(new BigDecimal("10")));
            assertEquals(0,reservedQty(orderItemId).compareTo(new BigDecimal("10")));
            assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("10")));
            assertEquals(0,movementSum(w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("10")));
            assertEquals(0,bigDecimalFor("SELECT iqty FROM production_plan_items WHERE id=?",planItemId).compareTo(new BigDecimal("10")));
            assertEquals(0,bigDecimalFor("SELECT inbound_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",planItemId,orderItemId).compareTo(new BigDecimal("10")));
            assertEquals(1,count("SELECT count(*) FROM production_finished_in_confirmations WHERE stock_document_id=?",inboundId));
        }
    }

    @Test
    void planningPackage_unallocatedOpenPurchaseOrderNeitherSuppliesNorBlocksThePlan() throws Exception {
        World w=seedWorld("package-open-po-independent");
        UUID planId=approvedPlan(w,w.goodsA(),"10","10");
        var before=planningPackageService.preview(planId,w.warehouseId());
        loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setWarehouseId(w.warehouseId());
        request.setDepartmentId(w.departmentId()); request.setApplicantId(w.employeeId());
        var requested=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(w.goodsB()); requested.setUnitId(w.unitId()); requested.setUnitRate(BigDecimal.ONE);
        requested.setQty(new BigDecimal("20")); request.setItems(List.of(requested));
        var source=purchaseRequestService.create(request); purchaseRequestService.approve(source.getId());
        var ordered=new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        ordered.setRequestItemId(source.getItems().getFirst().getId()); ordered.setGoodsId(w.goodsB());
        ordered.setUnitId(w.unitId()); ordered.setUnitRate(BigDecimal.ONE); ordered.setQty(new BigDecimal("20"));
        ordered.setPrice(new BigDecimal("50")); ordered.setAmountOriginal(new BigDecimal("1000")); ordered.setAmountLocal(new BigDecimal("1000"));
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today()); order.setWarehouseId(w.warehouseId()); order.setSupplierId(w.supplierId());
        order.setCurrencyId(w.currencyId()); order.setExchangeRate(BigDecimal.ONE); order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(activeSettlementMethodId()); order.setItems(List.of(ordered));
        var purchase=purchaseOrderService.create(order);
        UUID reviewer=createApprover(w); financeApproval.submit("PURCHASE",purchase.getId());
        loginAs(reviewer); approvePendingFinance("PURCHASE",purchase.getId()); loginAs(w.superAdminUserId());
        var after=planningPackageService.preview(planId,w.warehouseId());
        assertEquals(before.fingerprint(),after.fingerprint(),"unallocated open PO is not stock or plan entitlement");
        var command=new GeneratePlanningPackageRequest(); command.setWarehouseId(w.warehouseId());
        command.setIdempotencyKey("open-po-independent-"+planId); command.setPreviewFingerprint(after.fingerprint()); command.setGeneratePurchaseRequest(true);
        // An unrelated commercial head lease may remain held: planning does not
        // consume or lock this source merely because its SKU matches a shortage.
        try(var executor=java.util.concurrent.Executors.newSingleThreadExecutor();
            var connection=jdbc.getDataSource().getConnection();
            var lock=connection.prepareStatement("SELECT id FROM purchase_orders WHERE id=? FOR UPDATE")) {
            connection.setAutoCommit(false); lock.setObject(1,purchase.getId()); lock.executeQuery().close();
            var result=executor.submit(() -> {
                loginAs(w.superAdminUserId());
                try {return planningPackageService.confirm(planId,command);}
                finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
            }).get(15,java.util.concurrent.TimeUnit.SECONDS);
            assertNull(result.purchaseRequest());
            assertEquals(0,count("""
                    SELECT count(*) FROM production_material_supply_pegs peg JOIN production_material_demands demand ON demand.id=peg.demand_id
                    WHERE demand.plan_id=? AND peg.supply_type='PURCHASE_ORDER_ITEM' AND peg.supply_item_id=?
                    """,planId,purchase.getItems().getFirst().getId()),"no implicit allocation to an unrelated open PO");
            assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).compareTo(BigDecimal.ZERO));
            connection.rollback();
        }
    }

    @Test
    void planningPackage_concurrentSameKeyReplayThenCancelAndRecreateKeepsFrozenFacts() throws Exception {
        World w=seedWorld("package-replay-prefix"); UUID planId=approvedPlan(w,w.goodsA(),"10","10");
        var preview=planningPackageService.preview(planId,w.warehouseId());
        var command=new GeneratePlanningPackageRequest(); command.setWarehouseId(w.warehouseId());
        command.setIdempotencyKey("same-package-key-"+planId); command.setPreviewFingerprint(preview.fingerprint()); command.setGeneratePurchaseRequest(true);
        var held=new java.util.concurrent.CountDownLatch(1); var release=new java.util.concurrent.CountDownLatch(1);
        var waiterPid=new java.util.concurrent.atomic.AtomicInteger();
        UUID packageId;
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var first=workers.submit(() -> {
                loginAs(w.superAdminUserId());
                try {return new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(tx -> {
                    planMutationFootprint.lockPlan(planId,List.of()); held.countDown();
                    try {if(!release.await(10,java.util.concurrent.TimeUnit.SECONDS))throw new AssertionError("package prefix timeout");}
                    catch(InterruptedException error){Thread.currentThread().interrupt();throw new AssertionError(error);}
                    return planningPackageService.confirm(planId,command);
                });} finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
            });
            assertTrue(held.await(10,java.util.concurrent.TimeUnit.SECONDS));
            var second=workers.submit(() -> {
                loginAs(w.superAdminUserId());
                try {return new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(tx -> {
                    waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()",Integer.class));
                    return planningPackageService.confirm(planId,command);
                });} finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
            });
            long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(8); boolean waiting=false;
            while(System.nanoTime()<deadline&&!waiting) {
                if(waiterPid.get()!=0)waiting=Boolean.TRUE.equals(jdbc.queryForObject("SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=?",Boolean.class,waiterPid.get()));
                if(!waiting)Thread.sleep(20);
            }
            assertTrue(waiting); release.countDown();
            var original=first.get(15,java.util.concurrent.TimeUnit.SECONDS); var replay=second.get(15,java.util.concurrent.TimeUnit.SECONDS);
            packageId=original.packageId(); assertEquals(packageId,replay.packageId()); assertTrue(replay.replayed());
            assertEquals(1,count("SELECT count(*) FROM production_planning_packages WHERE plan_id=? AND idempotency_key=?",planId,command.getIdempotencyKey()));
        } finally {release.countDown();}
        loginAs(w.superAdminUserId());
        var cancellation=new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest("cancel-replayed-package-"+planId,"未开工整包撤回");
        assertEquals("CANCELLED",planningPackageService.cancel(planId,packageId,cancellation).status());
        assertTrue(planningPackageService.cancel(planId,packageId,cancellation).replayed());
        assertEquals(0,count("SELECT count(*) FROM production_material_demands WHERE package_id=? AND status NOT IN ('RELEASED','REVERSED')",packageId));
        var nextPreview=planningPackageService.preview(planId,w.warehouseId());
        command.setPreviewFingerprint(nextPreview.fingerprint()); command.setIdempotencyKey("recreated-package-"+planId);
        var recreated=planningPackageService.confirm(planId,command);
        assertFalse(packageId.equals(recreated.packageId()));
        assertEquals("CANCELLED",strFor("SELECT status FROM production_planning_packages WHERE id=?",packageId));
        assertEquals(0,bigDecimalFor("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",planId).compareTo(new BigDecimal("10")));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
    }

    @Test
    void qualityPrefix_secondReportAndFirstPassInboundConserveBothWaitingDirections() throws Exception {
        List<UUID> remainingInspections=new java.util.ArrayList<>();
        for(boolean reportFirst:List.of(true,false)) {
            World w=seedWorld(reportFirst?"report-first-prefix":"inbound-first-report-prefix");
            receiveOpeningInputsForA(w,"10"); UUID plan=approvedPlan(w,w.goodsA(),"10","10");
            issueReadyPlanAndMaterials(w,plan); UUID planItem=planItemIdFor(plan,w.goodsA()); UUID orderItem=orderItemIdOfPlan(plan);
            UUID firstReport=reportAndApprove(w,planItem,orderItem,w.goodsA(),"5");
            UUID inbound=finishedInDocForReport(firstReport);
            PrefixReportDraft second=createPrefixReportDraft(w,plan,planItem,orderItem,"5");
            Runnable report=()->reportService.approve(second.id());
            Runnable receive=()->confirmFinishedInboundFully(inbound);
            Runnable reportPrefix=()->qualityMutationFootprint.beginReport(second.id()).verifyUnchanged();
            Runnable receivePrefix=()->fulfillmentMutationLocks.acquire(()->productionMutationFootprint.forStockDocuments(List.of(inbound))).verifyUnchanged();
            runProductionPrefixRace(w,reportFirst?second.reporter():w.superAdminUserId(),reportFirst?reportPrefix:receivePrefix,
                    reportFirst?report:receive,reportFirst?w.superAdminUserId():second.reporter(),reportFirst?receive:report);
            assertEquals(0,bigDecimalFor("SELECT fqty FROM production_plan_items WHERE id=?",planItem).compareTo(new BigDecimal("10")));
            assertEquals(0,bigDecimalFor("SELECT iqty FROM production_plan_items WHERE id=?",planItem).compareTo(new BigDecimal("5")));
            assertEquals(0,producedQty(orderItem).compareTo(new BigDecimal("5")));
            assertEquals(0,reservedQty(orderItem).compareTo(new BigDecimal("5")));
            assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("5")));
            assertEquals(0,movementSum(w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("5")));
            assertEquals(1,count("SELECT count(*) FROM production_finished_in_confirmations WHERE stock_document_id=?",inbound));
            assertEquals(2,count("SELECT count(*) FROM production_daily_reports WHERE id IN (?,?) AND status=1",firstReport,second.id()));
            UUID secondItem=jdbc.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",UUID.class,second.id());
            finishedArrivalRegistrationService.register(second.id(),new ArrivalRegistrationRequest(
                    "prefix-second-arrival-"+second.id(),w.warehouseId(),List.of(new ArrivalRegistrationItemRequest(secondItem,"PREFIX-SECOND-05"))));
            remainingInspections.add(jdbc.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,secondItem));
        }
        var batch=new com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest(
                remainingInspections.reversed(),"prefix-two-plan-batch-"+UUID.randomUUID());
        var result=fqcService.passAll(batch);
        assertEquals(2,result.items().size());
        assertEquals(result.batchId(),fqcService.passAll(batch).batchId());
        assertTrue(fqcService.passAll(batch).replay());
        assertEquals(2,count("SELECT count(*) FROM production_fqc_pass_all_batch_items WHERE batch_id=?",result.batchId()));
        for(var item:result.items())assertEquals(0,item.inspection().passedQty().compareTo(new BigDecimal("5")));
    }

    @Test
    void qualityPrefix_failRemainingFiveAndPassFiveInboundConserveBothWaitingDirections() throws Exception {
        for(boolean failureFirst:List.of(true,false)) {
            World w=seedWorld(failureFirst?"failure-first-prefix":"inbound-first-failure-prefix");
            receiveOpeningInputsForA(w,"10"); UUID plan=approvedPlan(w,w.goodsA(),"10","10");
            issueReadyPlanAndMaterials(w,plan); UUID planItem=planItemIdFor(plan,w.goodsA()); UUID orderItem=orderItemIdOfPlan(plan);
            PrefixReportDraft report=createPrefixReportDraft(w,plan,planItem,orderItem,"10");
            loginAs(report.reporter()); reportService.approve(report.id()); loginAs(w.superAdminUserId());
            UUID reportItem=jdbc.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",UUID.class,report.id());
            finishedArrivalRegistrationService.register(report.id(),new ArrivalRegistrationRequest(
                    "prefix-fqc-arrival-"+report.id(),w.warehouseId(),List.of(new ArrivalRegistrationItemRequest(reportItem,"PREFIX-FQC-01"))));
            UUID inspection=jdbc.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,reportItem);
            fqcService.decide(inspection,new DecisionRequest("PASS",new BigDecimal("5"),null,null,null,"prefix-pass-"+inspection));
            UUID inbound=finishedInDocForReport(report.id());
            DecisionRequest fail=new DecisionRequest("FAIL",null,new BigDecimal("5"),"SCRAP","另五件品质不合格","prefix-fail-"+inspection);
            Runnable decide=()->fqcService.decide(inspection,fail);
            Runnable receive=()->confirmFinishedInboundFully(inbound);
            Runnable failurePrefix=()->qualityMutationFootprint.beginInspections(List.of(inspection)).verifyUnchanged();
            Runnable receivePrefix=()->fulfillmentMutationLocks.acquire(()->productionMutationFootprint.forStockDocuments(List.of(inbound))).verifyUnchanged();
            runProductionPrefixRace(w,w.superAdminUserId(),failureFirst?failurePrefix:receivePrefix,
                    failureFirst?decide:receive,w.superAdminUserId(),failureFirst?receive:decide);
            loginAs(w.superAdminUserId()); assertTrue(fqcService.decide(inspection,fail).replay());
            assertEquals(0,bigDecimalFor("SELECT passed_qty FROM production_fqc_inspections WHERE id=?",inspection).compareTo(new BigDecimal("5")));
            assertEquals(0,bigDecimalFor("SELECT failed_qty FROM production_fqc_inspections WHERE id=?",inspection).compareTo(new BigDecimal("5")));
            assertEquals(0,bigDecimalFor("SELECT fqty FROM production_plan_items WHERE id=?",planItem).compareTo(new BigDecimal("5")));
            assertEquals(0,bigDecimalFor("SELECT iqty FROM production_plan_items WHERE id=?",planItem).compareTo(new BigDecimal("5")));
            assertEquals(0,producedQty(orderItem).compareTo(new BigDecimal("5")));
            assertEquals(0,reservedQty(orderItem).compareTo(new BigDecimal("5")));
            assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("5")));
            assertEquals(0,movementSum(w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("5")));
            assertEquals(0,bigDecimalFor("SELECT qty FROM production_daily_report_items WHERE id=?",reportItem).compareTo(new BigDecimal("10")),"original report quantity remains immutable evidence");
            assertEquals(1,count("SELECT count(*) FROM production_fqc_contribution_adjustments WHERE inspection_id=?",inspection));
            assertEquals(0,bigDecimalFor("SELECT SUM(authorized_qty) FROM production_fqc_recovery_authorizations WHERE source_inspection_id=?",inspection).compareTo(new BigDecimal("5")));
            assertEquals(1,count("SELECT count(*) FROM production_finished_in_confirmations WHERE stock_document_id=?",inbound));
            UUID authorization=jdbc.queryForObject("SELECT id FROM production_fqc_recovery_authorizations WHERE source_inspection_id=?",UUID.class,inspection);
            var recoveryWorkspace=fqcReplenishmentService.createMaterialAnalysis(authorization);
            assertEquals(recoveryWorkspace.materialAnalysisId(),fqcReplenishmentService.createMaterialAnalysis(authorization).materialAnalysisId());
            var materialRequest=new com.uten.imp.features.production.quality.ProductionFqcReplenishmentMaterialService.ConfirmRequest("prefix-material-"+authorization);
            var blocked=fqcReplenishmentMaterials.confirm(authorization,materialRequest);
            assertEquals("BLOCKED",blocked.status(),"consumed opening inputs cannot be reused for recovery");
            assertEquals(blocked.cycleId(),fqcReplenishmentMaterials.confirm(authorization,materialRequest).cycleId());
            assertEquals(1,count("SELECT count(*) FROM production_fqc_replenishment_attempts WHERE authorization_id=?",authorization));
            UUID unissuedDraw=null;
            if(failureFirst) {
                receiveOpeningInputsForA(w,"5");
                var supplied=fqcReplenishmentMaterials.confirm(authorization,
                        new com.uten.imp.features.production.quality.ProductionFqcReplenishmentMaterialService.ConfirmRequest("prefix-material-supplied-"+authorization));
                assertEquals("AWAITING_WAREHOUSE",supplied.status());
                unissuedDraw=supplied.drawId();assertNotNull(unissuedDraw);
                assertEquals(0,bigDecimalFor("SELECT COALESCE(SUM(issued_qty),0) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",unissuedDraw).compareTo(BigDecimal.ZERO));
            }
            loginAs(report.reporter());
            assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->reportService.reverse(report.id())).getCode(),
                    "actual inbound must be reversed before the source report");
            loginAs(w.superAdminUserId()); stockDocService.reverseFinishedInbound(inbound);
            loginAs(report.reporter()); reportService.reverse(report.id()); loginAs(w.superAdminUserId());
            assertEquals(1,count("SELECT count(*) FROM production_fqc_recovery_cancellation_events WHERE authorization_id=?",authorization));
            assertEquals(0,count("SELECT count(*) FROM production_material_demands WHERE fqc_recovery_authorization_id=? AND status NOT IN ('RELEASED','REVERSED')",authorization));
            assertEquals(0,bigDecimalFor("SELECT fqty FROM production_plan_items WHERE id=?",planItem).compareTo(BigDecimal.ZERO));
            assertEquals(0,bigDecimalFor("SELECT iqty FROM production_plan_items WHERE id=?",planItem).compareTo(BigDecimal.ZERO));
            assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
            assertEquals(0,movementSum(w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
            assertEquals(0,bigDecimalFor("SELECT qty FROM production_daily_report_items WHERE id=?",reportItem).compareTo(new BigDecimal("10")));
            if(unissuedDraw!=null) {
                assertEquals((short)-1,jdbc.queryForObject("SELECT status FROM stock_documents WHERE id=?",Short.class,unissuedDraw));
                assertEquals(0,stockBalance(w.warehouseId(),w.goodsB()).compareTo(new BigDecimal("10")));
                assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("5")));
                assertEquals(0,bigDecimalFor("""
                        SELECT COALESCE(SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty),0)
                        FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.demand_id
                        WHERE demand.fqc_recovery_authorization_id=? AND NOT reservation.is_deleted
                        """,authorization).compareTo(BigDecimal.ZERO));
            }
        }
    }

    private void runProductionPrefixRace(World w,UUID firstActor,Runnable prefix,Runnable firstCommand,UUID secondActor,Runnable secondCommand) throws Exception {
        var held=new java.util.concurrent.CountDownLatch(1); var release=new java.util.concurrent.CountDownLatch(1);
        var waiterPid=new java.util.concurrent.atomic.AtomicInteger();
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var first=workers.submit(()->{
                loginAs(firstActor);
                try {new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(tx->{
                    prefix.run(); held.countDown();
                    try {assertTrue(release.await(12,java.util.concurrent.TimeUnit.SECONDS));}
                    catch(InterruptedException error){Thread.currentThread().interrupt();throw new AssertionError(error);}
                    firstCommand.run();
                });} finally {SecurityContextHolder.clearContext();}
            });
            assertTrue(held.await(10,java.util.concurrent.TimeUnit.SECONDS));
            var second=workers.submit(()->{
                loginAs(secondActor);
                try {new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(tx->{
                    waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()",Integer.class)); secondCommand.run();
                });} finally {SecurityContextHolder.clearContext();}
            });
            long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(8); boolean waiting=false;
            while(System.nanoTime()<deadline&&!waiting) {
                if(waiterPid.get()!=0)waiting=Boolean.TRUE.equals(jdbc.queryForObject("SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=?",Boolean.class,waiterPid.get()));
                if(!waiting)Thread.sleep(20);
            }
            assertTrue(waiting,"second service must wait on a real PostgreSQL lock");release.countDown();first.get(15,java.util.concurrent.TimeUnit.SECONDS);
            try {second.get(15,java.util.concurrent.TimeUnit.SECONDS);}
            catch(java.util.concurrent.ExecutionException stale) {
                ApiException error=org.junit.jupiter.api.Assertions.assertInstanceOf(ApiException.class,stale.getCause());
                assertEquals(ErrorCode.CONFLICT,error.getCode());assertTrue(error.getMessage().contains("本次操作未生效"));
                // Only a complete source-drift rollback is retryable here; a
                // database deadlock, quantity error or authorization failure fails the test.
                loginAs(secondActor);secondCommand.run();
            }
        } finally {release.countDown();loginAs(w.superAdminUserId());}
    }

    private PrefixReportDraft createPrefixReportDraft(World w,UUID planId,UUID planItem,UUID orderItem,String qty) {
        loginAs(w.superAdminUserId()); StartedSegment segment=startedSegmentFor(w,planId,planItem,orderItem);
        var assigned=jdbc.queryForMap("SELECT workshop_department_id,responsible_employee_id FROM production_execution_segments WHERE id=?",segment.segmentId());
        UUID reporter=createUserWithPerms(w,"prefix-reporter-"+UUID.randomUUID().toString().substring(0,8),
                "production_execution:view","production_daily_report:create","production_daily_report:approve","production_daily_report:reverse");
        jdbc.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",assigned.get("workshop_department_id"),reporter);
        DailyReportSaveRequest request=new DailyReportSaveRequest(); request.setIdempotencyKey("prefix-report-"+UUID.randomUUID());
        request.setBillDate(LocalDate.of(2026,1,25)); request.setWarehouseId(w.warehouseId());
        request.setDepartmentId((UUID)assigned.get("workshop_department_id"));request.setWorkerId((UUID)assigned.get("responsible_employee_id"));
        request.setWorkerIds(List.of((UUID)assigned.get("responsible_employee_id")));
        DailyReportItemLine line=new DailyReportItemLine();line.setGoodsId(w.goodsA());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));line.setPlanItemId(planItem);line.setSalesOrderItemId(orderItem);
        line.setExecutionSegmentId(segment.segmentId());line.setExecutionSegmentSalesAllocationId(segment.salesAllocationId());request.setItems(List.of(line));
        loginAs(reporter);
        try {return new PrefixReportDraft(reportService.create(request).getId(),reporter);}
        finally {loginAs(w.superAdminUserId());}
    }

    private record PrefixReportDraft(UUID id,UUID reporter) {}

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
        receiveOpeningInputsForA(w,"10");
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        issueReadyPlanAndMaterials(w,planId);
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
        receiveOpeningInputsForA(w,"10");
        UUID planId = approvedPlan(w, w.goodsA(), "10", "10");
        issueReadyPlanAndMaterials(w,planId);
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
        receiveOpeningInputsForA(w,"10");
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
        for (var draw : confirmed.drawDocuments()) {
            stockDocService.approveAndIssue(draw.requestId(),drawIssueRequest(draw.requestId(),
                    "exact-part-real-inputs-"+draw.requestId(),null,BigDecimal.ZERO));
        }
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
                WHERE event_type = 'SALES_SHIPMENT_PENDING_FINANCE_AUDIT'
                  AND aggregate_id = ?
                """, firstShipment) >= 1,
                "部分发货草稿先形成财务审核 outbox 任务");
        assertEquals(0, count("""
                SELECT count(*)
                FROM business_outbox
                WHERE event_type = 'SALES_SHIPMENT_PENDING_PICK'
                  AND aggregate_id = ?
                """, firstShipment),
                "财务放行前不得通知仓库待拣货");
        shipThroughWarehouse(firstShipment);
        assertTrue(count("""
                SELECT count(*)
                FROM business_outbox
                WHERE event_type = 'SALES_SHIPMENT_PENDING_PICK'
                  AND aggregate_id = ?
                """, firstShipment) >= 1,
                "财务放行后才形成仓库待拣货 outbox 任务");
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
        assertEquals("IN_PROGRESS", strFor(
                "select status from production_execution_segments where id=?",segmentId),
                "全量成品实收不代替真实材料清账，仍未确认的实耗不能凭BOM自动补齐");
        loginAs(w.superAdminUserId());
        assertThrows(ApiException.class,() -> materialSettlementService.close(planId),
                "领用原料未结清前不能关闭生产计划");
        var consumption = new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        consumption.setIdempotencyKey("exact-part-consumed-"+planId);
        consumption.setReason("车间实际确认十件A耗用B20和E10，无退料、损耗或剩余在制");
        List<com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line> consumedLines = new ArrayList<>();
        for (var input : Map.of(w.goodsB(),new BigDecimal("20"),w.goodsE(),new BigDecimal("10")).entrySet()) {
            var consumed = new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
            consumed.setDemandId(jdbc.queryForObject("""
                    select id from production_material_demands
                    where execution_segment_id=? and goods_id=? and is_deleted=false
                    """,UUID.class,segmentId,input.getKey()));
            consumed.setSettlementType("CONSUMED");
            consumed.setQtyBase(input.getValue());
            consumedLines.add(consumed);
        }
        consumption.setLines(consumedLines);
        assertTrue(materialSettlementService.post(planId,consumption,w.superAdminUserId())
                .stream().allMatch(com.uten.imp.features.stock.allocation.dto.ProductionMaterialClearanceRow::canClose));
        materialSettlementService.close(planId);
        assertEquals("COMPLETED", strFor("""
                SELECT status
                FROM production_execution_segments
                WHERE id = ?
                """, segmentId),
                "累计入库达到执行段计划10且实际材料已结清后才完成");
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId(); // reserved=10, stock=10
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
        Production finished = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10");
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
        LocalDate shippedBusinessDate = jdbc.queryForObject(
                "select (handed_over_at at time zone 'Asia/Shanghai')::date "
                        + "from sales_shipments where id = ?",
                LocalDate.class, shipmentId);
        assertEquals(shippedBusinessDate, jdbc.queryForObject(
                "select bill_date from ar_ap_ledger where source_doc_id = ?",
                LocalDate.class, shipmentId),
                "AR 立账/账龄起点 = 仓库 SHIPPED 上海业务日，不使用草稿单据日");
        assertEquals(shippedBusinessDate.plusDays(30), jdbc.queryForObject(
                "select due_date from ar_ap_ledger where source_doc_id = ?",
                LocalDate.class, shipmentId),
                "AR 到期日 = 仓库 SHIPPED 业务日 + 客户正数账期，不使用草稿单据日或最后操作日");
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
                "600", "560", "25", "15", BigDecimal.ONE, BusinessTime.today())).getId();
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
                "400", "400", "0", "0", BigDecimal.ONE, BusinessTime.today())).getId();
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
                w, arId, accountId, null, "100", "100", "0", "0",
                BigDecimal.ONE, BusinessTime.today());
        crossReq.getItems().get(0).setCurrencyId(usdId);
        ApiException cross = assertThrows(ApiException.class, () -> receiptService.create(crossReq));
        assertTrue(cross.getMessage().contains("核销原币必须与应收币种一致"),
                "核销原币与应收币种不一致在保存时即被拒: " + cross.getMessage());

        // (b) over-collect: cash 1100 > 未收 1000 → rejected.
        loginAs(w.superAdminUserId());
        int beforeDrafts=count("SELECT count(*) FROM finance_receipts WHERE client_id=?",w.clientId());
        ApiException over = assertThrows(ApiException.class, () -> receiptService.create(
                receiptRequest(w, arId, accountId, null,
                        "1100", "1100", "0", "0", BigDecimal.ONE, BusinessTime.today())));
        assertTrue(over.getMessage().contains("应收"), "超收在保存时即被拒: " + over.getMessage());
        assertEquals(beforeDrafts,count("SELECT count(*) FROM finance_receipts WHERE client_id=?",w.clientId()),
                "超收不得留下部分草稿");

        // (c) V1 line write-off is rejected before persistence; fees use header snapshots.
        loginAs(w.superAdminUserId());
        var mixed=receiptRequest(w,arId,accountId,null,
                "100","100","0","0",BigDecimal.ONE,BusinessTime.today());
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
        // 夹具使用专属期间 2026-03（全类只有本用例与 amounts_gl 生成凭证，后者固定走
        // 当月/单据期间，永不触达 2026-03）：已审 V0 收款被触发器宣告不可变
        // （fn_guard_finance_receipt_money_fact / V407 DELETE 守卫），无法清理，
        // 期间隔离让残留只封锁本专属月，不污染共享库其他用例。
        UUID receiptId=UUID.randomUUID();
        String billNo=docNumberService.nextNumber(
                com.uten.imp.common.docnumber.DocNumberPrefix.FIN_RECEIPT);
        jdbc.update("""
                insert into finance_receipts(
                  id,bill_no,bill_date,receipt_kind,client_id,currency_id,
                  exchange_rate,amount_original,amount_local,bank_fee,other_fee,
                  status,settlement_authority_version,is_deleted)
                values (?,?,?,'CUSTOMER_PREPAYMENT',?,?,1,100,100,0,0,1,0,false)
                """,receiptId,billNo,LocalDate.of(2026,3,15),w.clientId(),w.currencyId());

        assertEquals("MISSING",strFor("""
                select reconciliation_state
                from v_receipt_v0_gl_reconciliation where receipt_id=?
                """,receiptId),"历史 V0 已审收款缺凭证必须进入异常队列");
        // 同月已有其它链路测试立账（共享库），先配齐过账角色科目才能到达 V0 闸
        seedChartOfAccounts();
        ApiException blocked=assertThrows(ApiException.class,()->
                glPostingService.generate("2026-03"));
        assertTrue(blocked.getMessage().contains("历史 V0 已审收款"),blocked.getMessage());
        assertTrue(blocked.getMessage().contains("禁止按当前科目自动补账"),blocked.getMessage());
        // 不清理：残留只封锁 2026-03 这一专属期间（见方法头注释）。
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
                "600", "600", "0", "0", new BigDecimal("7.2"), BusinessTime.today())).getId();
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
            String cash, String actualAccountAmount, String bankFee, String otherFee,
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
        req.setAccountAmount(new BigDecimal(actualAccountAmount));
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
    void salesCashCycle_partialShipAdvanceSettlementReturnQualityAndOrderedReversalsReconcile() {
        World w=seedWorld("cash-cycle");
        // This funds test reuses the explicit opening-input compatibility production
        // fixture. The new material-analysis manufacturing route has its own scenarios.
        UUID orderItem=produceFinishedFromOpeningInputs(w,w.goodsA(),"20","20").orderItemId();
        UUID order=orderIdOfItem(orderItem);
        loginAs(w.superAdminUserId());
        seedChartOfAccounts();
        String suffix=UUID.randomUUID().toString().substring(0,8);
        UUID accountStyle=UUID.randomUUID(),account=UUID.randomUUID();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'ACCOUNT',0,'使用')",
                accountStyle,"CC-STYLE-"+suffix,"资金链验收账户科目");
        jdbc.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id) VALUES(?,?,?,'BANK',?,'使用',?)",
                account,"CC-BANK-"+suffix,"资金链验收账户",w.currencyId(),accountStyle);
        UUID reviewer=createUserWithPerms(w,"cash-cycle-reviewer","finance_receipt:view","finance_receipt:approve",
                "finance_receipt:reverse","customer_prepayment:view","finance:view:all");
        grantDataScope(reviewer,"finance",w.employeeId());

        var advance=receiptRequest(w,null,account,null,"400","400","0","0",BigDecimal.ONE,BusinessTime.today());
        advance.setReceiptKind("CUSTOMER_PREPAYMENT");
        advance.setSalesOrderId(order);
        advance.setCurrencyId(w.currencyId());
        advance.setExchangeRate(BigDecimal.ONE);
        advance.setAmountOriginal(new BigDecimal("400"));
        advance.setAccountAmount(new BigDecimal("400"));
        advance.setItems(List.of());
        UUID advanceReceipt=receiptService.create(advance).getId();
        loginAs(reviewer);
        receiptService.approve(advanceReceipt);
        assertNonemptySourceVoucher("RECEIPT",advanceReceipt);
        UUID advanceLedger=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='DIRECT_RECEIPT' AND source_doc_id=?",
                UUID.class,advanceReceipt);
        assertCashCycleState(w,order,account,"20","0","400","1600");

        loginAs(w.superAdminUserId());
        var firstShipmentRequest=shipmentRequest(w,orderItem,w.goodsA(),"10");
        firstShipmentRequest.setBillDate(BusinessTime.today());
        UUID firstShipment=shipmentService.create(firstShipmentRequest).getId();
        shipThroughWarehouse(firstShipment);
        UUID firstAr=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,firstShipment);
        assertCashCycleState(w,order,account,"10","1000","400","1600");
        var applyFirst=new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ApplyRequest(
                "cash-cycle-advance-a-"+order,advanceLedger,List.of(new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.Target(
                firstAr,order,new BigDecimal("300"))),"先抵第一批发货");
        var offsetFirst=customerAdvanceOffsets.apply(applyFirst);
        assertEquals(offsetFirst.batchId(),customerAdvanceOffsets.apply(applyFirst).batchId());
        assertCashCycleState(w,order,account,"10","700","400","1600");
        assertEquals("100.0000",salesMoneyQuery.salesOrderSummary(order).prepaymentAvailableOriginal());

        UUID firstReceipt=receiptService.create(receiptRequest(w,firstAr,account,null,"200","200","0","0",
                BigDecimal.ONE,BusinessTime.today())).getId();
        loginAs(reviewer);
        receiptService.approve(firstReceipt);
        assertThrows(ApiException.class,()->receiptService.approve(firstReceipt));
        assertNonemptySourceVoucher("RECEIPT",firstReceipt);
        assertCashCycleState(w,order,account,"10","500","600","1400");

        loginAs(w.superAdminUserId());
        var secondShipmentRequest=shipmentRequest(w,orderItem,w.goodsA(),"10");
        secondShipmentRequest.setBillDate(BusinessTime.today());
        UUID secondShipment=shipmentService.create(secondShipmentRequest).getId();
        shipThroughWarehouse(secondShipment);
        UUID secondAr=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,secondShipment);
        var offsetSecond=customerAdvanceOffsets.apply(new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ApplyRequest(
                "cash-cycle-advance-b-"+order,advanceLedger,List.of(new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.Target(
                secondAr,order,new BigDecimal("100"))),"抵第二批发货"));
        assertCashCycleState(w,order,account,"0","1400","600","1400");
        assertEquals("0.0000",salesMoneyQuery.salesOrderSummary(order).prepaymentAvailableOriginal());

        var finalReceiptRequest=receiptRequest(w,firstAr,account,null,"500","1400","0","0",BigDecimal.ONE,BusinessTime.today());
        var lastLine=new com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput();
        lastLine.setAppliedLedgerId(secondAr); lastLine.setCurrencyId(w.currencyId());
        lastLine.setExchangeRate(BigDecimal.ONE); lastLine.setAmountOriginal(new BigDecimal("900"));
        lastLine.setWriteOffAmount(BigDecimal.ZERO);
        finalReceiptRequest.setItems(List.of(finalReceiptRequest.getItems().getFirst(),lastLine));
        UUID finalReceipt=receiptService.create(finalReceiptRequest).getId();
        loginAs(reviewer);
        receiptService.approve(finalReceipt);
        assertNonemptySourceVoucher("RECEIPT",finalReceipt);
        assertCashCycleState(w,order,account,"0","0","2000","0");

        loginAs(w.superAdminUserId());
        String period=java.time.YearMonth.from(BusinessTime.today()).toString();
        glPostingService.generate(period);
        assertNonemptySourceVoucher("AR_POST",firstShipment);
        assertNonemptySourceVoucher("AR_POST",secondShipment);
        assertNonemptySourceVoucher("CUSTOMER_PREPAYMENT_OFFSET",offsetFirst.batchId());
        assertNonemptySourceVoucher("CUSTOMER_PREPAYMENT_OFFSET",offsetSecond.batchId());
        // Cost is a separate acceptance gate. Nonempty balanced cash vouchers do
        // not prove that manufacturing/stock valuation or COGS is correct.
        BigDecimal openingMaterialValue=bigDecimalFor("""
                SELECT COALESCE(SUM(movement.amount_local),0) FROM stock_movements movement
                JOIN stock_documents document ON document.id=movement.source_doc_id
                WHERE movement.goods_id IN(?,?) AND movement.warehouse_id=?
                  AND movement.source_doc_type='STOCK_DOC' AND document.doc_type='OTHER_IN'
                """,w.goodsB(),w.goodsE(),w.warehouseId());
        assertEquals(0,openingMaterialValue.compareTo(new BigDecimal("600")),
                "成本反例必须保留实际材料来源600，查得="+openingMaterialValue);
        assertDecimal("2000","SELECT SUM(amount_original) FROM ar_ap_ledger WHERE source_doc_id IN(?,?) AND source_doc_type='SALES_SHIPMENT'",firstShipment,secondShipment);
        System.out.println("SALES_FUNDS_COST_EVIDENCE opening_material_value="+openingMaterialValue
                +" shipped_commercial_value=2000 expected_material_cogs=600 actual_finished_stock_value="
                +bigDecimalFor("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",w.goodsA(),w.warehouseId())
                +" actual_material_stock_value="+bigDecimalFor("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id IN(?,?) AND warehouse_id=?",w.goodsB(),w.goodsE(),w.warehouseId()));

        UUID secondShipmentItem=jdbc.queryForObject("SELECT id FROM sales_shipment_items WHERE shipment_id=?",UUID.class,secondShipment);
        var returned=new com.uten.imp.features.sales.ret.dto.ReturnSaveRequest();
        returned.setBillDate(BusinessTime.today()); returned.setClientId(w.clientId());
        returned.setWarehouseId(w.warehouseId()); returned.setCurrencyId(w.currencyId());
        returned.setExchangeRate(BigDecimal.ONE); returned.setTaxRate(BigDecimal.ZERO);
        returned.setSettlementMethodId(shipmentService.detail(secondShipment).getSettlementMethodId());
        var returnedLine=new com.uten.imp.features.sales.ret.dto.ReturnItemLine();
        returnedLine.setOutItemId(secondShipmentItem); returnedLine.setOrderItemId(orderItem);
        returnedLine.setGoodsId(w.goodsA()); returnedLine.setUnitId(w.unitId()); returnedLine.setUnitRate(BigDecimal.ONE);
        returnedLine.setQty(new BigDecimal("5")); returnedLine.setPrice(new BigDecimal("999"));
        returnedLine.setAmountOriginal(new BigDecimal("99999")); returnedLine.setAmountLocal(new BigDecimal("99999"));
        returned.setItems(List.of(returnedLine));
        UUID returnId=customerReturnService.create(returned).getId();
        var approvedReturn=customerReturnService.approve(returnId);
        UUID returnItem=approvedReturn.getItems().getFirst().getId();
        assertEquals(0,approvedReturn.getTotalOriginal().compareTo(new BigDecimal("500")));
        assertCashCycleState(w,order,account,"0","0","2000","0");
        assertEquals("500.0000",salesMoneyQuery.salesOrderSummary(order).customerPendingBalanceOriginal());
        assertEquals("500.0000",salesMoneyQuery.salesOrderSummary(order).unrecognizedOrderOriginal());
        customerReturnService.setDisposition(returnId,new com.uten.imp.features.sales.ret.dto.CustomerDispositionRequest(
                "REFUND_CLOSED","不再补发，资金留待财务处置","cash-cycle-refund-choice-"+returnId));
        assertEquals("0.0000",salesMoneyQuery.salesOrderSummary(order).unrecognizedOrderOriginal());
        assertThrows(ApiException.class,()->customerReturnService.reverse(returnId));
        assertEquals(0,bigDecimalFor("SELECT balance_current FROM accounts WHERE id=?",account).compareTo(new BigDecimal("2000")),
                "选择不再补发没有执行现金退款");

        customerReturnQuality.dispose(returnId,returnItem,new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest(
                "GOOD_RELEASE",new BigDecimal("2"),"良品实收","cash-cycle-good-release-"+returnId));
        customerReturnQuality.dispose(returnId,returnItem,new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest(
                "SCRAP",BigDecimal.ONE,"报废确认","cash-cycle-scrap-"+returnId));
        customerReturnQuality.dispose(returnId,returnItem,new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest(
                "REWORK",new BigDecimal("2"),"返工待处理","cash-cycle-rework-"+returnId));
        var correction=new com.uten.imp.features.sales.ret.dto.ReturnQualityCorrectionRequest(
                "GOOD_RELEASE",BigDecimal.ONE,"更正一件良品判断","cash-cycle-correction-"+returnId);
        customerReturnQuality.correct(returnId,returnItem,correction);
        customerReturnQuality.correct(returnId,returnItem,correction);
        assertCashCycleState(w,order,account,"1","0","2000","0");
        assertEquals(0,bigDecimalFor("SELECT received_base_qty-released_base_qty-scrapped_base_qty-rework_base_qty FROM sales_return_quality_items WHERE return_id=?",
                returnId).compareTo(BigDecimal.ONE));
        glPostingService.generate(period);
        assertNonemptySourceVoucher("AR_POST",returnId);

        assertThrows(ApiException.class,()->receiptService.reverse(advanceReceipt));
        assertThrows(ApiException.class,()->customerAdvanceOffsets.reverse(offsetFirst.batchId(),
                new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ReverseRequest(offsetFirst.rowVersion(),"逆序请求应拒绝")));
        receiptService.reverse(finalReceipt);
        customerAdvanceOffsets.reverse(offsetSecond.batchId(),new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ReverseRequest(
                offsetSecond.rowVersion(),"先反后一次转销"));
        receiptService.reverse(firstReceipt);
        customerAdvanceOffsets.reverse(offsetFirst.batchId(),new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ReverseRequest(
                offsetFirst.rowVersion(),"再反前一次转销"));
        receiptService.reverse(advanceReceipt);
        assertCashCycleState(w,order,account,"1","2000","0","1500");
        glPostingService.generate(period);
        for (UUID receiptId:List.of(advanceReceipt,firstReceipt,finalReceipt)) assertNonemptySourceVoucher("RECEIPT_REV",receiptId);
        assertEquals(0,bigDecimalFor("SELECT amount_original FROM finance_receipts WHERE id=?",advanceReceipt).compareTo(new BigDecimal("400")),
                "红冲保留原预收金额快照");
    }

    @Test
    void salesCashCycle_foreignAdvanceThenReceiptAndReversalKeepSeparateBookAndBankAmounts() {
        World w=seedWorld("cash-cycle-fx");
        jdbc.update("UPDATE currencies SET code='USD-cycle-fx',name='美元资金链',exchange_rate=7 WHERE id=?",w.currencyId());
        UUID orderItem=produceFinishedFromOpeningInputs(w,w.goodsA(),"20","20").orderItemId();
        UUID order=orderIdOfItem(orderItem);
        loginAs(w.superAdminUserId());
        seedChartOfAccounts();
        UUID account=UUID.randomUUID(),style=UUID.randomUUID();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,'CC-FX-STYLE','外币资金链账户科目','ACCOUNT',0,'使用')",style);
        jdbc.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id) VALUES(?,'CC-FX-BANK','外币资金链账户','BANK',?,'使用',?)",account,w.currencyId(),style);
        UUID reviewer=createUserWithPerms(w,"cash-cycle-fx-reviewer","finance_receipt:view","finance_receipt:approve",
                "finance_receipt:reverse","customer_prepayment:view","finance:view:all");
        grantDataScope(reviewer,"finance",w.employeeId());

        var advance=receiptRequest(w,null,account,null,"400","400","0","0",new BigDecimal("6.8"),BusinessTime.today());
        advance.setReceiptKind("CUSTOMER_PREPAYMENT"); advance.setSalesOrderId(order);
        advance.setCurrencyId(w.currencyId()); advance.setExchangeRate(new BigDecimal("6.8"));
        advance.setAmountOriginal(new BigDecimal("400")); advance.setAccountAmount(new BigDecimal("400")); advance.setItems(List.of());
        UUID advanceReceipt=receiptService.create(advance).getId();
        loginAs(reviewer); receiptService.approve(advanceReceipt);
        loginAs(w.superAdminUserId());
        var shipmentRequest=shipmentRequest(w,orderItem,w.goodsA(),"10");
        shipmentRequest.setBillDate(BusinessTime.today());
        UUID shipment=shipmentService.create(shipmentRequest).getId(); shipThroughWarehouse(shipment);
        UUID ledger=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,shipment);
        UUID advanceLedger=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='DIRECT_RECEIPT' AND source_doc_id=?",UUID.class,advanceReceipt);
        var offset=customerAdvanceOffsets.apply(new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ApplyRequest(
                "cash-cycle-fx-offset-"+order,advanceLedger,List.of(new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.Target(
                ledger,order,new BigDecimal("300"))),"预收汇率6.8，原应收汇率7"));
        assertDecimal("700","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("4900","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("2040","SELECT source_amount_local FROM customer_open_item_offsets WHERE offset_batch_id=?",offset.batchId());
        assertDecimal("2100","SELECT target_amount_local FROM customer_open_item_offsets WHERE offset_batch_id=?",offset.batchId());
        assertDecimal("-60","SELECT exchange_difference FROM customer_open_item_offsets WHERE offset_batch_id=?",offset.batchId());

        UUID receipt=receiptService.create(receiptRequest(w,ledger,account,null,"200","200","0","0",new BigDecimal("7.2"),BusinessTime.today())).getId();
        loginAs(reviewer); receiptService.approve(receipt);
        assertDecimal("500","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("3500","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("1400","SELECT applied_amount_local FROM finance_receipt_lines WHERE receipt_id=?",receipt);
        assertDecimal("1440","SELECT amount_local FROM finance_receipt_lines WHERE receipt_id=?",receipt);
        assertDecimal("40","SELECT exchange_diff FROM finance_receipt_lines WHERE receipt_id=?",receipt);
        assertDecimal("600","SELECT balance_current FROM accounts WHERE id=?",account);
        assertEquals("1400.0000",salesMoneyQuery.salesOrderSummary(order).plannedRemainingOriginal());
        assertNonemptySourceVoucher("RECEIPT",receipt);
        loginAs(w.superAdminUserId());
        // A later dispatch freezes its own finance rate; the earlier AR and
        // cash/advance slices keep their historical rates during every reversal.
        jdbc.update("UPDATE currencies SET exchange_rate=8 WHERE id=?",w.currencyId());
        var laterShipmentRequest=shipmentRequest(w,orderItem,w.goodsA(),"10");
        laterShipmentRequest.setBillDate(BusinessTime.today());
        UUID laterShipment=shipmentService.create(laterShipmentRequest).getId();
        shipThroughWarehouse(laterShipment);
        UUID laterLedger=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,laterShipment);
        assertDecimal("7000","SELECT amount_original_local FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("8000","SELECT amount_original_local FROM ar_ap_ledger WHERE id=?",laterLedger);
        assertEquals("11500.0000",salesMoneyQuery.salesOrderSummary(order).arOutstandingLocal());
        assertEquals("0.0000",salesMoneyQuery.salesOrderSummary(order).unrecognizedOrderOriginal());
        assertEquals("1400.0000",salesMoneyQuery.salesOrderSummary(order).plannedRemainingOriginal());
        glPostingService.generate(java.time.YearMonth.from(BusinessTime.today()).toString());
        assertNonemptySourceVoucher("CUSTOMER_PREPAYMENT_OFFSET",offset.batchId());
        assertNonemptySourceVoucher("AR_POST",shipment);
        assertNonemptySourceVoucher("AR_POST",laterShipment);
        receiptService.reverse(receipt);
        assertDecimal("700","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("4900","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("400","SELECT balance_current FROM accounts WHERE id=?",account);
        customerAdvanceOffsets.reverse(offset.batchId(),new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ReverseRequest(offset.rowVersion(),"按原双币份额反转"));
        assertDecimal("1000","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("7000","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",ledger);
        assertDecimal("-400","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",advanceLedger);
        assertDecimal("-2720","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",advanceLedger);
        receiptService.reverse(advanceReceipt);
        assertDecimal("0","SELECT balance_current FROM accounts WHERE id=?",account);
        assertDecimal("0","SELECT SUM(in_amount-out_amount) FROM finance_reconciliations WHERE account_id=?",account);
        assertDecimal("6.800000","SELECT exchange_rate FROM finance_receipts WHERE id=?",advanceReceipt);
        assertDecimal("7.200000","SELECT exchange_rate FROM finance_receipts WHERE id=?",receipt);
        assertDecimal("8000","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",laterLedger);
        assertEquals("2000.0000",salesMoneyQuery.salesOrderSummary(order).plannedRemainingOriginal());
        assertNonemptySourceVoucher("RECEIPT_REV",receipt);
        assertNonemptySourceVoucher("RECEIPT_REV",advanceReceipt);
    }

    private void assertDecimal(String expected,String sql,Object...parameters) {
        assertEquals(0,new BigDecimal(expected).compareTo(bigDecimalFor(sql,parameters)),sql);
    }

    private void assertCashCycleState(World world,UUID order,UUID account,String stock,String invoiceRemaining,String bank,String planned) {
        var summary=salesMoneyQuery.salesOrderSummary(order);
        assertTrue(summary.positionComplete(),summary.warnings().toString());
        assertEquals(0,new BigDecimal(stock).compareTo(stockBalance(world.warehouseId(),world.goodsA())));
        assertEquals(0,stockBalance(world.warehouseId(),world.goodsA()).compareTo(movementSum(world.warehouseId(),world.goodsA())));
        assertEquals(0,new BigDecimal(invoiceRemaining).compareTo(new BigDecimal(summary.arOutstandingOriginal())));
        assertEquals(0,new BigDecimal(bank).compareTo(bigDecimalFor("SELECT balance_current FROM accounts WHERE id=?",account)));
        assertEquals(0,new BigDecimal(bank).compareTo(bigDecimalFor("SELECT COALESCE(SUM(in_amount-out_amount),0) FROM finance_reconciliations WHERE account_id=?",account)));
        assertEquals(0,new BigDecimal(planned).compareTo(new BigDecimal(summary.plannedRemainingOriginal())));
    }

    private void assertNonemptySourceVoucher(String type,UUID sourceId) {
        assertEquals(1,count("SELECT COUNT(*) FROM gl_vouchers WHERE source_type=? AND source_doc_id=?",type,sourceId));
        assertTrue(count("SELECT COUNT(*) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_type=? AND voucher.source_doc_id=?",type,sourceId)>=2);
        assertEquals(0,bigDecimalFor("SELECT COALESCE(SUM(entry.direction*entry.amount),0) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_type=? AND voucher.source_doc_id=?",type,sourceId).signum());
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
        loginAs(w.superAdminUserId());
        UUID shipmentId = createShipment(w, orderItemId, w.goodsA(), "10");
        shipThroughWarehouse(shipmentId); // posts AR in the final SHIPPED business period
        String billNo = strFor("select bill_no from sales_shipments where id = ?", shipmentId);
        String recognitionPeriod = strFor(
                "select to_char(bill_date, 'YYYY-MM') from ar_ap_ledger where source_doc_id = ?",
                shipmentId);

        // GL's postAr/postAp CROSS JOIN payment_styles by path (/113/ /031/ /123/ /203/ /041/).
        // These chart-of-accounts nodes are loaded via data bootstrap, not Flyway — absent in the
        // test container — so seed them here as fixture data before generating GL.
        seedChartOfAccounts();
        glPostingService.generate(recognitionPeriod); // rebuild AUTO vouchers for the SHIPPED period

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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
        UUID orderId = orderIdOfItem(orderItemId);
        UUID salesOwner = createUserWithPerms(w, "sales-owner", "sales_shipment:create");
        UUID salesOther = createUserWithPerms(w, "sales-other", "sales_shipment:create");
        UUID financeUser = createUserWithPerms(w, "finance-s29", "finance_shipment_audit");
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

        // (4) finance releases the shipment; the warehouse cannot self-release.
        loginAs(financeUser);
        confirmShipmentFinance(shipmentId);

        // (5) warehouse CAN pick after finance release (has warehouse-work)
        loginAs(warehouseUser);
        shipmentService.transitionWarehouseWork(shipmentId, picking);

        // (6) role isolation: warehouse lacks create → create DENIED (@PreAuthorize fires first)
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
    // #30 (concurrency — idempotency) Replaying the same IQC disposition remains quality-only.
    // The first warehouse confirmation stocks +20; a retry (network redelivery / double-click)
    // with the identical warehouse key is absorbed as a no-op. This is the "会不会对一个事情重复"
    // guard: retries never inflate inventory.
    // ---------------------------------------------------------------------------------------------
    @Test
    void concurrency_idempotentIqcStockInDoesNotDoubleCountStock() {
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
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "首次 PASS 仅放行，库存仍为 0");
        // retry with the SAME quality idempotency key remains quality-only.
        inspectionService.dispose("PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "PASS", null, "合格", idemKey));
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(BigDecimal.ZERO),
                "同品质幂等键重放不产生库存");

        var stockInRequest = latestIqcStockInRequest(
                "PURCHASE", receiptId, inspectionItemId,
                new BigDecimal("20"),
                "stock-s30i-" + inspectionItemId,
                "S30-A01");
        loginAs(createIqcWarehouseConfirmer(w, "iqc-stock-s30"));
        var firstStockIn = iqcStockInService.confirm(
                "PURCHASE", receiptId, stockInRequest);
        var replayedStockIn = iqcStockInService.confirm(
                "PURCHASE", receiptId, stockInRequest);
        assertFalse(firstStockIn.replayed());
        assertTrue(replayedStockIn.replayed());
        assertEquals(firstStockIn.batchId(), replayedStockIn.batchId());
        assertEquals(0, stockBalance(w.warehouseId(), h).compareTo(new BigDecimal("20")),
                "同仓库入库幂等键重放不翻倍(仍 20，非 40)");

        // V451 库位学习：首次确认落一行 IQC 来源偏好；幂等重放不重复学习/计数；
        // 货品主档 stock_place 回写本次库位（货架目视化/即时库存同步的口径）。
        Map<String, Object> learned = jdbc.queryForMap("""
                select place, source_kind, selection_count, version
                from warehouse_goods_place_preferences
                where warehouse_id = ? and goods_id = ? and color_id is null
                """, w.warehouseId(), h);
        assertEquals("S30-A01", learned.get("place"));
        assertEquals("IQC_STOCK_IN", learned.get("source_kind"));
        assertEquals(1L, ((Number) learned.get("selection_count")).longValue());
        assertEquals("S30-A01", jdbc.queryForObject(
                "select stock_place from goods where id = ?", String.class, h));
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
                        .compareTo(BigDecimal.ZERO),
                "非最终 IQC PASS 只放行，真实库存仍为 0");
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(BigDecimal.ZERO),
                "仓库确认前不得提高可完工量");
        assertEquals(0, count("""
                select count(*) from business_outbox
                where event_type = 'PRODUCTION_MATERIAL_ANALYSIS_READY'
                  and aggregate_id = ?
                """, analysisId),
                "品质 PASS 不得提前发布物料齐套事件");

        UUID warehouseConfirmer = createIqcWarehouseConfirmer(
                w, "iqc-stock-analysis-wakeup");
        loginAs(warehouseConfirmer);
        iqcStockInService.confirm(
                "PURCHASE", receiptId,
                latestIqcStockInRequest(
                        "PURCHASE", receiptId, inspectionItemId,
                        new BigDecimal("10"),
                        "stock-analysis-partial-" + receiptId,
                        "AN-A01"));
        loginAs(w.superAdminUserId());
        assertEquals(0, stockBalance(w.warehouseId(), material)
                        .compareTo(new BigDecimal("10")),
                "首批仓库确认后真实库存增加 10");
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(new BigDecimal("5")),
                "首批仓库确认后可完工量由 0 增至 5");
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
                "首批仓库入库用 stock-in item lineage 产生一条 durable ready 事件");

        loginAs(w.superAdminUserId());
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
                        .compareTo(new BigDecimal("10")),
                "最终 PASS 后未确认切片仍不进入库存");
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(new BigDecimal("5")),
                "最终切片仓库确认前可完工量保持 5");
        assertEquals(1, count("""
                select count(*) from business_outbox
                where event_type = 'PRODUCTION_MATERIAL_ANALYSIS_READY'
                  and aggregate_id = ?
                """, analysisId),
                "品质整单结案不额外发布齐套事件");

        loginAs(warehouseConfirmer);
        iqcStockInService.confirm(
                "PURCHASE", receiptId,
                latestIqcStockInRequest(
                        "PURCHASE", receiptId, inspectionItemId,
                        new BigDecimal("10"),
                        "stock-analysis-final-" + receiptId,
                        "AN-A02"));
        loginAs(w.superAdminUserId());
        assertEquals(0, stockBalance(w.warehouseId(), material)
                        .compareTo(new BigDecimal("20")),
                "最终切片仓库确认后真实库存累计为 20");
        assertEquals(0, analysisService.detail(analysisId).products().getFirst()
                        .readyFinishQty().compareTo(new BigDecimal("10")),
                "最终仓库确认把可完工量刷新至 10");
        assertEquals(1, count("""
                select count(*) from business_outbox
                where event_type = 'PRODUCTION_MATERIAL_ANALYSIS_READY'
                  and aggregate_id = ?
                  and payload->>'sourceDocumentId' = ?
                  and payload->>'sourceEventId' is not null
                  and payload->>'readyFinishDelta' = '5'
                  and payload->>'readyFinishQty' = '10'
                """, analysisId, receiptId.toString()),
                "最终仓库入库切片使用 stock-in item 幂等 lineage");

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
    // V466 补货单通道收口：部分不合格 + 登记实物退回后，原订单是唯一补货通道——
    // 供给行动复活（不再邀请重新下单）、预计到货按合格净量重开等待补货、
    // 追加通知因在途覆盖缺口而不再生成新申请；退回反向后自愈回取消态并恢复邀请。
    // ---------------------------------------------------------------------------------------------
    @Test
    void partiallyRejectedReturnKeepsOriginalOrderAsSingleReplacementChannel() {
        runPartialIqcReturn(false);
    }

    @Test
    void procurementReceiptMinimum_replacementIsCountedOnceAfterProvenIqcReturn() {
        runPartialIqcReturn(true);
    }

    @Test
    void procurementReplacement_afterConfirmedCreditReacquiresOnlyOriginalNetPayable() {
        runPartialIqcReturn(true,true);
    }

    @Test
    void procurementActualCredit_preservesActualDocumentAcrossNonFiniteFundingParts(){
        IqcActualCreditFixture fixture=returnedIqcCreditFixture("actual-credit-nonfinite",true);
        World w=fixture.world();
        UUID caseId=fixture.caseId();
        long version=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,caseId);
        var allocation=new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ActualCreditAllocation(
                caseId,version,new BigDecimal("3"),BigDecimal.ONE);
        var request=reviewedActualCredit(caseId,fixture.sourceApId(),List.of(allocation),"1");
        rejectionService.confirmCredit(caseId,request);
        assertSupplierApAmounts(w,new BigDecimal("999"));
        assertEquals(1,count("select count(*) from procurement_iqc_credit_documents where id=? and amount_original=1 and amount_local=1",request.commandId()));
        assertEquals(2,count("select count(*) from procurement_iqc_credit_slices where credit_document_id=? and amount_original is null",request.commandId()),
                "Actual one-unit credit spans exact 1/3 and 2/3 funding ratios; neither is a rounded currency fact");
        assertEquals(0,bigDecimalFor("select sum(base_qty) from procurement_iqc_credit_slices where credit_document_id=?",request.commandId()).compareTo(new BigDecimal("3")));
        long afterVersion=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,caseId);
        rejectionService.confirmCredit(caseId,request);
        assertEquals(afterVersion,jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,caseId));
        assertEquals(1,count("select count(*) from ar_ap_ledger where source_doc_id=? and status=1",request.commandId()));
        var changed=new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest(
                request.expectedVersion(),request.commandId(),request.creditReference(),request.creditDate(),request.reason(),
                request.baseQty(),new BigDecimal("2"),request.sourceApLedgerId(),request.allocations(),request.expectedBookAllocationHash());
        assertThrows(ApiException.class,()->rejectionService.confirmCredit(caseId,changed));
        rejectionService.reverseCredit(caseId,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ReverseRequest(
                afterVersion,UUID.randomUUID(),"实际贷项撤回，保留全部原应付和退回来源",request.commandId()));
        assertSupplierApAmounts(w,new BigDecimal("1000"));
        assertEquals(0,new BigDecimal(rejectionService.detail(caseId).resolution().creditableBaseQty()).compareTo(new BigDecimal("20")));
    }

    @Test
    void procurementActualCredit_oneDocumentClosesTwoReturnedGenerationsAndReversesTogether(){
        IqcActualCreditFixture fixture=returnedIqcCreditFixture("actual-credit-generations",false);
        World w=fixture.world();
        UUID replacement=receiveIntoQuarantine(w,fixture.materialId(),fixture.orderItemId(),"2","RETURN_REPLACEMENT");
        UUID inspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_id=? and receipt_type='PURCHASE'",UUID.class,replacement);
        inspectionService.dispose("PURCHASE",replacement,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "FAIL",null,"本代免费补回再次不合格","fail-free-again-"+replacement));
        UUID child=awaitIqcRejection("PURCHASE",replacement);
        long childVersion=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,child);
        final long beforeReturnVersion=childVersion;
        assertThrows(ApiException.class,()->rejectionService.previewCredit(child,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest(
                beforeReturnVersion,UUID.randomUUID(),"NOT-RETURNED",BusinessTime.today(),"未实退不得贷项",new BigDecimal("2"),new BigDecimal("100"),fixture.sourceApId(),
                List.of(new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ActualCreditAllocation(child,beforeReturnVersion,new BigDecimal("2"),new BigDecimal("100"))))));
        rejectionService.recordReturn(child,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest(
                childVersion,UUID.randomUUID(),"FREE-RETURN-"+child,BusinessTime.today(),"本代两件实物已退回供应商"));
        long originalVersion=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,fixture.caseId());
        childVersion=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,child);
        var request=reviewedActualCredit(fixture.caseId(),fixture.sourceApId(),List.of(
                new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ActualCreditAllocation(fixture.caseId(),originalVersion,new BigDecimal("18"),new BigDecimal("900")),
                new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ActualCreditAllocation(child,childVersion,new BigDecimal("2"),new BigDecimal("100"))),"1000");
        rejectionService.confirmCredit(fixture.caseId(),request);
        assertSupplierApAmounts(w,BigDecimal.ZERO);
        assertEquals(1,count("select count(*) from procurement_iqc_credit_documents where id=?",request.commandId()));
        assertEquals(2,count("select count(*) from procurement_iqc_credit_case_allocations where credit_document_id=?",request.commandId()));
        assertEquals(0,count("select count(*) from ar_ap_ledger where source_doc_id=? and status=1",replacement),"Free replacement must never create a second or zero AP");
        assertEquals("SETTLED",rejectionService.detail(fixture.caseId()).resolution().resolutionState());
        assertEquals("SETTLED",rejectionService.detail(child).resolution().resolutionState());
        long version=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,child);
        rejectionService.reverseCredit(child,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ReverseRequest(
                version,UUID.randomUUID(),"撤回同一供应商贷项的全部明确分项",request.commandId()));
        assertSupplierApAmounts(w,new BigDecimal("1000"));
        assertEquals("RETURN_RECORDED",rejectionService.detail(fixture.caseId()).caseItem().status());
        assertEquals("RETURN_RECORDED",rejectionService.detail(child).caseItem().status());
        assertEquals(0,count("select count(*) from procurement_iqc_credit_slices where credit_document_id=? and fn_procurement_consideration_active('CREDIT',id)",request.commandId()));
    }

    private record IqcActualCreditFixture(World world,UUID materialId,UUID orderItemId,UUID caseId,UUID sourceApId){}

    private IqcActualCreditFixture returnedIqcCreditFixture(String tag,boolean splitFailure){
        World w=seedWorld(tag);UUID finished=UUID.randomUUID(),material=UUID.randomUUID();
        insertGoods(finished,"IQC-ACTUAL-FG-"+finished,"实际贷项成品","自制",w.unitId(),w.unitLegacy());
        insertGoods(material,"IQC-ACTUAL-RM-"+material,"实际贷项材料","采购",w.unitId(),w.unitLegacy());
        jdbc.update("update goods set default_supplier_id=? where id=?",w.supplierId(),material);
        insertBom(finished,material,"2");loginAs(w.superAdminUserId());
        AnalysisView analysis=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),tag+finished,
                List.of(new PreviewItem("OTHER",null,finished,null,w.unitId(),tag,"实际供应商单据贷项",BusinessTime.today(),new BigDecimal("10")))));
        UUID orderItem=approvePurchaseForAnalysis(w,analysis,material);
        UUID receipt=receiveIntoQuarantine(w,material,orderItem,"20","NORMAL");
        UUID inspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_id=? and receipt_type='PURCHASE'",UUID.class,receipt);
        if(splitFailure)inspectionService.dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "FAIL",BigDecimal.ONE,"第一件实检不合格",tag+"-fail-one"));
        inspectionService.dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "FAIL",null,"剩余本批实检不合格",tag+"-fail-rest"));
        UUID caseId=awaitIqcRejection("PURCHASE",receipt);
        long version=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,caseId);
        rejectionService.recordReturn(caseId,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest(
                version,UUID.randomUUID(),tag+"-returned",BusinessTime.today(),"整批不良实物已实际退回供应商"));
        UUID ap=jdbc.queryForObject("select id from ar_ap_ledger where source_doc_id=? and source_doc_type='PURCHASE_RECEIPT' and status=1",UUID.class,receipt);
        return new IqcActualCreditFixture(w,material,orderItem,caseId,ap);
    }

    private com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest reviewedActualCredit(
            UUID caseId,UUID ap,List<com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ActualCreditAllocation> allocations,String actual){
        long version=allocations.stream().filter(item->item.caseId().equals(caseId)).findFirst().orElseThrow().expectedVersion();
        UUID command=UUID.randomUUID();
        var draft=new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest(
                version,command,"ACTUAL-"+command,BusinessTime.today(),"按供应商实际贷项原始单据明确分项",null,new BigDecimal(actual),ap,allocations);
        var preview=rejectionService.previewCredit(caseId,draft);
        return new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest(
                version,command,draft.creditReference(),draft.creditDate(),draft.reason(),null,draft.actualAmountOriginal(),ap,allocations,preview.bookAllocationHash());
    }

    private void runPartialIqcReturn(boolean receiveReplacement) {
        runPartialIqcReturn(receiveReplacement,false);
    }

    @Test
    void procurementPartialFirstReceipt_replacementFirstKeepsOriginalPayableAndDemand() {
        runPartialFirstReceiptReplacement(false);
    }

    @Test
    void procurementPartialFirstReceipt_explicitNormalFirstKeepsReplacementEntitlement() {
        runPartialFirstReceiptReplacement(true);
    }

    private void runPartialFirstReceiptReplacement(boolean normalFirst) {
        World w=seedWorld(normalFirst?"iqc-partial-normal-first":"iqc-partial-replacement-first");
        UUID finished=UUID.randomUUID(),material=UUID.randomUUID();
        insertGoods(finished,"IQC-PARTIAL-FG-"+finished,"分批到货成品","自制",w.unitId(),w.unitLegacy());
        insertGoods(material,"IQC-PARTIAL-RM-"+material,"分批补回物料","采购",w.unitId(),w.unitLegacy());
        jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),material);
        insertBom(finished,material,"2");
        loginAs(w.superAdminUserId());
        AnalysisView analysis=analysisService.preview(new PreviewRequest(null,null,null,w.warehouseId(),
                "partial-replacement-"+finished,List.of(new PreviewItem("OTHER",null,finished,null,w.unitId(),
                "PARTIAL-"+finished,"分批正常到货与退回补回",BusinessTime.today(),new BigDecimal("10")))));
        UUID orderItemId=approvePurchaseForAnalysis(w,analysis,material);
        UUID first=receiveIntoQuarantine(w,material,orderItemId,"14","NORMAL");
        assertSupplierApAmounts(w,new BigDecimal("700"));
        UUID inspection=jdbc.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,first);
        inspectionService.dispose("PURCHASE",first,inspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        "FAIL",new BigDecimal("8"),"原14件中8件不合格","partial-first-fail-"+first));
        passAndStockPurchase(w,first,"6");
        UUID rejection=awaitIqcRejection("PURCHASE",first);
        long version=jdbc.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,rejection);
        rejectionService.recordReturn(rejection,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest(
                version,UUID.randomUUID(),"PARTIAL-RETURN-"+rejection,BusinessTime.today(),"本次不合格8件已实际退回"));
        assertSupplierApAmounts(w,new BigDecimal("700"));
        assertEquals(0,stockBalance(w.warehouseId(),material).compareTo(new BigDecimal("6")));

        ApiException missingIntent=assertThrows(ApiException.class,()->receiveIntoQuarantine(w,material,orderItemId,"8"));
        assertEquals(ErrorCode.CONFLICT,missingIntent.getCode());
        assertTrue(missingIntent.getMessage().contains("明确选择"));
        assertSupplierApAmounts(w,new BigDecimal("700"));
        UUID ambiguousDraft=jdbc.queryForObject("SELECT id FROM purchase_receipts WHERE supplier_id=? AND status=0 AND is_deleted=FALSE",UUID.class,w.supplierId());
        purchaseReceiptService.delete(ambiguousDraft);
        assertEquals(0,count("SELECT COUNT(*) FROM procurement_iqc_replacement_allocations WHERE case_id=?",rejection));

        if(normalFirst){
            UUID normal=receiveIntoQuarantine(w,material,orderItemId,"6","NORMAL");
            assertEquals(0,count("SELECT COUNT(*) FROM procurement_iqc_replacement_allocations WHERE replacement_receipt_id=?",normal));
            assertSupplierApAmounts(w,new BigDecimal("1000"));
            passAndStockPurchase(w,normal,"6");
        }
        UUID replacement=receiveIntoQuarantine(w,material,orderItemId,"8","RETURN_REPLACEMENT");
        assertEquals(0,bigDecimalFor("SELECT SUM(allocated_base_qty) FROM procurement_iqc_replacement_allocations WHERE case_id=? AND status='ACTIVE'",rejection)
                .compareTo(new BigDecimal("8")),"原单未收满时也必须把明确补回的8件全量追到原实退，不能只认超订量2件");
        assertEquals(0,count("SELECT COUNT(*) FROM ar_ap_ledger WHERE source_doc_type='PURCHASE_RECEIPT' AND source_doc_id=? AND status=1",replacement),
                "免费补回不产生第二笔或零金额应付");
        assertSupplierApAmounts(w,new BigDecimal(normalFirst?"1000":"700"));
        passAndStockPurchase(w,replacement,"8");
        if(!normalFirst){
            UUID normal=receiveIntoQuarantine(w,material,orderItemId,"6","NORMAL");
            passAndStockPurchase(w,normal,"6");
        }
        assertSupplierApAmounts(w,new BigDecimal("1000"));
        assertEquals(0,stockBalance(w.warehouseId(),material).compareTo(new BigDecimal("20")));
        assertEquals(0,receiptMinimum("PURCHASE",orderItemId,BigDecimal.ONE).compareTo(new BigDecimal("20")));
        assertEquals(0,bigDecimalFor("SELECT qty FROM purchase_order_items WHERE id=?",orderItemId).compareTo(new BigDecimal("20")));
        assertEquals(1,count("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY'",analysis.analysisId()),
                "正常到货和补回共用原需求、原订单，不建立第二份采购行动");
    }

    @Test
    void salesAmendmentPendingFinanceDoesNotRollBackAlreadyOrderedReceiptAndStockIn() {
        runSalesAmendmentReceipt(false);
    }

    @Test
    void purchasedRootArrivalWaitsForFinanceThenHandsOverTheSameQualifiedLotOnce() {
        runSalesAmendmentReceipt(true);
    }

    private void runSalesAmendmentReceipt(boolean purchasedRoot) {
        World w = seedWorld(purchasedRoot ? "root-finance-amendment" : "analysis-finance-amendment");
        UUID finished = UUID.randomUUID();
        UUID material = purchasedRoot ? finished : UUID.randomUUID();
        insertGoods(finished, "AMEND-FG-" + finished, "改单前已安排成品", purchasedRoot ? "采购" : "自制",
                w.unitId(), w.unitLegacy());
        if (!purchasedRoot) {
            insertGoods(material, "AMEND-RM-" + material, "改单前已订材料", "采购",
                    w.unitId(), w.unitLegacy());
            insertBom(finished, material, "2");
        }
        jdbc.update("update goods set default_supplier_id=? where id=?", w.supplierId(), material);
        UUID salesOrder = createApprovedOrder(w, finished, "10", "100");
        UUID salesItem = orderItemId(salesOrder);
        loginAs(w.superAdminUserId());
        AnalysisView initial = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "amend-preview-" + salesOrder,
                List.of(new PreviewItem("SALES_ORDER_ITEM", salesItem,
                        null, null, null, null, null, BusinessTime.today(), new BigDecimal("10")))));
        if (!purchasedRoot) {
            MaterialView root = initial.flatMaterials().stream()
                    .filter(row -> "ROOT_SUPPLY".equals(row.nodeRole())).findFirst().orElseThrow();
            initial = analysisService.saveRoutes(initial.analysisId(), new RouteRequest(
                    initial.version(), initial.fingerprint(), "amend-make-route-" + salesOrder,
                    List.of(new RouteDecision(root.materialLineId(), root.actionGroupKey(), "MAKE", "按已确认的原计划自制"))));
        }
        UUID purchaseItem = approvePurchaseForAnalysis(w, initial, material);

        loginAs(w.superAdminUserId());
        OrderChangeQtyRequest.Line line = new OrderChangeQtyRequest.Line();
        line.setOrderItemId(salesItem);
        line.setNewQty(new BigDecimal("12"));
        OrderChangeQtyRequest change = new OrderChangeQtyRequest();
        change.setItems(List.of(line));
        salesOrderService.changeQty(salesOrder, change);
        assertFalse(jdbc.queryForObject("select finance_confirmed from sales_orders where id=?",
                Boolean.class, salesOrder));

        String receiptQty = purchasedRoot ? "10" : "20";
        UUID receipt = receiveIntoQuarantine(w, material, purchaseItem, receiptQty, "NORMAL");
        passAndStockPurchase(w, receipt, receiptQty);
        assertEquals(0, stockBalance(w.warehouseId(), material).compareTo(new BigDecimal(receiptQty)));
        assertSupplierApAmounts(w, new BigDecimal(purchasedRoot ? "500" : "1000"));
        AnalysisView refreshed = analysisService.detail(initial.analysisId());
        UUID analysisItem = refreshed.products().getFirst().analysisLineId();
        assertTrue(refreshed.planningBlockedReasons().get(analysisItem).contains("等待财务确认"));
        assertFalse(refreshed.products().getFirst().canSchedule());
        assertEquals(0, refreshed.products().getFirst().requestedQty().compareTo(new BigDecimal("10")));
        if (purchasedRoot) {
            assertEquals(0, count("select count(*) from preplan_root_output_events where analysis_id=?",
                    refreshed.analysisId()));
        } else {
            assertEquals(0, refreshed.products().getFirst().readyFinishQty().compareTo(new BigDecimal("10")));
        }
        MaterialView pendingMaterial = refreshed.flatMaterials().stream()
                .filter(row -> material.equals(row.goodsId())).findFirst().orElseThrow();
        ApiException denied = assertThrows(ApiException.class, () -> analysisCommandService.issueWorkshopPlans(
                refreshed.analysisId(), new IssueWorkshopPlansRequest(refreshed.version(), refreshed.fingerprint(),
                        "amend-new-plan-" + salesOrder, w.warehouseId(), BusinessTime.today(), BusinessTime.today(),
                        false, List.of(new IssueWorkshopPlansRequest.IssuePlanLine(analysisItem, new BigDecimal("10"))))));
        assertEquals(ErrorCode.CONFLICT, denied.getCode());
        assertTrue(denied.getMessage().contains("等待财务确认"));
        assertEquals(1, count("select count(*) from preplan_supply_actions where analysis_id=? and route='BUY'",
                refreshed.analysisId()));
        assertEquals(0, stockBalance(w.warehouseId(), material).compareTo(new BigDecimal(receiptQty)));
        if (purchasedRoot) {
            assertEquals(0, pendingMaterial.shortageQty().compareTo(BigDecimal.ZERO),
                    "等待财审不能把已经合格入库的货重新显示成实物缺口");
            assertEquals(0, pendingMaterial.allocatedAvailableQty().compareTo(new BigDecimal("10")));
            var claim = reviewClaims.claim("SALES_ORDER_FINANCE_CONFIRM", salesOrder.toString());
            Long revision = jdbc.queryForObject("select finance_review_revision from sales_orders where id=?",
                    Long.class, salesOrder);
            financeConfirmService.confirm(salesOrder, new com.uten.imp.features.sales.order
                    .SalesOrderFinanceConfirmService.FinanceConfirmRequest(null, revision, claim.claimId()));
            AnalysisView approved = analysisService.detail(initial.analysisId());
            NotifyRequest retry = new NotifyRequest(approved.version(), approved.fingerprint(),
                    "amend-approved-handoff-" + salesOrder, "BUY",
                    List.of(pendingMaterial.materialLineId()), null, null);
            analysisCommandService.notifySupply(approved.analysisId(), retry);
            analysisCommandService.notifySupply(approved.analysisId(), retry);
            assertEquals(1, count("select count(*) from preplan_root_output_events where analysis_id=? and event_kind='FULFILL'",
                    approved.analysisId()));
            assertEquals(1, count("select count(*) from preplan_supply_actions where analysis_id=? and route='BUY'",
                    approved.analysisId()));
            assertEquals(0, bigDecimalFor("select reserved_qty from sales_order_items where id=?", salesItem)
                    .compareTo(new BigDecimal("10")));
            assertEquals(0, stockBalance(w.warehouseId(), material).compareTo(new BigDecimal(receiptQty)));
        }
    }

    private void passAndStockPurchase(World w,UUID receiptId,String qty){
        loginAs(w.superAdminUserId());
        UUID inspection=jdbc.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,receiptId);
        inspectionService.dispose("PURCHASE",receiptId,inspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"本批合格","partial-pass-"+receiptId));
        loginAs(createIqcWarehouseConfirmer(w,"partial-stock-"+receiptId));
        iqcStockInService.confirm("PURCHASE",receiptId,latestIqcStockInRequest("PURCHASE",receiptId,inspection,
                new BigDecimal(qty),"partial-stock-"+receiptId,"PARTIAL-REPLACEMENT"));
        loginAs(w.superAdminUserId());
    }

    private void runPartialIqcReturn(boolean receiveReplacement,boolean creditBeforeReplacement) {
        World w = seedWorld(creditBeforeReplacement?"iqc-replacement-credit":receiveReplacement?"iqc-replacement-bound":"iqc-partial-return-v466");
        UUID finished = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        insertGoods(finished, "V465-FG-"+finished, "部分退回补采成品", "自制",
                w.unitId(), w.unitLegacy());
        insertGoods(material, "V465-RM-"+material, "部分退回补采原料", "采购",
                w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id = ? where id = ?",
                w.supplierId(), material);
        insertBom(finished, material, "2");
        loginAs(w.superAdminUserId());

        AnalysisView initial = analysisService.preview(new PreviewRequest(
                null, null, null, w.warehouseId(),
                "iqc-partial-return-v466-" + finished,
                List.of(new PreviewItem(
                        "OTHER", null, finished, null, w.unitId(),
                        "V465-" + finished, "部分不合格退回后原订单继续补",
                        LocalDate.of(2026, 9, 3), new BigDecimal("10")))));
        UUID analysisId = initial.analysisId();
        UUID orderItemId = approvePurchaseForAnalysis(w, initial, material);
        UUID orderId = jdbc.queryForObject(
                "select order_id from purchase_order_items where id = ?",
                UUID.class, orderItemId);

        UUID receiptId = receiveIntoQuarantine(w, material, orderItemId, "20");
        assertSupplierApAmounts(w,new BigDecimal("1000"));
        UUID inspectionItemId = jdbc.queryForObject("""
                select id from procurement_inspection_items
                where receipt_type = 'PURCHASE' and receipt_id = ? and goods_id = ?
                """, UUID.class, receiptId, material);
        inspectionService.dispose(
                "PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto
                        .InspectionDispositionRequest(
                        "FAIL", new BigDecimal("8"), "部分不合格",
                        "v466-fail-" + receiptId));
        while (businessOutboxProcessor.processNext()) {
            // 投影 IQC 不合格退回/贷项案件，供登记实物退回。
        }
        inspectionService.dispose(
                "PURCHASE", receiptId, inspectionItemId,
                new com.uten.imp.features.warehouse.inbound.dto
                        .InspectionDispositionRequest(
                        "PASS", null, "其余合格",
                        "v466-pass-" + receiptId));
        loginAs(createIqcWarehouseConfirmer(w, "v466-stock-"+inspectionItemId));
        iqcStockInService.confirm(
                "PURCHASE", receiptId,
                latestIqcStockInRequest(
                        "PURCHASE", receiptId, inspectionItemId,
                        new BigDecimal("12"),
                        "v466-stock-" + inspectionItemId,
                        "V465-A01"));
        loginAs(w.superAdminUserId());

        assertEquals(0,receiptMinimum("PURCHASE",orderItemId,BigDecimal.ONE).compareTo(new BigDecimal("20")),
                "只判不合格但未记录实物退回，不能把8从实收下限扣掉");

        UUID actionId = jdbc.queryForObject("""
                select action.id
                from preplan_supply_actions action
                join preplan_supply_action_allocations allocation
                  on allocation.action_id = action.id
                join purchase_order_items poi
                  on poi.request_item_id = allocation.external_item_id
                where poi.id = ? and action.route = 'BUY'
                """, UUID.class, orderItemId);
        assertEquals("CANCELLED", strFor(
                "select status from preplan_supply_actions where id = ?", actionId),
                "整行结案且存在不合格时，旧行动先按既有口径取消");

        UUID caseId = awaitIqcRejection("PURCHASE",receiptId);
        long caseVersion = jdbc.queryForObject(
                "select row_version from procurement_iqc_rejection_cases where id = ?",
                Long.class, caseId);
        rejectionService.recordReturn(caseId, new com.uten.imp.features
                .finance.payables.ProcurementIqcRejectionContracts
                .RecordReturnRequest(
                caseVersion, UUID.randomUUID(), "V466-RET-001",
                BusinessTime.today(), "部分不合格实物退回供应商"));
        assertSupplierApAmounts(w,new BigDecimal("1000"));
        assertEquals(0,receiptMinimum("PURCHASE",orderItemId,BigDecimal.ONE).compareTo(new BigDecimal("12")),
                "有精确IQC实退凭据后仅扣一次8，普通returned_qty没有重复减少");

        assertEquals("CANCELLED", strFor(
                "select status from preplan_supply_actions where id = ?", actionId),
                "行动按 V250 追加式契约保持取消，不复活");

        Map<String, Object> progress = jdbc.queryForMap("""
                select demand_requested_qty - demand_qualified_qty as gap_qty,
                       demand_future_qty as future_qty
                from v_preplan_buy_action_slice_progress where action_id = ?
                """, actionId);
        assertEquals(0, ((BigDecimal) progress.get("gap_qty"))
                .compareTo(new BigDecimal("8")), "缺口 = 需求 20 − 合格入库 12");
        assertEquals(0, ((BigDecimal) progress.get("future_qty"))
                        .compareTo(new BigDecimal("8")),
                "原订单欠货（未收+已退+已退回不合格）计入在途");

        AnalysisView afterReturn = analysisService.detail(analysisId);
        MaterialView row = afterReturn.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(material) && m.actionable())
                .findFirst().orElseThrow();
        analysisCommandService.notifySupply(
                analysisId,
                new NotifyRequest(
                        afterReturn.version(), afterReturn.fingerprint(),
                        "v466-notify-after-return-" + analysisId,
                        "BUY", List.of(row.materialLineId()), List.of(), null));
        assertEquals("CANCELLED", strFor(
                "select status from preplan_supply_actions where id = ?", actionId),
                "通知后行动状态不变（仍取消）");
        assertEquals(1, count("""
                select count(*) from purchase_requests request
                where request.id in (
                    select action.external_document_id
                    from preplan_supply_actions action
                    where action.analysis_id = ? and action.route = 'BUY')
                """, analysisId), "已取消行动的原订单欠货是有效在途，不再重复生成采购申请");

        Map<String, Object> expectation = jdbc.queryForMap("""
                select item.ordered_qty, item.accepted_qty, expectation.status
                from inbound_expectation_items item
                join inbound_expectations expectation
                  on expectation.id = item.expectation_id
                where item.order_item_id = ?
                """, orderItemId);
        assertEquals(0, ((BigDecimal) expectation.get("ordered_qty"))
                .compareTo(new BigDecimal("20")));
        assertEquals(0, ((BigDecimal) expectation.get("accepted_qty"))
                        .compareTo(new BigDecimal("12")),
                "预计到货按合格净量重开，等待供应商在原订单上补 8");
        assertEquals("OPEN", expectation.get("status"));
        assertFalse(jdbc.queryForObject(
                "select is_closed from purchase_orders where id = ?",
                Boolean.class, orderId), "原订单等待补货，未结案");

        if(receiveReplacement) {
            if(creditBeforeReplacement) {
                long creditVersion=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,caseId);
                var creditDraft=new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest(
                        creditVersion,UUID.randomUUID(),"IQC-CREDIT-"+caseId,BusinessTime.today(),"供应商已确认原8件价款贷项400",
                        new BigDecimal("8"),new BigDecimal("400"),
                        jdbc.queryForObject("select source_ap_ledger_id from procurement_iqc_rejection_cases where id=?",UUID.class,caseId),
                        List.of(new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ActualCreditAllocation(
                                caseId,creditVersion,new BigDecimal("8"),new BigDecimal("400"))));
                var preview=rejectionService.previewCredit(caseId,creditDraft);
                rejectionService.confirmCredit(caseId,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest(
                        creditDraft.expectedVersion(),creditDraft.commandId(),creditDraft.creditReference(),creditDraft.creditDate(),
                        creditDraft.reason(),creditDraft.baseQty(),creditDraft.actualAmountOriginal(),creditDraft.sourceApLedgerId(),
                        creditDraft.allocations(),preview.bookAllocationHash()));
                assertSupplierApAmounts(w,new BigDecimal("600"));
            }
            UUID replacementReceipt=receiveIntoQuarantine(w,material,orderItemId,"8");
            assertEquals(0,receiptMinimum("PURCHASE",orderItemId,BigDecimal.ONE).compareTo(new BigDecimal("20")),
                    "毛收28−原IQC实退8=20，替补分配账不能再扣一次8");
            UUID replacementInspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='PURCHASE' and receipt_id=?",UUID.class,replacementReceipt);
            inspectionService.dispose("PURCHASE",replacementReceipt,replacementInspection,
                    new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"替补到货合格","replacement-pass-"+replacementReceipt));
            loginAs(createIqcWarehouseConfirmer(w,"replacement-stock-"+replacementReceipt));
            iqcStockInService.confirm("PURCHASE",replacementReceipt,latestIqcStockInRequest("PURCHASE",replacementReceipt,
                    replacementInspection,new BigDecimal("8"),"replacement-stock-"+replacementReceipt,"REPLACEMENT"));
            assertEquals(0,stockBalance(w.warehouseId(),material).compareTo(new BigDecimal("20")));
            assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=? and color_id is null",
                    w.warehouseId(),material).compareTo(new BigDecimal("1000")),"最终20件实际取得成本为1000，补回不能叠加第二份原不良品成本");
            assertEquals(0,receiptMinimum("PURCHASE",orderItemId,BigDecimal.ONE).compareTo(new BigDecimal("20")));
            assertEquals("CLOSED",strFor("select status from inbound_expectations where order_type='PURCHASE' and order_id=?",orderId));
            assertSupplierApAmounts(w,new BigDecimal("1000"));
            return;
        }

        caseVersion = jdbc.queryForObject(
                "select row_version from procurement_iqc_rejection_cases where id = ?",
                Long.class, caseId);
        rejectionService.reverseReturn(caseId, new com.uten.imp.features
                .finance.payables.ProcurementIqcRejectionContracts.ReverseRequest(
                caseVersion, UUID.randomUUID(), "V466 反向验证"));
        assertEquals(0,receiptMinimum("PURCHASE",orderItemId,BigDecimal.ONE).compareTo(new BigDecimal("20")),
                "实退冲销恢复原20约束，不依赖OPEN/CLOSED展示状态");
        AnalysisView afterReverse = analysisService.detail(analysisId);
        MaterialView reopened = afterReverse.flatMaterials().stream()
                .filter(m -> m.goodsId().equals(material) && m.actionable())
                .findFirst().orElseThrow();
        analysisCommandService.notifySupply(
                analysisId,
                new NotifyRequest(
                        afterReverse.version(), afterReverse.fingerprint(),
                        "v466-notify-after-reverse-" + analysisId,
                        "BUY", List.of(reopened.materialLineId()), List.of(), null));
        assertEquals("CANCELLED", strFor(
                "select status from preplan_supply_actions where id = ?", actionId),
                "退回反向后行动仍取消（追加式契约），但欠货不再计入在途");
        assertEquals(2, count("""
                select count(*) from purchase_requests request
                where request.id in (
                    select action.external_document_id
                    from preplan_supply_actions action
                    where action.analysis_id = ? and action.route = 'BUY')
                """, analysisId), "反向后缺口重新可通知，替代申请正常生成");
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
        ProcurementCase pc = submitPurchaseForFinance(w, g, h, "10"); // PENDING case, version 1
        assertEquals("PENDING", strFor(
                "select status from procurement_order_approval_cases where order_type='PURCHASE' and order_id = ?",
                pc.orderId()), "提交后审核案 PENDING");

        loginAs(pc.reviewerUserId());
        BatchDecisionItem decision =
                claimFinanceDecision(pendingFinanceDecision("PURCHASE",pc.orderId()));
        financeApproval.approveBatch(List.of(decision), null); // first approve succeeds 0→1
        assertEquals(1, intFor("select status from purchase_orders where id = ?", pc.orderId()),
                "首次审批 → 订单 0→1 生效");

        // second approve (same case) rejected — no double-approval regardless of version
        assertThrows(ApiException.class,
                () -> financeApproval.approveBatch(List.of(decision), null),
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
        UUID orderItemId = produceFinishedFromOpeningInputs(w, w.goodsA(), "10", "10").orderItemId();
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
        // 纯数量行：keeperA 无 goods:cost:view，带价/金额会被 StockDocService 拒绝
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
        return receiveIntoQuarantine(w,goodsId,orderItemId,qty,null);
    }

    private UUID receiveIntoQuarantine(World w, UUID goodsId, UUID orderItemId, String qty,String replacementIntent) {
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
        ri.setReplacementIntent(replacementIntent);
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

    /** Drive procurement up to finance SUBMIT (case PENDING, version 1) — everything procureDirectBuy
     *  does EXCEPT the final approve — so a test can exercise the approval lock. */
    record ProcurementCase(UUID orderId, UUID reviewerUserId) {}

    ProcurementCase submitPurchaseForFinance(World w, UUID finished, UUID buy, String orderQty) {
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
        UUID reviewer = createApprover(w);
        financeApproval.submit("PURCHASE", orderId); // PENDING, version 1
        return new ProcurementCase(orderId, reviewer);
    }

    @Test
    void financeReviewLease_salesRequiresLiveOwnGenerationAndReleasesTerminalClaims() {
        World w=seedWorld("finance-lease-sales");
        loginAs(w.superAdminUserId());
        var request=orderRequest(w,w.goodsC(),"10","100");
        var order=salesOrderService.create(request);
        UUID id=order.getId();
        salesOrderService.approve(id);
        var initialDecision=new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeConfirmService.confirm(id,initialDecision)).getCode());
        assertFalse(financeConfirmService.review(id).financeConfirmed());
        var first=reviewClaims.claim("SALES_ORDER_FINANCE_CONFIRM",id.toString());
        request.getItems().getFirst().setId(order.getItems().getFirst().getId());
        request.setRemark("审核中不得改动");
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> salesOrderService.update(id,request)).getCode());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> salesOrderService.cancel(id)).getCode());
        var wrong=new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,UUID.randomUUID());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeConfirmService.confirm(id,wrong)).getCode());
        // Simulate time passing for a negative expiry test, never fabricate an approval or bypass a guard.
        jdbc.update("update task_claims set lease_until=now()-interval '1 second' where id=?",first.claimId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeConfirmService.confirm(id,
                new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,first.claimId()))).getCode());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> reviewClaims.heartbeat("SALES_ORDER_FINANCE_CONFIRM",id.toString(),first.claimId())).getCode());
        var current=reviewClaims.claim("SALES_ORDER_FINANCE_CONFIRM",id.toString());
        assertFalse(first.claimId().equals(current.claimId()));
        reviewClaims.release("SALES_ORDER_FINANCE_CONFIRM",id.toString(),first.claimId());
        assertEquals(current.claimId(),reviewClaims.activeClaimView("SALES_ORDER_FINANCE_CONFIRM",id.toString()).orElseThrow().claimId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeConfirmService.confirm(id,
                new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,first.claimId()))).getCode());
        financeConfirmService.confirm(id,new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,current.claimId()));
        assertTrue(financeConfirmService.review(id).financeConfirmed());
        assertTrue(reviewClaims.activeClaimView("SALES_ORDER_FINANCE_CONFIRM",id.toString()).isEmpty());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> reviewClaims.claim("SALES_ORDER_FINANCE_CONFIRM",id.toString())).getCode());
        reviewClaims.release("SALES_ORDER_FINANCE_CONFIRM",id.toString(),current.claimId());
        assertEquals(0,count("select count(*) from ar_ap_ledger where source_doc_id=?",id),"销售财审不产生应收事实");

        UUID rejectedOrder=salesOrderService.create(orderRequest(w,w.goodsC(),"2","100")).getId();
        salesOrderService.approve(rejectedOrder);
        var rejectionClaim=reviewClaims.claim("SALES_ORDER_FINANCE_CONFIRM",rejectedOrder.toString());
        financeConfirmService.reject(rejectedOrder,new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceRejectRequest(
                "请核对条款",0L,rejectionClaim.claimId()));
        assertTrue(financeConfirmService.review(rejectedOrder).financeRejected());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> reviewClaims.heartbeat("SALES_ORDER_FINANCE_CONFIRM",rejectedOrder.toString(),rejectionClaim.claimId())).getCode());
        salesOrderService.cancel(rejectedOrder);
        assertTrue(Boolean.TRUE.equals(jdbc.queryForObject("select is_stopped from sales_orders where id=?",Boolean.class,rejectedOrder)));
    }

    @Test
    void financeReviewLease_claimWaitsForCommercialEditAndThenBlocksFurtherEditing() throws Exception {
        World w=seedWorld("finance-lease-edit");
        loginAs(w.superAdminUserId());
        var request=orderRequest(w,w.goodsC(),"1","100");
        var saved=salesOrderService.create(request);
        UUID orderId=saved.getId();
        request.getItems().getFirst().setId(saved.getItems().getFirst().getId());
        salesOrderService.approve(orderId);
        UUID reviewer=createUserWithPerms(w,"finance-lease-waiter","sales_order_finance:view","sales_order_finance:confirm");
        request.setRemark("先完成的销售修改");
        var edited=new java.util.concurrent.CountDownLatch(1);
        var release=new java.util.concurrent.CountDownLatch(1);
        var pool=java.util.concurrent.Executors.newFixedThreadPool(2);
        String waitingName="finance-claim-wait-"+orderId;
        try {
            var edit=pool.submit(() -> {
                loginAs(w.superAdminUserId());
                try { return new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(status -> {
                    var result=salesOrderService.update(orderId,request);
                    edited.countDown();
                    try { assertTrue(release.await(20,java.util.concurrent.TimeUnit.SECONDS)); }
                    catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new IllegalStateException(interrupted); }
                    return result;
                }); } finally { SecurityContextHolder.clearContext(); }
            });
            assertTrue(edited.await(20,java.util.concurrent.TimeUnit.SECONDS));
            var claim=pool.submit(() -> {
                loginAs(reviewer);
                try { return new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(status -> {
                    jdbc.queryForObject("select set_config('application_name',?,true)",String.class,waitingName);
                    return reviewClaims.claim("SALES_ORDER_FINANCE_CONFIRM",orderId.toString());
                }); } finally { SecurityContextHolder.clearContext(); }
            });
            long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(8);
            boolean blocked=false;
            while(System.nanoTime()<deadline) {
                blocked=count("select count(*) from pg_stat_activity where application_name=? and wait_event_type='Lock'",waitingName)>0;
                if(blocked)break;
                Thread.sleep(20);
            }
            assertTrue(blocked,"真实认领事务必须等待销售持有的header锁，不能在检查与提交之间插入租约");
            release.countDown();
            edit.get(20,java.util.concurrent.TimeUnit.SECONDS);
            var held=claim.get(20,java.util.concurrent.TimeUnit.SECONDS);
            loginAs(w.superAdminUserId());
            assertEquals("先完成的销售修改",strFor("select remark from sales_orders where id=?",orderId));
            request.setRemark("认领后不允许修改");
            assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> salesOrderService.update(orderId,request)).getCode());
            loginAs(reviewer);
            reviewClaims.release("SALES_ORDER_FINANCE_CONFIRM",orderId.toString(),held.claimId());
        } finally { release.countDown();pool.shutdownNow(); }
    }

    @Test
    void financeReviewLease_mixedProcurementBatchIsAtomicAndUnclaimedReverseCancelsOnlyPendingAttempts() {
        World w=seedWorld("finance-lease-procurement");
        UUID product=UUID.randomUUID(),raw=UUID.randomUUID();
        insertGoods(product,"LEASE-P","lease product","自制",w.unitId(),w.unitLegacy());
        insertGoods(raw,"LEASE-R","lease material","采购",w.unitId(),w.unitLegacy());
        insertBom(product,raw,"2");
        jdbc.update("update goods set default_supplier_id=? where id=?",w.supplierId(),raw);
        ProcurementCase purchase=submitPurchaseForFinance(w,product,raw,"10");
        ProcurementCase subcontract=submitLeafSubcontractForFinance(w);
        putDirectTargetStock(w,w.goodsE(),"10");
        BatchDecisionItem purchaseDecision=pendingFinanceDecision("PURCHASE",purchase.orderId());
        BatchDecisionItem subcontractDecision=pendingFinanceDecision("SUBCONTRACT",subcontract.orderId());
        loginAs(purchase.reviewerUserId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeApproval.approveBatch(List.of(purchaseDecision),null)).getCode());
        BatchDecisionItem ownedPurchase=claimFinanceDecision(purchaseDecision);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeApproval.approveBatch(List.of(ownedPurchase,subcontractDecision),null)).getCode());
        assertEquals(0,intFor("select status from purchase_orders where id=?",purchase.orderId()));
        assertEquals(0,intFor("select status from subcontract_orders where id=?",subcontract.orderId()));
        assertEquals(0,count("select count(*) from inbound_expectations where order_id in (?,?)",purchase.orderId(),subcontract.orderId()));

        loginAs(subcontract.reviewerUserId());
        BatchDecisionItem otherOwned=claimFinanceDecision(subcontractDecision);
        loginAs(purchase.reviewerUserId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeApproval.approveBatch(List.of(otherOwned,ownedPurchase),null)).getCode());
        loginAs(subcontract.reviewerUserId());
        reviewClaims.release("PROCUREMENT_FINANCE_APPROVE",subcontractDecision.caseId().toString(),otherOwned.expectedClaimId());
        loginAs(purchase.reviewerUserId());
        BatchDecisionItem ownedSubcontract=claimFinanceDecision(subcontractDecision);
        var wrongGeneration=new BatchDecisionItem(ownedPurchase.caseId(),ownedPurchase.expectedVersion(),UUID.randomUUID());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> financeApproval.approveBatch(List.of(ownedSubcontract,wrongGeneration),null)).getCode());
        var approved=financeApproval.approveBatch(List.of(ownedSubcontract,ownedPurchase),"核对原始金额与数量");
        assertEquals(2,approved.processed());
        assertEquals(1,intFor("select status from purchase_orders where id=?",purchase.orderId()));
        assertEquals(1,intFor("select status from subcontract_orders where id=?",subcontract.orderId()));
        assertEquals(2,count("select count(*) from inbound_expectations where order_id in (?,?)",purchase.orderId(),subcontract.orderId()));
        assertTrue(reviewClaims.activeClaimView("PROCUREMENT_FINANCE_APPROVE",purchaseDecision.caseId().toString()).isEmpty());
        assertTrue(reviewClaims.activeClaimView("PROCUREMENT_FINANCE_APPROVE",subcontractDecision.caseId().toString()).isEmpty());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> reviewClaims.heartbeat("PROCUREMENT_FINANCE_APPROVE",subcontractDecision.caseId().toString(),ownedSubcontract.expectedClaimId())).getCode());

        loginAs(w.superAdminUserId());
        UUID purchaseItem=jdbc.queryForObject("select id from purchase_order_items where order_id=? and is_deleted=false",UUID.class,purchase.orderId());
        purchaseOrderService.changeQty(purchase.orderId(),new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(
                List.of(new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(purchaseItem,new BigDecimal("18")))));
        BatchDecisionItem reconfirmation=pendingFinanceDecision("PURCHASE",purchase.orderId());
        loginAs(purchase.reviewerUserId());
        BatchDecisionItem heldReconfirmation=claimFinanceDecision(reconfirmation);
        loginAs(w.superAdminUserId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> purchaseOrderService.reverse(purchase.orderId())).getCode());
        assertEquals("PENDING",strFor("select status from procurement_order_approval_cases where id=?",reconfirmation.caseId()));
        assertEquals(0,jdbc.queryForObject("select qty from purchase_order_items where id=?",BigDecimal.class,purchaseItem).compareTo(new BigDecimal("18")));
        loginAs(purchase.reviewerUserId());
        reviewClaims.release("PROCUREMENT_FINANCE_APPROVE",reconfirmation.caseId().toString(),heldReconfirmation.expectedClaimId());
        loginAs(w.superAdminUserId());
        purchaseOrderService.reverse(purchase.orderId());
        assertEquals(-1,intFor("select status from purchase_orders where id=?",purchase.orderId()));
        assertEquals("APPROVED",strFor("select status from procurement_order_approval_cases where id=?",purchaseDecision.caseId()));
        assertEquals("CANCELED",strFor("select status from procurement_order_approval_cases where id=?",reconfirmation.caseId()));
        assertEquals(1,count("select count(*) from procurement_order_approval_events where case_id=? and event_type='CANCELED' and reason='ORDER_REVERSED'",reconfirmation.caseId()));
        assertEquals(1,count("select count(*) from procurement_order_qty_change_logs where case_id=?",reconfirmation.caseId()));
        loginAs(purchase.reviewerUserId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> reviewClaims.claim("PROCUREMENT_FINANCE_APPROVE",reconfirmation.caseId().toString())).getCode());

        loginAs(w.superAdminUserId());
        UUID subcontractItem=jdbc.queryForObject("select id from subcontract_order_items where order_id=? and is_deleted=false",UUID.class,subcontract.orderId());
        subcontractOrderService.changeQty(subcontract.orderId(),new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(
                List.of(new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(subcontractItem,new BigDecimal("8")))));
        BatchDecisionItem subcontractReconfirmation=pendingFinanceDecision("SUBCONTRACT",subcontract.orderId());
        loginAs(subcontract.reviewerUserId());
        BatchDecisionItem heldSubcontractReconfirmation=claimFinanceDecision(subcontractReconfirmation);
        loginAs(w.superAdminUserId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> subcontractOrderService.reverse(subcontract.orderId())).getCode());
        assertEquals("PENDING",strFor("select status from procurement_order_approval_cases where id=?",subcontractReconfirmation.caseId()));
        loginAs(subcontract.reviewerUserId());
        reviewClaims.release("PROCUREMENT_FINANCE_APPROVE",subcontractReconfirmation.caseId().toString(),heldSubcontractReconfirmation.expectedClaimId());
        loginAs(w.superAdminUserId());
        subcontractOrderService.reverse(subcontract.orderId());
        assertEquals("APPROVED",strFor("select status from procurement_order_approval_cases where id=?",subcontractDecision.caseId()));
        assertEquals("CANCELED",strFor("select status from procurement_order_approval_cases where id=?",subcontractReconfirmation.caseId()));
        assertEquals(1,count("select count(*) from procurement_order_approval_events where case_id=? and event_type='CANCELED' and reason='ORDER_REVERSED'",subcontractReconfirmation.caseId()));
        assertEquals(1,count("select count(*) from procurement_order_qty_change_logs where case_id=?",subcontractReconfirmation.caseId()));

        ProcurementCase draft=submitPurchaseForFinance(w,product,raw,"2");
        BatchDecisionItem draftCase=pendingFinanceDecision("PURCHASE",draft.orderId());
        loginAs(draft.reviewerUserId());
        BatchDecisionItem heldDraft=claimFinanceDecision(draftCase);
        loginAs(w.superAdminUserId());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> purchaseOrderService.cancel(draft.orderId())).getCode());
        loginAs(draft.reviewerUserId());
        reviewClaims.release("PROCUREMENT_FINANCE_APPROVE",draftCase.caseId().toString(),heldDraft.expectedClaimId());
        loginAs(w.superAdminUserId());
        purchaseOrderService.cancel(draft.orderId());
        assertEquals("CANCELED",strFor("select status from procurement_order_approval_cases where id=?",draftCase.caseId()));
        assertEquals(1,count("select count(*) from procurement_order_approval_events where case_id=? and event_type='CANCELED' and reason='ORDER_CANCELED'",draftCase.caseId()));
    }

    ProcurementCase submitLeafSubcontractForFinance(World w) {
        return submitLeafSubcontractForFinance(w,w.unitId(),BigDecimal.ONE);
    }

    ProcurementCase submitLeafSubcontractForFinance(World w,BigDecimal quantity) {
        return submitLeafSubcontractForFinance(w,w.unitId(),BigDecimal.ONE,quantity);
    }

    private ProcurementCase submitLeafSubcontractForFinance(World w,UUID orderUnit,BigDecimal unitRate) {
        return submitLeafSubcontractForFinance(w,orderUnit,unitRate,BigDecimal.TEN);
    }

    private ProcurementCase submitLeafSubcontractForFinance(World w,UUID orderUnit,BigDecimal unitRate,BigDecimal quantity) {
        loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026,1,15)); request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId()); request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE); request.setTaxRate(BigDecimal.ZERO); request.setSettlementMethodId(activeSettlementMethodId());
        var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setGoodsId(w.goodsE()); line.setUnitId(orderUnit); line.setUnitRate(unitRate);
        line.setQty(quantity); line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(quantity.multiply(line.getPrice())); line.setAmountLocal(line.getAmountOriginal()); request.setItems(List.of(line));
        UUID orderId=subcontractOrderService.create(request).getId();
        UUID reviewer=createApprover(w);
        financeApproval.submit("SUBCONTRACT",orderId);
        return new ProcurementCase(orderId,reviewer);
    }

    @Test
    void subcontractQuantityRevision_keepsBaseUnitsAndGrossIssueHistoryAfterActualMaterialReturn() {
        runSubcontractQuantityBasis(true);
    }

    @Test
    void subcontractMultiUnit_partialOutboundReturnAndQualifiedReceiptConsumeExactTargetBase() {
        runSubcontractQuantityBasis(false);
    }

    @Test
    void subcontractStoredReceiptReversalRestoresOriginalMaterialAndSupplierFeeSeparately() {
        runSubcontractQuantityBasis(false,1);
    }

    @Test
    void subcontractShippedReceiptCannotReverseItsMaterialsOrSupplierFee() {
        runSubcontractQuantityBasis(false,2);
    }

    @Test
    void directSubcontractDraftNoChildrenOrQualifiedTargetStockCanReachFinanceWithoutProduction() {
        World w=seedWorld("sc-draft-ready");receiveOpeningInputsForA(w,"10");
        var leaf=subcontractOrderService.create(directSubcontractDraft(w,w.goodsE(),"5"));
        financeApproval.submit("SUBCONTRACT",leaf.getId());
        putDirectTargetStock(w,w.goodsA(),"10");
        var target=subcontractOrderService.create(directSubcontractDraft(w,w.goodsA(),"5","5"));
        assertEquals(0,count("select count(*) from production_material_analysis_items where source_ref in (?,?)","SC-ORDER:"+leaf.getItems().getFirst().getId(),"SC-ORDER:"+target.getItems().getFirst().getId()));
        UUID reviewer=createApprover(w);financeApproval.submit("SUBCONTRACT",target.getId());loginAs(reviewer);approvePendingFinance("SUBCONTRACT",target.getId());
        assertEquals(2,count("select count(*) from subcontract_material_plan_items item join subcontract_material_plans plan on plan.id=item.plan_id where plan.order_id=? and item.flow_mode='DIRECT_OUTBOUND' and item.preparation_status='READY_OUTBOUND'",target.getId()));
        assertEquals(0,bigDecimalFor("select sum(r.qty-r.released_qty-r.consumed_qty) from stock_reservations r join subcontract_material_plan_items item on item.id=r.owner_id join subcontract_material_plans plan on plan.id=item.plan_id where plan.order_id=? and r.owner_type='SUBCONTRACT_OUTBOUND' and r.status=0",target.getId()).compareTo(new BigDecimal("10")),"同货两行各5只预留真实库存10，不能各读10份可用量");
    }

    @Test
    void directSubcontractDraftSharedPoolAndIdleEditsKeepOnePreparationPerOriginalLine() {
        World w=seedWorld("sc-draft-shared");putDirectTargetStock(w,w.goodsA(),"3");
        var request=directSubcontractDraft(w,w.goodsA(),"6","6");var order=subcontractOrderService.create(request);
        UUID originalSecond=order.getItems().get(1).getId();
        assertEquals(0,bigDecimalFor("select sum(source.requested_qty) from production_material_analysis_items source join subcontract_order_items item on item.id=source.subcontract_order_item_id where item.order_id=?",order.getId()).compareTo(new BigDecimal("9")),"两行12件只共用现货3件一次，前置制造总量9件");
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->financeApproval.submit("SUBCONTRACT",order.getId())).getCode());
        var changed=directSubcontractDraft(w,w.goodsA(),"7","6");var edited=subcontractOrderService.update(order.getId(),changed);
        assertEquals(originalSecond,edited.getItems().get(1).getId(),"未改行保留真实UUID与原准备谱系");
        assertEquals(0,bigDecimalFor("select sum(source.requested_qty) from production_material_analysis_items source join subcontract_order_items item on item.id=source.subcontract_order_item_id join production_material_analyses analysis on analysis.id=source.analysis_id where item.order_id=? and analysis.status<>'CANCELLED'",order.getId()).compareTo(new BigDecimal("10")));
        subcontractOrderService.update(order.getId(),changed);
        assertEquals(2,count("select count(*) from production_material_analysis_items source join subcontract_order_items item on item.id=source.subcontract_order_item_id join production_material_analyses analysis on analysis.id=source.analysis_id where item.order_id=? and analysis.status<>'CANCELLED'",order.getId()));
        subcontractOrderService.delete(order.getId());
        assertEquals(0,count("select count(*) from production_material_analysis_items source join subcontract_order_items item on item.id=source.subcontract_order_item_id join production_material_analyses analysis on analysis.id=source.analysis_id where item.order_id=? and analysis.status<>'CANCELLED'",order.getId()));
    }

    @Test
    void directSubcontractDraftPlansBeforeFinanceProtectsStartedLinesAndFinishesBeforeOutbound() {
        World w=seedWorld("sc-draft-produce");
        UUID clerk=createUserWithPerms(w,"sc-draft-clerk","subcontract_order:view","subcontract_order:create","subcontract_order:edit","subcontract_order:delete","subcontract_order:submit_finance","subcontract_order:price:view");
        UUID planner=createUserWithPerms(w,"sc-draft-planner","notice:read","production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route","production_material_analysis:generate","production_plan:view","production_plan:approve","production_execution:view","production_execution:start");
        UUID keeper=createUserWithPerms(w,"sc-draft-keeper","notice:read","stock_doc:view","stock_doc:approve","stock_doc:issue","subcontract_material_issue:view","subcontract_material_issue:approve","subcontract_outbound:execute");
        UUID quality=createUserWithPerms(w,"sc-draft-quality","production_quality_inspection:view","production_quality_inspection:approve");
        for(var membership:Map.of(planner,"SUB_PLAN",keeper,"SUB_WH",quality,"DEPT_QA").entrySet())jdbc.update("update employees set department_id=(select id from departments where code=? and is_deleted=false) where id=(select employee_id from users where id=?)",membership.getValue(),membership.getKey());
        var request=directSubcontractDraft(w,w.goodsA(),"5");loginAs(clerk);var order=subcontractOrderService.create(request);
        UUID orderItem=order.getItems().getFirst().getId();
        UUID analysis=jdbc.queryForObject("select analysis_id from production_material_analysis_items where subcontract_order_item_id=?",UUID.class,orderItem);
        assertEquals("WAITING_PLAN",subcontractOrderProgress.progress(order.getId()).materialLines().getFirst().preparationStatus());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->financeApproval.submit("SUBCONTRACT",order.getId())).getCode());
        UUID outsider=createUserWithPerms(w,"sc-draft-outsider","production_material_analysis:view","production_material_analysis:route","production_material_analysis:generate");
        loginAs(outsider);assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,()->analysisService.detail(analysis)).getCode());
        loginAs(planner);var view=analysisService.detail(analysis);var assignment=productionAssignment("sc-draft-produce");
        assertTrue(analysisService.list("SC-ORDER:"+orderItem,null,null,1,20).getItems().stream().anyMatch(item->item.analysisId().equals(analysis)));
        var plan=analysisCommandService.issueWorkshopPlans(analysis,new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"sc-draft-plan-"+order.getId(),w.warehouseId(),BusinessTime.today(),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,view.products().getFirst().analysisLineId(),new BigDecimal("5"),BusinessTime.today(),null,assignment.workshopId(),null,assignment.workerId(),null,null)))).plans().getFirst();
        assertTrue(hasSegmentStatus(plan.planId(),"WAITING"));assertTrue(plan.drawIds().isEmpty());
        var changed=directSubcontractDraft(w,w.goodsA(),"6");loginAs(clerk);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->subcontractOrderService.update(order.getId(),changed)).getCode());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->subcontractOrderService.delete(order.getId())).getCode());
        assertEquals(orderItem,subcontractOrderService.update(order.getId(),request).getItems().getFirst().getId());
        receiveOpeningInputsForA(w,"5");
        loginAs(planner);
        var waiting=executionSegmentService.list(plan.planId()).getFirst();
        executionSegmentService.recheckMaterial(plan.planId(),waiting.id(),new SegmentTransitionRequest(waiting.lockVersion(),"sc-draft-recheck-"+plan.planId()));
        loginAs(keeper);
        for(UUID draw:jdbc.queryForList("select link.draw_id from plan_draw_links link join stock_documents doc on doc.id=link.draw_id where link.plan_id=? and link.is_deleted=false and doc.doc_type='DRAW' and doc.status=0",UUID.class,plan.planId()))
            stockDocService.approveAndIssue(draw,drawIssueRequest(draw,"sc-draft-draw-"+draw,"实际发料",BigDecimal.ZERO));
        loginAs(planner);UUID planItem=planItemIdFor(plan.planId(),w.goodsA());var started=startedSegmentFor(w,plan.planId(),planItem,null);
        UUID report=reportAndApproveExecutionSegment(w,planItem,null,w.goodsA(),started.segmentId(),null,"5",false,"0",keeper,quality);
        loginAs(keeper);confirmFinishedInboundFully(finishedInDocForReport(report));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("5")));
        assertTrue(count("select count(*) from business_outbox where event_type='SUBCONTRACT_ORDER_PREPARATION_ARRIVED' and aggregate_id=?",orderItem)>0);
        loginAs(clerk);assertEquals("READY_FOR_FINANCE",subcontractOrderProgress.progress(order.getId()).materialLines().getFirst().preparationStatus());
        UUID reviewer=createApprover(w);financeApproval.submit("SUBCONTRACT",order.getId());loginAs(reviewer);approvePendingFinance("SUBCONTRACT",order.getId());loginAs(keeper);
        assertEquals(0,count("select count(*) from subcontract_material_plan_items item join subcontract_material_plans plan on plan.id=item.plan_id where plan.order_id=? and item.flow_mode='MAKE_THEN_OUTBOUND'",order.getId()));
        UUID issue=jdbc.queryForObject("select issue.id from subcontract_material_issues issue join subcontract_material_issue_items item on item.issue_id=issue.id where item.order_item_id=? and issue.status=0 and issue.is_deleted=false",UUID.class,orderItem);
        subcontractMaterialIssueService.approve(issue);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsA()).signum(),"财审通过即可从真实仓库出仓，不再倒挂等生产");
    }

    @Test
    void directSubcontractFinanceApprovalRechecksTargetStockAfterSubmission() {
        World w=seedWorld("sc-draft-recheck");putDirectTargetStock(w,w.goodsA(),"5");
        var order=subcontractOrderService.create(directSubcontractDraft(w,w.goodsA(),"5"));UUID reviewer=createApprover(w);financeApproval.submit("SUBCONTRACT",order.getId());
        var shipmentRequest=directCustomerShipmentRequest(w,"FREE","1");shipmentRequest.getItems().getFirst().setGoodsId(w.goodsA());
        UUID shipment=shipmentService.create(shipmentRequest).getId();shipmentService.confirmSales(shipment,0L);shipThroughWarehouse(shipment);
        loginAs(reviewer);assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->approvePendingFinance("SUBCONTRACT",order.getId())).getCode());
        assertEquals(0,count("select count(*) from subcontract_material_plans where order_id=?",order.getId()));
        assertEquals(0,count("select count(*) from subcontract_orders where id=? and status=1",order.getId()));
    }

    private com.uten.imp.features.subcontract.order.dto.OrderSaveRequest directSubcontractDraft(World w,UUID goods,String... quantities){
        loginAs(w.superAdminUserId());var request=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today());request.setDeliverDate(BusinessTime.today().plusDays(3));request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(activeSettlementMethodId());
        var lines=new ArrayList<com.uten.imp.features.subcontract.order.dto.OrderItemLine>();
        for(String qty:quantities){var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setGoodsId(goods);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("10"));line.setAmountOriginal(line.getQty().multiply(line.getPrice()));line.setAmountLocal(line.getAmountOriginal());lines.add(line);}
        request.setItems(lines);return request;
    }

    private void putDirectTargetStock(World w,UUID goods,String qty){
        loginAs(w.superAdminUserId());var request=new com.uten.imp.features.stock.dto.StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(w.warehouseId());request.setBillDate(BusinessTime.today());
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();line.setGoodsId(goods);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("10"));line.setAmountOriginal(line.getQty().multiply(line.getPrice()));line.setAmountLocal(line.getAmountOriginal());request.setItems(List.of(line));stockDocService.approve(stockDocService.create(request).getId());
    }

    private void runSubcontractQuantityBasis(boolean reviseOrder) {
        runSubcontractQuantityBasis(reviseOrder,0);
    }

    private void runSubcontractQuantityBasis(boolean reviseOrder,int reverseStored) {
        World w=seedWorld(reverseStored==0?(reviseOrder?"sc-qty-revision":"sc-qty-base"):"sc-stored-reverse-"+reverseStored);
        receiveOpeningInputsForA(w,"20"); // Explicit known stock E20 at cost10, recorded by real OTHER_IN.
        UUID box=UUID.randomUUID();
        jdbc.update("insert into units(id,code,name) values (?,?,'box')",box,"SC-BOX-"+box);
        var submitted=submitLeafSubcontractForFinance(w,box,new BigDecimal("2"));
        loginAs(submitted.reviewerUserId());
        approvePendingFinance("SUBCONTRACT",submitted.orderId());
        loginAs(w.superAdminUserId());
        UUID orderId=submitted.orderId();
        UUID itemId=jdbc.queryForObject("select id from subcontract_order_items where order_id=?",UUID.class,orderId);
        UUID planItem=jdbc.queryForObject("select id from subcontract_material_plan_items where order_item_id=?",UUID.class,itemId);
        assertEquals(0,bigDecimalFor("select unit_rate from subcontract_material_plan_items where id=?",planItem).compareTo(BigDecimal.ONE));
        assertEquals(0,bigDecimalFor("select bom_unit_qty from subcontract_material_plan_items where id=?",planItem).compareTo(new BigDecimal("2")));
        assertEquals(w.unitId(),jdbc.queryForObject("select unit_id from subcontract_material_plan_items where id=?",UUID.class,planItem));
        if(reviseOrder) changeSubcontractQtyAndReconfirm(w,submitted,itemId,"8");
        assertEquals(0,bigDecimalFor("select planned_qty from subcontract_material_plan_items where id=?",planItem)
                .compareTo(new BigDecimal(reviseOrder?"16":"20")),"目标计划按订单箱数乘冻结换算率一次");
        UUID issueId=jdbc.queryForObject("""
                select issue.id from subcontract_material_issues issue join subcontract_material_issue_items item on item.issue_id=issue.id
                where item.order_item_id=? and issue.status=0 and issue.is_deleted=false
                """,UUID.class,itemId);
        var draft=subcontractMaterialIssueService.detail(issueId);
        var edit=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
        edit.setBillDate(draft.getBillDate()); edit.setSupplierId(w.supplierId()); edit.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();
        var original=draft.getItems().getFirst();
        line.setGoodsId(w.goodsE()); line.setUnitId(original.getUnitId()); line.setUnitRate(original.getUnitRate());
        line.setQty(BigDecimal.TEN); line.setOrderItemId(itemId); line.setPlanItemId(planItem); line.setParentGoodsId(w.goodsE());
        edit.setItems(List.of(line));
        subcontractMaterialIssueService.update(issueId,edit);
        var issued=subcontractMaterialIssueService.approve(issueId).getItems().getFirst();
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(BigDecimal.TEN),"编辑后仍只发10个，不能再次乘箱换算率");
        assertEquals(0,bigDecimalFor("select issued_qty from subcontract_material_plan_items where id=?",planItem).compareTo(BigDecimal.TEN));
        assertEquals(0,bigDecimalFor("select frozen_unit_qty from subcontract_material_issue_items where id=?",issued.getId()).compareTo(new BigDecimal("2")));
        var returned=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();
        returned.setBillDate(LocalDate.of(2026,1,20)); returned.setSupplierId(w.supplierId()); returned.setWarehouseId(w.warehouseId());
        var returnLine=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();
        returnLine.setGoodsId(w.goodsE()); returnLine.setUnitId(w.unitId()); returnLine.setUnitRate(BigDecimal.ONE);
        returnLine.setQty(new BigDecimal("2")); returnLine.setMaterialIssueItemId(issued.getId());
        returnLine.setOrderItemId(itemId); returnLine.setParentGoodsId(w.goodsE()); returned.setItems(List.of(returnLine));
        UUID returnId=subcontractMaterialReturnService.create(returned).getId();
        subcontractMaterialReturnService.approve(returnId);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("12")));
        var tooSmall=new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(List.of(
                new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(itemId,new BigDecimal("3"))));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->subcontractOrderService.changeQty(orderId,tooSmall)).getCode());
        if(reviseOrder) changeSubcontractQtyAndReconfirm(w,submitted,itemId,"4");
        assertEquals(0,bigDecimalFor("select planned_qty from subcontract_material_plan_items where id=?",planItem)
                .compareTo(new BigDecimal(reviseOrder?"10":"20")),"缩单时新目标8个+实退2个=毛计划10；未缩单保留原计划20");
        assertEquals(0,bigDecimalFor("select issued_qty from subcontract_material_plan_items where id=?",planItem).compareTo(BigDecimal.TEN));
        assertEquals(reviseOrder?0:1,count("""
                select count(*) from subcontract_material_issues issue join subcontract_material_issue_items item on item.issue_id=issue.id
                where item.order_item_id=? and issue.status=0 and issue.is_deleted=false
                """,itemId),"实退后缩单不应重复下发已退的两件");
        var receipt=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        receipt.setBillDate(BusinessTime.today()); receipt.setSupplierId(w.supplierId()); receipt.setWarehouseId(w.warehouseId());
        receipt.setCurrencyId(w.currencyId()); receipt.setExchangeRate(BigDecimal.ONE); receipt.setTaxRate(BigDecimal.ZERO);
        receipt.setSettlementMethodId(subcontractOrderSettlementMethodOf(itemId));
        var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
        receiptLine.setGoodsId(w.goodsE()); receiptLine.setOrderItemId(itemId); receiptLine.setUnitId(box);
        receiptLine.setUnitRate(new BigDecimal("2")); receiptLine.setQty(new BigDecimal("4")); receiptLine.setPrice(new BigDecimal("50"));
        receiptLine.setAmountOriginal(new BigDecimal("200")); receiptLine.setAmountLocal(new BigDecimal("200")); receipt.setItems(List.of(receiptLine));
        UUID receiptId=subcontractReceiptService.create(receipt).getId();
        subcontractReceiptService.approve(receiptId);
        if(reviseOrder){
            UUID reversedReceipt=receiptId;
            UUID resolvedInspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='SUBCONTRACT' and receipt_id=?",UUID.class,reversedReceipt);
            inspectionService.dispose("SUBCONTRACT",reversedReceipt,resolvedInspection,
                    new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"回厂已检验，仓库尚未入库","sc-reverse-before-store-"+reversedReceipt));
            subcontractReceiptService.reverse(reversedReceipt);
            assertEquals(0,bigDecimalFor("select consumed_qty from subcontract_material_issue_items where id=?",issued.getId()).signum(),
                    "未实际入仓的回厂红冲恢复本单原实发来源，不能LIFO挪动另一批材料");
            assertEquals(1,count("select count(*) from subcontract_receipt_material_consumptions c join subcontract_receipt_items i on i.id=c.receipt_item_id where i.receipt_id=? and c.reversal_of is not null",reversedReceipt));
            receiptId=subcontractReceiptService.create(receipt).getId();
            subcontractReceiptService.approve(receiptId);
        }
        assertEquals(0,bigDecimalFor("select consumed_qty from subcontract_material_issue_items where id=?",issued.getId()).compareTo(new BigDecimal("8")),
                "4箱回厂消费8个目标件，毛出10=消费8+实退2");
        assertEquals(reviseOrder?"CLOSED":"OPEN",strFor("select status from inbound_expectations where order_type='SUBCONTRACT' and order_id=?",orderId));
        assertEquals(0,bigDecimalFor("select accepted_qty from inbound_expectation_items where order_item_id=?",itemId).compareTo(new BigDecimal("4")));
        UUID inspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='SUBCONTRACT' and receipt_id=?",UUID.class,receiptId);
        inspectionService.dispose("SUBCONTRACT",receiptId,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "PASS",null,"多单位回厂合格验收","sc-base-iqc-"+inspection));
        loginAs(createIqcWarehouseConfirmer(w,"sc-base-stockin-"+w.goodsA()));
        iqcStockInService.confirm("SUBCONTRACT",receiptId,latestIqcStockInRequest("SUBCONTRACT",receiptId,inspection,new BigDecimal("8"),"sc-base-stock-"+inspection,"SC-BASE"));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("20")),"实退2+合格回厂8加回原余量10，基本量守恒");
        for(int cycle=0;cycle<100&&inventoryValueWork.runBatch()>0;cycle++){ }
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsE())
                .compareTo(new BigDecimal("400")),"自有材料200+真实加工费200，目标件出仓与材料退回不产生第二笔采购成本");
        UUID originalReceiptItem=jdbc.queryForObject("select id from subcontract_receipt_items where receipt_id=?",UUID.class,receiptId);
        assertEquals("SUBCONTRACT_RECEIPT_ITEM",strFor("select source_kind from stock_value_production_cost_objects where execution_segment_id=?",originalReceiptItem));
        assertEquals("DIRECT_TARGET",strFor("select consumption_basis from subcontract_receipt_material_consumptions where receipt_item_id=?",originalReceiptItem),
                "两单位换算仍是目标件基本量1:1，不应被当成历史BOM估计");
        assertEquals(0,bigDecimalFor("select sum(n.owned_value_local) from stock_value_nodes n join stock_value_pools p on p.id=n.pool_id where p.goods_id=? and n.owner_kind='COST_WIP'",w.goodsE()).signum());
        if(reverseStored==0)return;
        loginAs(w.superAdminUserId());
        if(reverseStored==2){
            var shipmentRequest=directCustomerShipmentRequest(w,"FREE","1");
            shipmentRequest.getItems().getFirst().setGoodsId(w.goodsE());
            UUID shipment=shipmentService.create(shipmentRequest).getId();
            shipmentService.confirmSales(shipment,0L);shipThroughWarehouse(shipment);
            UUID blockedReceipt=receiptId;
            assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->subcontractReceiptService.reverse(blockedReceipt)).getCode());
            assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("19")));
            assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("380")));
            assertEquals(0,bigDecimalFor("select consumed_qty from subcontract_material_issue_items where id=?",issued.getId()).compareTo(new BigDecimal("8")));
            assertEquals(0,count("select count(*) from stock_value_events where source_doc_id=? and operation in('POSITION_STORE_REVERSE','CONSUMPTION_RETURN')",receiptId));
            assertEquals(0,count("select count(*) from stock_value_production_cost_outputs where execution_segment_id=? and withdrawn_movement_id is not null",originalReceiptItem));
            return;
        }
        subcontractReceiptService.reverse(receiptId);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("12")));
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("120")),"原库存12件仍保留120；原自有材料80退回供应商在料，原加工费200单独撤回");
        assertEquals(0,bigDecimalFor("select sum(owned_value_local) from stock_value_nodes where owner_kind='SUBCONTRACT_WIP' and owner_id=?",issued.getId()).compareTo(new BigDecimal("80")));
        assertEquals(0,bigDecimalFor("select sum(known_value_local) from stock_value_events where source_doc_id=? and operation='POSITION_STORE_REVERSE'",receiptId).compareTo(new BigDecimal("200")));
        assertEquals(0,bigDecimalFor("select consumed_qty from subcontract_material_issue_items where id=?",issued.getId()).signum());
        assertEquals(1,count("select count(*) from stock_value_production_cost_outputs where execution_segment_id=? and withdrawn_movement_id is not null",originalReceiptItem));
        assertEquals(0,count("select count(*) from stock_value_production_cost_objects where execution_segment_id=? and state='FINAL'",originalReceiptItem));
    }

    private void changeSubcontractQtyAndReconfirm(World w,ProcurementCase submitted,UUID itemId,String newQty) {
        loginAs(w.superAdminUserId());
        subcontractOrderService.changeQty(submitted.orderId(),new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(List.of(
                new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(itemId,new BigDecimal(newQty)))));
        loginAs(submitted.reviewerUserId()); approvePendingFinance("SUBCONTRACT",submitted.orderId()); loginAs(w.superAdminUserId());
    }

    private BigDecimal receiptMinimum(String type,UUID orderItemId,BigDecimal rate) {
        return new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(status ->
                com.uten.imp.common.finance.ProcurementOrderQuantityBounds.receipts(quantityEntityManager,type,orderItemId).minimumOrderedQty(rate));
    }

    private void assertSupplierApAmounts(World w,BigDecimal expected) {
        Map<String,Object> ap=jdbc.queryForMap("""
                select coalesce(sum(amount_original),0) as original,coalesce(sum(amount_original_local),0) as local
                from ar_ap_ledger where supplier_id=? and currency_id=? and direction='AP' and status=1 and is_deleted=false
                """,w.supplierId(),w.currencyId());
        org.junit.jupiter.api.Assertions.assertAll("真实应付原币/本币合计（实物退回不等于贷项；免费补回不重复收费）",
                ()->assertEquals(0,((BigDecimal)ap.get("original")).compareTo(expected),"原币实际="+ap.get("original")+", expected="+expected),
                ()->assertEquals(0,((BigDecimal)ap.get("local")).compareTo(expected),"本币实际="+ap.get("local")+", expected="+expected));
    }

    @Test
    void subcontractQuantityRevision_preservesExactOriginalAmountUsingFrozenExchangeRate() {
        World w=seedWorld("sc-qty-exact");
        receiveOpeningInputsForA(w,"1");
        loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026,1,15)); request.setSupplierId(w.supplierId()); request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId()); request.setExchangeRate(new BigDecimal("7"));
        request.setTaxRate(BigDecimal.ZERO); request.setSettlementMethodId(activeSettlementMethodId());
        var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setGoodsId(w.goodsE()); line.setUnitId(w.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("0.001")); line.setPrice(new BigDecimal("0.5"));
        line.setAmountOriginal(new BigDecimal("0.0005")); line.setAmountLocal(new BigDecimal("0.0035")); request.setItems(List.of(line));
        var created=subcontractOrderService.create(request);
        UUID reviewer=createApprover(w);
        financeApproval.submit("SUBCONTRACT",created.getId());
        loginAs(reviewer); approvePendingFinance("SUBCONTRACT",created.getId());
        changeSubcontractQtyAndReconfirm(w,new ProcurementCase(created.getId(),reviewer),created.getItems().getFirst().getId(),"0.0001");
        var revised=subcontractOrderService.detail(created.getId());
        assertEquals(0,revised.getTotalOriginal().compareTo(new BigDecimal("0.00005")));
        assertEquals(0,revised.getTotalLocal().compareTo(new BigDecimal("0.00035")),
                "原币0.00005完整保留，再按冻结汇率7换算，不人为改成0.0001");
        assertEquals(2,count("select count(*) from procurement_order_approval_cases where order_type='SUBCONTRACT' and order_id=? and status='APPROVED'",created.getId()));
    }

    @Test
    void procurementReceiptMinimum_pureExcessReceiptCannotLendReturnedAllowanceToNormalReceipt() {
        runPostedExcessReturnBound(false);
    }

    @Test
    void procurementReceiptMinimum_mixedReceiptKeepsItsOwnPostedAllowanceWithoutInventingSlices() {
        runPostedExcessReturnBound(true);
    }

    private void runPostedExcessReturnBound(boolean mixedLine) {
        World w=seedWorld(mixedLine?"receipt-bound-mixed":"receipt-bound-separate");
        loginAs(w.superAdminUserId());
        // Explicit general replenishment source, separate from the modern production-analysis acceptance.
        var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setWarehouseId(w.warehouseId());
        request.setDepartmentId(w.departmentId()); request.setApplicantId(w.employeeId());
        var requested=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(w.goodsD()); requested.setUnitId(w.unitId()); requested.setUnitRate(BigDecimal.ONE);
        requested.setQty(new BigDecimal("30")); request.setItems(List.of(requested));
        var savedRequest=purchaseRequestService.create(request); purchaseRequestService.approve(savedRequest.getId());
        var orderRequest=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderRequest.setBillDate(BusinessTime.today()); orderRequest.setSupplierId(w.supplierId()); orderRequest.setWarehouseId(w.warehouseId());
        orderRequest.setCurrencyId(w.currencyId()); orderRequest.setExchangeRate(BigDecimal.ONE); orderRequest.setTaxRate(BigDecimal.ZERO);
        orderRequest.setSettlementMethodId(activeSettlementMethodId());
        var ordered=new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        ordered.setGoodsId(w.goodsD()); ordered.setUnitId(w.unitId()); ordered.setUnitRate(BigDecimal.ONE);
        ordered.setQty(new BigDecimal("20")); ordered.setPrice(new BigDecimal("50"));
        ordered.setAmountOriginal(new BigDecimal("1000")); ordered.setAmountLocal(new BigDecimal("1000"));
        ordered.setRequestItemId(savedRequest.getItems().getFirst().getId()); orderRequest.setItems(List.of(ordered));
        var order=purchaseOrderService.create(orderRequest);
        UUID reviewer=createApprover(w); financeApproval.submit("PURCHASE",order.getId());
        loginAs(reviewer); approvePendingFinance("PURCHASE",order.getId()); loginAs(w.superAdminUserId());
        UUID itemId=order.getItems().getFirst().getId();
        if(!mixedLine) {
            UUID normal=receiveIntoQuarantine(w,w.goodsD(),itemId,"20");
            passAndStockPurchaseReceipt(w,normal,new BigDecimal("20"));
        }
        assertThrows(com.uten.imp.application.port.ProcurementArrivalBlockedException.class,
                () -> receiveIntoQuarantine(w,w.goodsD(),itemId,mixedLine?"24":"4"));
        UUID exceptionId=jdbc.queryForObject("select id from procurement_arrival_exceptions where order_type='PURCHASE' and order_item_id=?",UUID.class,itemId);
        UUID excessReceipt=jdbc.queryForObject("select receipt_id from procurement_arrival_exceptions where id=?",UUID.class,exceptionId);
        loginAs(reviewer);
        var pending=arrivalControl.financeDetail(exceptionId);
        arrivalControl.financeDecide(exceptionId,new com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalDecisionRequest(
                pending.version(),"APPROVE_ALL",null,"明确批准此到货行超量4"));
        assertEquals(0,receiptMinimum("PURCHASE",itemId,BigDecimal.ONE).compareTo(new BigDecimal(mixedLine?"0":"20")),
                "仅财务决定而未审核收货的超量不进入posted allowance");
        loginAs(w.superAdminUserId());
        arrivalControl.stockInWithDecisionSession(exceptionId,target->purchaseReceiptService.approveFromWarehouseDecision(target.receiptId()));
        passAndStockPurchaseReceipt(w,excessReceipt,new BigDecimal(mixedLine?"24":"4"));
        assertEquals(0,receiptMinimum("PURCHASE",itemId,BigDecimal.ONE).compareTo(new BigDecimal("20")),"实际收到24、独立批准超量4，合同基准20");
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsD()).compareTo(new BigDecimal("24")));
        var returned=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();
        returned.setBillDate(BusinessTime.today()); returned.setSupplierId(w.supplierId()); returned.setWarehouseId(w.warehouseId());
        returned.setCurrencyId(w.currencyId()); returned.setExchangeRate(BigDecimal.ONE); returned.setTaxRate(BigDecimal.ZERO);
        returned.setSettlementMethodId(purchaseOrderSettlementMethodOf(itemId));
        var returnLine=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();
        returnLine.setGoodsId(w.goodsD()); returnLine.setUnitId(w.unitId()); returnLine.setUnitRate(BigDecimal.ONE);
        returnLine.setQty(new BigDecimal("2")); returnLine.setPrice(new BigDecimal("50"));
        returnLine.setAmountOriginal(new BigDecimal("100")); returnLine.setAmountLocal(new BigDecimal("100"));
        returnLine.setOrderItemId(itemId); returnLine.setReceiptItemId(purchaseReceiptService.detail(excessReceipt).getItems().getFirst().getId());
        returned.setItems(List.of(returnLine));
        UUID returnId=supplierPurchaseReturnService.create(returned).getId(); supplierPurchaseReturnService.approve(returnId);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsD()).compareTo(new BigDecimal("22")));
        assertEquals(0,receiptMinimum("PURCHASE",itemId,BigDecimal.ONE).compareTo(new BigDecimal(mixedLine?"18":"20")),
                "Oeff逐receipt_item_id封顶：纯超到行净2只保留O2；混合行净22可承载O4，不猜先退哪一片");
        assertEquals(0,bigDecimalFor("select arrival_overage_posted_qty from purchase_order_items where id=?",itemId).compareTo(new BigDecimal("4")),
                "精确最低量是前向规则；原posted超量历史累计不被重写");
        if(mixedLine) {
            purchaseOrderService.changeQty(order.getId(),new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(List.of(
                    new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(itemId,new BigDecimal("18")))));
            loginAs(reviewer);approvePendingFinance("PURCHASE",order.getId());loginAs(w.superAdminUserId());
            RuntimeException blocked=assertThrows(RuntimeException.class,()->supplierPurchaseReturnService.reverse(returnId));
            Throwable cause=blocked;while(cause.getCause()!=null)cause=cause.getCause();
            assertTrue(cause instanceof java.sql.SQLException,"必须由数据库来源容量守卫拒绝，而不是其他偶发异常");
            assertEquals("23514",((java.sql.SQLException)cause).getSQLState());
            assertTrue(cause.getMessage().contains("return reversal would exceed source quantity"));
            assertEquals(0,stockBalance(w.warehouseId(),w.goodsD()).compareTo(new BigDecimal("22")),"拒绝整笔回滚，不能留下退货反向库存或金额");
            assertEquals(1,intFor("select status from purchase_returns where id=?",returnId));
            assertEquals(1,count("select count(*) from stock_movements where source_doc_type='PURCHASE_RETURN' and source_doc_id=?",returnId));
        } else {
            assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->purchaseOrderService.changeQty(order.getId(),
                    new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(List.of(
                            new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(itemId,new BigDecimal("19")))))).getCode(),
                    "独立超到行已退掉的许可不能借给正常20行，19必须拒绝");
        }
        for(String qty:List.of("24","20")) {
            loginAs(w.superAdminUserId());
            purchaseOrderService.changeQty(order.getId(),new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(List.of(
                    new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(itemId,new BigDecimal(qty)))));
            loginAs(reviewer); approvePendingFinance("PURCHASE",order.getId()); loginAs(w.superAdminUserId());
            assertEquals("20".equals(qty),purchaseOrderService.detail(order.getId()).isClosed(),
                    "商业结案按已实际入库净22判定，增加到24重开、减回20再结案；不能沿用改量前is_closed");
        }
        supplierPurchaseReturnService.reverse(returnId);
        assertEquals(0,receiptMinimum("PURCHASE",itemId,BigDecimal.ONE).compareTo(new BigDecimal("20")));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsD()).compareTo(new BigDecimal("24")));
    }

    private void passAndStockPurchaseReceipt(World w,UUID receiptId,BigDecimal qtyBase) {
        loginAs(w.superAdminUserId());
        UUID inspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='PURCHASE' and receipt_id=?",UUID.class,receiptId);
        inspectionService.dispose("PURCHASE",receiptId,inspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"合格确认","receipt-bound-pass-"+receiptId));
        loginAs(createIqcWarehouseConfirmer(w,"receipt-bound-stock-"+receiptId));
        iqcStockInService.confirm("PURCHASE",receiptId,latestIqcStockInRequest("PURCHASE",receiptId,inspection,qtyBase,"receipt-bound-stock-"+receiptId,"RECEIPT-BOUND"));
        loginAs(w.superAdminUserId());
    }

    @Test
    void subcontractProductReturnReversal_preservesProvenIqcReplacementCapacityInBusinessAndBaseUnits() {
        World w=seedWorld("sc-iqc-return-capacity");receiveOpeningInputsForA(w,"20");
        UUID box=UUID.randomUUID();jdbc.update("insert into units(id,code,name) values (?,?,'box')",box,"SC-IQC-BOX-"+box);
        var submitted=submitLeafSubcontractForFinance(w,box,new BigDecimal("2"));
        loginAs(submitted.reviewerUserId());approvePendingFinance("SUBCONTRACT",submitted.orderId());loginAs(w.superAdminUserId());
        UUID item=jdbc.queryForObject("select id from subcontract_order_items where order_id=?",UUID.class,submitted.orderId());
        changeSubcontractQtyAndReconfirm(w,submitted,item,"4");
        UUID issue=jdbc.queryForObject("""
                select h.id from subcontract_material_issues h join subcontract_material_issue_items i on i.issue_id=h.id
                where i.order_item_id=? and h.status=0 and h.is_deleted=false
                """,UUID.class,item);
        var draft=subcontractMaterialIssueService.detail(issue);
        var edited=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
        edited.setBillDate(BusinessTime.today());edited.setSupplierId(w.supplierId());edited.setWarehouseId(w.warehouseId());
        var issueLine=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();
        issueLine.setGoodsId(w.goodsE());issueLine.setUnitId(w.unitId());issueLine.setUnitRate(BigDecimal.ONE);
        issueLine.setQty(new BigDecimal("8"));issueLine.setOrderItemId(item);issueLine.setParentGoodsId(w.goodsE());
        issueLine.setPlanItemId(draft.getItems().getFirst().getPlanItemId());edited.setItems(List.of(issueLine));
        subcontractMaterialIssueService.update(issue,edited);subcontractMaterialIssueService.approve(issue);
        UUID receipt=receiveSubcontractIntoQuarantine(w,item,box,"4");
        UUID inspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='SUBCONTRACT' and receipt_id=?",UUID.class,receipt);
        inspectionService.dispose("SUBCONTRACT",receipt,inspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("FAIL",new BigDecimal("2"),"1箱不合格","sc-iqc-fail-"+receipt));
        inspectionService.dispose("SUBCONTRACT",receipt,inspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"其余合格","sc-iqc-pass-"+receipt));
        UUID rejection=awaitIqcRejection("SUBCONTRACT",receipt);
        loginAs(createIqcWarehouseConfirmer(w,"sc-iqc-first-"+receipt));
        iqcStockInService.confirm("SUBCONTRACT",receipt,latestIqcStockInRequest("SUBCONTRACT",receipt,inspection,new BigDecimal("6"),"sc-iqc-stock-"+receipt,"SC-IQC"));
        for(int cycle=0;cycle<100&&inventoryValueWork.runBatch()>0;cycle++){ }
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsE())
                .compareTo(new BigDecimal("330")),"原剩余12件120+PASS六件材料60+加工费150");
        assertEquals(0,bigDecimalFor("select sum(n.owned_value_local) from stock_value_nodes n join stock_value_pools p on p.id=n.pool_id where p.goods_id=? and n.owner_kind='COST_WIP'",w.goodsE())
                .compareTo(new BigDecimal("20")),"FAIL两件保留原自有材料20，不把加工费和自料混入同一拒收来源");
        loginAs(w.superAdminUserId());
        long version=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,rejection);
        rejectionService.recordReturn(rejection,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest(
                version,UUID.randomUUID(),"SC-IQC-RETURN",BusinessTime.today(),"实际退回1箱不良件供返修"));
        UUID replacement=receiveSubcontractIntoQuarantine(w,item,box,"1");
        UUID replacementInspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='SUBCONTRACT' and receipt_id=?",UUID.class,replacement);
        inspectionService.dispose("SUBCONTRACT",replacement,replacementInspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"返修补货合格","sc-iqc-replace-pass-"+replacement));
        loginAs(createIqcWarehouseConfirmer(w,"sc-iqc-replace-"+replacement));
        iqcStockInService.confirm("SUBCONTRACT",replacement,latestIqcStockInRequest("SUBCONTRACT",replacement,replacementInspection,
                new BigDecimal("2"),"sc-iqc-replace-stock-"+replacement,"SC-IQC"));
        for(int cycle=0;cycle<100&&inventoryValueWork.runBatch()>0;cycle++){ }
        loginAs(w.superAdminUserId());
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsE())
                .compareTo(new BigDecimal("400")),"免费补回仅承接原失败材料20和原加工费50，不重复耗料或增加新加工费用");
        assertEquals(1,count("select count(*) from subcontract_receipt_material_consumptions where receipt_item_id in (select id from subcontract_receipt_items where receipt_id in (?,?)) and reversal_of is null",receipt,replacement));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("20")));
        assertEquals(0,bigDecimalFor("select received_qty from subcontract_order_items where id=?",item).compareTo(new BigDecimal("5")));
        assertEquals(0,receiptMinimum("SUBCONTRACT",item,new BigDecimal("2")).compareTo(new BigDecimal("4")),"5箱毛收−1箱已实退=4箱，基本量10−2=8");
        assertEquals(0,bigDecimalFor("select sum(consumed_qty) from subcontract_material_issue_items where order_item_id=?",item).compareTo(new BigDecimal("8")),
                "返修补货复用原料，不能再次消费2个目标件");
        RuntimeException detachedProof=assertThrows(RuntimeException.class,()->
                new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(transaction ->
                    jdbc.update("""
                        update procurement_iqc_replacement_allocations
                        set status='REVERSED',row_version=row_version+1,reversed_at=now(),reversed_by=?,reverse_reason='capacity proof cannot be removed alone'
                        where replacement_receipt_id=? and status='ACTIVE'
                        """,w.superAdminUserId(),replacement)));
        Throwable proofCause=detachedProof;
        while(proofCause.getCause()!=null) proofCause=proofCause.getCause();
        assertTrue(proofCause instanceof java.sql.SQLException,"补回来源不能被单独撤销而留下已入库实物");
        assertEquals("23514",((java.sql.SQLException)proofCause).getSQLState());
        assertEquals(1,count("select count(*) from procurement_iqc_replacement_allocations where replacement_receipt_id=? and status='ACTIVE'",replacement));
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("20")),"拒绝撤销来源的事务不得改变实物或成本");
        var returned=new com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest();
        returned.setBillDate(BusinessTime.today());returned.setSupplierId(w.supplierId());returned.setWarehouseId(w.warehouseId());
        returned.setCurrencyId(w.currencyId());returned.setExchangeRate(BigDecimal.ONE);returned.setTaxRate(BigDecimal.ZERO);
        returned.setSettlementMethodId(subcontractOrderSettlementMethodOf(item));
        var returnLine=new com.uten.imp.features.subcontract.ret.dto.ReturnItemLine();
        returnLine.setGoodsId(w.goodsE());returnLine.setUnitId(box);returnLine.setUnitRate(new BigDecimal("2"));
        returnLine.setQty(new BigDecimal("0.5"));returnLine.setPrice(new BigDecimal("50"));
        returnLine.setAmountOriginal(new BigDecimal("25"));returnLine.setAmountLocal(new BigDecimal("25"));
        returnLine.setOrderItemId(item);returnLine.setReceiptItemId(subcontractReceiptService.detail(receipt).getItems().getFirst().getId());returned.setItems(List.of(returnLine));
        UUID productReturn=supplierSubcontractReturnService.create(returned).getId();supplierSubcontractReturnService.approve(productReturn);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("19")));
        supplierSubcontractReturnService.reverse(productReturn);
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("20")));
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsE())
                .compareTo(new BigDecimal("400")),"成品退供应商红冲按原实物退回成本恢复，不能把加工费售价当材料成本");
        assertEquals(0,bigDecimalFor("select returned_qty from subcontract_order_items where id=?",item).signum());
        assertEquals(0,receiptMinimum("SUBCONTRACT",item,new BigDecimal("2")).compareTo(new BigDecimal("4")));
    }

    @Test
    void subcontractMixedFreeReplacement_keepsTwoOriginalMaterialBatchesInOneWarehouseConfirmation(){
        World w=seedWorld("sc-mixed-material-roots");receiveOpeningInputsForA(w,"20");
        UUID box=UUID.randomUUID();jdbc.update("insert into units(id,code,name) values (?,?,'box')",box,"SC-MIX-"+box);
        var submitted=submitLeafSubcontractForFinance(w,box,new BigDecimal("2"));
        loginAs(submitted.reviewerUserId());approvePendingFinance("SUBCONTRACT",submitted.orderId());loginAs(w.superAdminUserId());
        UUID orderItem=jdbc.queryForObject("select id from subcontract_order_items where order_id=?",UUID.class,submitted.orderId());
        changeSubcontractQtyAndReconfirm(w,submitted,orderItem,"4");
        UUID issue=jdbc.queryForObject("""
                select header.id from subcontract_material_issues header join subcontract_material_issue_items item on item.issue_id=header.id
                where item.order_item_id=? and header.status=0 and not header.is_deleted
                """,UUID.class,orderItem);
        var draft=subcontractMaterialIssueService.detail(issue);
        var request=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();
        line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("8"));
        line.setOrderItemId(orderItem);line.setParentGoodsId(w.goodsE());line.setPlanItemId(draft.getItems().getFirst().getPlanItemId());request.setItems(List.of(line));
        subcontractMaterialIssueService.update(issue,request);subcontractMaterialIssueService.approve(issue);
        List<UUID> originals=new ArrayList<>();
        for(int batch=0;batch<2;batch++){
            UUID receipt=receiveSubcontractIntoQuarantine(w,orderItem,box,"2");originals.add(receipt);
            UUID inspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='SUBCONTRACT' and receipt_id=?",UUID.class,receipt);
            inspectionService.dispose("SUBCONTRACT",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                    "FAIL",null,"本回厂批实际退修","sc-mix-fail-"+receipt));
        }
        for(UUID receipt:originals){
            UUID rejection=awaitIqcRejection("SUBCONTRACT",receipt);
            long version=jdbc.queryForObject("select row_version from procurement_iqc_rejection_cases where id=?",Long.class,rejection);
            rejectionService.recordReturn(rejection,new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest(
                    version,UUID.randomUUID(),"SC-MIX-RETURN",BusinessTime.today(),"按原回厂批交还供应商返修"));
        }
        UUID replacement=receiveSubcontractIntoQuarantine(w,orderItem,box,"4");
        UUID inspection=jdbc.queryForObject("select id from procurement_inspection_items where receipt_type='SUBCONTRACT' and receipt_id=?",UUID.class,replacement);
        inspectionService.dispose("SUBCONTRACT",replacement,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "PASS",null,"两个原回厂批合并免费补回验收","sc-mix-pass-"+replacement));
        loginAs(createIqcWarehouseConfirmer(w,"sc-mix-stock"));
        var stored=iqcStockInService.confirm("SUBCONTRACT",replacement,latestIqcStockInRequest("SUBCONTRACT",replacement,inspection,
                new BigDecimal("8"),"sc-mix-stock-"+replacement,"SC-MIX"));
        for(int cycle=0;cycle<100&&inventoryValueWork.runBatch()>0;cycle++){ }
        assertEquals(2,count("select count(*) from procurement_iqc_stock_in_batch_items where batch_id=?",stored.batchId()),
                "同次确认按原回厂批拆实物成本来源，不能把两批成本互借");
        assertEquals(2,count("select count(*) from subcontract_receipt_material_consumptions where receipt_item_id in (select id from subcontract_receipt_items where receipt_id in (?,?))",originals.get(0),originals.get(1)));
        assertEquals(0,count("select count(*) from subcontract_receipt_material_consumptions where receipt_item_id in (select id from subcontract_receipt_items where receipt_id=?)",replacement),"免费补回不再领用公司材料");
        assertEquals(0,stockBalance(w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("20")));
        assertEquals(0,bigDecimalFor("select amount_local from stock_balances where warehouse_id=? and goods_id=?",w.warehouseId(),w.goodsE()).compareTo(new BigDecimal("400")));
    }

    private UUID receiveSubcontractIntoQuarantine(World w,UUID item,UUID unit,String qty) {
        var request=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(subcontractOrderSettlementMethodOf(item));
        var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
        line.setOrderItemId(item);line.setGoodsId(w.goodsE());line.setUnitId(unit);line.setUnitRate(new BigDecimal("2"));
        line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));line.setAmountLocal(line.getAmountOriginal());request.setItems(List.of(line));
        UUID receipt=subcontractReceiptService.create(request).getId();subcontractReceiptService.approve(receipt);return receipt;
    }

    private UUID awaitIqcRejection(String type,UUID receiptId) {
        long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(20);
        do {
            businessOutboxProcessor.processNext();
            var cases=jdbc.queryForList("select id from procurement_iqc_rejection_cases where receipt_type=? and receipt_id=?",UUID.class,type,receiptId);
            int pending=count("""
                    select count(*) from business_outbox event join procurement_inspection_items inspection on inspection.id=event.aggregate_id
                    where event.event_type='PROCUREMENT_IQC_REJECTION_DETECTED' and event.status<>1
                      and inspection.receipt_type=? and inspection.receipt_id=?
                    """,type,receiptId);
            if(cases.size()==1 && pending==0)return cases.getFirst();
            try { Thread.sleep(25); }
            catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IllegalStateException(interrupted);}
        } while(System.nanoTime()<deadline);
        throw new AssertionError("IQC事件未完成真实投影，不能用跳过异步完成的夹具继续实物退回："+receiptId);
    }

    @Test
    void materialSettlement_workshopScopeAndExplicitManagementActionsRemainSeparate() {
        World w=seedWorld("material-scope");
        receiveOpeningInputsForA(w,"10");
        UUID planId=approvedPlan(w,w.goodsA(),"10","10");
        var preview=planningPackageService.preview(planId,w.warehouseId());
        var source=preview.executionSegments().getFirst();
        var firstWorkshop=productionAssignment("material-scope-a");
        var secondWorkshop=productionAssignment("material-scope-b");
        var packageRequest=new GeneratePlanningPackageRequest();
        packageRequest.setWarehouseId(w.warehouseId());
        packageRequest.setIdempotencyKey("material-scope-package");
        packageRequest.setPreviewFingerprint(preview.fingerprint());
        packageRequest.setGeneratePurchaseRequest(false);
        var segmentRequests=new ArrayList<GeneratePlanningPackageRequest.ExecutionSegment>();
        for (var assignment:List.of(firstWorkshop,secondWorkshop)) {
            var segment=new GeneratePlanningPackageRequest.ExecutionSegment();
            segment.setClientSegmentKey("scope-"+assignment.workshopId());
            segment.setSourcePlanItemId(source.sourcePlanItemId());
            segment.setRequestedStatus("READY");
            segment.setPlannedQty(new BigDecimal("5"));
            segment.setWorkshopDepartmentId(assignment.workshopId());
            segment.setResponsibleEmployeeId(assignment.workerId());
            segment.setPlanBeginDate(LocalDate.of(2026,1,20));
            segment.setPlanEndDate(LocalDate.of(2026,1,31));
            segment.setBomFingerprint(source.bomFingerprint());
            segmentRequests.add(segment);
        }
        packageRequest.setSegments(segmentRequests);
        var issued=planningPackageService.confirm(planId,packageRequest);
        for(var draw:issued.drawDocuments()) stockDocService.approveAndIssue(draw.requestId(),
                drawIssueRequest(draw.requestId(),"scope-issue-"+draw.requestId(),null,BigDecimal.ZERO));
        for (var segment:executionSegmentService.list(planId)) executionSegmentService.start(planId,segment.id(),
                new SegmentTransitionRequest(segment.lockVersion(),"scope-start-"+segment.id()));
        UUID ownSegment=issued.executionSegments().stream().filter(s -> s.workshopDepartmentId().equals(firstWorkshop.workshopId()))
                .findFirst().orElseThrow().segmentId();
        UUID otherSegment=issued.executionSegments().stream().filter(s -> s.workshopDepartmentId().equals(secondWorkshop.workshopId()))
                .findFirst().orElseThrow().segmentId();
        UUID otherDemand=jdbc.queryForObject("select id from production_material_demands where execution_segment_id=? and goods_id=?",
                UUID.class,otherSegment,w.goodsB());
        UUID unrelatedPlan=approvedPlan(w,w.goodsA(),"10","10");
        UUID worker=createUserWithPerms(w,"material-worker","production_execution:view","production_material:settle",
                "production_material:reverse","production_material:close");
        UUID workerEmployee=jdbc.queryForObject("select employee_id from users where id=?",UUID.class,worker);
        jdbc.update("update employees set department_id=? where id=?",firstWorkshop.workshopId(),workerEmployee);
        // The seeded DEPT_PROD workshop inherits a legacy view-all grant. This actor is explicitly
        // the ordinary scoped worker; a separate supervisor below covers the real view-all branch.
        jdbc.update("""
                insert into user_permission_overrides(user_id,permission_id,effect)
                select ?,id,'revoke' from permissions where code='production_plan:view:all'
                on conflict(user_id,permission_id) do update set effect='revoke'
                """,worker);
        loginAs(worker);
        var ownRows=materialSettlementService.clearance(planId);
        assertEquals(2,ownRows.size());
        assertTrue(ownRows.stream().allMatch(row -> ownSegment.equals(row.executionSegmentId())));
        assertTrue(materialSettlementService.capabilities(planId,ownSegment).canSettle());
        assertFalse(materialSettlementService.capabilities(planId,ownSegment).canClose());
        assertFalse(materialSettlementService.capabilities(planId,null).canSettle(),"整计划入口不能把单段权限放大");
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,() -> materialSettlementService.clearance(planId,otherSegment)).getCode());
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,() -> materialSettlementService.settlementSources(planId,otherSegment)).getCode());
        UUID ownDemand=ownRows.stream().filter(row -> row.goodsId().equals(w.goodsB())).findFirst().orElseThrow().demandId();
        var ownLine=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        ownLine.setDemandId(ownDemand); ownLine.setSettlementType("CONSUMED"); ownLine.setQtyBase(BigDecimal.ONE);
        var otherLine=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        otherLine.setDemandId(otherDemand); otherLine.setSettlementType("CONSUMED"); otherLine.setQtyBase(BigDecimal.ONE);
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        request.setIdempotencyKey("material-scope-mixed"); request.setReason("车间实际用料");
        request.setLines(List.of(ownLine,otherLine));
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> materialSettlementService.post(planId,request,worker)).getCode());
        assertEquals(0,count("select count(*) from production_material_settlement_events where plan_id=?",planId),"混入其他车间需求必须整体拒绝");
        request.setLines(List.of(ownLine));
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> materialSettlementService.post(unrelatedPlan,request,worker)).getCode());
        assertEquals(0,count("select count(*) from production_material_settlement_events where plan_id=?",unrelatedPlan));
        request.setExecutionSegmentId(otherSegment);
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> materialSettlementService.post(planId,request,worker)).getCode());
        request.setExecutionSegmentId(ownSegment); request.setIdempotencyKey("material-scope-own");
        var posted=materialSettlementService.post(planId,request,worker);
        assertTrue(posted.stream().allMatch(row -> ownSegment.equals(row.executionSegmentId())));
        materialSettlementService.post(planId,request,worker);
        assertEquals(1,count("select count(*) from production_material_settlement_events where plan_id=?",planId));
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> materialSettlementService.close(planId)).getCode(),
                "只有本执行段操作权不能关闭整个计划");
        UUID posting=materialSettlementService.settlementSources(planId,ownSegment).getFirst().postingId();
        var reversal=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        reversal.setExecutionSegmentId(ownSegment); reversal.setIdempotencyKey("material-scope-reverse"); reversal.setReason("修正实际用料记录");
        var reverseLine=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        reverseLine.setDemandId(ownDemand); reverseLine.setSettlementType("CONSUMED"); reverseLine.setQtyBase(BigDecimal.ONE); reverseLine.setSourcePostingId(posting);
        reversal.setLines(List.of(reverseLine));
        materialSettlementService.reverse(planId,reversal,worker);
        UUID supervisor=createUserWithPerms(w,"material-manageall","production_plan:view","production_plan:view:all",
                "production_material:settle","production_material:reverse","production_material:close");
        loginAs(supervisor);
        assertEquals(4,materialSettlementService.clearance(planId).size(),"view-all保留读全部材料的能力");
        assertTrue(materialSettlementService.capabilities(planId,null).canSettle());
        assertTrue(materialSettlementService.capabilities(planId,null).canReverse());
        assertTrue(materialSettlementService.capabilities(planId,null).canClose());
        var managedRequest=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        managedRequest.setIdempotencyKey("material-scope-manager-post");
        managedRequest.setReason("获授权的全量管理人核实另一车间用料"); managedRequest.setLines(List.of(otherLine));
        assertEquals(4,materialSettlementService.post(planId,managedRequest,supervisor).size());
        UUID managedPosting=materialSettlementService.settlementSources(planId).getFirst().postingId();
        var managedReverse=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        managedReverse.setIdempotencyKey("material-scope-manager-reverse"); managedReverse.setReason("核对后冲销");
        var managedReverseLine=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        managedReverseLine.setDemandId(otherDemand); managedReverseLine.setSettlementType("CONSUMED");
        managedReverseLine.setQtyBase(BigDecimal.ONE); managedReverseLine.setSourcePostingId(managedPosting);
        managedReverse.setLines(List.of(managedReverseLine));
        materialSettlementService.reverse(planId,managedReverse,supervisor);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> materialSettlementService.close(planId)).getCode(),
                "全量管理范围叠加close动作通过鉴权，但仍不得绕过成品未入库的实物守卫");
        UUID reader=createUserWithPerms(w,"material-readall","production_plan:view","production_plan:view:all");
        UUID sharedReader=createUserWithPerms(w,"material-shared","production_plan:view",
                "production_material:settle","production_material:reverse","production_material:close");
        grantDataScope(sharedReader,"production_plan",w.employeeId());
        for (UUID readOnlyUser:List.of(reader,sharedReader)) {
            loginAs(readOnlyUser);
            assertEquals(4,materialSettlementService.clearance(planId).size());
            assertFalse(materialSettlementService.capabilities(planId,null).canSettle());
            assertFalse(materialSettlementService.capabilities(planId,null).canReverse());
            assertFalse(materialSettlementService.capabilities(planId,null).canClose());
            assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                    () -> materialSettlementService.post(planId,managedRequest,readOnlyUser)).getCode(),
                    "只有全量读范围但无动作，或只有手工共享加动作，均不能借旧幂等键写入");
            assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                    () -> materialSettlementService.reverse(planId,managedReverse,readOnlyUser)).getCode());
            assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> materialSettlementService.close(planId)).getCode());
        }
        // Replayed commands re-check the live assignment; an old key cannot retain transferred task rights.
        jdbc.update("update employees set department_id=? where id=?",w.departmentId(),workerEmployee);
        loginAs(worker);
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> materialSettlementService.post(planId,request,worker)).getCode());
        assertEquals(4,count("select count(*) from production_material_settlement_events where plan_id=?",planId),
                "仅两次获授权实耗与其对应冲销各产生一笔事件");
    }

    UUID createUserWithPerms(World w, String tag, String... permCodes) {
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
    void seedChartOfAccounts() {
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

    /** Explicit compatibility-plan fixture with real opening inputs, DRAW issue, START and FINISHED_IN.
     * New planning-chain acceptance starts at material analysis in its own scenarios. */
    private record Production(UUID orderItemId, UUID planItemId, UUID finishedInId) {}

    private record ProductionAssignment(UUID workshopId, UUID workerId) {}

    private Production produceFinishedFromOpeningInputs(World w, UUID goodsId, String orderQty, String planQty) {
        assertEquals(w.goodsA(),goodsId,"This fixture explicitly supplies B2+E1 for seeded product A only");
        loginAs(w.superAdminUserId());
        receiveOpeningInputsForA(w,planQty);
        UUID planId = approvedPlan(w, goodsId, orderQty, planQty);
        issueReadyPlanAndMaterials(w,planId);
        UUID planItemId = planItemIdFor(planId, goodsId);
        UUID orderItemId = orderItemIdOfPlan(planId);
        UUID reportId = reportAndApprove(w, planItemId, orderItemId, goodsId, planQty);
        UUID finishedInId = finishedInDocForReport(reportId);
        confirmFinishedInboundFully(finishedInId);
        return new Production(orderItemId, planItemId, finishedInId);
    }

    @Autowired private com.uten.imp.features.stock.valuation.InventoryValueWorkService inventoryValueWork;
    @Autowired private org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate inventoryValueJdbc;
    @Autowired private com.uten.imp.features.stock.InventoryMutationLock inventoryCostLock;
    @Autowired private com.uten.imp.features.stock.valuation.InventoryBusinessValueSupport inventoryCostSupport;
    @Autowired private com.uten.imp.features.stock.valuation.ProductionInventoryValueService productionInventoryValues;
    @Autowired private com.uten.imp.features.stock.valuation.SubcontractOwnMaterialCostService subcontractInventoryValues;

    private void drainCostsWithFreshRunnerWithoutSession(){
        var values=new com.uten.imp.features.stock.valuation.InventoryValuationService(inventoryValueJdbc,inventoryCostLock);
        var production=new com.uten.imp.features.stock.valuation.InventoryProductionCostService(inventoryValueJdbc,inventoryCostLock,values);
        var fresh=new com.uten.imp.features.stock.valuation.InventoryValueWorkService(values,production,inventoryCostLock,transactionManager);
        fresh.configureSourceRecalculations(inventoryValueJdbc,inventoryCostSupport,productionInventoryValues,subcontractInventoryValues);
        var operator=SecurityContextHolder.getContext();SecurityContextHolder.clearContext();
        try{for(int i=0;i<100&&fresh.runBatch()>0;i++) { }}finally{SecurityContextHolder.setContext(operator);}
    }

    @Test
    void finalReportTargetChangeRepricesExistingOutputThroughPersistedWork(){
        World w=seedWorld("actual-cost-target");loginAs(w.superAdminUserId());receiveOpeningInputsForA(w,"20");
        UUID plan=approvedPlan(w,w.goodsA(),"20","20");issueReadyPlanAndMaterials(w,plan);
        UUID planItem=planItemIdFor(plan,w.goodsA()),orderItem=orderItemIdOfPlan(plan);
        UUID firstReport=reportAndApprove(w,planItem,orderItem,w.goodsA(),"5");confirmFinishedInboundFully(finishedInDocForReport(firstReport));
        var consumption=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        consumption.setIdempotencyKey("actual-target-consumption-"+plan);consumption.setReason("实际确认整批材料耗用");
        var lines=new ArrayList<com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line>();
        for(var demand:jdbc.queryForList("SELECT id,required_qty FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",plan)){
            var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();line.setDemandId((UUID)demand.get("id"));
            line.setSettlementType("CONSUMED");line.setQtyBase((BigDecimal)demand.get("required_qty"));lines.add(line);
        }
        consumption.setLines(lines);materialSettlementService.post(plan,consumption,w.superAdminUserId());drainCostsWithFreshRunnerWithoutSession();
        assertEquals(0,bigDecimalFor("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("150")));
        StartedSegment segment=startedSegmentFor(w,plan,planItem,orderItem);
        UUID finalReport=reportAndApproveExecutionSegment(w,planItem,orderItem,w.goodsA(),segment.segmentId(),segment.salesAllocationId(),"5",true);
        assertEquals(0,bigDecimalFor("SELECT planned_qty FROM production_execution_segments WHERE id=?",segment.segmentId()).compareTo(BigDecimal.TEN));
        assertTrue(Boolean.TRUE.equals(jdbc.queryForObject("SELECT business_refresh_pending FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Boolean.class,segment.segmentId())));
        drainCostsWithFreshRunnerWithoutSession();
        assertEquals(0,bigDecimalFor("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("300")),
                "The existing five outputs are repriced by the approved ten-unit target before the next physical inbound");
        assertEquals(1,count("SELECT count(*) FROM stock_value_production_cost_revisions WHERE execution_segment_id=? AND source_doc_type='PRODUCTION_TARGET_REPORT' AND source_item_id=?",segment.segmentId(),finalReport));
        confirmFinishedInboundFully(finishedInDocForReport(finalReport));drainCostsWithFreshRunnerWithoutSession();
        assertEquals(0,bigDecimalFor("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("600")));
        assertEquals(0,bigDecimalFor("SELECT material_snapshot_product_qty FROM production_execution_segments WHERE id=?",segment.segmentId()).compareTo(new BigDecimal("20")));
        assertDatabaseGuardRejects(()->jdbc.update("UPDATE production_execution_segments SET material_snapshot_product_qty=10 WHERE id=?",segment.segmentId()));
        assertDatabaseGuardRejects(()->{
            jdbc.execute("SET LOCAL session_replication_role=replica");
            jdbc.queryForObject("SELECT set_config('app.cap_segment_allocations','on',true)",String.class);
            jdbc.queryForObject("SELECT set_config('app.cap_segment_report_id',?,true)",String.class,finalReport.toString());
            jdbc.update("UPDATE production_execution_segments SET planned_qty=9 WHERE id=?",segment.segmentId());
        });
    }

    @Test
    void finalReportDoesNotCapAwayFailedPhysicalOutputOrAllocateItsHeldCostToGoodStock(){
        World w=seedWorld("actual-cost-bad-output");loginAs(w.superAdminUserId());receiveOpeningInputsForA(w,"20");
        UUID plan=approvedPlan(w,w.goodsA(),"20","20");issueReadyPlanAndMaterials(w,plan);
        UUID planItem=planItemIdFor(plan,w.goodsA()),orderItem=orderItemIdOfPlan(plan);
        StartedSegment segment=startedSegmentFor(w,plan,planItem,orderItem);
        UUID first=reportAndApproveExecutionSegment(w,planItem,orderItem,w.goodsA(),segment.segmentId(),segment.salesAllocationId(),"10",false,"5");
        confirmFinishedInboundFully(finishedInDocForReport(first));
        UUID second=reportAndApproveExecutionSegment(w,planItem,orderItem,w.goodsA(),segment.segmentId(),segment.salesAllocationId(),"10",true,"5");
        confirmFinishedInboundFully(finishedInDocForReport(second));
        assertEquals(0,bigDecimalFor("SELECT planned_qty FROM production_execution_segments WHERE id=?",segment.segmentId()).compareTo(new BigDecimal("20")),
                "The ten failed units are produced units; final reporting cannot silently cancel their cost basis");
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        request.setIdempotencyKey("actual-bad-consumption-"+plan);request.setReason("实际确认20件产出所耗材料，10件不良成本待处置");
        var lines=new ArrayList<com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line>();
        for(var demand:jdbc.queryForList("SELECT id,required_qty FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",plan)){
            var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();line.setDemandId((UUID)demand.get("id"));
            line.setSettlementType("CONSUMED");line.setQtyBase((BigDecimal)demand.get("required_qty"));lines.add(line);
        }
        request.setLines(lines);materialSettlementService.post(plan,request,w.superAdminUserId());drainCostsWithFreshRunnerWithoutSession();
        assertEquals(0,bigDecimalFor("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsA()).compareTo(new BigDecimal("300")));
        assertEquals(0,bigDecimalFor("SELECT sum(owned_value_local) FROM stock_value_nodes WHERE owner_kind='COST_WIP' AND owner_id=?",segment.segmentId()).compareTo(new BigDecimal("300")));
        assertEquals(0,count("SELECT count(*) FROM stock_value_production_cost_objects WHERE execution_segment_id=? AND state='FINAL'",segment.segmentId()));
    }

    @Test
    void actualMovingAverageCostIgnoresSalesPriceAndConfirmedConsumptionReachesSoldGoods() {
        World w=seedWorld("actual-cost-600");
        Production made=produceFinishedFromOpeningInputs(w,w.goodsA(),"20","20");
        UUID plan=jdbc.queryForObject("SELECT plan_id FROM production_plan_items WHERE id=?",UUID.class,made.planItemId());
        assertEquals(0,bigDecimalFor("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
        UUID shipment=createShipment(w,made.orderItemId(),w.goodsA(),"20");
        shipThroughWarehouse(shipment);
        assertEquals(0,bigDecimalFor("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO),
                "Sales price 2000 cannot subtract from the pending inventory cost");
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        request.setIdempotencyKey("actual-consume-600-"+plan);request.setReason("实际确认B40和E20全部耗用");
        var lines=new ArrayList<com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line>();
        for(var demand:jdbc.queryForList("SELECT id,required_qty FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",plan)){
            var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
            line.setDemandId((UUID)demand.get("id"));line.setSettlementType("CONSUMED");line.setQtyBase((BigDecimal)demand.get("required_qty"));lines.add(line);
        }
        request.setLines(lines);materialSettlementService.post(plan,request,w.superAdminUserId());
        var operatorContext=SecurityContextHolder.getContext();
        SecurityContextHolder.clearContext();
        try {
            for(int i=0;i<100&&inventoryValueWork.runBatch()>0;i++) { }
        } finally {
            SecurityContextHolder.setContext(operatorContext);
        }
        assertEquals(0,bigDecimalFor("""
                SELECT SUM(n.owned_value_local) FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id
                WHERE p.goods_id=? AND n.owner_kind='COGS'
                """,w.goodsA()).compareTo(new BigDecimal("600")));
        assertEquals(0,bigDecimalFor("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsA()).compareTo(BigDecimal.ZERO));
        assertEquals(0,count("SELECT COUNT(*) FROM production_material_settlement_postings WHERE demand_id IN(SELECT id FROM production_material_demands WHERE plan_id=?) AND issue_posting_id IS NULL",plan));
        var original=jdbc.queryForMap("""
                SELECT posting.id,posting.demand_id,posting.issue_posting_id FROM production_material_settlement_postings posting
                JOIN production_material_demands demand ON demand.id=posting.demand_id
                WHERE demand.plan_id=? AND demand.goods_id=? AND posting.source_posting_id IS NULL
                """,plan,w.goodsB());
        int expectedCogs=600;
        for(String restoredQty:List.of("10","10","20")){
            var reverse=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
            reverse.setIdempotencyKey("actual-cost-return-"+UUID.randomUUID());reverse.setReason("核实未耗用材料，按原领料来源纠正实耗");
            var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
            line.setDemandId((UUID)original.get("demand_id"));line.setSourcePostingId((UUID)original.get("id"));
            line.setSettlementType("CONSUMED");line.setQtyBase(new BigDecimal(restoredQty));reverse.setLines(List.of(line));
            materialSettlementService.reverse(plan,reverse,w.superAdminUserId());
            assertTrue(bigDecimalFor("""
                    SELECT coalesce(sum(least(node.owned_value_local,0)),0) FROM stock_value_nodes node
                    JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COST_WIP'
                    """,w.goodsB()).signum()<0,"Allocated correction remains visible as pending reallocation until the worker completes");
            operatorContext=SecurityContextHolder.getContext();SecurityContextHolder.clearContext();
            try{for(int i=0;i<100&&inventoryValueWork.runBatch()>0;i++) { }}finally{SecurityContextHolder.setContext(operatorContext);}
            expectedCogs-=Integer.parseInt(restoredQty)*10;
            assertEquals(0,bigDecimalFor("SELECT sum(node.owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COGS'",w.goodsA())
                    .compareTo(BigDecimal.valueOf(expectedCogs)));
        }
        assertEquals(0,bigDecimalFor("SELECT sum(node.owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='WIP'",w.goodsB())
                .compareTo(new BigDecimal("400")));
        assertEquals(0,count("SELECT count(*) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id IN(?,?,?) AND (SELECT count(*) FROM stock_value_edges edge WHERE edge.parent_node_id=node.id)>2",w.goodsA(),w.goodsB(),w.goodsE()));
        assertEquals(0,count("SELECT count(*) FROM stock_value_production_cost_objects object JOIN production_execution_segments segment ON segment.id=object.execution_segment_id WHERE segment.plan_id=? AND object.state='FINAL'",plan));
        assertEquals(0,bigDecimalFor("SELECT sum(source_amount_exact) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.kind='SOURCE'",w.goodsB()).compareTo(new BigDecimal("400")));
        assertDatabaseGuardRejects(()->{
            jdbc.execute("SET LOCAL session_replication_role=replica");
            jdbc.update("UPDATE stock_value_nodes SET returned_consumption_qty=returned_consumption_qty-1 WHERE owner_kind='COST_WIP' AND returned_consumption_qty>0 AND pool_id IN(SELECT id FROM stock_value_pools WHERE goods_id=?)",w.goodsB());
        });
    }

    private void assertDatabaseGuardRejects(Runnable mutation){
        RuntimeException rejected=assertThrows(RuntimeException.class,()->new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                .executeWithoutResult(status->mutation.run()));
        Throwable cause=rejected;while(cause.getCause()!=null)cause=cause.getCause();
        assertTrue(cause instanceof java.sql.SQLException,"The database must reject the mutation");
        assertTrue(java.util.Set.of("23514","55000").contains(((java.sql.SQLException)cause).getSQLState()),"A domain guard must reject it, not an unrelated fixture error");
    }

    /** Known opening inventory is a fixture input, recorded through the real warehouse service. */
    private void receiveOpeningInputsForA(World w, String plannedOutput) {
        loginAs(w.superAdminUserId());
        var request = new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(LocalDate.of(2026,1,1));
        request.setWarehouseId(w.warehouseId());
        request.setRemark("Explicit test opening inputs: B2 and E1 per product A");
        List<com.uten.imp.features.stock.dto.StockDocItemLine> lines = new ArrayList<>();
        for (var input : Map.of(w.goodsB(),new BigDecimal("2"),w.goodsE(),BigDecimal.ONE).entrySet()) {
            var line = new com.uten.imp.features.stock.dto.StockDocItemLine();
            line.setGoodsId(input.getKey());
            line.setUnitId(w.unitId());
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(new BigDecimal(plannedOutput).multiply(input.getValue()));
            line.setPrice(new BigDecimal("10"));
            line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
            line.setAmountLocal(line.getAmountOriginal());
            lines.add(line);
        }
        request.setItems(lines);
        var opening = stockDocService.create(request);
        stockDocService.approve(opening.getId());
    }

    /** Explicitly issue a compatibility plan using the existing hard BOM and actual opening stock. */
    private void issueReadyPlanAndMaterials(World w, UUID planId) {
        loginAs(w.superAdminUserId());
        PlanningPreviewResult preview = planningPackageService.preview(planId,w.warehouseId());
        GeneratePlanningPackageRequest request = new GeneratePlanningPackageRequest();
        request.setWarehouseId(w.warehouseId());
        request.setIdempotencyKey("explicit-fixture-issue-"+planId);
        request.setPreviewFingerprint(preview.fingerprint());
        request.setGeneratePurchaseRequest(false);
        PlanningPackageResult issued = planningPackageService.confirm(planId,request);
        assertFalse(issued.executionSegments().isEmpty());
        assertTrue(issued.executionSegments().stream().allMatch(segment -> "READY".equals(segment.status())),
                "Fixture opening inputs must really cover the plan; never bypass WAITING");
        for (var draw : issued.drawDocuments()) {
            stockDocService.approveAndIssue(draw.requestId(),drawIssueRequest(draw.requestId(),
                    "explicit-fixture-draw-"+draw.requestId(),null,BigDecimal.ZERO));
        }
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

    private void confirmShipmentFinance(UUID shipmentId) {
        var claim=reviewClaims.claim("SALES_SHIPMENT_FINANCE_AUDIT",shipmentId.toString());
        var info=shipmentService.financeAuditInfo(shipmentId);
        shipmentService.financeAudit(shipmentId,new com.uten.imp.features.sales.shipment.dto.ShipmentFinanceDecisionRequest(
                ((Number)info.get("reviewRevision")).longValue(),info.get("contentHash").toString(),claim.claimId(),null));
    }
    /** Warehouse drives the full pick→pack→ship lifecycle (PENDING_PICK→PICKING→PICKED→SHIPPED). */
    private void shipThroughWarehouse(UUID shipmentId) {
        confirmShipmentFinance(shipmentId);
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
    private record StartedSegment(UUID segmentId, UUID salesAllocationId) {}

    /**
     * Start an already-issued execution segment through the real service. Missing segments or
     * materials are fixture errors: this helper never creates a package, changes a BOM, or seeds stock.
     * A complete saved assignment is retained; repeated reporting reuses the started segment.
     */
    private StartedSegment startedSegmentFor(World w, UUID planId, UUID planItemId, UUID orderItemId) {
        UUID segmentId = jdbc.query("""
                select id from production_execution_segments
                where plan_id = ? and source_plan_item_id = ? and is_deleted = false
                order by created_at
                """, (rs, i) -> rs.getObject("id", UUID.class), planId, planItemId)
                .stream().findFirst().orElse(null);
        assertNotNull(segmentId,"Explicitly issue the real plan and its materials before starting production");
        UUID salesAllocationId = salesAllocationOf(segmentId, orderItemId);

        String status = jdbc.queryForObject(
                "select status from production_execution_segments where id = ?",
                String.class, segmentId);
        if (!"IN_PROGRESS".equals(status)) {
            final UUID startedSegmentId = segmentId;
            ExecutionSegmentView current = executionSegmentService.list(planId)
                    .stream()
                    .filter(segment -> segment.id().equals(startedSegmentId))
                    .findFirst()
                    .orElseThrow();
            assertTrue(List.of("READY","DISPATCHED").contains(current.status()),
                    "Waiting material cannot be turned into a started fixture");
            if (current.workshopDepartmentId()==null || current.responsibleEmployeeId()==null) {
                ProductionAssignment assignment = productionAssignment("e2e-" + planId);
                current = executionSegmentService.assign(planId,startedSegmentId,
                        new SegmentAssignmentRequest(current.lockVersion(),"e2e-assign-"+startedSegmentId,
                                assignment.workshopId(),null,assignment.workerId(),
                                LocalDate.of(2026,1,20),LocalDate.of(2026,1,31)));
            }
            executionSegmentService.start(
                    planId, startedSegmentId,
                    new SegmentTransitionRequest(
                            current.lockVersion(),
                            "e2e-start-" + startedSegmentId));
        }
        return new StartedSegment(segmentId, salesAllocationId);
    }

    private UUID salesAllocationOf(UUID segmentId, UUID orderItemId) {
        if (orderItemId == null) {
            return null;
        }
        return jdbc.query("""
                select id from execution_segment_sales_allocations
                where execution_segment_id = ? and sales_order_item_id = ?
                """, (rs, i) -> rs.getObject("id", UUID.class), segmentId, orderItemId)
                .stream().findFirst().orElse(null);
    }

    private UUID reportAndApprove(World w, UUID planItemId, UUID orderItemId,
                                  UUID goodsId, String qty) {
        UUID planId = jdbc.queryForObject(
                "select plan_id from production_plan_items where id = ?", UUID.class, planItemId);
        StartedSegment segment = startedSegmentFor(w, planId, planItemId, orderItemId);
        return reportAndApproveExecutionSegment(
                w, planItemId, orderItemId, goodsId,
                segment.segmentId(), segment.salesAllocationId(), qty);
    }

    private UUID reportAndApproveExecutionSegment(
            World w,
            UUID planItemId,
            UUID orderItemId,
            UUID goodsId,
            UUID executionSegmentId,
            UUID salesAllocationId,
            String qty) {
        return reportAndApproveExecutionSegment(w,planItemId,orderItemId,goodsId,executionSegmentId,salesAllocationId,qty,false);
    }

    private UUID reportAndApproveExecutionSegment(World w,UUID planItemId,UUID orderItemId,UUID goodsId,
            UUID executionSegmentId,UUID salesAllocationId,String qty,boolean finalReport) {
        return reportAndApproveExecutionSegment(w,planItemId,orderItemId,goodsId,executionSegmentId,salesAllocationId,qty,finalReport,"0");
    }

    private UUID reportAndApproveExecutionSegment(World w,UUID planItemId,UUID orderItemId,UUID goodsId,
            UUID executionSegmentId,UUID salesAllocationId,String qty,boolean finalReport,String failedQty) {
        return reportAndApproveExecutionSegment(w,planItemId,orderItemId,goodsId,executionSegmentId,salesAllocationId,qty,finalReport,failedQty,null,null);
    }

    private UUID reportAndApproveExecutionSegment(World w,UUID planItemId,UUID orderItemId,UUID goodsId,
            UUID executionSegmentId,UUID salesAllocationId,String qty,boolean finalReport,String failedQty,UUID warehouseActor,UUID qualityActor) {
        Map<String, Object> segmentReportingScope = jdbc.queryForMap("""
                select workshop_department_id, responsible_employee_id
                from production_execution_segments
                where id = ? and is_deleted = false
                """, executionSegmentId);
        UUID workshopDepartmentId =
                (UUID) segmentReportingScope.get("workshop_department_id");
        UUID responsibleEmployeeId =
                (UUID) segmentReportingScope.get("responsible_employee_id");
        DailyReportSaveRequest req = new DailyReportSaveRequest();
        req.setIdempotencyKey("e2e-report-" + UUID.randomUUID());
        req.setBillDate(LocalDate.of(2026, 1, 25));
        req.setWarehouseId(w.warehouseId());
        req.setDepartmentId(workshopDepartmentId);
        req.setWorkerId(responsibleEmployeeId);
        req.setWorkerIds(List.of(responsibleEmployeeId));
        DailyReportItemLine line = new DailyReportItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPlanItemId(planItemId);
        line.setSalesOrderItemId(orderItemId);
        line.setExecutionSegmentId(executionSegmentId);
        line.setExecutionSegmentSalesAllocationId(salesAllocationId);
        line.setIsFinal(finalReport);
        req.setItems(List.of(line));
        // V470 车间任务写侧对象范围：报工操作者必须属于执行段车间（超管不豁免）。
        // E2E 用车间员工身份执行 create/approve，随后还原调用者身份。
        org.springframework.security.core.Authentication previousAuth =
                SecurityContextHolder.getContext().getAuthentication();
        UUID workshopReporter = createUserWithPerms(
                w, "wsrep-" + UUID.randomUUID().toString().substring(0, 8),
                "production_execution:view",
                "production_daily_report:create",
                "production_daily_report:edit",
                "production_daily_report:approve",
                "production_daily_report:reverse");
        jdbc.update("""
                update employees set department_id = ?
                where id = (select employee_id from users where id = ?)
                """, workshopDepartmentId, workshopReporter);
        loginAs(workshopReporter);
        DailyReportDetail report;
        try {
            report = reportService.create(req);
            reportService.approve(report.getId());
        } finally {
            SecurityContextHolder.getContext().setAuthentication(previousAuth);
        }
        assertEquals(0, count("""
                SELECT COUNT(*)
                FROM production_fqc_inspections
                WHERE source_report_id = ?
                """, report.getId()),
                "报工审核后待仓库登记，不得越过仓库直接建 FQC");
        UUID reportItemId = jdbc.queryForObject("""
                        SELECT id
                        FROM production_daily_report_items
                        WHERE report_id = ? AND is_deleted = FALSE
                        """, UUID.class, report.getId());
        if(warehouseActor!=null)loginAs(warehouseActor);
        finishedArrivalRegistrationService.register(
                report.getId(),
                new ArrivalRegistrationRequest(
                        "e2e-arrival-" + UUID.randomUUID(),
                        w.warehouseId(),
                        List.of(new ArrivalRegistrationItemRequest(
                                reportItemId, "E2E-FINISHED-01"))));
        UUID inspectionId = jdbc.queryForObject("""
                        SELECT id
                        FROM production_fqc_inspections
                        WHERE source_report_id = ?
                          AND source_report_item_id IN (
                              SELECT id
                              FROM production_daily_report_items
                              WHERE report_id = ?)
                        """, UUID.class, report.getId(), report.getId());
        BigDecimal failed=new BigDecimal(failedQty),passed=new BigDecimal(qty).subtract(failed);
        if(qualityActor!=null)loginAs(qualityActor);
        var fqc = fqcService.decide(
                inspectionId,
                new DecisionRequest(
                        failed.signum()==0?"PASS":passed.signum()==0?"FAIL":"PARTIAL",
                        passed.signum()==0?null:passed,
                        failed.signum()==0?null:failed,
                        failed.signum()==0?null:"REWORK",
                        failed.signum()==0?null:"实际不良保留待返工处置",
                        "e2e-fqc-" + UUID.randomUUID()));
        assertFalse(fqc.replay());
        assertEquals(
                0,
                fqc.inspection().authorizedInboundQty()
                        .compareTo(passed));
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

    OrderSaveRequest orderRequest(World w, UUID goodsId, String qty, String price) {
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
    void loginAs(UUID userId) {
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
    // segments are WAITING (X waits on Y, Y waits on Z; Z 最深层、仅软门禁物料 → READY).
    // Producing Z (segment report + FINISHED_IN) fires the existing V194 hook
    // (onFinishedInboundApproved) which promotes Y's WAITING segment → READY — proving the
    // orchestrator-built tree composes with the existing bottom-up auto-release ("下层完成自动释放上层").
    // V414 后报工必须引用已开工执行段（见 DailyReportExecutionSegmentGuard），无段直产路径已封死，
    // 故 Z 配软门禁 BOM 让整树确认自然为其建段。
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
        // Z 挂一个软门禁采购件 BOM：不产生需求/子计划（软门禁物料不参与展开），
        // 但让整树确认走到 Z 层为其建 ZERO_MATERIAL 执行段（V414 后报工必须有段）。
        insertBom(z, w.goodsD(), "1");
        jdbc.update("update goods_bom_items set hard_gate = false where goods_id = ?", z);
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
        // before any production: X & Y WAITING on their MAKE child; Z（最深层，仅软门禁物料）READY
        assertTrue(hasSegmentStatus(planId, "WAITING"), "X 段 WAITING(等 Y 完工)");
        assertTrue(hasSegmentStatus(yPlan, "WAITING"), "Y 段 WAITING(等 Z 完工)");
        assertTrue(hasSegmentStatus(zPlan, "READY"), "Z 段 READY(最深层，无硬门禁需求)");

        // produce Z (leaf): segment report + FINISHED_IN (no sales link)
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
        UUID planId = jdbc.queryForObject(
                "select plan_id from production_plan_items where id = ?", UUID.class, planItemId);
        // V414 后内部件报工同样必须引用已开工执行段（无销售关联 → 分摊为空）
        StartedSegment segment = startedSegmentFor(w, planId, planItemId, null);
        UUID reportId = reportAndApproveExecutionSegment(
                w, planItemId, null, goodsId,
                segment.segmentId(), null, qty);
        confirmFinishedInboundFully(finishedInDocForReport(reportId));
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


    /** 2026-09-05 顶层与子层同构：根供料路线显式确认为 MAKE 后根产品才可排产。 */
    private void confirmRootMakeRoute(UUID analysisId, AnalysisView view) {
        var product = view.products().getFirst();
        assertNotNull(product.rootMaterialLineId(), "V478 根供料节点应存在");
        MaterialView root = view.flatMaterials().stream()
                .filter(m -> m.materialLineId().equals(product.rootMaterialLineId()))
                .findFirst().orElseThrow();
        analysisService.saveRoutes(analysisId, new RouteRequest(view.version(), view.fingerprint(),
                "routes-root-" + analysisId, List.of(
                        new RouteDecision(root.materialLineId(), root.actionGroupKey(), "MAKE", null))));
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
    World seedWorld(String tag) {
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
        jdbc.update("insert into clients(id, code, name, status, code_sequence, sales_payment_type) "
                        + "values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from clients), 'CASH')",
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

    void insertGoods(UUID id, String code, String name, String sourceType,
                             UUID unitId, int unitLegacy) {
        jdbc.update("insert into goods(id, code, name, source_type, status, unit_id, unit_legacy_id, price, code_sequence) "
                        + "values (?, ?, ?, ?, '使用', ?, ?, 100, "
                        + "(select coalesce(max(code_sequence), 0) + 1 from goods))",
                id, code, name, sourceType, unitId, unitLegacy);
    }

    private UUID insertScopedClient(
            UUID categoryId, UUID ownerEmployeeId, String code, boolean deleted) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into clients(
                    id,category_id,code,name,status,code_sequence,owner_employee_id,
                    is_deleted,sales_payment_type)
                values (?,?,?,?,'使用',
                    (select coalesce(max(code_sequence),0)+1 from clients),?,?,'CASH')
                """, id, categoryId, code, "客户-" + code, ownerEmployeeId, deleted);
        return id;
    }

    private static com.uten.imp.features.master.client.dto.ClientQueryFilter clientFilter(
            UUID categoryId, boolean excludeLegacyFinanceStub) {
        return new com.uten.imp.features.master.client.dto.ClientQueryFilter(
                categoryId, null, java.util.Set.of(),
                null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null,
                null, null, null, null, null,
                excludeLegacyFinanceStub,
                false);
    }

    void insertBom(UUID parent, UUID component, String qty) {
        jdbc.update("insert into goods_bom_items(goods_id, component_goods_id, qty) values (?, ?, ?)",
                parent, component, new java.math.BigDecimal(qty));
    }

    /** Holds the IDs of a seeded world so later chain steps can reference them. */
    record World(
            UUID departmentId,
            UUID employeeId,
            UUID superAdminUserId,
            UUID goodsA, UUID goodsB, UUID goodsC, UUID goodsD, UUID goodsE,
            UUID clientId, UUID supplierId, UUID warehouseId,
            UUID unitId, UUID currencyId, UUID colorId,
            int unitLegacy) {}
}
