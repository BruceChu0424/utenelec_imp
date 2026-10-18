package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WorkbenchBadgeReadPort;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import com.uten.imp.features.admin.serveroperations.HostOperationsClient;
import com.uten.imp.features.admin.serveroperations.HostOperationsException;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.notice.ServerStatusAlertScheduler;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/**
 * 工作台徽章汇总(GET /api/workbench/badges, ADR-108)的真库契约。
 *
 * <ol>
 *   <li>逐个来源与<b>原单项计数端点</b>比对: 同一登录身份下, 汇总里每个事实数 = 端点返回值,
 *       且「来源出现在汇总里」⇔「端点对该身份返回 200」(资格判定就是端点自己的)。</li>
 *   <li>入口口径与迁移前前端两张注册表逐条对照(本类 {@link #LEGACY_FORMULAS} 按原 Dart
 *       todo_badge_registry / in_progress_badge_registry 抄录, 不引用服务端目录, 独立成证)。</li>
 *   <li>容器 = 其入口之和, 总数 = 全部容器之和; 无权身份拿不到对应入口。</li>
 *   <li>某来源 SQL 报错时保存点隔离, 其它来源照常算出。</li>
 *   <li>未读索引摘要随读/弹窗确认变化, 与汇总里的未读事实一致。</li>
 *   <li>语句预算: 一次汇总 vs 原来逐个端点各打一遍。</li>
 * </ol>
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>, 否则本类 SKIP。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
@Import({ProductionJdbcMeasurement.Configuration.class, WorkbenchBadgeSummaryPostgresTest.BrokenSourceConfiguration.class})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = WorkbenchBadgeSummaryPostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class WorkbenchBadgeSummaryPostgresTest {

    // The comparisons deliberately make separate HTTP reads. Other cached Spring
    // contexts must not publish into this database between those reads: mocking
    // this context's scheduler alone cannot stop a scheduler in another context.
    private static final PostgreSQLContainer<?> DATABASE =
            new PostgreSQLContainer<>("postgres:16-alpine");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        DATABASE.start();
        registry.add("spring.datasource.url", DATABASE::getJdbcUrl);
        registry.add("spring.datasource.username", DATABASE::getUsername);
        registry.add("spring.datasource.password", DATABASE::getPassword);
        try {
            var attachments = java.nio.file.Files.createTempDirectory("uten-badge-attachments-");
            registry.add("uten.storage.local-dir", attachments::toString);
        } catch (java.io.IOException error) {
            throw new IllegalStateException("Cannot create badge fixture attachment directory", error);
        }
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        // afterTestClass listeners run in reverse order: close the dirty Spring
        // context (and its schedulers/connections) before stopping PostgreSQL.
        @Override public int getOrder() {
            return new DirtiesContextTestExecutionListener().getOrder() - 1;
        }
        @Override public void afterTestClass(TestContext ignored) {
            DATABASE.stop();
        }
    }

    /** 来源键 → 迁移前前端轮询的原端点。 */
    private static final Map<String, String> ORIGINAL_ENDPOINTS = new LinkedHashMap<>();

    static {
        ORIGINAL_ENDPOINTS.put("visitorApproval", "/api/visitor-approval/pending-count");
        ORIGINAL_ENDPOINTS.put("visitorHost", "/api/visitor-approval/host-pending-count");
        ORIGINAL_ENDPOINTS.put("profileReview", "/api/hr/profile-changes/pending-count");
        ORIGINAL_ENDPOINTS.put("hrTask", "/api/org/hr-tasks/count");
        ORIGINAL_ENDPOINTS.put("expense", "/api/expense-claims/counts");
        ORIGINAL_ENDPOINTS.put("salesStage", "/api/sales/orders/progress/stage-counts");
        ORIGINAL_ENDPOINTS.put("salesOrderFinance", "/api/sales/orders/finance-confirmation/count");
        ORIGINAL_ENDPOINTS.put("shipmentFinance", "/api/sales/shipments/pending-finance-count");
        ORIGINAL_ENDPOINTS.put("warehouseSalesOutbound", "/api/warehouse/sales-outbound/counts");
        // ADR-134 报价核价: 新入口, 原端点即本次新增的计数端点。
        ORIGINAL_ENDPOINTS.put("salesQuote", "/api/sales/quotes/counts");
        ORIGINAL_ENDPOINTS.put("salesQuoteFinance", "/api/sales/quotes/finance-review/count");
        ORIGINAL_ENDPOINTS.put("procurementApproval", "/api/finance/procurement-approvals/count");
        ORIGINAL_ENDPOINTS.put("iqcRejection", "/api/procurement/iqc-rejections/counts");
        ORIGINAL_ENDPOINTS.put("warehouseInboundExpectation", "/api/warehouse/inbound/expectations/count");
        ORIGINAL_ENDPOINTS.put("warehouseArrivalException", "/api/warehouse/inbound/arrival-exceptions/count");
        ORIGINAL_ENDPOINTS.put("financeArrivalException", "/api/finance/procurement-arrival-exceptions/count");
        ORIGINAL_ENDPOINTS.put("purchaseSupplierReturn", "/api/procurement/arrival-exceptions/count?orderType=PURCHASE");
        ORIGINAL_ENDPOINTS.put("subcontractSupplierReturn", "/api/procurement/arrival-exceptions/count?orderType=SUBCONTRACT");
        ORIGINAL_ENDPOINTS.put("iqcPending", "/api/procurement/inspection/pending-count");
        ORIGINAL_ENDPOINTS.put("finishedInbound", "/api/warehouse/production-finished-in/tasks/count");
        ORIGINAL_ENDPOINTS.put("qualityResult", "/api/warehouse/quality-results/type-counts");
        ORIGINAL_ENDPOINTS.put("subcontractOutbound", "/api/warehouse/subcontract-outbound/tasks/count");
        ORIGINAL_ENDPOINTS.put("productionSchedule", "/api/production/schedule/pending-count");
        ORIGINAL_ENDPOINTS.put("productionOverproductionRate", "/api/production/overproduction-rate/count");
        ORIGINAL_ENDPOINTS.put("productionOverLimitPending", "/api/production/over-limit-dispositions/count");
        ORIGINAL_ENDPOINTS.put("productionMaterialIncrement", "/api/production/material-increments/count");
        // ADR-117 车间催计划: 新入口, 没有迁移前的旧口径, 原端点即本次新增的计数端点。
        ORIGINAL_ENDPOINTS.put("productionPlanningUrge", "/api/production/material-analyses/workshop-urges/count");
        ORIGINAL_ENDPOINTS.put("workshopTask", "/api/production/workshop-tasks/count");
        ORIGINAL_ENDPOINTS.put("productionExecution", "/api/production/execution-workbench/count");
        ORIGINAL_ENDPOINTS.put("fqcPending", "/api/production/quality-inspections/count");
        ORIGINAL_ENDPOINTS.put("rdTask", "/api/rd-tasks/count");
        ORIGINAL_ENDPOINTS.put("purchaseTask", "/api/operations/workbench/purchase/count");
        ORIGINAL_ENDPOINTS.put("subcontractTask", "/api/operations/workbench/subcontract/count");
        // ADR-143 委外领料: 新事实 subcontractDraw.drawable, 没有迁移前的旧口径, 原端点即本次新增的计数端点。
        ORIGINAL_ENDPOINTS.put("subcontractDraw", "/api/subcontract/draw-tasks/count");
        ORIGINAL_ENDPOINTS.put("productionDraw", "/api/operations/workbench/warehouse/count");
        ORIGINAL_ENDPOINTS.put("productionReturn", "/api/stock/production-materials/return-requests/warehouse/count");
        ORIGINAL_ENDPOINTS.put("drafts", "/api/documents/drafts/count");
        ORIGINAL_ENDPOINTS.put("financeExpenseConfirmation", "/api/finance/expenses/gl-confirmation-count");
        ORIGINAL_ENDPOINTS.put("financeRejected", "/api/documents/finance-rejected/count");
        ORIGINAL_ENDPOINTS.put("subcontractShortDelivery", "/api/subcontract/short-deliveries/count");
        // ADR-131 车间内料仓: 新入口, 没有迁移前的旧口径, 原端点即本次新增的计数端点。
        ORIGINAL_ENDPOINTS.put("workshopMaterial", "/api/workshop-material/badge-counts");
        ORIGINAL_ENDPOINTS.put("serverStatus", "/api/admin/server-status");
        // Manual server operations is a registered source, independently gated by its real status endpoint.
        ORIGINAL_ENDPOINTS.put("serverOperations", "/api/admin/server-operations/status");
        ORIGINAL_ENDPOINTS.put("stockCountFinance", "/api/stock/count-review-badges/finance");
        ORIGINAL_ENDPOINTS.put("stockCountWarehouse", "/api/stock/count-review-badges/warehouse");
        ORIGINAL_ENDPOINTS.put("notices", "/api/notices/unread-index");
    }

    /**
     * 迁移前前端注册表的入口口径(红 | 黄 两组事实数之和), 逐条抄自原 Dart 代码:
     * todo_badge_registry.todoEntryCount 与 in_progress_badge_registry.inProgressEntryCount。
     * 合并说明: 我的访客/访客审批/我的报销的红黄两枚原来分属两个枚举值, 现为同一入口的两个数;
     * 业务审核中心原来是 FinanceAuditCenterBadge 对五个入口求和; 仓库三张任务中心卡原来是
     * Warehouse*TaskBadge 对各自来源求和; 车间任务原来在生产模块内,
     * 现单列 workshop 容器(工作台生产管理卡本来就不含它)。
     */
    private static final Map<String, List<List<String>>> LEGACY_FORMULAS = new LinkedHashMap<>();

    static {
        legacy("visitorHost", List.of("visitorHost.pending"), List.of("visitorHost.ongoing"));
        legacy("visitorApproval", List.of("visitorApproval.pending"), List.of("visitorApproval.ongoing"));
        legacy("hrProfileReview", List.of("profileReview.count"), List.of());
        legacy("hrTaskCenter", List.of("hrTask.count"), List.of());
        legacy("expenseMine", List.of("expense.draftCount", "expense.rejectedCount"), List.of("expense.processingCount"));
        legacy("financeAuditCenter", List.of("salesOrderFinance.count", "shipmentFinance.count",
                "procurementApproval.count", "financeArrivalException.count",
                "iqcRejection.open"), List.of());
        legacy("financeQuoteReview", List.of("salesQuoteFinance.pending"), List.of());
        legacy("financeExpenseConfirmation", List.of("financeExpenseConfirmation.count"), List.of());
        // 2026-10-02 盘点审批(ADR/库存盘点)：普通仓交财务审核的入口（红=待审）。
        legacy("financeStockCountReview", List.of("stockCountFinance.count"), List.of());
        legacy("expenseFinance", List.of("expense.pendingApprovalCount", "expense.pendingPaymentCount"), List.of());
        legacy("financeDrafts", List.of("drafts.financeReceipt", "drafts.financePayment", "drafts.financeExpense",
                "drafts.financeOtherIncome", "drafts.financeBankTransfer"), List.of());
        legacy("productionSchedule", List.of("productionSchedule.count"), List.of());
        legacy("productionRateApprovals", List.of("productionOverproductionRate.count"), List.of());
        legacy("productionOverLimitPending", List.of("productionOverLimitPending.count"), List.of());
        legacy("productionMaterialIncrementApprovals", List.of("productionMaterialIncrement.count"), List.of());
        legacy("productionPlanningUrges", List.of("productionPlanningUrge.count"), List.of());
        legacy("productionBatches", List.of(), List.of("productionExecution.count"));
        legacy("productionDrafts", List.of("drafts.productionPlan", "drafts.productionDailyReport"), List.of());
        legacy("productionWorkshop", List.of("workshopTask.preparing"), List.of("workshopTask.inProgress"));
        legacy("rdTaskCenter", List.of("rdTask.open"), List.of("rdTask.inProgress"));
        // 两个实际工作方向含生产领/退料，旧领料入口只保留查询兼容，不再重复贡献模块合计。
        legacy("warehouseOutboundCenter", List.of("warehouseSalesOutbound.PENDING_PICK",
                "subcontractOutbound.count", "productionDraw.count"), List.of());
        legacy("warehouseInboundCenter", List.of("warehouseInboundExpectation.count",
                "warehouseArrivalException.count", "finishedInbound.count", "productionReturn.count"), List.of());
        legacy("warehouseDrawCenter", List.of("productionDraw.count", "productionReturn.count"), List.of());
        // ADR-131 车间内料仓: 红 = 待发料 + 待收退回, 黄 = 盘点中 (新入口, 口径即计数端点本身)。
        legacy("warehouseWorkshopMaterial", List.of("workshopMaterial.pendingIssue", "workshopMaterial.pendingReturn"),
                List.of("workshopMaterial.counting"));
        legacy("warehouseQualityResult", List.of("qualityResult.actionable.*"), List.of("qualityResult.inProgress.*"));
        // 2026-10-02 盘点审批(ADR/库存盘点)：内料仓/仓库侧审核入口（红=待审）。
        legacy("warehouseStockCountReview", List.of("stockCountWarehouse.count"), List.of());
        legacy("warehouseDrafts", List.of("drafts.stockDocument"), List.of());
        legacy("purchaseTaskCenter", List.of("purchaseTask.pending"), List.of("purchaseTask.inProgress"));
        legacy("purchaseSupplierReturn", List.of("purchaseSupplierReturn.count"), List.of());
        legacy("purchaseDrafts", List.of("drafts.purchaseOrder", "drafts.purchaseReceipt", "drafts.purchaseReturn"), List.of());
        // ADR-143 §4.1: 委外任务中心入口红数 = 待处理 + 可领(新增事实 subcontractDraw.drawable)。
        // ADR-171 修订二(2026-10-09): 黄数再加「领料中」——已提交领料、等仓库发出的行
        // (subcontractDraw.submitted); 领料未结束的订货单已不进 subcontractTask.inProgress(V834)。
        legacy("subcontractTaskCenter", List.of("subcontractTask.pending", "subcontractDraw.drawable"),
                List.of("subcontractTask.inProgress", "subcontractDraw.submitted"));
        legacy("subcontractSupplierReturn", List.of("subcontractSupplierReturn.count"), List.of());
        legacy("subcontractDrafts", List.of("drafts.subcontractOrder", "drafts.subcontractReturn",
                "drafts.subcontractMaterialReturn", "drafts.subcontractWaste"), List.of());
        legacy("qualityIqcPending", List.of("iqcPending.count"), List.of());
        legacy("qualityFqcPending", List.of("fqcPending.count"), List.of());
        legacy("salesAttention", List.of("salesStage.REJECTED", "salesStage.SHIPPABLE"), List.of());
        legacy("salesOrderInFlight", List.of(), List.of("salesStage.PENDING", "salesStage.PRODUCING",
                "salesStage.SHIPMENT_PENDING", "salesStage.WAREHOUSE_PENDING"));
        legacy("salesShipmentFinanceRejected", List.of("financeRejected.salesShipment"), List.of());
        legacy("salesQuoteFinanceRejected", List.of("financeRejected.salesQuote"), List.of());
        legacy("salesQuoteAwaitingConversion", List.of("salesQuote.awaitingConversion"), List.of());
        // V788 报价议价：客户确认待办（红=待客户确认的报价）。
        legacy("salesQuoteAwaitingCustomerConfirmation", List.of("salesQuote.awaitingCustomerConfirmation"), List.of());
        legacy("salesDrafts", List.of("drafts.salesOrder", "drafts.salesShipment", "drafts.salesReturn",
                "drafts.salesQuote"), List.of());
        legacy("serverStatusAlert", List.of("serverStatus.alerts"), List.of());
        // A new registered entry: its independent contract is the manual status endpoint above.
        legacy("serverUpdateAvailable", List.of("serverOperations.updates"), List.of());
    }

    private static void legacy(String entry, List<String> todo, List<String> inProgress) {
        LEGACY_FORMULAS.put(entry, List.of(todo, inProgress));
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired NoticeService notices;
    @Autowired WorkbenchBadgeReadPort badgePort;
    @Autowired com.uten.imp.common.docnumber.DocNumberService docNumbers;
    @Autowired BrokenSourceConfiguration snapshotSource;

    /**
     * 服务器状态告警调度(@Profile("!cloud"), fixedDelay 5 分钟)会在测试中途给 seed 超管发
     * 定向通知——notices 徽章汇总先读(0)、原端点后读(N)的 TOCTOU 假红(生产两处同一查询无此问题)。
     * 本类独立完整迁移数据库, 再用 Mockito 替换此上下文的调度器; 其它测试上下文的
     * 后台任务仍正常运行, 但无法改变本类的对账事实。
     */
    @MockitoBean
    ServerStatusAlertScheduler serverStatusAlertScheduler;

    private FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        snapshotSource.hostAvailable = true;
        snapshotSource.hostPlatformUnsupported = false;
        snapshotSource.hostUpdateAvailable = false;
        snapshotSource.hostStatusCalls.set(0);
    }

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test
    void superAdminSummaryEqualsEveryOriginalEndpointAndLegacyFormula() throws Exception {
        var world = fixture.seedWorld("BADGE" + tag());
        grantAllBusinessActions(world.superAdminUserId());
        Authentication admin = auth(world.superAdminUserId());

        JsonNode summary = getJson("/api/workbench/badges", admin);
        Map<String, Long> facts = facts(summary);

        // 明确授出全部业务动作的超管: 每个来源都与同一任务资格端点逐字段相等。
        for (Map.Entry<String, String> source : ORIGINAL_ENDPOINTS.entrySet()) {
            Map<String, Long> expected = endpointFacts(source.getKey(), source.getValue(), admin);
            assertThat(expected).as("超管访问原端点 %s", source.getValue()).isNotNull();
            assertThat(slice(facts, source.getKey()))
                    .as("来源 %s 的事实数必须逐字段等于原端点 %s", source.getKey(), source.getValue())
                    .isEqualTo(expected);
        }
        assertThat(facts.keySet()).as("故意报错的测试来源被保存点隔离, 不出现")
                .noneMatch(key -> key.startsWith(BrokenSourceConfiguration.KEY + "."));
        assertThat(summary.path("staleEntries")).as("未被入口引用的来源出错不连累任何入口").isEmpty();
        assertThat(texts(summary.path("staleSources")))
                .as("出错的来源单独列出, 前端据此保留它上一次的事实数")
                .containsExactly(BrokenSourceConfiguration.KEY);

        // 入口口径 = 迁移前前端注册表。
        JsonNode entries = summary.path("entries");
        assertThat(names(entries)).as("明确授出全部业务动作时看到全部入口").isEqualTo(new TreeSet<>(LEGACY_FORMULAS.keySet()));
        for (var formula : LEGACY_FORMULAS.entrySet()) {
            JsonNode counts = entries.path(formula.getKey());
            assertThat(counts.path("todo").asLong())
                    .as("入口 %s 红数", formula.getKey()).isEqualTo(sum(formula.getValue().get(0), facts));
            assertThat(counts.path("inProgress").asLong())
                    .as("入口 %s 黄数", formula.getKey()).isEqualTo(sum(formula.getValue().get(1), facts));
        }
        assertRollups(summary);
    }

    @Test
    void administratorCatalogAndReadOnlyPermissionsNeverSubscribeToUnassignedBusinessTasks() throws Exception {
        var world = fixture.seedWorld("AUDIENCE" + tag());
        UUID readOnly = fixture.createUserWithPerms(world, "reader-" + tag(),
                "rd_task:view", "subcontract_order:view", "subcontract_application:view",
                "purchase_request:view", "purchase_order:view", "employee:view", "production_plan:view");
        UUID admin = fixture.createUserWithPerms(world, "finance-admin-" + tag(),
                "rd_task:view", "subcontract_order:view", "subcontract_application:view",
                "purchase_request:view", "purchase_order:view", "employee:view", "production_plan:view");
        db.update("UPDATE users SET is_super_admin=TRUE WHERE id=?", admin);
        UUID rdOperator = fixture.createUserWithPerms(world, "rd-operator-" + tag(), "rd_task:view", "rd_task:resolve");
        db.update("""
                INSERT INTO rd_tasks(id, task_no, title, category, status, priority, goods_id, reporter_employee_id)
                VALUES (?, ?, '任务资格测试', 'BOM', 'OPEN', 'NORMAL', ?, ?)
                """, UUID.randomUUID(), docNumbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.RD_TASK), world.goodsA(), world.employeeId());
        for (UUID observer : List.of(readOnly, admin)) {
            JsonNode summary = getJson("/api/workbench/badges", auth(observer));
            assertThat(summary.path("entries").path("rdTaskCenter").path("todo").asLong()).isZero();
            assertThat(summary.path("entries").path("subcontractTaskCenter").path("todo").asLong()).isZero();
            assertThat(summary.path("entries").path("purchaseTaskCenter").path("todo").asLong()).isZero();
            assertThat(summary.path("entries").path("productionSchedule").path("todo").asLong()).isZero();
        }
        JsonNode operator = getJson("/api/workbench/badges", auth(rdOperator));
        assertThat(operator.path("entries").path("rdTaskCenter").path("todo").asLong()).isPositive();
        db.update("""
                UPDATE user_permission_overrides SET effect='revoke'
                WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='rd_task:resolve')
                """, rdOperator);
        assertThat(getJson("/api/workbench/badges", auth(rdOperator))
                .path("entries").path("rdTaskCenter").path("todo").asLong()).isZero();
    }

    @Test
    void oneSummaryUsesOneSnapshotAcrossAnIndependentCommittedWrite() throws Exception {
        var world = fixture.seedWorld("BADGESNAPSHOT" + tag());
        UUID user = fixture.createUserWithPerms(world, "snapshot-" + tag(), "rd_task:view");
        snapshotSource.snapshotUser = user;
        try {
            JsonNode summary = getJson("/api/workbench/badges", auth(world.superAdminUserId()));
            assertThat(summary.path("facts").path("aaSnapshotBefore.count").asLong()).isZero();
            assertThat(summary.path("facts").path("zzSnapshotAfter.count").asLong()).isZero();
            assertThat(db.queryForObject("SELECT failed_attempts FROM users WHERE id=?", Long.class, user))
                    .as("另一事务确实已经提交，而汇总所有来源仍读同一快照").isEqualTo(1L);
            assertRollups(summary);
        } finally {
            snapshotSource.snapshotUser = null;
        }
    }

    @Test
    void entriesFollowEachOriginalEndpointGateForRestrictedUsers() throws Exception {
        var world = fixture.seedWorld("BADGEGATE" + tag());
        List<UUID> users = List.of(
                fixture.createUserWithPerms(world, "rd-" + tag(), "rd_task:view"),
                fixture.createUserWithPerms(world, "wh-" + tag(),
                        "stock_doc:view", "warehouse_inbound:view", "sales_shipment:warehouse-work"),
                fixture.createUserWithPerms(world, "sales-" + tag(),
                        "sales_order:view", "sales_order_finance:view", "notice:read", "expense:apply"));
        for (UUID user : users) {
            Authentication actor = auth(user);
            JsonNode summary = getJson("/api/workbench/badges", actor);
            Map<String, Long> facts = facts(summary);
            Set<String> granted = new TreeSet<>();
            for (Map.Entry<String, String> source : ORIGINAL_ENDPOINTS.entrySet()) {
                Map<String, Long> expected = endpointFacts(source.getKey(), source.getValue(), actor);
                Map<String, Long> actual = slice(facts, source.getKey());
                if (expected == null) {
                    assertThat(actual).as("端点 %s 拒绝时, 汇总里也不得出现来源 %s",
                            source.getValue(), source.getKey()).isEmpty();
                } else {
                    granted.add(source.getKey());
                    assertThat(actual).as("端点 %s 放行时来源 %s 逐字段相等",
                            source.getValue(), source.getKey()).isEqualTo(expected);
                }
            }
            // 入口出现 ⇔ 它引用的来源至少一个放行。
            Set<String> expectedEntries = new TreeSet<>();
            for (var formula : LEGACY_FORMULAS.entrySet()) {
                boolean visible = formula.getValue().stream().flatMap(List::stream)
                        .map(fact -> fact.substring(0, fact.indexOf('.')))
                        .anyMatch(granted::contains);
                if (visible) expectedEntries.add(formula.getKey());
            }
            assertThat(names(summary.path("entries"))).as("用户 %s 可见入口", user).isEqualTo(expectedEntries);
            assertRollups(summary);
        }
    }

    @Test
    void registeredServerUpdateUsesRealPermissionsAndOnlyItsEntryBecomesStaleWhenHostIsUnavailable() throws Exception {
        var world = fixture.seedWorld("BADGEHOST" + tag());
        Authentication updater = auth(fixture.createUserWithPerms(world, "updater-" + tag(), "server:update"));
        Authentication monitor = auth(fixture.createUserWithPerms(world, "monitor-" + tag(), "server_status:view"));
        Authentication unrelated = auth(fixture.createUserWithPerms(world, "unrelated-" + tag(), "rd_task:view"));
        snapshotSource.hostUpdateAvailable = true;

        JsonNode updateStatus = getJson("/api/admin/server-operations/status", updater);
        assertThat(updateStatus.path("available").asBoolean()).isTrue();
        assertThat(updateStatus.path("canUpdate").asBoolean()).isTrue();
        JsonNode updateSummary = getJson("/api/workbench/badges", updater);
        assertThat(facts(updateSummary)).containsEntry("serverOperations.updates", 1L);
        assertThat(updateSummary.path("entries").path("serverUpdateAvailable").path("todo").asLong()).isEqualTo(1L);
        assertThat(texts(updateSummary.path("staleEntries"))).isEmpty();
        assertThat(texts(updateSummary.path("staleSources"))).containsExactly(BrokenSourceConfiguration.KEY);
        assertRollups(updateSummary);

        JsonNode monitorStatus = getJson("/api/admin/server-operations/status", monitor);
        assertThat(monitorStatus.path("available").asBoolean()).isTrue();
        assertThat(monitorStatus.path("canUpdate").asBoolean()).isFalse();
        JsonNode monitorSummary = getJson("/api/workbench/badges", monitor);
        assertThat(facts(monitorSummary)).containsEntry("serverOperations.updates", 0L);
        assertThat(monitorSummary.path("entries").path("serverUpdateAvailable").path("todo").asLong()).isZero();
        assertThat(texts(monitorSummary.path("staleEntries"))).isEmpty();
        assertThat(texts(monitorSummary.path("staleSources"))).containsExactly(BrokenSourceConfiguration.KEY);
        assertRollups(monitorSummary);

        snapshotSource.hostAvailable = false;
        JsonNode unavailableStatus = getJson("/api/admin/server-operations/status", updater);
        assertThat(unavailableStatus.path("available").asBoolean()).isFalse();
        assertThat(unavailableStatus.path("canUpdate").asBoolean()).as("Host availability never grants or removes the update authority").isTrue();
        JsonNode unavailableSummary = getJson("/api/workbench/badges", updater);
        assertThat(facts(unavailableSummary)).doesNotContainKey("serverOperations.updates");
        assertThat(texts(unavailableSummary.path("staleSources")))
                .containsExactlyInAnyOrder(BrokenSourceConfiguration.KEY, "serverOperations");
        assertThat(texts(unavailableSummary.path("staleEntries"))).containsExactly("serverUpdateAvailable");
        assertRollups(unavailableSummary);

        int callsBeforeDenial = snapshotSource.hostStatusCalls.get();
        var denied = http.perform(get("/api/admin/server-operations/status").with(authentication(unrelated)))
                .andReturn().getResponse();
        assertThat(denied.getStatus()).isEqualTo(403);
        JsonNode unrelatedSummary = getJson("/api/workbench/badges", unrelated);
        assertThat(facts(unrelatedSummary).keySet()).noneMatch(key -> key.startsWith("serverOperations."));
        assertThat(names(unrelatedSummary.path("entries"))).doesNotContain("serverUpdateAvailable");
        assertThat(texts(unrelatedSummary.path("staleEntries"))).isEmpty();
        assertThat(texts(unrelatedSummary.path("staleSources"))).containsExactly(BrokenSourceConfiguration.KEY);
        assertThat(snapshotSource.hostStatusCalls.get()).as("An unauthorized reader cannot invoke the host boundary").isEqualTo(callsBeforeDenial);
    }

    @Test
    void unsupportedPlatformKeepsPermissionsAndClearsOnlyTheInapplicableUpdateFact() throws Exception {
        var world = fixture.seedWorld("BADGEPLATFORM" + tag());
        Authentication updater = auth(fixture.createUserWithPerms(world, "updater-" + tag(), "server:update"));
        Authentication monitor = auth(fixture.createUserWithPerms(world, "monitor-" + tag(), "server_status:view"));
        snapshotSource.hostUpdateAvailable = true;
        assertThat(facts(getJson("/api/workbench/badges", updater)))
                .containsEntry("serverOperations.updates", 1L);

        snapshotSource.hostPlatformUnsupported = true;
        for (Authentication actor : List.of(updater, monitor)) {
            JsonNode status = getJson("/api/admin/server-operations/status", actor);
            assertThat(status.path("available").asBoolean()).isFalse();
            assertThat(status.path("failure").path("code").asText()).isEqualTo("HOST_PLATFORM_UNSUPPORTED");
            assertThat(status.path("currentVersion").isNull()).isTrue();
            assertThat(status.path("canUpdate").asBoolean()).isEqualTo(actor == updater);
            JsonNode summary = getJson("/api/workbench/badges", actor);
            assertThat(facts(summary)).containsEntry("serverOperations.updates", 0L);
            assertThat(summary.path("entries").path("serverUpdateAvailable").path("todo").asLong()).isZero();
            assertThat(texts(summary.path("staleSources"))).containsExactly(BrokenSourceConfiguration.KEY);
            assertThat(texts(summary.path("staleEntries"))).isEmpty();
            assertRollups(summary);
        }
    }

    @Test
    void unreadIndexDigestTracksReadAndPopupAcknowledgement() throws Exception {
        var world = fixture.seedWorld("BADGENOTICE" + tag());
        UUID user = fixture.createUserWithPerms(world, "nt-" + tag(), "notice:read");
        Authentication actor = auth(user);
        JsonNode before = getJson("/api/notices/unread-index", actor);

        fixture.loginAs(world.superAdminUserId());
        var first = notices.publishForUser(user, "测试通知一", "内容", "system", "系统", "/sales/orders/" + UUID.randomUUID());
        notices.publishForUser(user, "测试通知二", "内容", "system", "系统");
        actor = auth(user);

        JsonNode afterPublish = getJson("/api/notices/unread-index", actor);
        assertThat(afterPublish.path("unreadCount").asLong()).isEqualTo(before.path("unreadCount").asLong() + 2);
        assertThat(afterPublish.path("digest").asLong()).isNotEqualTo(before.path("digest").asLong());
        assertThat(afterPublish.path("digest").asLong()).as("摘要只取 48 位, Web 端数字精度内")
                .isBetween(0L, (1L << 48) - 1);
        JsonNode firstItem = item(afterPublish, first.getId());
        assertThat(firstItem.path("pendingArrival").asBoolean()).isTrue();
        assertThat(firstItem.path("actionRoute").asText()).isEqualTo(first.getActionRoute());

        Map<String, Long> summaryFacts = facts(getJson("/api/workbench/badges", actor));
        assertThat(summaryFacts.get("notices.unread")).isEqualTo(afterPublish.path("unreadCount").asLong());
        assertThat(summaryFacts.get("notices.digest")).isEqualTo(afterPublish.path("digest").asLong());

        fixture.loginAs(user);
        notices.acknowledgePopup(first.getId());
        SecurityContextHolder.clearContext();
        JsonNode afterAck = getJson("/api/notices/unread-index", actor);
        assertThat(afterAck.path("unreadCount").asLong()).as("确认弹窗不改已读")
                .isEqualTo(afterPublish.path("unreadCount").asLong());
        assertThat(item(afterAck, first.getId()).path("pendingArrival").asBoolean()).isFalse();
        assertThat(afterAck.path("digest").asLong()).as("不再弹横幅也要让摘要变化")
                .isNotEqualTo(afterPublish.path("digest").asLong());

        fixture.loginAs(user);
        notices.markRead(first.getId());
        SecurityContextHolder.clearContext();
        JsonNode afterRead = getJson("/api/notices/unread-index", actor);
        assertThat(afterRead.path("unreadCount").asLong()).isEqualTo(afterPublish.path("unreadCount").asLong() - 1);
        assertThat(afterRead.path("digest").asLong()).isNotEqualTo(afterAck.path("digest").asLong());
    }

    /**
     * 只读端口(工作台概览的本部门待办用, permissions-08): 只算请求的入口、只读它们引用的来源,
     * 数字与汇总逐个相等; 语句数少于整份汇总。
     */
    @Test
    void readPortReturnsTheSummaryNumbersForTheRequestedEntriesOnly() throws Exception {
        var world = fixture.seedWorld("BADGEPORT" + tag());
        grantAllBusinessActions(world.superAdminUserId());
        Authentication admin = auth(world.superAdminUserId());
        JsonNode summary = getJson("/api/workbench/badges", admin);
        Set<String> wanted = Set.of("expenseFinance", "productionSchedule", "purchaseTaskCenter", "visitorApproval");

        SecurityContextHolder.getContext().setAuthentication(admin);
        ProductionJdbcMeasurement.Sample subset = ProductionJdbcMeasurement.begin();
        WorkbenchBadgeReadPort.Entries entries;
        try {
            entries = badgePort.entries(wanted);
        } finally {
            ProductionJdbcMeasurement.end();
            SecurityContextHolder.clearContext();
        }
        ProductionJdbcMeasurement.Sample full = ProductionJdbcMeasurement.begin();
        try {
            getJson("/api/workbench/badges", admin);
        } finally {
            ProductionJdbcMeasurement.end();
        }

        assertThat(entries.todo().keySet()).isEqualTo(wanted);
        for (String entry : wanted) {
            assertThat(entries.todo().get(entry)).as("入口 %s 红数与汇总相同", entry)
                    .isEqualTo(summary.path("entries").path(entry).path("todo").asLong());
        }
        Map<String, Long> summaryFacts = facts(summary);
        assertThat(entries.facts().keySet()).as("只读所请求入口引用的来源")
                .allMatch(key -> key.startsWith("expense.") || key.startsWith("productionSchedule.")
                        || key.startsWith("purchaseTask.") || key.startsWith("visitorApproval."));
        entries.facts().forEach((key, value) ->
                assertThat(value).as("事实数 %s 与汇总相同", key).isEqualTo(summaryFacts.get(key)));
        assertThat(entries.staleEntries()).isEmpty();
        System.out.printf(Locale.ROOT, "WORKBENCH_BADGE_PORT subset statements=%d | full summary statements=%d%n",
                subset.logicalStatements, full.logicalStatements);
        assertThat(subset.logicalStatements).as("只算 4 个入口的语句数少于整份汇总")
                .isLessThan(full.logicalStatements);
    }

    @Test
    void oneSummaryReplacesTheOldPerEndpointPollingBudget() throws Exception {
        var world = fixture.seedWorld("BADGEBUDGET" + tag());
        grantAllBusinessActions(world.superAdminUserId());
        Authentication admin = auth(world.superAdminUserId());
        getJson("/api/workbench/badges", admin); // 预热: 首次调用的元数据/计划缓存不计入

        ProductionJdbcMeasurement.Sample summary = ProductionJdbcMeasurement.begin();
        long summaryStarted = System.nanoTime();
        try {
            getJson("/api/workbench/badges", admin);
        } finally {
            ProductionJdbcMeasurement.end();
        }
        long summaryNanos = System.nanoTime() - summaryStarted;

        ProductionJdbcMeasurement.Sample legacy = ProductionJdbcMeasurement.begin();
        long legacyStarted = System.nanoTime();
        try {
            for (String endpoint : ORIGINAL_ENDPOINTS.values()) {
                var response = http.perform(get(endpoint).with(authentication(admin))).andReturn().getResponse();
                assertThat(response.getStatus()).as("Original endpoint %s must execute its query", endpoint).isEqualTo(200);
            }
        } finally {
            ProductionJdbcMeasurement.end();
        }
        long legacyNanos = System.nanoTime() - legacyStarted;

        System.out.printf(Locale.ROOT,
                "WORKBENCH_BADGE_BUDGET summary: requests=1 statements=%d jdbcMillis=%.1f wallMillis=%.1f"
                        + " | legacy: requests=%d statements=%d jdbcMillis=%.1f wallMillis=%.1f%n",
                summary.logicalStatements, summary.jdbcNanos / 1e6, summaryNanos / 1e6,
                ORIGINAL_ENDPOINTS.size(), legacy.logicalStatements, legacy.jdbcNanos / 1e6, legacyNanos / 1e6);
        // 本测试类的测试配置注入了一个必然失败的来源(select 1 / 0, 验证出错来源不拖垮整份汇总),
        // 汇总会执行它一次而逐个端点的旧轮询不会, 比较时扣掉这一条。
        assertThat(summary.logicalStatements - 1)
                .as("一次汇总的语句数不超过原来逐个端点之和(汇总额外只有保存点)")
                .isLessThanOrEqualTo(legacy.logicalStatements);
        assertThat(summary.logicalStatements).as("语句预算").isLessThanOrEqualTo(90);
    }

    // ---------------------------------------------------------------------------------------

    private void assertRollups(JsonNode summary) {
        Map<String, long[]> modules = new TreeMap<>();
        long totalTodo = 0, totalInProgress = 0;
        for (var module : summary.path("modules").properties()) {
            modules.put(module.getKey(), new long[] {
                    module.getValue().path("todo").asLong(), module.getValue().path("inProgress").asLong()});
            totalTodo += module.getValue().path("todo").asLong();
            totalInProgress += module.getValue().path("inProgress").asLong();
        }
        assertThat(summary.path("total").path("todo").asLong()).as("总红 = 容器之和").isEqualTo(totalTodo);
        assertThat(summary.path("total").path("inProgress").asLong()).as("总黄 = 容器之和").isEqualTo(totalInProgress);
        long entryTodo = 0, entryInProgress = 0;
        for (var entry : summary.path("entries").properties()) {
            if (entry.getKey().equals("warehouseDrawCenter")) continue;
            entryTodo += entry.getValue().path("todo").asLong();
            entryInProgress += entry.getValue().path("inProgress").asLong();
        }
        assertThat(entryTodo).as("实际入口之和 = 总数，旧领料别名不重复计入").isEqualTo(totalTodo);
        assertThat(entryInProgress).isEqualTo(totalInProgress);
        JsonNode alias = summary.path("entries").path("warehouseDrawCenter");
        if (!alias.isMissingNode()) {
            Map<String, Long> facts = facts(summary);
            assertThat(alias.path("todo").asLong()).as("旧领料入口仍兼容领料和退料事实")
                    .isEqualTo(facts.getOrDefault("productionDraw.count", 0L) + facts.getOrDefault("productionReturn.count", 0L));
        }
    }

    private Map<String, Long> endpointFacts(String source, String endpoint, Authentication actor) throws Exception {
        var response = http.perform(get(endpoint).with(authentication(actor))).andReturn().getResponse();
        if (response.getStatus() == 403 || response.getStatus() == 401) return null;
        assertThat(response.getStatus()).as("原端点 %s", endpoint).isEqualTo(200);
        JsonNode body = json.readTree(response.getContentAsByteArray());
        Map<String, Long> out = new TreeMap<>();
        switch (source) {
            case "serverOperations" -> {
                assertThat(body.path("available").asBoolean()).as("The normal endpoint comparison uses the controlled healthy host").isTrue();
                out.put("updates", body.path("canUpdate").asBoolean() && body.path("updateAvailable").asBoolean() ? 1L : 0L);
            }
            case "serverStatus" -> {
                long alerts = 0;
                for (JsonNode alert : body.path("alerts")) {
                    String status = alert.path("status").asText();
                    if ("WARNING".equals(status) || "CRITICAL".equals(status)) alerts++;
                }
                out.put("alerts", alerts);
            }
            case "notices" -> {
                out.put("unread", body.path("unreadCount").asLong());
                out.put("digest", body.path("digest").asLong());
                JsonNode latest = body.path("latestPublishedAt");
                out.put("latestPublishedAt", latest.isNumber()
                        ? latest.decimalValue().movePointRight(3).longValue()
                        : latest.isTextual() ? java.time.Instant.parse(latest.asText()).toEpochMilli() : 0L);
            }
            case "iqcRejection" -> {
                out.putAll(WorkbenchBadgeSources.numbers(json.convertValue(body, Map.class)));
                // 原前端模型 ProcurementIqcRejectionCounts.open 的口径, 现由服务端来源算一次。
                out.put("open", body.path("actionablePendingReturn").asLong() + body.path("actionableReturnRecorded").asLong()
                        + body.path("actionableFinanceException").asLong());
            }
            case "salesStage" -> body.properties().forEach(field -> {
                if (field.getKey().startsWith("TASK_")) out.put(field.getKey().substring(5), field.getValue().asLong());
            });
            default -> out.putAll(WorkbenchBadgeSources.numbers(json.convertValue(body, Map.class)));
        }
        return out;
    }

    private static Map<String, Long> slice(Map<String, Long> facts, String source) {
        Map<String, Long> out = new TreeMap<>();
        String prefix = source + ".";
        facts.forEach((key, value) -> {
            if (key.startsWith(prefix)) out.put(key.substring(prefix.length()), value);
        });
        return out;
    }

    private static long sum(List<String> keys, Map<String, Long> facts) {
        long total = 0;
        for (String key : keys) {
            if (key.endsWith(".*")) {
                String prefix = key.substring(0, key.length() - 1);
                total += facts.entrySet().stream()
                        .filter(fact -> fact.getKey().startsWith(prefix))
                        .mapToLong(Map.Entry::getValue).sum();
            } else {
                total += facts.getOrDefault(key, 0L);
            }
        }
        return total;
    }

    private Map<String, Long> facts(JsonNode summary) {
        Map<String, Long> out = new TreeMap<>();
        summary.path("facts").properties().forEach(fact -> out.put(fact.getKey(), fact.getValue().asLong()));
        return out;
    }

    private static Set<String> names(JsonNode object) {
        Set<String> out = new TreeSet<>();
        object.fieldNames().forEachRemaining(out::add);
        return out;
    }

    private static List<String> texts(JsonNode array) {
        List<String> out = new ArrayList<>();
        array.forEach(node -> out.add(node.asText()));
        return out;
    }

    private static JsonNode item(JsonNode index, UUID id) {
        List<JsonNode> matches = new ArrayList<>();
        for (JsonNode item : index.path("items")) {
            if (id.toString().equals(item.path("id").asText())) matches.add(item);
        }
        assertThat(matches).as("未读索引应含通知 %s", id).hasSize(1);
        return matches.getFirst();
    }

    private JsonNode getJson(String path, Authentication actor) throws Exception {
        var response = http.perform(get(path).with(authentication(actor))).andReturn().getResponse();
        assertThat(response.getStatus()).as("GET %s", path).isEqualTo(200);
        return json.readTree(response.getContentAsByteArray());
    }

    private Authentication auth(UUID userId) {
        fixture.loginAs(userId);
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        SecurityContextHolder.clearContext();
        return authentication;
    }

    private void grantAllBusinessActions(UUID userId) {
        db.update("""
                INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                SELECT ?, permission.id, 'grant' FROM permissions permission
                WHERE NOT ('SUPERADMIN_ONLY'=ANY(COALESCE(permission.grant_policy,ARRAY[]::text[])))
                ON CONFLICT (user_id, permission_id) DO UPDATE SET effect='grant', active=TRUE
                """, userId);
    }

    private static String tag() {
        return UUID.randomUUID().toString().substring(0, 8).toUpperCase(Locale.ROOT);
    }

    /** 一个执行必定报错 SQL 的来源: 验证保存点隔离后其它来源照常。键名排在最前, 先执行。 */
    @TestConfiguration(proxyBeanMethods = false)
    static class BrokenSourceConfiguration {
        static final String KEY = "aaBrokenForTest";
        volatile UUID snapshotUser;
        volatile boolean hostAvailable = true;
        volatile boolean hostPlatformUnsupported;
        volatile boolean hostUpdateAvailable;
        final java.util.concurrent.atomic.AtomicInteger hostStatusCalls = new java.util.concurrent.atomic.AtomicInteger();

        /** Only the external host dependency is controlled; controllers, SQL and gates remain real. */
        @Bean
        @Primary
        HostOperationsClient badgeHostOperations(ObjectMapper mapper) {
            return (operation, payload, actorId, requestId) -> {
                if (operation != HostOperationsClient.Operation.STATUS || !payload.isEmpty()) {
                    throw new AssertionError("Badge aggregation must only read local host status");
                }
                hostStatusCalls.incrementAndGet();
                if (hostPlatformUnsupported) {
                    // Simulate the transport's local platform fact, never a helper-supplied error code.
                    throw java.util.Objects.requireNonNull(org.springframework.test.util.ReflectionTestUtils
                            .<HostOperationsException>invokeMethod(HostOperationsException.class, "platformUnsupported"));
                }
                if (!hostAvailable) throw new HostOperationsException("UNAVAILABLE");
                return mapper.createObjectNode()
                        .put("available", true).put("manualOnly", true)
                        .put("timerActive", false).put("timerEnabled", false)
                        .put("currentVersion", "v2.5.18").put("sourceRevision", "0".repeat(64))
                        .put("sourceConfigured", true).put("updateAvailable", hostUpdateAvailable)
                        .put("serverTimeZone", "UTC")
                        .put("serverTime", java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString());
            };
        }

        @Bean
        WorkbenchBadgeSources snapshotWorkbenchBadgeSource(JdbcTemplate jdbc) {
            return () -> List.of(
                    new WorkbenchBadgeSources.Source("aaSnapshotBefore", () -> {
                        UUID user = snapshotUser;
                        if (user == null) return Map.of();
                        long before = jdbc.queryForObject(
                                "SELECT failed_attempts FROM users WHERE id=?", Long.class, user);
                        // A separate committed transaction models another staff
                        // member completing work while the summary is being read.
                        try (var connection = jdbc.getDataSource().getConnection();
                             var update = connection.prepareStatement(
                                     "UPDATE users SET failed_attempts=failed_attempts+1 WHERE id=?")) {
                            connection.setAutoCommit(true);
                            update.setObject(1, user);
                            update.executeUpdate();
                        } catch (java.sql.SQLException error) {
                            throw new IllegalStateException(error);
                        }
                        return Map.of("count", before);
                    }),
                    new WorkbenchBadgeSources.Source("zzSnapshotAfter", () -> {
                        UUID user = snapshotUser;
                        if (user == null) return Map.of();
                        return Map.of("count", jdbc.queryForObject(
                                "SELECT failed_attempts FROM users WHERE id=?", Long.class, user));
                    }));
        }

        @Bean
        WorkbenchBadgeSources brokenWorkbenchBadgeSource(JdbcTemplate jdbc) {
            return () -> List.of(new WorkbenchBadgeSources.Source(KEY, () -> {
                jdbc.queryForObject("select 1 / 0", Long.class);
                return Map.of("never", 1L);
            }));
        }
    }
}
