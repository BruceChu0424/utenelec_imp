package com.uten.imp.businesschain;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCountService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CorrectCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.Supplement;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.VersionRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPeriodService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseController;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.CloseStatusView;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.ReopenRequest;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.RetryRequest;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseScheduler;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.Result;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseTrigger;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.BinUsageRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.LedgerRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.ProductUsageRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.WastePoint;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportQueryService;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.support.DailyReportApproveRequests;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 车间内料仓自动结算 (包 S3): 每种料的处理方式 (主料按理论比例分摊、辅料按主料理论分摊、记车间费用、
 * 盘盈产品分 0、有实际没理论记损失并标红), 价值从在制移到成本在制并登记为产品成本投入、在制不留余量;
 * 三种拦截各自的内容与通知收件人 (未审报工含制单人), 报工审核后被拦的期间立即再试, 补完后自动结算,
 * 上一期没结时本期等待并在上一期结完后跟着结; 撤销结算只撤成本不动数量、24 小时内定时任务不重结、
 * "重新结算"写新的一次结算、只能撤最近一期; 同一期两个线程并发只结一次; 连续失败 3 次改为每天一次并通知设置负责人。
 *
 * <p>全部走真实服务与真实库 (V740 的结算断言、期间链、成本投入守卫在提交时生效)。本类关掉自动触发
 * ({@code uten.workshop-material.auto-close.enabled=false}), 按需要直接调用单次结算尝试, 或临时打开触发器
 * 验证"提交后后台结算"; 员工点的"重新结算"不受这个开关影响。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.workshop-material.auto-close.enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = WorkshopMaterialClosePostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class WorkshopMaterialClosePostgresTest {

    private static final TypeReference<List<Map<String, Object>>> BLOCKERS = new TypeReference<>() {};
    private static final LocalDate REPORT_DATE = LocalDate.of(2026, 1, 25);
    private static MigratedSchemaBaseline.ScopedDatabase database;

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) throws Exception {
        // Pool FINAL includes the database-wide durable valuation fence. Other FullChain
        // worlds intentionally retain unfinished cost scopes; the close/value assertions
        // need their own database while preserving that production publication rule.
        database = MigratedSchemaBaseline.openDatabase("workshop_material_close");
        registry.add("spring.datasource.url", database::getJdbcUrl);
        registry.add("spring.datasource.username", database::getUsername);
        registry.add("spring.datasource.password", database::getPassword);
        var attachments = java.nio.file.Files.createTempDirectory("workshop-close-attachments-");
        registry.add("uten.storage.local-dir", attachments::toString);
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) throws Exception {
            if (database != null) database.close();
        }
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired WorkshopMaterialCloseService closes;
    @Autowired WorkshopMaterialCloseTrigger trigger;
    @Autowired WorkshopMaterialCloseScheduler scheduler;
    @Autowired WorkshopMaterialReportQueryService reports;
    @Autowired WorkshopMaterialCountService counts;
    @Autowired ProductionDailyReportService dailyReports;

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    // =============================================================================================
    // 处理方式、价值移动、报表
    // =============================================================================================

    @Test
    void closeClassifiesEveryMaterialAndMovesItsValueIntoTheProductCost() {
        CloseBench bench = CloseBench.create(beans, "classify");
        bench.confirmInboundAndDrain();
        UUID own = bench.granule("主料颗粒", "OWN");
        UUID shared = bench.granule("色母", "SHARED");
        UUID expense = bench.granule("脱模剂", "EXPENSE");
        UUID gain = bench.granule("回收料", "OWN");
        UUID loss = bench.granule("试料", "OWN");
        bench.edge(bench.world.goodsA(), own, "0.2");
        bench.stockIn(own, "10", "10");
        bench.stockIn(shared, "5", "20");
        bench.stockIn(expense, "5", "5");
        bench.stockIn(gain, "5", "8");
        bench.stockIn(loss, "5", "6");
        // 先完成原仓颗粒入库的价值传播，再发料调入内料仓。
        var preCloseGoods = new java.util.ArrayList<UUID>(List.of(bench.world.goodsA(), bench.world.goodsB(), bench.world.goodsE()));
        preCloseGoods.addAll(bench.granules);
        InventoryValueWorkTestSupport.drain(bench.valueWork, db, preCloseGoods);
        bench.enable(List.of());
        assertEquals("BOM", db.queryForObject("""
                SELECT origin FROM production_execution_periodic_materials WHERE execution_segment_id = ?""",
                String.class, bench.segment));
        bench.issue(own, "3", null);
        bench.issue(shared, "1", null);
        bench.issue(expense, "2", null);
        bench.issue(gain, "1", null);
        bench.issue(loss, "1", null);

        // 发料是从原仓到内料仓的新一轮价值传播。盘盈在提交盘点时按内料仓当时的
        // 池均价核定，因此入库后等原仓、结算后再等都不能替代这里的调入价值就绪。
        InventoryValueWorkTestSupport.drain(bench.valueWork, db, preCloseGoods);
        var gainPool = beans.getBean(com.uten.imp.application.port.InventoryValuationPort.class).pool(
                new com.uten.imp.application.port.InventoryValuationPort.PoolKey(bench.bin, gain, null));
        assertEquals(com.uten.imp.application.port.InventoryValuationPort.State.FINAL, gainPool.state());
        money("1", gainPool.qtyBase());
        money("8", gainPool.knownValueLocal());

        UUID first = bench.firstPeriod;
        UUID count = bench.startCount(first, BusinessTime.today().minusDays(1));
        bench.weighed(count, "own", own, "1.8");
        bench.weighed(count, "shared", shared, "0.9");
        bench.weighed(count, "expense", expense, "1.5");
        bench.weighed(count, "gain", gain, "1.4");
        bench.weighed(count, "loss", loss, "0.7");
        PeriodView counted = bench.submit(count);
        assertEquals("COUNTED", counted.status());
        assertEquals("QUEUED", counted.closeState());

        assertEquals(Result.CLOSED, closes.attempt(first, TriggerKind.AFTER_COUNT, bench.admin));
        // 结算后的成本分摊还会排价值任务；等产品及各颗粒传播完，再断言最终成本。
        var drainGoods = new java.util.ArrayList<UUID>(List.of(bench.world.goodsA(), bench.world.goodsB(), bench.world.goodsE()));
        drainGoods.addAll(bench.granules);
        InventoryValueWorkTestSupport.drain(bench.valueWork, db, drainGoods);
        assertEquals("CLOSED/NONE", state(first));

        // 主料: 实际 1.2, 理论 5 件 x 0.2 = 1.0, 浪费率 20% 不标红; 全部分给这张工单的成本范围 (单行即尾差)
        Map<String, Object> ownRow = material(first, own);
        assertEquals("ALLOCATED", ownRow.get("outcome"));
        money("1.2", ownRow.get("consumed_qty"));
        money("0", ownRow.get("loss_qty"));
        money("1", ownRow.get("theory_qty"));
        money("0.2", ownRow.get("waste_rate"));
        assertEquals("", ownRow.get("flags"));
        money("12", ownRow.get("value_at_close"));
        UUID scope = db.queryForObject("SELECT fn_production_execution_cost_scope(?)", UUID.class, bench.segment);
        List<Map<String, Object>> ownAllocations = allocations((UUID) ownRow.get("id"));
        assertEquals(1, ownAllocations.size());
        assertEquals(scope, ownAllocations.getFirst().get("cost_scope_segment_id"));
        money("1.2", ownAllocations.getFirst().get("allocated_qty"));
        money("1", ownAllocations.getFirst().get("basis_qty"));
        assertEquals(Boolean.TRUE, ownAllocations.getFirst().get("is_tail"));
        assertNotNull(ownAllocations.getFirst().get("value_node_id"));
        money("12", ownAllocations.getFirst().get("value_at_close"));

        // 辅料: 没有理论, 按本期主料理论 (1.0) 分摊
        Map<String, Object> sharedRow = material(first, shared);
        assertEquals("ALLOCATED", sharedRow.get("outcome"));
        assertNull(sharedRow.get("theory_qty"));
        money("1", sharedRow.get("allocation_basis_qty"));
        money("0.1", sharedRow.get("consumed_qty"));
        money("2", sharedRow.get("value_at_close"));

        // 记车间费用: 盘点时已出到外部, 结算只记金额; 盘盈: 产品分 0, 按池均价核定; 有实际没理论: 损失并标红
        Map<String, Object> expenseRow = material(first, expense);
        assertEquals("EXPENSED", expenseRow.get("outcome"));
        money("0", expenseRow.get("consumed_qty"));
        money("2.5", expenseRow.get("value_at_close"));
        Map<String, Object> gainRow = material(first, gain);
        assertEquals("GAIN", gainRow.get("outcome"));
        money("0", gainRow.get("consumed_qty"));
        money("3.2", gainRow.get("value_at_close"));
        assertTrue(allocations((UUID) gainRow.get("id")).isEmpty(), "盘盈产品分 0");
        Map<String, Object> lossRow = material(first, loss);
        assertEquals("UNALLOCATED_LOSS", lossRow.get("outcome"));
        money("0.3", lossRow.get("loss_qty"));
        assertEquals("ACTUAL_WITHOUT_THEORY", lossRow.get("flags"));
        money("1.8", lossRow.get("value_at_close"));
        assertEquals("LOSS", db.queryForObject("""
                SELECT node.owner_kind FROM stock_value_events event
                JOIN stock_value_nodes node ON node.id = event.result_node_id
                WHERE event.source_doc_type = 'WORKSHOP_PERIOD_LOSS' AND event.source_event_id = ?""",
                String.class, lossRow.get("id")));

        // 分摊切片已登记为产品成本投入 (成本对象已存在), 在制里这一期不留余量
        assertEquals(2, db.queryForObject("""
                SELECT count(*) FROM stock_value_production_cost_inputs input
                JOIN workshop_material_close_allocations allocation ON allocation.id = input.approved_posting_id
                WHERE input.input_kind = 'PERIODIC_MATERIAL' AND input.execution_segment_id = ?
                  AND allocation.value_node_id = input.input_node_id""", Integer.class, scope));
        for (UUID goods : List.of(own, shared, expense, gain, loss)) {
            money("0", wipRemaining(periodLine(first, goods)));
        }

        // 理论明细追到每行报工: 5 件 x 0.2 公斤, 单重取结算时的 BOM
        Map<String, Object> theory = db.queryForMap("""
                SELECT theory.output_qty_base, theory.unit_weight, theory.weight_source, theory.theory_qty
                FROM workshop_material_close_theory_lines theory
                JOIN workshop_material_period_closes period_close ON period_close.id = theory.close_id
                WHERE period_close.period_id = ?""", first);
        money("5", theory.get("output_qty_base"));
        money("0.2", theory.get("unit_weight"));
        assertEquals("BOM_AT_CLOSE", theory.get("weight_source"));
        money("1", theory.get("theory_qty"));
        assertTrue(dateLocked(bench.segment), "已结算期间的报工日期被锁");

        // 报表: 用量表、产品用料 (独占期给真实单耗)、浪费率趋势、缺单重、收发明细
        bench.login();
        List<BinUsageRow> usage = reports.binUsage(bench.bin, null, null);
        assertEquals(5, usage.size());
        BinUsageRow ownUsage = usage.stream().filter(row -> own.equals(row.goodsId())).findFirst().orElseThrow();
        assertEquals("ALLOCATED", ownUsage.outcome());
        money("0.2", ownUsage.diffQty());
        money("12", ownUsage.valueAtClose());
        money("10", ownUsage.unitCost());
        assertEquals(1, ownUsage.closeNo());
        assertTrue(usage.stream().filter(row -> loss.equals(row.goodsId())).findFirst().orElseThrow()
                .flags().contains("ACTUAL_WITHOUT_THEORY"));
        List<ProductUsageRow> products = reports.productUsage(bench.bin, null, null);
        ProductUsageRow ownProduct = products.stream()
                .filter(row -> own.equals(row.materialGoodsId())).findFirst().orElseThrow();
        assertEquals(bench.world.goodsA(), ownProduct.productGoodsId());
        money("5", ownProduct.outputQty());
        money("0.2", ownProduct.unitWeight());
        money("1.2", ownProduct.allocatedQty());
        assertTrue(ownProduct.exclusivePeriod());
        money("0.24", ownProduct.actualPerUnit());
        List<WastePoint> trend = reports.wasteTrend(bench.bin, own);
        assertEquals(1, trend.size());
        money("0.2", trend.getFirst().wasteRate());
        assertTrue(reports.missingWeights(bench.bin).isEmpty());
        PageResponse<LedgerRow> ledger = reports.ledger(bench.bin, null, null, 1, 50);
        assertEquals(10, ledger.getTotal());
        LedgerRow issued = ledger.getItems().stream()
                .filter(row -> "ISSUE".equals(row.sourceKind()) && own.equals(row.goodsId())).findFirst().orElseThrow();
        assertNotNull(issued.docNo());
        assertTrue(issued.requestNo().startsWith("ZL"), issued.requestNo());
        assertTrue(ledger.getItems().stream().anyMatch(row -> "GAIN".equals(row.sourceKind())
                && row.remark() != null && row.remark().contains("盘点第 1 版")));

        // 没有"查看货品成本"的人看不到金额; 只有看与盘点权限的人没有撤销与重试按钮
        UUID viewer = bench.fixture.createUserWithPerms(bench.world, "wm-close-viewer-" + suffix(),
                "workshop_material:view", "workshop_material:count");
        bench.fixture.loginAs(viewer);
        List<BinUsageRow> masked = reports.binUsage(bench.bin, null, null);
        assertEquals(5, masked.size());
        assertTrue(masked.stream().allMatch(row -> row.valueAtClose() == null && row.currentValue() == null
                && row.unitCost() == null));
        assertTrue(closes.status(first).allowedActions().isEmpty());
        bench.login();
        CloseStatusView status = closes.status(first);
        assertEquals("CLOSED", status.status());
        assertEquals(1, status.lastClose().closeNo());
        assertTrue(status.allowedActions().contains("REOPEN"));
    }

    // =============================================================================================
    // 三种拦截、报工审核后立即再试、补录后结算、上一期没结时等待
    // =============================================================================================

    @Test
    void blockersNotifyTheRightPeopleAndTheChainClosesOnceEverythingIsSupplied() {
        CloseBench bench = CloseBench.create(beans, "blockers");
        UUID chosen = bench.granule("认料颗粒", "OWN");
        UUID other = bench.granule("另一种颗粒", "OWN");
        UUID bomKeeper = bench.fixture.createUserWithPerms(bench.world, "wm-close-bom-" + suffix(),
                "notice:read", "goods:bom:edit");
        bench.enable(List.of(new WorkshopMaterialChoicePort.ProductChoice(bench.world.goodsA(),
                WorkshopMaterialChoicePort.KIND_MATERIAL, List.of(new WorkshopMaterialChoicePort.MaterialRef(chosen, null)),
                false, null)));
        assertEquals("CHOICE", db.queryForObject("""
                SELECT origin FROM production_execution_periodic_materials WHERE execution_segment_id = ?""",
                String.class, bench.segment));
        // 一张没审的报工草稿 (制单人能收通知)
        Object draft = ReflectionTestUtils.invokeMethod(bench.fixture, "createPrefixReportDraft", bench.world,
                bench.plan, bench.planItem, bench.orderItem, "5");
        UUID draftId = ReflectionTestUtils.invokeMethod(draft, "id");
        UUID maker = ReflectionTestUtils.invokeMethod(draft, "reporter");
        db.update("""
                INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                SELECT ?, permission.id, 'grant' FROM permissions permission WHERE permission.code = 'notice:read'""",
                maker);
        String draftNo = db.queryForObject("SELECT bill_no FROM production_daily_reports WHERE id = ?", String.class,
                draftId);
        String productName = db.queryForObject("SELECT name FROM goods WHERE id = ?", String.class,
                bench.world.goodsA());

        bench.stockIn(other, "10", "10");
        bench.issue(other, "1", null);
        UUID first = bench.firstPeriod;
        UUID count = bench.startCount(first, BusinessTime.today().minusDays(1));
        bench.weighed(count, "other", other, "0.5");
        bench.weighed(count, "chosen", chosen, "0");
        bench.submit(count);

        // 未审报工 + 缺单重: 被拦, 差什么、谁来补, 通知审核人/制单人与 BOM 维护人
        assertEquals(Result.BLOCKED, closes.attempt(first, TriggerKind.AFTER_COUNT, bench.admin));
        assertEquals("COUNTED/BLOCKED", state(first));
        List<Map<String, Object>> blocked = blockers(first);
        assertEquals(List.of("DRAFT_REPORT", "MISSING_WEIGHT"), kinds(blocked));
        assertEquals(1, ((Number) blocked.get(0).get("count")).intValue());
        assertEquals("报工审核人或制单人", blocked.get(0).get("responsible"));
        assertEquals(List.of(draftNo), blocked.get(0).get("samples"));
        assertEquals("BOM 维护人", blocked.get(1).get("responsible"));
        assertEquals(List.of(productName), blocked.get(1).get("samples"));
        assertEquals(1, openNotices(bomKeeper, aggregate(first, "WEIGHT")));
        assertEquals(1, openNotices(maker, aggregate(first, "REPORT")), "审核人删不了别人的草稿, 制单人也收到");
        String content = db.queryForObject("""
                SELECT content FROM notices WHERE audience_user_id = ? AND aggregate_id = ? AND resolved_at IS NULL""",
                String.class, bomKeeper, aggregate(first, "WEIGHT"));
        assertFalse(content.matches(".*[A-Z_]{6,}.*"), "通知正文不带代号: " + content);
        bench.login();
        CloseStatusView blockedStatus = closes.status(first);
        assertEquals("BLOCKED", blockedStatus.closeState());
        assertEquals(2, blockedStatus.blockers().size());
        assertTrue(blockedStatus.allowedActions().contains("CLOSE_RETRY"));

        // 下一期也盘完了: 等上一期结算 (只在页面显示, 不发通知)
        UUID second = bench.nextPeriod(first);
        UUID secondCount = bench.startCount(second, BusinessTime.today());
        bench.weighed(secondCount, "other", other, "0.5");
        bench.submit(secondCount);
        assertEquals(Result.BLOCKED, closes.attempt(second, TriggerKind.AFTER_COUNT, bench.admin));
        assertEquals(List.of("PREVIOUS_PERIOD_OPEN"), kinds(blockers(second)));
        assertEquals(0, db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_id IN (?, ?, ?)",
                Integer.class, aggregate(second, "REPORT"), aggregate(second, "WEIGHT"), aggregate(second, "STOCK")));

        // 补单重; 审核那张草稿后立即在后台再试一次: 现在差的是"有理论没进过料"
        bench.edge(bench.world.goodsA(), chosen, "0.1");
        ReflectionTestUtils.setField(trigger, "enabled", true);
        try {
            bench.fixture.loginAs(maker);
            dailyReports.approve(draftId, DailyReportApproveRequests.freshKey());
            awaitBlockers(first, List.of("THEORY_WITHOUT_STOCK"));
        } finally {
            ReflectionTestUtils.setField(trigger, "enabled", false);
            bench.login();
        }
        assertEquals(0, openNotices(bomKeeper, aggregate(first, "WEIGHT")), "补好的拦截项撤卡");
        assertEquals(0, openNotices(maker, aggregate(first, "REPORT")));

        // 仓库在直接发料里补录漏录的那批到这一期: 同事务自动更正 (领入 1.2, 实际 1.2, 追加 21 型)
        bench.stockIn(chosen, "5", "12");
        bench.issue(chosen, "1.2", new Supplement(first, "上午那批忘了录"));
        money("1.2", db.queryForObject("SELECT actual_qty FROM workshop_material_period_lines WHERE id = ?",
                BigDecimal.class, periodLine(first, chosen)));

        // 定时补做 (同一入口): 本期结算后, 等着的下一期跟着结
        assertEquals(Result.CLOSED, closes.attempt(first, TriggerKind.SCHEDULED, bench.admin));
        assertEquals("CLOSED/NONE", state(first));
        assertEquals("CLOSED/NONE", state(second));
        Map<String, Object> chosenRow = material(first, chosen);
        assertEquals("ALLOCATED", chosenRow.get("outcome"));
        money("1.2", chosenRow.get("consumed_qty"));
        money("1", chosenRow.get("theory_qty"), "两张报工共 10 件 x 0.1 公斤");
        money("0.2", chosenRow.get("waste_rate"));
        assertEquals(2, db.queryForObject("""
                SELECT count(*) FROM workshop_material_close_theory_lines theory
                JOIN workshop_material_period_closes period_close ON period_close.id = theory.close_id
                WHERE period_close.period_id = ? AND theory.weight_source = 'BOM_AT_CLOSE'""", Integer.class, first));
        Map<String, Object> otherRow = material(first, other);
        assertEquals("UNALLOCATED_LOSS", otherRow.get("outcome"));
        money("0.5", otherRow.get("loss_qty"));
        assertEquals("NOTHING", material(second, other).get("outcome"));
        assertEquals(0, openNoticesForAggregate(aggregate(first, "STOCK")));
    }

    // =============================================================================================
    // 撤销结算、保留期、重新结算、只能撤最近一期
    // =============================================================================================

    @Test
    void reopenReturnsOnlyCostHoldsForADayAndSettleAgainWritesANewClose() {
        CloseBench bench = CloseBench.create(beans, "reopen");
        UUID own = bench.granule("主料颗粒", "OWN");
        bench.edge(bench.world.goodsA(), own, "0.2");
        bench.stockIn(own, "10", "10");
        bench.enable(List.of());
        bench.issue(own, "3", null);
        UUID first = bench.firstPeriod;
        UUID count = bench.startCount(first, BusinessTime.today().minusDays(1));
        bench.weighed(count, "own", own, "1.8");
        bench.submit(count);
        assertEquals(Result.CLOSED, closes.attempt(first, TriggerKind.AFTER_COUNT, bench.admin));
        UUID line = periodLine(first, own);
        int postings = postingCount(line);
        money("1.8", balance(bench.bin, own));
        assertTrue(dateLocked(bench.segment));

        // 撤销: 只撤成本, 数量不动; 期间回到已盘点并保留 24 小时
        bench.login();
        CloseStatusView reopened = closes.reopen(first, new ReopenRequest(bench.periodVersion(first),
                "盘点数录错了", key("reopen")));
        assertEquals("COUNTED", reopened.status());
        assertEquals("HELD", reopened.closeState());
        assertNotNull(reopened.heldUntil());
        assertEquals(Boolean.TRUE, db.queryForObject("""
                SELECT held_until > now() + interval '23 hours' AND held_until <= now() + interval '24 hours'
                FROM workshop_material_periods WHERE id = ?""", Boolean.class, first), "保留 24 小时");
        assertNull(reopened.lastClose());
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM workshop_material_period_closes
                WHERE period_id = ? AND status = 'REVERSED' AND reversal_event_id IS NOT NULL""", Integer.class, first));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM workshop_material_close_allocations allocation
                JOIN workshop_material_close_materials material ON material.id = allocation.close_material_id
                JOIN workshop_material_period_closes period_close ON period_close.id = material.close_id
                WHERE period_close.period_id = ? AND allocation.reversed_at IS NULL""", Integer.class, first));
        money("1.2", wipRemaining(line), "分摊原路退回在制");
        money("1.8", balance(bench.bin, own));
        assertEquals(postings, postingCount(line), "撤销不动盘点过账");
        assertFalse(dateLocked(bench.segment), "撤销后这一期的报工可以再改");

        // 保留期内定时任务与自动触发都不重结
        assertEquals(Result.SKIPPED, closes.attempt(first, TriggerKind.SCHEDULED, bench.admin));
        scheduler.runBatch();
        assertEquals("COUNTED/HELD", state(first));

        // 更正盘点 (少数了 0.3 公斤) 后点"重新结算": 后台结算, 写新的一次结算
        UUID corrected = bench.correct(first, "袋料少数了一袋");
        bench.login();
        counts.saveLine(corrected, "own", new CountLineInput(0L, "WEIGHED", null, own, null, null, null,
                new BigDecimal("1.5"), null, null, null));
        bench.submit(corrected);
        assertEquals("COUNTED/HELD", state(first), "更正提交不打破保留期");
        bench.login();
        CloseStatusView queued = closes.retry(first, new RetryRequest(key("retry")));
        assertEquals("QUEUED", queued.closeState());
        awaitState(first, "CLOSED/NONE");
        assertEquals(2, db.queryForObject("""
                SELECT close_no FROM workshop_material_period_closes WHERE period_id = ? AND status = 'ACTIVE'""",
                Integer.class, first));
        money("1.5", material(first, own).get("consumed_qty"));
        money("0", wipRemaining(line));
        assertEquals("MANUAL", db.queryForObject("""
                SELECT trigger_kind FROM workshop_material_period_closes WHERE period_id = ? AND status = 'ACTIVE'""",
                String.class, first));

        // 下一期也提交盘点以后, 不能再撤这一期
        UUID second = bench.nextPeriod(first);
        UUID secondCount = bench.startCount(second, BusinessTime.today());
        bench.weighed(secondCount, "own", own, "1.5");
        bench.submit(secondCount);
        bench.login();
        ApiException notLatest = assertThrows(ApiException.class, () -> closes.reopen(first,
                new ReopenRequest(bench.periodVersion(first), "还想再撤一次", key("reopen-again"))));
        assertEquals(ErrorCode.CONFLICT, notLatest.getCode());
        assertTrue(notLatest.getMessage().contains("最近一期"), notLatest.getMessage());
    }

    // =============================================================================================
    // 并发与失败退避
    // =============================================================================================

    @Test
    void twoConcurrentAttemptsCloseThePeriodOnlyOnce() throws Exception {
        CloseBench bench = countedSingleMaterial("concurrent");
        UUID first = bench.firstPeriod;
        ExecutorService pool = Executors.newFixedThreadPool(2);
        try {
            CountDownLatch ready = new CountDownLatch(2);
            CountDownLatch go = new CountDownLatch(1);
            List<Future<Result>> futures = new ArrayList<>();
            for (int index = 0; index < 2; index++) {
                futures.add(pool.submit(() -> {
                    ready.countDown();
                    go.await();
                    return closes.attempt(first, TriggerKind.AFTER_COUNT, bench.admin);
                }));
            }
            assertTrue(ready.await(10, TimeUnit.SECONDS));
            go.countDown();
            List<Result> results = new ArrayList<>();
            for (Future<Result> future : futures) results.add(future.get(120, TimeUnit.SECONDS));
            assertEquals(1, Collections.frequency(results, Result.CLOSED), "只结一次: " + results);
            assertEquals(1, Collections.frequency(results, Result.SKIPPED), "另一个取不到期间锁或看到已结算: " + results);
        } finally {
            pool.shutdownNow();
        }
        assertEquals(1, db.queryForObject("SELECT count(*) FROM workshop_material_period_closes WHERE period_id = ?",
                Integer.class, first));
        assertEquals("CLOSED/NONE", state(first));
    }

    @Test
    void threeFailuresBackOffToDailyAndNotifySetupHolders() {
        CloseBench bench = countedSingleMaterial("failing");
        UUID first = bench.firstPeriod;
        UUID setupHolder = bench.fixture.createUserWithPerms(bench.world, "wm-close-setup-" + suffix(),
                "notice:read", "workshop_material:setup");
        // 操作人不是有效账号: 写结算结果时失败, 整体回滚后另起事务记失败
        UUID ghost = UUID.randomUUID();
        for (int attempt = 1; attempt <= 3; attempt++) {
            assertEquals(Result.FAILED, closes.attempt(first, TriggerKind.SCHEDULED, ghost));
            assertEquals(attempt, db.queryForObject(
                    "SELECT close_failures FROM workshop_material_periods WHERE id = ?", Integer.class, first));
            assertEquals(0, db.queryForObject(
                    "SELECT count(*) FROM workshop_material_period_closes WHERE period_id = ?", Integer.class, first));
        }
        bench.login();
        CloseStatusView failing = closes.status(first);
        assertEquals("FAILED", failing.closeState());
        assertEquals(3, failing.failures());
        assertTrue(failing.lastErrorMessage().contains("自动重试"), failing.lastErrorMessage());
        assertFalse(failing.lastErrorMessage().matches(".*(SQL|Exception|[A-Z_]{6,}).*"),
                "只给业务文案: " + failing.lastErrorMessage());
        assertEquals(1, openNotices(setupHolder, aggregate(first, "FAILING")));

        // 连续失败 3 次后定时任务改为每天一次: 这一轮不再尝试
        int attempts = db.queryForObject("SELECT close_attempts FROM workshop_material_periods WHERE id = ?",
                Integer.class, first);
        scheduler.runBatch();
        assertEquals(attempts, db.queryForObject("SELECT close_attempts FROM workshop_material_periods WHERE id = ?",
                Integer.class, first));

        // "立即重试"不受退避限制; 结算成功后失败提醒撤卡
        assertEquals(Result.CLOSED, closes.attempt(first, TriggerKind.MANUAL, bench.admin));
        assertEquals("CLOSED/NONE", state(first));
        assertEquals(0, db.queryForObject("SELECT close_failures FROM workshop_material_periods WHERE id = ?",
                Integer.class, first));
        assertEquals(0, openNotices(setupHolder, aggregate(first, "FAILING")));
    }

    /** 撤销结算只给逐人授予的权限并要再输入一次登录密码; 立即重试要盘点权限; 看状态只要查看权限。 */
    @Test
    void closeEndpointsDeclareTheirPermissionsAndStepUp() throws Exception {
        Method reopen = WorkshopMaterialCloseController.class.getMethod("reopen", UUID.class, ReopenRequest.class);
        assertNotNull(reopen.getAnnotation(RequiresStepUp.class));
        assertEquals("hasAuthority('workshop_material:reopen')", reopen.getAnnotation(PreAuthorize.class).value());
        Method retry = WorkshopMaterialCloseController.class.getMethod("retry", UUID.class, RetryRequest.class);
        assertNull(retry.getAnnotation(RequiresStepUp.class));
        assertEquals("hasAuthority('workshop_material:count')", retry.getAnnotation(PreAuthorize.class).value());
        Method status = WorkshopMaterialCloseController.class.getMethod("status", UUID.class);
        assertEquals("hasAuthority('workshop_material:view')", status.getAnnotation(PreAuthorize.class).value());
    }

    // =============================================================================================
    // 夹具
    // =============================================================================================

    /** 一种主料、盘完待结算: 发 3 公斤, 盘剩 1.8, 理论 1.0。 */
    private CloseBench countedSingleMaterial(String tag) {
        CloseBench bench = CloseBench.create(beans, tag);
        UUID own = bench.granule("主料颗粒", "OWN");
        bench.edge(bench.world.goodsA(), own, "0.2");
        bench.stockIn(own, "10", "10");
        bench.enable(List.of());
        bench.issue(own, "3", null);
        UUID count = bench.startCount(bench.firstPeriod, BusinessTime.today().minusDays(1));
        bench.weighed(count, "own", own, "1.8");
        bench.submit(count);
        return bench;
    }

    /**
     * 一张在产的注塑工单: 世界里的成品 A 计划 10 件, 已领料、已开工、已审报工 5 件 (表头日期 2026-01-25);
     * 之后按场景加整批领料的料、BOM 期间边或认料, 开启车间整批领料 (启用日 2026-01-01, 在产工单当场绑定)。
     * 全部以超管操作 (全权限、不受车间范围限制)。
     */
    static final class CloseBench {

        static final LocalDate GO_LIVE = LocalDate.of(2026, 1, 1);

        @Autowired AutowireCapableBeanFactory beans;
        @Autowired JdbcTemplate db;
        @Autowired StockDocService stock;
        @Autowired WorkshopMaterialSettingsService settings;
        @Autowired WorkshopMaterialRequisitionService requisitions;
        @Autowired WorkshopMaterialPeriodService periods;
        @Autowired WorkshopMaterialCountService counts;
        @Autowired InventoryValueWorkService valueWork;

        FullChainEndToEndTest fixture;
        FullChainEndToEndTest.World world;
        UUID admin;
        UUID plan;
        UUID planItem;
        UUID orderItem;
        UUID report;
        UUID segment;
        UUID workshop;
        UUID receiver;
        UUID kg;
        UUID bin;
        UUID firstPeriod;

        static CloseBench create(AutowireCapableBeanFactory beans, String tag) {
            CloseBench bench = new CloseBench();
            beans.autowireBean(bench);
            bench.start(tag);
            return bench;
        }

        private void start(String tag) {
            fixture = new FullChainEndToEndTest();
            beans.autowireBean(fixture);
            world = fixture.seedWorld("wm-close-" + tag + "-" + suffix());
            admin = world.superAdminUserId();
            fixture.loginAs(admin);
            ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", world, "10");
            plan = ReflectionTestUtils.invokeMethod(fixture, "approvedPlan", world, world.goodsA(), "10", "10");
            ReflectionTestUtils.invokeMethod(fixture, "issueReadyPlanAndMaterials", world, plan);
            planItem = db.queryForObject("""
                    SELECT id FROM production_plan_items WHERE plan_id = ? AND goods_id = ? AND NOT is_deleted""",
                    UUID.class, plan, world.goodsA());
            orderItem = db.queryForObject("""
                    SELECT order_item_id FROM plan_order_item_links WHERE plan_item_id = ? AND NOT is_deleted""",
                    UUID.class, planItem);
            report = ReflectionTestUtils.invokeMethod(fixture, "reportAndApprove", world, planItem, orderItem,
                    world.goodsA(), "5");
            segment = db.queryForObject("""
                    SELECT id FROM production_execution_segments
                    WHERE source_plan_item_id = ? AND NOT is_deleted ORDER BY created_at LIMIT 1""",
                    UUID.class, planItem);
            Map<String, Object> assigned = db.queryForMap("""
                    SELECT workshop_department_id, responsible_employee_id, status
                    FROM production_execution_segments WHERE id = ?""", segment);
            assertEquals("IN_PROGRESS", assigned.get("status"), "报了一半的工单仍在生产中");
            workshop = (UUID) assigned.get("workshop_department_id");
            receiver = (UUID) assigned.get("responsible_employee_id");
            assertNotNull(workshop);
            assertNotNull(receiver);
            kg = massUnit();
            login();
        }

        void login() {
            fixture.loginAs(admin);
        }

        /** 成品点收入库 (成本对象随之建立), 并等库存价值后台任务做完。 */
        void confirmInboundAndDrain() {
            login();
            fixture.confirmFinishedInboundFully(fixture.finishedInDocForReport(report));
            // 成品入库的价值任务之外, 颗粒货品后续 stockIn 的价值任务也要能等到——
            // drain 范围含已建颗粒(此时颗粒价值任务尚未产生, 等的是 A/B/E 成品)。
            var drainGoods = new java.util.ArrayList<UUID>(List.of(world.goodsA(), world.goodsB(), world.goodsE()));
            drainGoods.addAll(granules);
            InventoryValueWorkTestSupport.drain(valueWork, db, drainGoods);
            login();
        }

        final java.util.List<UUID> granules = new java.util.ArrayList<>();

        UUID granule(String name, String costBasis) {
            UUID id = UUID.randomUUID();
            granules.add(id);
            int legacy = db.queryForObject("SELECT legacy_id FROM units WHERE id = ?", Integer.class, kg);
            db.update("""
                    INSERT INTO goods(id, code, name, source_type, status, unit_id, unit_legacy_id, price, code_sequence,
                                      issue_method, periodic_cost_basis, bulk_package_qty, owning_warehouse_id, min_qty)
                    VALUES (?, ?, ?, '采购', '使用', ?, ?, 10, (SELECT coalesce(max(code_sequence), 0) + 1 FROM goods),
                            'PERIODIC', ?, 25, ?, 0)""",
                    id, "WMC-" + id.toString().substring(0, 8), name + "-" + id.toString().substring(0, 4), kg, legacy,
                    costBasis, world.warehouseId());
            return id;
        }

        /** 期间边: 只填单个重量 (公斤/件), 形状按 V740 守卫。 */
        void edge(UUID product, UUID granule, String kilogramsPerPiece) {
            db.update("""
                    INSERT INTO goods_bom_items(goods_id, component_goods_id, qty, hard_gate, control_stage,
                                                consumption_basis, basis_output_qty)
                    VALUES (?, ?, ?, FALSE, 'START', 'PER_UNIT', 1)""",
                    product, granule, new BigDecimal(kilogramsPerPiece));
        }

        /** 颗粒按单价进仓库叶仓 (内料仓发料的来源)。 */
        void stockIn(UUID goods, String qty, String price) {
            login();
            StockDocSaveRequest request = new StockDocSaveRequest();
            request.setDocType("OTHER_IN");
            request.setWarehouseId(world.warehouseId());
            request.setBillDate(BusinessTime.today());
            StockDocItemLine line = new StockDocItemLine();
            line.setGoodsId(goods);
            line.setUnitId(kg);
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(new BigDecimal(qty));
            line.setPrice(new BigDecimal(price));
            line.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal(price)));
            line.setAmountLocal(line.getAmountOriginal());
            request.setItems(List.of(line));
            stock.approve(stock.create(request).getId());
        }

        void enable(List<WorkshopMaterialChoicePort.ProductChoice> choices) {
            login();
            var view = settings.update(workshop, new SettingsRequest(0L, true, world.warehouseId(), GO_LIVE, choices,
                    key("enable")));
            assertTrue(view.periodicEnabled());
            bin = view.binWarehouseId();
            firstPeriod = view.currentPeriod().id();
        }

        RequisitionView issue(UUID goods, String qty, Supplement supplement) {
            login();
            return requisitions.directIssue(new DirectIssueRequest(workshop, receiver, List.of(new DirectIssueLine(
                    goods, null, null, new BigDecimal(qty), world.warehouseId())), supplement, key("issue")));
        }

        /** 车间申请退回、仓库收退回。 */
        RequisitionView returned(UUID goods, String qty) {
            login();
            RequisitionView requested = requisitions.create(new RequisitionCreate("RETURN", workshop, List.of(
                    new RequisitionLineInput(goods, null, new BigDecimal(qty), null)), null, key("return")));
            return requisitions.fulfil(requested.id(), new FulfilRequest(requested.rowVersion(), List.of(
                    new FulfilLine(requested.lines().getFirst().id(), world.warehouseId(), new BigDecimal(qty))),
                    null, key("receive-return")));
        }

        UUID startCount(UUID period, LocalDate cutoff) {
            login();
            return periods.startCount(period, new StartCountRequest(periodVersion(period), cutoff, key("start")))
                    .count().id();
        }

        void weighed(UUID count, String lineKey, UUID goods, String qty) {
            login();
            counts.saveLine(count, lineKey, new CountLineInput(null, "WEIGHED", null, goods, null, null, null,
                    new BigDecimal(qty), null, null, null));
        }

        PeriodView submit(UUID count) {
            login();
            long version = db.queryForObject("SELECT row_version FROM workshop_material_counts WHERE id = ?",
                    Long.class, count);
            return counts.submit(count, new VersionRequest(version, key("submit")));
        }

        UUID correct(UUID period, String reason) {
            login();
            return counts.correct(period, new CorrectCountRequest(periodVersion(period), reason, key("correct"))).id();
        }

        long periodVersion(UUID period) {
            return db.queryForObject("SELECT row_version FROM workshop_material_periods WHERE id = ?", Long.class,
                    period);
        }

        UUID nextPeriod(UUID period) {
            return db.queryForObject("""
                    SELECT following.id FROM workshop_material_periods current_period
                    JOIN workshop_material_periods following
                      ON following.bin_warehouse_id = current_period.bin_warehouse_id
                     AND following.period_no = current_period.period_no + 1
                    WHERE current_period.id = ?""", UUID.class, period);
        }

        private UUID massUnit() {
            UUID id = UUID.randomUUID();
            db.update("INSERT INTO units(id, legacy_id, code, name, status) VALUES (?, ?, ?, '千克', '使用')",
                    id, 900_000_000 + ThreadLocalRandom.current().nextInt(90_000_000), "KG-" + id.toString().substring(0, 8));
            db.update("""
                    INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                    VALUES (?, 'MASS', 'KG', 'MANUAL_GOVERNANCE')""", id);
            return id;
        }
    }

    // ---------------------------------------------------------------------------------------------

    private String state(UUID period) {
        return db.queryForObject("SELECT status || '/' || close_state FROM workshop_material_periods WHERE id = ?",
                String.class, period);
    }

    /** 这一期这种料在有效结算里的结果。 */
    private Map<String, Object> material(UUID period, UUID goods) {
        return db.queryForMap("""
                SELECT material.id, material.outcome, material.consumed_qty, material.loss_qty, material.theory_qty,
                       material.allocation_basis_qty, material.waste_rate, array_to_string(material.flags, ',') AS flags,
                       material.value_at_close
                FROM workshop_material_close_materials material
                JOIN workshop_material_period_closes period_close
                  ON period_close.id = material.close_id AND period_close.status = 'ACTIVE'
                JOIN workshop_material_period_lines line ON line.id = material.period_line_id
                WHERE line.period_id = ? AND line.goods_id = ?""", period, goods);
    }

    private List<Map<String, Object>> allocations(UUID closeMaterialId) {
        return db.queryForList("""
                SELECT cost_scope_segment_id, basis_qty, allocated_qty, is_tail, value_node_id, value_at_close
                FROM workshop_material_close_allocations WHERE close_material_id = ? ORDER BY cost_scope_segment_id""",
                closeMaterialId);
    }

    private UUID periodLine(UUID period, UUID goods) {
        return db.queryForObject("""
                SELECT id FROM workshop_material_period_lines WHERE period_id = ? AND goods_id = ? AND color_id IS NULL""",
                UUID.class, period, goods);
    }

    /** 期间用量行名下在制里还剩的数量。 */
    private BigDecimal wipRemaining(UUID periodLine) {
        return db.queryForObject("""
                SELECT COALESCE(sum(head.range_to - head.range_from), 0)
                FROM stock_value_nodes root
                JOIN stock_value_nodes head ON head.id = root.return_head_id
                WHERE root.kind = 'ISSUE_POSITION' AND root.root_issue_id = root.id
                  AND head.owner_kind = 'WIP' AND head.owner_id = ?""", BigDecimal.class, periodLine);
    }

    private int postingCount(UUID periodLine) {
        return db.queryForObject("SELECT count(*) FROM workshop_material_count_postings WHERE period_line_id = ?",
                Integer.class, periodLine);
    }

    private BigDecimal balance(UUID warehouse, UUID goods) {
        return db.queryForObject("""
                SELECT COALESCE((SELECT qty FROM stock_balances WHERE warehouse_id = ? AND goods_id = ? AND color_id IS NULL), 0)""",
                BigDecimal.class, warehouse, goods);
    }

    private boolean dateLocked(UUID segment) {
        return Boolean.TRUE.equals(db.queryForObject("SELECT fn_workshop_material_report_date_locked(?, ?)",
                Boolean.class, segment, REPORT_DATE));
    }

    private List<Map<String, Object>> blockers(UUID period) {
        String stored = db.queryForObject("SELECT CAST(close_blockers AS text) FROM workshop_material_periods WHERE id = ?",
                String.class, period);
        try {
            return json.readValue(stored, BLOCKERS);
        } catch (Exception error) {
            throw new AssertionError("结算拦截项不是合法的列表: " + stored, error);
        }
    }

    private static List<String> kinds(List<Map<String, Object>> blockers) {
        return blockers.stream().map(row -> (String) row.get("kind")).toList();
    }

    private void awaitBlockers(UUID period, List<String> expected) {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60);
        while (System.nanoTime() < deadline) {
            if (state(period).equals("COUNTED/BLOCKED") && kinds(blockers(period)).equals(expected)) return;
            pause();
        }
        fail("后台结算没有在 60 秒内把拦截项更新为 " + expected + ", 现在是 " + state(period) + " " + blockers(period));
    }

    private void awaitState(UUID period, String expected) {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60);
        while (System.nanoTime() < deadline) {
            if (state(period).equals(expected)) return;
            pause();
        }
        fail("后台结算没有在 60 秒内完成, 现在是 " + state(period));
    }

    private static void pause() {
        try {
            Thread.sleep(200);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new AssertionError("等待后台结算时被中断", interrupted);
        }
    }

    private int openNotices(UUID user, UUID aggregate) {
        return db.queryForObject("""
                SELECT count(*) FROM notices WHERE audience_user_id = ? AND aggregate_id = ? AND resolved_at IS NULL""",
                Integer.class, user, aggregate);
    }

    private int openNoticesForAggregate(UUID aggregate) {
        return db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_id = ? AND resolved_at IS NULL",
                Integer.class, aggregate);
    }

    private static UUID aggregate(UUID period, String suffix) {
        return UUID.nameUUIDFromBytes((period + ":" + suffix).getBytes(StandardCharsets.UTF_8));
    }

    static String key(String tag) {
        return "wm-close-" + tag + "-" + UUID.randomUUID();
    }

    static String suffix() {
        return UUID.randomUUID().toString().substring(0, 8);
    }

    static void money(String expected, Object actual) {
        money(expected, actual, null);
    }

    static void money(String expected, Object actual, String message) {
        assertNotNull(actual, message);
        BigDecimal value = actual instanceof BigDecimal decimal ? decimal : new BigDecimal(actual.toString());
        assertEquals(0, new BigDecimal(expected).compareTo(value),
                () -> (message == null ? "" : message + ": ") + "expected " + expected + ", actual " + value);
    }
}
