package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WorkbenchBadgeReadPort;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import com.uten.imp.features.notice.NoticeService;
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
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

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
        "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
@Import({ProductionJdbcMeasurement.Configuration.class, WorkbenchBadgeSummaryPostgresTest.BrokenSourceConfiguration.class})
class WorkbenchBadgeSummaryPostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
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
        ORIGINAL_ENDPOINTS.put("productionMaterialIncrement", "/api/production/material-increments/count");
        ORIGINAL_ENDPOINTS.put("workshopTask", "/api/production/workshop-tasks/count");
        ORIGINAL_ENDPOINTS.put("productionExecution", "/api/production/execution-workbench/count");
        ORIGINAL_ENDPOINTS.put("fqcPending", "/api/production/quality-inspections/count");
        ORIGINAL_ENDPOINTS.put("rdTask", "/api/rd-tasks/count");
        ORIGINAL_ENDPOINTS.put("purchaseTask", "/api/operations/workbench/purchase/count");
        ORIGINAL_ENDPOINTS.put("subcontractTask", "/api/operations/workbench/subcontract/count");
        ORIGINAL_ENDPOINTS.put("productionDraw", "/api/operations/workbench/warehouse/count");
        ORIGINAL_ENDPOINTS.put("productionReturn", "/api/stock/production-materials/return-requests/warehouse/count");
        ORIGINAL_ENDPOINTS.put("drafts", "/api/documents/drafts/count");
        ORIGINAL_ENDPOINTS.put("financeRejected", "/api/documents/finance-rejected/count");
        ORIGINAL_ENDPOINTS.put("subcontractShortDelivery", "/api/subcontract/short-deliveries/count");
        ORIGINAL_ENDPOINTS.put("serverStatus", "/api/admin/server-status");
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
        legacy("expenseFinance", List.of("expense.pendingApprovalCount", "expense.pendingPaymentCount"), List.of());
        legacy("financeDrafts", List.of("drafts.financeReceipt", "drafts.financePayment", "drafts.financeExpense",
                "drafts.financeOtherIncome", "drafts.financeBankTransfer"), List.of());
        legacy("productionSchedule", List.of("productionSchedule.count"), List.of());
        legacy("productionRateApprovals", List.of("productionOverproductionRate.count"), List.of());
        legacy("productionMaterialIncrementApprovals", List.of("productionMaterialIncrement.count"), List.of());
        legacy("productionBatches", List.of(), List.of("productionExecution.count"));
        legacy("productionDrafts", List.of("drafts.productionPlan", "drafts.productionDailyReport"), List.of());
        legacy("productionWorkshop", List.of("workshopTask.preparing"), List.of("workshopTask.inProgress"));
        legacy("rdTaskCenter", List.of("rdTask.open"), List.of("rdTask.inProgress"));
        // 仓库三张任务中心卡: 原 WarehouseOutbound/Inbound/DrawTaskBadge 对各自来源求和。
        legacy("warehouseOutboundCenter", List.of("warehouseSalesOutbound.PENDING_PICK",
                "subcontractOutbound.count"), List.of());
        legacy("warehouseInboundCenter", List.of("warehouseInboundExpectation.count",
                "warehouseArrivalException.count", "finishedInbound.count"), List.of());
        legacy("warehouseDrawCenter", List.of("productionDraw.count", "productionReturn.count"), List.of());
        legacy("warehouseQualityResult", List.of("qualityResult.actionable.*"), List.of("qualityResult.inProgress.*"));
        legacy("warehouseDrafts", List.of("drafts.stockDocument"), List.of());
        legacy("purchaseTaskCenter", List.of("purchaseTask.pending"), List.of("purchaseTask.inProgress"));
        legacy("purchaseSupplierReturn", List.of("purchaseSupplierReturn.count"), List.of());
        legacy("purchaseDrafts", List.of("drafts.purchaseOrder", "drafts.purchaseReceipt", "drafts.purchaseReturn"), List.of());
        legacy("subcontractTaskCenter", List.of("subcontractTask.pending"), List.of("subcontractTask.inProgress"));
        legacy("subcontractSupplierReturn", List.of("subcontractSupplierReturn.count"), List.of());
        legacy("subcontractDrafts", List.of("drafts.subcontractOrder", "drafts.subcontractReturn",
                "drafts.subcontractMaterialReturn", "drafts.subcontractWaste"), List.of());
        legacy("qualityIqcPending", List.of("iqcPending.count"), List.of());
        legacy("qualityFqcPending", List.of("fqcPending.count"), List.of());
        legacy("salesAttention", List.of("salesStage.REJECTED", "salesStage.SHIPPABLE"), List.of());
        legacy("salesOrderInFlight", List.of(), List.of("salesStage.PENDING", "salesStage.PRODUCING",
                "salesStage.SHIPMENT_PENDING", "salesStage.WAREHOUSE_PENDING"));
        legacy("salesShipmentFinanceRejected", List.of("financeRejected.salesShipment"), List.of());
        legacy("salesDrafts", List.of("drafts.salesOrder", "drafts.salesShipment", "drafts.salesReturn",
                "drafts.salesQuote"), List.of());
        legacy("serverStatusAlert", List.of("serverStatus.alerts"), List.of());
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

    private FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test
    void superAdminSummaryEqualsEveryOriginalEndpointAndLegacyFormula() throws Exception {
        var world = fixture.seedWorld("BADGE" + tag());
        Authentication admin = auth(world.superAdminUserId());

        JsonNode summary = getJson("/api/workbench/badges", admin);
        Map<String, Long> facts = facts(summary);

        // 超管拥有全部权限: 每个来源都必须在汇总里, 且逐字段等于原端点。
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
        assertThat(names(entries)).as("超管看到全部入口").isEqualTo(new TreeSet<>(LEGACY_FORMULAS.keySet()));
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
                http.perform(get(endpoint).with(authentication(admin))).andReturn();
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
        for (JsonNode entry : summary.path("entries")) {
            entryTodo += entry.path("todo").asLong();
            entryInProgress += entry.path("inProgress").asLong();
        }
        assertThat(entryTodo).as("每个入口恰属一个容器: 入口之和 = 总数").isEqualTo(totalTodo);
        assertThat(entryInProgress).isEqualTo(totalInProgress);
    }

    private Map<String, Long> endpointFacts(String source, String endpoint, Authentication actor) throws Exception {
        var response = http.perform(get(endpoint).with(authentication(actor))).andReturn().getResponse();
        if (response.getStatus() == 403 || response.getStatus() == 401) return null;
        assertThat(response.getStatus()).as("原端点 %s", endpoint).isEqualTo(200);
        JsonNode body = json.readTree(response.getContentAsByteArray());
        Map<String, Long> out = new TreeMap<>();
        switch (source) {
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
                out.put("open", body.path("pendingReturn").asLong() + body.path("returnRecorded").asLong()
                        + body.path("financeException").asLong());
            }
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

    private static String tag() {
        return UUID.randomUUID().toString().substring(0, 8).toUpperCase(Locale.ROOT);
    }

    /** 一个执行必定报错 SQL 的来源: 验证保存点隔离后其它来源照常。键名排在最前, 先执行。 */
    @TestConfiguration(proxyBeanMethods = false)
    static class BrokenSourceConfiguration {
        static final String KEY = "aaBrokenForTest";

        @Bean
        WorkbenchBadgeSources brokenWorkbenchBadgeSource(JdbcTemplate jdbc) {
            return () -> List.of(new WorkbenchBadgeSources.Source(KEY, () -> {
                jdbc.queryForObject("select 1 / 0", Long.class);
                return Map.of("never", 1L);
            }));
        }
    }
}
