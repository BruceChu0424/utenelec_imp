package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMachineService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialChoiceAdapter;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCountService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CancelRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ChooseRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerSpec;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineBatchCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.OtherIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.LeafStockView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialStockOption;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionRow;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountResult;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.Supplement;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.VersionRequest;
import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialOtherIssueService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPeriodService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPositionQueryService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
import org.junit.jupiter.api.AfterEach;
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

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 车间内料仓的进出 (包 S2): 直接发料按叶仓拆调拨、原子回滚与同号重放, 车间申请与按申请发料、
 * 退回点收、其它耗用、作废, 盘点中发料记进下一期, 漏录补录到盘点中或已盘点的那一期 (已盘点的同事务
 * 自动更正), 通用单据进出内料仓被拒, 公共可用量不含内料仓颗粒, 业务清空在有认料与机台时能跑通。
 *
 * <p>全部走真实服务与真实库 (库存单据、流水、估价、V740 的守卫与延迟断言), 按真实账号切换:
 * 仓库 (发料、设置)、另一位只持发料权限但不管这个仓的仓管、车间 (申请、盘点、认料)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!",
        "uten.workshop-material.auto-close.enabled=false"})
class WorkshopMaterialIssuePostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired DataSource dataSource;
    @Autowired StockDocService stock;
    @Autowired WorkshopMaterialSettingsService settings;
    @Autowired WorkshopMaterialRequisitionService requisitions;
    @Autowired WorkshopMaterialOtherIssueService otherIssues;
    @Autowired WorkshopMaterialPeriodService periods;
    @Autowired WorkshopMaterialCountService counts;
    @Autowired WorkshopMaterialPositionQueryService positions;
    @Autowired WorkshopMachineService machines;
    @Autowired WorkshopMaterialChoiceAdapter choices;
    @Autowired com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPositionController positionController;
    @Autowired com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionController requisitionController;
    FullChainEndToEndTest fixture;

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    /** 一个车间: 两个叶仓 (A 为内料仓的主仓), 仓库账号管 A, 另一位发料人不管任何仓, 车间账号在车间里。 */
    private record Shop(FullChainEndToEndTest.World world, UUID admin, UUID workshop, UUID worker, UUID kg,
                        UUID leafA, UUID leafB, UUID warehouseUser, UUID otherIssuer, UUID workshopUser) {}

    // =============================================================================================
    // 直接发料
    // =============================================================================================

    @Test
    void directIssueSplitsByLeafReplaysOnceAndRemembersTheReceiver() {
        Shop shop = shop("direct");
        UUID granule = granule(shop, "颗粒甲", shop.leafA());
        otherIn(shop, shop.leafA(), granule, "200", "10");
        otherIn(shop, shop.leafB(), granule, "100", "20");
        UUID bin = enable(shop, BusinessTime.today());
        UUID period = openPeriod(bin);

        fixture.loginAs(shop.warehouseUser());
        DirectIssueRequest request = new DirectIssueRequest(shop.workshop(), shop.worker(), List.of(
                new DirectIssueLine(granule, null, new BigDecimal("4"), null, shop.leafA()),
                new DirectIssueLine(granule, null, null, new BigDecimal("50"), shop.leafB())), null, key("direct"));
        RequisitionView issued = requisitions.directIssue(request);

        assertEquals("DONE", issued.status());
        assertEquals("WAREHOUSE_DIRECT", issued.origin());
        assertTrue(issued.requestNo().startsWith("ZL"), issued.requestNo());
        assertEquals(1, issued.lines().size(), "一种料一行申请");
        money("150", issued.lines().getFirst().fulfilledQty());
        assertEquals(2, issued.documents().size(), "两个叶仓拆成两张调拨单");
        assertNotEquals(issued.documents().get(0).billNo(), issued.documents().get(1).billNo());
        assertTrue(issued.documents().stream().allMatch(document -> period.equals(document.periodId())));
        balance(bin, granule, "150", "2000");
        balance(shop.leafA(), granule, "100", "1000");
        balance(shop.leafB(), granule, "50", "1000");
        assertEquals(BusinessTime.today(), db.queryForObject("""
                SELECT DISTINCT business_date FROM workshop_material_requisition_postings posting
                JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
                WHERE line.requisition_id = ?""", LocalDate.class, issued.id()));

        // 同号同内容重放: 返回原结果, 不重复入账; 命令账本只一行
        RequisitionView replay = requisitions.directIssue(request);
        assertEquals(issued.id(), replay.id());
        balance(bin, granule, "150", "2000");
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM workshop_material_requisitions WHERE workshop_department_id = ?""",
                Integer.class, shop.workshop()));
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM workshop_material_commands WHERE idempotency_key = ? AND target_id = ?""",
                Integer.class, request.idempotencyKey(), issued.id()));
        // 同号不同内容: 拒绝
        DirectIssueRequest changed = new DirectIssueRequest(shop.workshop(), shop.worker(), List.of(
                new DirectIssueLine(granule, null, null, new BigDecimal("10"), shop.leafA())), null,
                request.idempotencyKey());
        ApiException reused = assertThrows(ApiException.class, () -> requisitions.directIssue(changed));
        assertEquals(ErrorCode.CONFLICT, reused.getCode());
        assertTrue(reused.getMessage().contains("同一请求号"), reused.getMessage());

        // 领料人默认该车间上一次的领料人
        assertEquals(shop.worker(), requisitions.defaults(shop.workshop()).receiverEmployeeId());
    }

    @Test
    void directIssueRollsBackAsAWholeWhenOneLeafIsShort() {
        Shop shop = shop("atomic");
        UUID granule = granule(shop, "颗粒乙", shop.leafA());
        otherIn(shop, shop.leafA(), granule, "200", "10");
        otherIn(shop, shop.leafB(), granule, "10", "10");
        UUID bin = enable(shop, BusinessTime.today());

        fixture.loginAs(shop.warehouseUser());
        DirectIssueRequest request = new DirectIssueRequest(shop.workshop(), shop.worker(), List.of(
                new DirectIssueLine(granule, null, null, new BigDecimal("100"), shop.leafA()),
                new DirectIssueLine(granule, null, null, new BigDecimal("50"), shop.leafB())), null, key("atomic"));
        ApiException shortage = assertThrows(ApiException.class, () -> requisitions.directIssue(request));
        assertTrue(shortage.getMessage().contains("不足"), shortage.getMessage());

        assertEquals(0, db.queryForObject("SELECT count(*) FROM workshop_material_requisitions WHERE workshop_department_id = ?",
                Integer.class, shop.workshop()));
        assertEquals(0, db.queryForObject("SELECT count(*) FROM workshop_material_stock_documents WHERE bin_warehouse_id = ?",
                Integer.class, bin));
        assertEquals(0, db.queryForObject("SELECT count(*) FROM workshop_material_commands WHERE idempotency_key = ?",
                Integer.class, request.idempotencyKey()));
        balance(shop.leafA(), granule, "200", "2000");
        assertEquals(0, db.queryForObject(
                "SELECT count(*) FROM stock_balances WHERE warehouse_id = ? AND goods_id = ? AND qty <> 0",
                Integer.class, bin, granule));
    }

    // =============================================================================================
    // 车间申请、按申请发、退回点收、其它耗用、作废
    // =============================================================================================

    @Test
    void requestIsNotifiedOnlyToTheLeafKeeperAndFulfilReturnOtherIssueAndCancelWork() {
        Shop shop = shop("request");
        UUID granule = granule(shop, "颗粒丙", shop.leafA());
        otherIn(shop, shop.leafA(), granule, "200", "10");
        UUID bin = enable(shop, BusinessTime.today());
        UUID period = openPeriod(bin);

        fixture.loginAs(shop.workshopUser());
        RequisitionView request = requisitions.create(new RequisitionCreate("ISSUE", shop.workshop(),
                List.of(new RequisitionLineInput(granule, null, null, new BigDecimal("2"))), "机台快用完了",
                key("request")));
        assertEquals("PENDING", request.status());
        money("50", request.lines().getFirst().requestedQty());
        assertEquals(shop.leafA(), request.lines().getFirst().suggestedLeafWarehouseId());

        // 待办只通知预填叶仓的仓管 (持发料权限); 另一位发料人不管这个仓, 收不到
        assertEquals(1, notices(shop.warehouseUser(), "WORKSHOP_MATERIAL_REQUISITION_PENDING", request.id()));
        assertEquals(0, notices(shop.otherIssuer(), "WORKSHOP_MATERIAL_REQUISITION_PENDING", request.id()));
        String content = db.queryForObject("""
                SELECT content FROM notices WHERE audience_user_id = ? AND aggregate_id = ?""",
                String.class, shop.warehouseUser(), request.id());
        assertTrue(content.contains("颗粒丙") && content.contains("50 公斤"), content);

        // 仓管按申请发 (改成 60 公斤); 办完撤卡
        fixture.loginAs(shop.warehouseUser());
        RequisitionView done = requisitions.fulfil(request.id(), new FulfilRequest(request.rowVersion(),
                List.of(new FulfilLine(request.lines().getFirst().id(), null, new BigDecimal("60"))), null,
                key("fulfil")));
        assertEquals("DONE", done.status());
        money("60", done.lines().getFirst().fulfilledQty());
        assertEquals(period, done.documents().getFirst().periodId());
        balance(bin, granule, "60", "600");
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM notices WHERE aggregate_id = ? AND resolved_at IS NULL""", Integer.class,
                request.id()));
        ApiException again = assertThrows(ApiException.class, () -> requisitions.fulfil(request.id(),
                new FulfilRequest(done.rowVersion(), List.of(new FulfilLine(request.lines().getFirst().id(), null,
                        BigDecimal.ONE)), null, key("fulfil-again"))));
        assertTrue(again.getMessage().contains("办完或作废"), again.getMessage());

        // 车间退回 20 公斤, 仓库点收到叶仓 A (内料仓一侧 8 型调出)
        fixture.loginAs(shop.workshopUser());
        RequisitionView returning = requisitions.create(new RequisitionCreate("RETURN", shop.workshop(),
                List.of(new RequisitionLineInput(granule, null, new BigDecimal("20"), null)), null, key("return")));
        assertTrue(returning.requestNo().startsWith("ZT"), returning.requestNo());
        assertEquals(1, notices(shop.warehouseUser(), "WORKSHOP_MATERIAL_RETURN_PENDING", returning.id()));
        fixture.loginAs(shop.warehouseUser());
        requisitions.fulfil(returning.id(), new FulfilRequest(returning.rowVersion(),
                List.of(new FulfilLine(returning.lines().getFirst().id(), shop.leafA(), new BigDecimal("20"))), null,
                key("receive")));
        balance(bin, granule, "40", "400");
        balance(shop.leafA(), granule, "160", "1600");

        // 其它耗用: 清机 5 公斤, 从内料仓其它出库, 记进开着的那一期
        fixture.loginAs(shop.workshopUser());
        var purge = otherIssues.create(new OtherIssueRequest(shop.workshop(), granule, null, new BigDecimal("5"),
                "PURGE", null, key("purge")));
        assertEquals(period, purge.periodId());
        balance(bin, granule, "35", "350");
        ApiException other = assertThrows(ApiException.class, () -> otherIssues.create(new OtherIssueRequest(
                shop.workshop(), granule, null, BigDecimal.ONE, "OTHER", null, key("other-blank"))));
        assertEquals(ErrorCode.VALIDATION_FAILED, other.getCode());

        // 作废还没办的申请
        RequisitionView pending = requisitions.create(new RequisitionCreate("ISSUE", shop.workshop(),
                List.of(new RequisitionLineInput(granule, null, BigDecimal.TEN, null)), null, key("to-cancel")));
        RequisitionView cancelled = requisitions.cancel(pending.id(), new CancelRequest(pending.rowVersion(),
                "填错了", key("cancel")));
        assertEquals("CANCELLED", cancelled.status());
        assertEquals(0, db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_id = ? AND resolved_at IS NULL",
                Integer.class, pending.id()));

        // 车间页: 本期进 60、退 20、其它 5, 账面 35
        PositionRow row = positions.position(bin).rows().getFirst();
        money("35", row.bookQty());
        money("60", row.periodInQty());
        money("20", row.periodReturnQty());
        money("5", row.periodOtherQty());
        // 徽章: 车间账号只数本车间
        assertEquals(0, positions.badgeCounts().pendingIssue());
    }

    // =============================================================================================
    // 归期: 盘点中发料算下一期; 漏录补录到盘点中或已盘点的那一期
    // =============================================================================================

    @Test
    void issuesDuringCountingGoToTheNextPeriodAndSupplementsCorrectTheCountedPeriod() {
        Shop shop = shop("periods");
        UUID granule = granule(shop, "颗粒丁", shop.leafA());
        UUID uncounted = granule(shop, "颗粒戊", shop.leafA());
        otherIn(shop, shop.leafA(), granule, "500", "10");
        otherIn(shop, shop.leafA(), uncounted, "50", "10");
        UUID bin = enable(shop, BusinessTime.today());
        UUID first = openPeriod(bin);
        fixture.loginAs(shop.warehouseUser());
        directIssue(shop, granule, "100", null, "first");

        // 开始盘点 (截止今天): 这一期盘点中, 下一期同时开出
        fixture.loginAs(shop.workshopUser());
        StartCountResult started = periods.startCount(first, new StartCountRequest(periodVersion(first), null,
                key("start")));
        assertEquals("COUNTING", started.period().status());
        assertEquals(BusinessTime.today(), started.period().endDate());
        UUID second = started.nextPeriod().id();
        assertEquals(BusinessTime.today().plusDays(1), started.nextPeriod().startDate());

        // 盘点开始后当天再发的料: 记进下一期, 业务日期照记今天
        fixture.loginAs(shop.warehouseUser());
        RequisitionView late = directIssue(shop, granule, "30", null, "late");
        assertEquals(second, late.documents().getFirst().periodId());
        assertEquals(BusinessTime.today(), db.queryForObject("""
                SELECT posting.business_date FROM workshop_material_requisition_postings posting
                JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
                WHERE line.requisition_id = ?""", LocalDate.class, late.id()));

        // 漏录补录到盘点中的那一期
        RequisitionView missed = directIssue(shop, granule, "20", new Supplement(first, "早上领的忘了录"), "missed");
        assertEquals(first, missed.documents().getFirst().periodId());
        assertTrue(missed.documents().getFirst().supplement());

        // 盘点: 4 袋 × 25 = 100, 实际 = 100 + 20 - 100 = 20
        fixture.loginAs(shop.workshopUser());
        UUID count = started.count().id();
        counts.saveLine(count, "B-1", new CountLineInput(null, "FULL_BAGS", null, granule, null,
                new BigDecimal("4"), new BigDecimal("25"), null, null, null, null));
        PeriodView counted = counts.submit(count, new VersionRequest(countVersion(count), key("submit")));
        assertEquals("COUNTED", counted.status());
        assertEquals("QUEUED", counted.closeState());
        UUID line = periodLine(first, granule);
        money("120", db.queryForObject("SELECT transfer_in_qty FROM workshop_material_period_lines WHERE id = ?",
                BigDecimal.class, line));
        money("20", netConsume(line));

        // 已盘点后补录 10 公斤: 同一事务自动更正 (领入 130, 期末不变, 实际 30, 追加 21 型 10)
        fixture.loginAs(shop.warehouseUser());
        directIssue(shop, granule, "10", new Supplement(first, "下午那批也漏了"), "missed-after");
        money("130", db.queryForObject("SELECT transfer_in_qty FROM workshop_material_period_lines WHERE id = ?",
                BigDecimal.class, line));
        money("30", db.queryForObject("SELECT actual_qty FROM workshop_material_period_lines WHERE id = ?",
                BigDecimal.class, line));
        money("30", netConsume(line));
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM workshop_material_count_postings WHERE period_line_id = ? AND reason = 'SUPPLEMENT'""",
                Integer.class, line));
        money("100", db.queryForObject("SELECT fn_workshop_material_book_as_of(?, ?, NULL)", BigDecimal.class,
                first, granule));
        balance(bin, granule, "130", null);

        // 那一期的盘点里没盘到这种料: 先更正盘点
        ApiException notCounted = assertThrows(ApiException.class, () -> directIssue(shop, uncounted, "5",
                new Supplement(first, "漏录"), "not-counted"));
        assertEquals(ErrorCode.VALIDATION_FAILED, notCounted.getCode());
        assertTrue(notCounted.getMessage().contains("没有盘到"), notCounted.getMessage());
        // 普通发料不能指定已盘点的那一期以外的期间; 开着的那一期不能当补录目标
        ApiException openTarget = assertThrows(ApiException.class, () -> directIssue(shop, granule, "5",
                new Supplement(second, "漏录"), "open-target"));
        assertTrue(openTarget.getMessage().contains("盘点"), openTarget.getMessage());
    }

    // =============================================================================================
    // 通用单据、公共可用量
    // =============================================================================================

    @Test
    void genericDocumentsCannotMoveGranulesAndPublicAvailabilityExcludesTheBin() {
        Shop shop = shop("generic");
        UUID granule = granule(shop, "颗粒己", shop.leafA());
        otherIn(shop, shop.leafA(), granule, "200", "10");
        UUID bin = enable(shop, BusinessTime.today());
        fixture.loginAs(shop.warehouseUser());
        RequisitionView issued = directIssue(shop, granule, "80", null, "public");

        // 通用调拨进内料仓、其它入库到内料仓、内料仓单据红冲: 一律被拒
        fixture.loginAs(shop.admin());
        assertThrows(ApiException.class, () -> transferDraft(shop, granule, "10", shop.leafA(), bin));
        var otherIn = new StockDocSaveRequest();
        otherIn.setDocType("OTHER_IN");
        otherIn.setWarehouseId(bin);
        otherIn.setBillDate(BusinessTime.today());
        otherIn.setItems(List.of(line(shop, granule, "5", "10")));
        assertThrows(RuntimeException.class, () -> stock.approve(stock.create(otherIn).getId()));
        UUID document = issued.documents().getFirst().documentId();
        ApiException reversed = assertThrows(ApiException.class, () -> stock.reverse(document));
        assertTrue(reversed.getMessage().contains("不能红冲"), reversed.getMessage());

        // 内料仓不是记账叶仓: 公共可用量、物料分析、齐套都看不到内料仓里的颗粒
        assertFalse(db.queryForObject("SELECT fn_warehouse_is_active_accounting_leaf(?)", Boolean.class, bin));
        fixture.loginAs(shop.workshopUser());
        PositionRow row = positions.position(bin).rows().getFirst();
        money("80", row.bookQty());
        money("120", row.warehouseAvailableQty());
    }

    // =============================================================================================
    // 设置: 停用只撤销设错的开启; 认料改认与互斥; 开工状态与报工截止在没有绑定时不拦
    // =============================================================================================

    @Test
    void disableOnlyUndoesAnUnusedEnableAndChoicesSupersedeCleanly() {
        Shop shop = shop("settings");
        UUID granule = granule(shop, "颗粒辛", shop.leafA());
        otherIn(shop, shop.leafA(), granule, "100", "10");
        UUID bin = enable(shop, BusinessTime.today());
        UUID firstPeriod = openPeriod(bin);

        // 从未用过: 停用删掉空的第 1 期, 之后可以像第一次一样重新开启
        fixture.loginAs(shop.warehouseUser());
        long version = db.queryForObject("SELECT row_version FROM workshop_material_settings WHERE workshop_department_id = ?",
                Long.class, shop.workshop());
        var disabled = settings.update(shop.workshop(), new SettingsRequest(version, false, null, null, null,
                key("disable")));
        assertFalse(disabled.periodicEnabled());
        assertEquals(0, db.queryForObject("SELECT count(*) FROM workshop_material_periods WHERE id = ?", Integer.class,
                firstPeriod));
        var again = settings.update(shop.workshop(), new SettingsRequest(disabled.rowVersion(), true, shop.leafA(),
                BusinessTime.today(), List.of(), key("enable-again")));
        assertTrue(again.periodicEnabled());
        assertEquals(bin, again.binWarehouseId(), "同一主仓下取回原来的内料仓");
        assertEquals(1, again.currentPeriod().no());
        assertTrue(settings.inProgressPending(shop.workshop()).products().isEmpty());

        // 有过进出以后: 不能停用
        directIssue(shop, granule, "10", null, "used");
        ApiException inUse = assertThrows(ApiException.class, () -> settings.update(shop.workshop(),
                new SettingsRequest(again.rowVersion(), false, null, null, null, key("disable-used"))));
        assertEquals(ErrorCode.CONFLICT, inUse.getCode());
        assertTrue(inUse.getMessage().contains("已经在用"), inUse.getMessage());

        // 认料: 用料 → 同样再认一次不动 → 改为不用内料仓的料 (原认料作废为改认料)
        UUID product = UUID.randomUUID();
        fixture.insertGoods(product, "P-" + product.toString().substring(0, 8), "注塑件-" + product.toString().substring(0, 4),
                "自制", shop.world().unitId(), shop.world().unitLegacy());
        fixture.loginAs(shop.workshopUser());
        var material = new WorkshopMaterialChoicePort.ProductChoice(product, WorkshopMaterialChoicePort.KIND_MATERIAL,
                List.of(new WorkshopMaterialChoicePort.MaterialRef(granule, null)), true, null);
        var chosen = choices.chooseAndList(new ChooseRequest(shop.workshop(), List.of(material), key("choose")));
        assertEquals(1, chosen.choices().size());
        assertTrue(chosen.choices().getFirst().alsoOrderMaterials());
        var same = choices.chooseAndList(new ChooseRequest(shop.workshop(), List.of(material), key("choose-same")));
        assertEquals(chosen.choices().getFirst().id(), same.choices().getFirst().id(), "同样的认料不另起一行");
        var none = choices.chooseAndList(new ChooseRequest(shop.workshop(), List.of(
                new WorkshopMaterialChoicePort.ProductChoice(product, WorkshopMaterialChoicePort.KIND_NONE, List.of(),
                        false, null)), key("choose-none")));
        assertEquals("NONE", none.choices().getFirst().kind());
        assertEquals("CHANGED", db.queryForObject("SELECT superseded_reason FROM goods_periodic_material_choices WHERE id = ?",
                String.class, chosen.choices().getFirst().id()));
        // 有 BOM 的产品不能勾"还要按工单领别的料"
        ApiException withBom = assertThrows(ApiException.class, () -> choices.chooseAndList(new ChooseRequest(
                shop.workshop(), List.of(new WorkshopMaterialChoicePort.ProductChoice(shop.world().goodsA(),
                WorkshopMaterialChoicePort.KIND_MATERIAL, List.of(new WorkshopMaterialChoicePort.MaterialRef(granule, null)),
                true, null)), key("choose-bom"))));
        assertEquals(ErrorCode.VALIDATION_FAILED, withBom.getCode());
        // 辅料不能认作产品用料
        UUID colourant = granule(shop, "色母", shop.leafA(), "SHARED");
        ApiException shared = assertThrows(ApiException.class, () -> choices.chooseAndList(new ChooseRequest(
                shop.workshop(), List.of(new WorkshopMaterialChoicePort.ProductChoice(product,
                WorkshopMaterialChoicePort.KIND_MATERIAL, List.of(new WorkshopMaterialChoicePort.MaterialRef(colourant, null)),
                false, null)), key("choose-shared"))));
        assertTrue(shared.getMessage().contains("主料"), shared.getMessage());
        // 其它车间的人办不了本车间的内料仓
        assertThrows(ApiException.class, () -> requisitions.defaults(UUID.randomUUID()));
    }

    // =============================================================================================
    // 业务清空: 认料、机台保留, 不因引用被清空的表而拒绝
    // =============================================================================================

    @Test
    void businessResetRunsWithChoicesAndMachinesPresent() throws Exception {
        Shop shop = shop("reset");
        UUID granule = granule(shop, "颗粒庚", shop.leafA());
        enable(shop, BusinessTime.today());
        fixture.loginAs(shop.warehouseUser());
        machines.createBatch(new MachineBatchCreate(shop.workshop(), 2, "R", 1,
                List.of(new ContainerSpec("干燥机料斗", new BigDecimal("50"))), key("machines")));
        UUID product = UUID.randomUUID();
        fixture.insertGoods(product, "P-" + product.toString().substring(0, 8), "注塑件-" + product.toString().substring(0, 4),
                "自制", shop.world().unitId(), shop.world().unitLegacy());
        fixture.loginAs(shop.workshopUser());
        choices.chooseAndList(new ChooseRequest(shop.workshop(), List.of(new WorkshopMaterialChoicePort.ProductChoice(
                product, WorkshopMaterialChoicePort.KIND_MATERIAL,
                List.of(new WorkshopMaterialChoicePort.MaterialRef(granule, null)), false, null)), key("choose")));

        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("SET LOCAL lock_timeout = '30s'");
                statement.execute("SET LOCAL statement_timeout = '300s'");
                // 未生成 attachment 的上传会话也有清理 outbox。显式保留这个外键形态，
                // 使单跑就能重现全量里前序附件测试留下的状态；整段在 finally 回滚。
                try (var uploadFixture = connection.prepareStatement("""
                        WITH session AS (
                            INSERT INTO attachment_upload_sessions(
                                storage_key, owner_type, owner_id, user_id, original_name, content_type,
                                expected_size_bytes, expires_at, status, storage_provider)
                            VALUES (gen_random_uuid()::text, 'SALES_ORDER', gen_random_uuid(), ?,
                                    'reset-fixture.txt', 'text/plain', 1, now() + interval '1 hour', 'PENDING', 'local')
                            RETURNING id, storage_key
                        )
                        INSERT INTO attachment_object_outbox(
                            upload_session_id, operation, storage_key, dedupe_key, storage_provider)
                        SELECT id, 'DELETE_STAGING', storage_key, 'reset-fixture|' || storage_key, 'local'
                        FROM session
                        """)) {
                    uploadFixture.setObject(1, shop.workshopUser());
                    assertEquals(1, uploadFixture.executeUpdate());
                }
                // reset 的附件门拦全库业务附件; 共享库里前面用例留下的附件行会触发拒绝
                // (单跑恒绿、全量红)。本用例的关注点是认料/机台的保留口径, 按生产
                // 「附件清理准备已完成」的状态先清业务附件行(事务内, 回滚不留痕)。
                statement.execute(
                        """
                        DELETE FROM attachment_object_outbox
                        WHERE attachment_id IN (SELECT id FROM attachments
                                WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT'))
                           OR upload_session_id IN (SELECT id FROM attachment_upload_sessions
                                WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT'))
                        """);
                statement.execute(
                        "DELETE FROM attachments WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT')");
                statement.execute(
                        "DELETE FROM attachment_upload_sessions WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE','EMPLOYEE_CONTRACT')");
                try (ResultSet cleared = statement.executeQuery("SELECT cleared_rows FROM business_data_reset()")) {
                    assertTrue(cleared.next());
                }
                try (ResultSet kept = statement.executeQuery(
                        "SELECT (SELECT count(*) FROM goods_periodic_material_choices WHERE product_goods_id = '"
                                + product + "'), (SELECT count(*) FROM workshop_machines WHERE workshop_department_id = '"
                                + shop.workshop() + "'), (SELECT count(*) FROM workshop_material_settings)")) {
                    assertTrue(kept.next());
                    assertEquals(1, kept.getInt(1), "认料保留");
                    assertEquals(2, kept.getInt(2), "机台保留");
                    assertEquals(0, kept.getInt(3), "设置清空, 清空后需重新开启");
                }
            } finally {
                connection.rollback();
            }
        }
    }

    // =============================================================================================
    // 可发到内料仓的料 (申请、发料、上线准备的下拉) 与领料单记进了哪一期
    // =============================================================================================

    @Test
    void materialDropdownListsStockPerLeafAndRequisitionsTellWhichPeriodTheyWentInto() {
        Shop shop = shop("materials");
        UUID granule = granule(shop, "颗粒下拉", shop.leafA());
        UUID untouched = granule(shop, "颗粒无货", shop.leafB(), "SHARED");
        // 归属仓 = 最新入库仓 (V590 入库自动回写, 不因整批领料例外): 先收叶仓 B 再收叶仓 A, 默认出库仓才是 A。
        otherIn(shop, shop.leafB(), granule, "30", "10");
        otherIn(shop, shop.leafA(), granule, "200", "10");
        UUID bin = enable(shop, BusinessTime.today());
        UUID period = openPeriod(bin);

        // 车间申请: 还没发料, 不知道记进哪一期
        fixture.loginAs(shop.workshopUser());
        RequisitionView pending = requisitions.create(new RequisitionCreate("ISSUE", shop.workshop(),
                List.of(new RequisitionLineInput(granule, null, new BigDecimal("20"), null)), null, key("request")));
        assertNull(pending.period(), "还在等发料");

        // 仓库直接发料: 记进开着的第 1 期
        fixture.loginAs(shop.warehouseUser());
        RequisitionView issued = directIssue(shop, granule, "50", null, "issue");
        assertNotNull(issued.period());
        assertEquals(period, issued.period().id());
        assertEquals(1, issued.period().no());
        assertEquals("OPEN", issued.period().status());
        assertEquals(period, requisitionController.detail(issued.id()).period().id());

        fixture.loginAs(shop.workshopUser());
        List<MaterialStockOption> options = positionController.materials(shop.workshop());
        MaterialStockOption used = options.getFirst();
        assertEquals(granule, used.goodsId(), "进过这个内料仓的料排在前面");
        assertEquals("OWN", used.costBasis());
        money("25", used.bulkPackageQty());
        assertEquals("千克", used.unitName());
        assertEquals(shop.leafA(), used.defaultLeafWarehouseId());
        assertNotNull(used.defaultLeafWarehouseName());
        money("180", used.warehouseAvailableQty());
        assertEquals(List.of(shop.leafA(), shop.leafB()).stream().sorted().toList(),
                used.leafWarehouses().stream().map(LeafStockView::warehouseId).sorted().toList(),
                "内料仓自己不算出库仓");
        money("150", used.leafWarehouses().stream().filter(leaf -> leaf.warehouseId().equals(shop.leafA()))
                .findFirst().orElseThrow().availableQty());
        money("30", used.leafWarehouses().stream().filter(leaf -> leaf.warehouseId().equals(shop.leafB()))
                .findFirst().orElseThrow().availableQty());
        MaterialStockOption empty = options.stream().filter(option -> option.goodsId().equals(untouched))
                .findFirst().orElseThrow();
        assertEquals("SHARED", empty.costBasis());
        money("0", empty.warehouseAvailableQty());
        assertEquals(List.of(shop.leafB()), empty.leafWarehouses().stream().map(LeafStockView::warehouseId).toList(),
                "默认出库叶仓没货也列出");
        assertTrue(options.stream().allMatch(option -> Boolean.TRUE.equals(db.queryForObject(
                "SELECT issue_method = 'PERIODIC' FROM goods WHERE id = ?", Boolean.class, option.goodsId()))),
                "只列整批领料的料");

        // 对象范围: 别的车间的人查不了这个车间; 没有查看权限的人进不了接口
        Object otherAssignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment",
                "wm-other-" + UUID.randomUUID().toString().substring(0, 8));
        UUID otherWorkshop = ReflectionTestUtils.invokeMethod(otherAssignment, "workshopId");
        UUID outsider = fixture.createUserWithPerms(shop.world(), "out-" + UUID.randomUUID().toString().substring(0, 8),
                "notice:read", "workshop_material:view", "workshop_material:request");
        db.update("UPDATE employees SET department_id = ? WHERE id = (SELECT employee_id FROM users WHERE id = ?)",
                otherWorkshop, outsider);
        fixture.loginAs(outsider);
        ApiException foreign = assertThrows(ApiException.class, () -> positionController.materials(shop.workshop()));
        assertEquals(ErrorCode.FORBIDDEN, foreign.getCode());
        UUID noView = fixture.createUserWithPerms(shop.world(), "nv-" + UUID.randomUUID().toString().substring(0, 8),
                "notice:read");
        fixture.loginAs(noView);
        assertThrows(org.springframework.security.access.AccessDeniedException.class,
                () -> positionController.materials(shop.workshop()));
    }

    // =============================================================================================
    // 夹具
    // =============================================================================================

    private Shop shop(String tag) {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String unique = tag + "-" + UUID.randomUUID().toString().substring(0, 8);
        var world = fixture.seedWorld("wm-issue-" + unique);
        fixture.loginAs(world.superAdminUserId());
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "wm-issue-" + unique);
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment, "workshopId");
        UUID worker = ReflectionTestUtils.invokeMethod(assignment, "workerId");
        UUID kg = UUID.randomUUID();
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'千克','使用')",
                kg, 900_000_000 + ThreadLocalRandom.current().nextInt(90_000_000), "KG-" + unique);
        db.update("""
                INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                VALUES (?, 'MASS', 'KG', 'MANUAL_GOVERNANCE')""", kg);
        UUID leafB = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES (?,?,?,'使用')", leafB, "WHB-" + unique,
                "叶仓乙-" + unique);
        UUID warehouseUser = fixture.createUserWithPerms(world, "wh-" + unique, "notice:read",
                "workshop_material:view", "workshop_material:issue", "workshop_material:count",
                "workshop_material:setup");
        UUID otherIssuer = fixture.createUserWithPerms(world, "wh2-" + unique, "notice:read",
                "workshop_material:view", "workshop_material:issue");
        UUID workshopUser = fixture.createUserWithPerms(world, "shop-" + unique, "notice:read",
                "workshop_material:view", "workshop_material:request", "workshop_material:count",
                "workshop_material:choose");
        db.update("UPDATE employees SET department_id = ? WHERE id = (SELECT employee_id FROM users WHERE id = ?)",
                workshop, workshopUser);
        db.update("INSERT INTO warehouse_keepers(warehouse_id, employee_id) SELECT ?, employee_id FROM users WHERE id = ?",
                world.warehouseId(), warehouseUser);
        return new Shop(world, world.superAdminUserId(), workshop, worker, kg, world.warehouseId(), leafB,
                warehouseUser, otherIssuer, workshopUser);
    }

    private UUID granule(Shop shop, String name, UUID owningWarehouse) {
        return granule(shop, name, owningWarehouse, "OWN");
    }

    private UUID granule(Shop shop, String name, UUID owningWarehouse, String basis) {
        UUID id = UUID.randomUUID();
        int legacy = db.queryForObject("SELECT legacy_id FROM units WHERE id=?", Integer.class, shop.kg());
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,
                                  issue_method,periodic_cost_basis,bulk_package_qty,owning_warehouse_id,min_qty)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),
                        'PERIODIC',?,25,?,0)""",
                id, "WM-" + id.toString().substring(0, 8), name + "-" + id.toString().substring(0, 4), shop.kg(), legacy,
                basis, owningWarehouse);
        return id;
    }

    /** 仓库账号开启车间整批领料 (内料仓挂在叶仓 A 所在主仓下)。返回内料仓。 */
    private UUID enable(Shop shop, LocalDate goLive) {
        fixture.loginAs(shop.warehouseUser());
        var view = settings.update(shop.workshop(), new SettingsRequest(0L, true, shop.leafA(), goLive, List.of(),
                key("enable")));
        assertTrue(view.periodicEnabled());
        assertNotNull(view.binWarehouseId());
        assertEquals(1, view.currentPeriod().no());
        return view.binWarehouseId();
    }

    private RequisitionView directIssue(Shop shop, UUID goods, String qty, Supplement supplement, String tag) {
        return requisitions.directIssue(new DirectIssueRequest(shop.workshop(), shop.worker(),
                List.of(new DirectIssueLine(goods, null, null, new BigDecimal(qty), shop.leafA())), supplement,
                key(tag)));
    }

    private void otherIn(Shop shop, UUID warehouse, UUID goods, String qty, String price) {
        fixture.loginAs(shop.admin());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(warehouse);
        request.setBillDate(BusinessTime.today());
        request.setItems(List.of(line(shop, goods, qty, price)));
        stock.approve(stock.create(request).getId());
    }

    private UUID transferDraft(Shop shop, UUID goods, String qty, UUID from, UUID to) {
        var request = new StockDocSaveRequest();
        request.setDocType("TRANSFER");
        request.setWarehouseId(from);
        request.setToWarehouseId(to);
        request.setBillDate(BusinessTime.today());
        request.setItems(List.of(line(shop, goods, qty, null)));
        return stock.create(request).getId();
    }

    private static StockDocItemLine line(Shop shop, UUID goods, String qty, String price) {
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(shop.kg());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        if (price != null) {
            line.setPrice(new BigDecimal(price));
            line.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal(price)));
            line.setAmountLocal(line.getAmountOriginal());
        }
        return line;
    }

    private UUID openPeriod(UUID bin) {
        return db.queryForObject("SELECT id FROM workshop_material_periods WHERE bin_warehouse_id = ? AND status = 'OPEN'",
                UUID.class, bin);
    }

    private long periodVersion(UUID period) {
        return db.queryForObject("SELECT row_version FROM workshop_material_periods WHERE id = ?", Long.class, period);
    }

    private long countVersion(UUID count) {
        return db.queryForObject("SELECT row_version FROM workshop_material_counts WHERE id = ?", Long.class, count);
    }

    private UUID periodLine(UUID period, UUID goods) {
        return db.queryForObject("""
                SELECT id FROM workshop_material_period_lines WHERE period_id = ? AND goods_id = ? AND color_id IS NULL""",
                UUID.class, period, goods);
    }

    private BigDecimal netConsume(UUID line) {
        return db.queryForObject("""
                SELECT COALESCE(sum(CASE kind WHEN 'CONSUME' THEN qty WHEN 'CONSUME_REVERSE' THEN -qty ELSE 0 END), 0)
                FROM workshop_material_count_postings WHERE period_line_id = ?""", BigDecimal.class, line);
    }

    private int notices(UUID user, String event, UUID aggregate) {
        return db.queryForObject("""
                SELECT count(*) FROM notices WHERE audience_user_id = ? AND source_event = ? AND aggregate_id = ?""",
                Integer.class, user, event, aggregate);
    }

    private void balance(UUID warehouse, UUID goods, String qty, String amount) {
        var row = db.queryForMap("""
                SELECT qty, amount_local FROM stock_balances WHERE warehouse_id = ? AND goods_id = ? AND color_id IS NULL""",
                warehouse, goods);
        money(qty, (BigDecimal) row.get("qty"));
        if (amount != null) money(amount, (BigDecimal) row.get("amount_local"));
    }

    private static String key(String tag) {
        return "wm-" + tag + "-" + UUID.randomUUID();
    }

    private static void money(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), () -> "expected " + expected + ", actual " + actual);
    }
}
