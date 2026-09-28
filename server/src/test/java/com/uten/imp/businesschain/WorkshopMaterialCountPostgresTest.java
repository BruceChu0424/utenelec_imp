package com.uten.imp.businesschain;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.application.port.WorkshopMaterialNoticePort;
import com.uten.imp.application.port.WorkshopMaterialReportGuardPort;
import com.uten.imp.application.port.WorkshopMaterialStatePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMachineService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCountService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerSlot;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerSpec;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CorrectCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountDetail;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineBatchCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountResult;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.VersionRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ZeroRestRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPeriodService;
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

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 车间内料仓盘点 (包 S2): 开始盘点即截止并开出下一期 (截止日默认今天、可选更早、不能早于期初),
 * 两人逐行保存与版本冲突 (带回最新那一行), 缺容器或缺料不许提交, "其余记 0", 提交即过 21/22 型,
 * 更正按对称的过账调整规则, 撤回盘点删掉空的下一期, 同号重放不重复过账。
 *
 * <p>全部走真实服务与真实库; 每次提交时 V740 的期间用量、盘点过账净额、流水合计 = 余额等延迟断言生效。
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
class WorkshopMaterialCountPostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired WorkshopMaterialSettingsService settings;
    @Autowired WorkshopMaterialRequisitionService requisitions;
    @Autowired WorkshopMaterialPeriodService periods;
    @Autowired WorkshopMaterialCountService counts;
    @Autowired com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCountController countController;
    @Autowired WorkshopMachineService machines;
    @Autowired WorkshopMaterialNoticePort notices;
    @Autowired WorkshopMaterialStatePort state;
    @Autowired WorkshopMaterialReportGuardPort reportGuard;
    @Autowired WorkshopMaterialChoicePort choices;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    FullChainEndToEndTest fixture;

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    private record Shop(FullChainEndToEndTest.World world, UUID admin, UUID workshop, UUID worker, UUID kg,
                        UUID leaf, UUID warehouseUser, UUID counterA, UUID counterB, UUID bin, UUID firstPeriod) {}

    // =============================================================================================
    // 开始盘点、撤回盘点
    // =============================================================================================

    @Test
    void startingACountCutsOffTheOpenPeriodAndWithdrawDeletesTheEmptyNextPeriod() {
        Shop shop = shop("start", BusinessTime.today().minusDays(3));
        UUID first = shop.firstPeriod();
        fixture.loginAs(shop.counterA());

        // 截止日早于这一期的开始日: 拒绝
        ApiException tooEarly = assertThrows(ApiException.class, () -> periods.startCount(first,
                new StartCountRequest(0L, BusinessTime.today().minusDays(4), key("too-early"))));
        assertEquals(ErrorCode.VALIDATION_FAILED, tooEarly.getCode());
        // 截止日不写 = 今天
        StartCountResult today = periods.startCount(first, new StartCountRequest(0L, null, key("today")));
        assertEquals("COUNTING", today.period().status());
        assertEquals(BusinessTime.today(), today.period().endDate());
        assertEquals("OPEN", today.nextPeriod().status());
        assertEquals(2, today.nextPeriod().no());
        assertEquals(1, today.count().version());
        assertEquals("DRAFT", today.count().status());
        assertTrue(today.period().allowedActions().contains("WITHDRAW_COUNT"));

        // 撤回: 删掉空的下一期与草稿, 本期回到开着
        PeriodView withdrawn = periods.withdrawCount(first, new VersionRequest(today.period().rowVersion(),
                key("withdraw")));
        assertEquals("OPEN", withdrawn.status());
        assertNull(withdrawn.endDate());
        assertEquals(1, db.queryForObject("SELECT count(*) FROM workshop_material_periods WHERE bin_warehouse_id = ?",
                Integer.class, shop.bin()));
        assertEquals(0, db.queryForObject("SELECT count(*) FROM workshop_material_counts WHERE period_id = ?",
                Integer.class, first));

        // 交班时盘点: 截止到昨天
        StartCountResult yesterday = periods.startCount(first, new StartCountRequest(withdrawn.rowVersion(),
                BusinessTime.today().minusDays(1), key("yesterday")));
        assertEquals(BusinessTime.today().minusDays(1), yesterday.period().endDate());
        assertEquals(BusinessTime.today(), yesterday.nextPeriod().startDate());

        // 开始盘点后已经有料进了下一期: 不能再撤回
        fixture.loginAs(shop.warehouseUser());
        UUID granule = granule(shop, "颗粒撤");
        otherIn(shop, granule, "50", "10");
        issue(shop, granule, "10", "after-cutoff");
        fixture.loginAs(shop.counterA());
        ApiException late = assertThrows(ApiException.class, () -> periods.withdrawCount(first,
                new VersionRequest(yesterday.period().rowVersion(), key("withdraw-late"))));
        assertTrue(late.getMessage().contains("不能再撤回"), late.getMessage());
    }

    // =============================================================================================
    // 逐行保存、覆盖核对、提交过账
    // =============================================================================================

    @Test
    void twoCountersSaveLinesConcurrentlyAndSubmitRequiresEveryContainerAndMaterial() {
        Shop shop = shop("lines", BusinessTime.today());
        UUID granule = granule(shop, "颗粒盘");
        fixture.loginAs(shop.warehouseUser());
        MachineList created = machines.createBatch(new MachineBatchCreate(shop.workshop(), 2, "J", 1, List.of(
                new ContainerSpec("干燥机料斗", new BigDecimal("50")),
                new ContainerSpec("储料桶", new BigDecimal("100"))), key("machines")));
        assertEquals(2, created.machines().size());
        assertEquals(2, created.machines().getFirst().containers().size());
        otherIn(shop, granule, "300", "10");
        issue(shop, granule, "200", "issue");

        fixture.loginAs(shop.counterA());
        StartCountResult started = periods.startCount(shop.firstPeriod(), new StartCountRequest(0L, null,
                key("start")));
        UUID count = started.count().id();
        assertEquals(2, started.count().machines().size());
        assertEquals(4, started.count().missingContainerCount());
        assertEquals(1, started.count().missingMaterialCount());
        ContainerSlot hopper1 = started.count().machines().get(0).containers().get(0);
        ContainerSlot bucket1 = started.count().machines().get(0).containers().get(1);
        ContainerSlot hopper2 = started.count().machines().get(1).containers().get(0);
        ContainerSlot bucket2 = started.count().machines().get(1).containers().get(1);
        UUID machine1 = started.count().machines().get(0).machineId();
        UUID machine2 = started.count().machines().get(1).machineId();

        // A 录 1 号机料斗: 满
        CountLineView full = counts.saveLine(count, hopper1.clientLineKey(), new CountLineInput(null, "CONTAINER",
                null, granule, null, null, null, null, machine1, hopper1.containerId(), "FULL"));
        money("50", full.qtyBase());
        assertEquals(0, full.rowVersion());
        // B 同时也当新行录同一个容器: 冲突, 带回 A 录的那一行
        fixture.loginAs(shop.counterB());
        WorkshopMaterialCountService.LineConflict stale = assertThrows(WorkshopMaterialCountService.LineConflict.class,
                () -> counts.saveLine(count, hopper1.clientLineKey(), new CountLineInput(null, "CONTAINER", null,
                        granule, null, null, null, null, machine1, hopper1.containerId(), "HALF")));
        assertEquals("FULL", stale.latest().fillLevel());
        // B 按最新版本改成半: 成功
        CountLineView half = counts.saveLine(count, hopper1.clientLineKey(), new CountLineInput(0L, "CONTAINER",
                null, granule, null, null, null, null, machine1, hopper1.containerId(), "HALF"));
        money("25", half.qtyBase());
        assertEquals(1, half.rowVersion());
        // A 拿旧版本再改: 冲突, 带回 B 的半
        fixture.loginAs(shop.counterA());
        WorkshopMaterialCountService.LineConflict lost = assertThrows(WorkshopMaterialCountService.LineConflict.class,
                () -> counts.saveLine(count, hopper1.clientLineKey(), new CountLineInput(0L, "CONTAINER", null,
                        granule, null, null, null, null, machine1, hopper1.containerId(), "EMPTY")));
        assertEquals("HALF", lost.latest().fillLevel());
        assertEquals(1, lost.latest().rowVersion());

        // 还有 3 个容器没录: 不许提交
        ApiException missing = assertThrows(ApiException.class, () -> counts.submit(count,
                new VersionRequest(countVersion(count), key("submit-early"))));
        assertEquals(ErrorCode.VALIDATION_FAILED, missing.getCode());
        assertTrue(missing.getMessage().contains("3 个容器"), missing.getMessage());

        // 1 号机储料桶直接填公斤, 2 号机停机全空; 袋料 2 袋 x 25 + 开口袋 7.3 公斤
        counts.saveLine(count, bucket1.clientLineKey(), new CountLineInput(null, "CONTAINER", null, granule, null,
                null, null, new BigDecimal("12.5"), machine1, bucket1.containerId(), "WEIGHED"));
        counts.saveLine(count, hopper2.clientLineKey(), new CountLineInput(null, "CONTAINER", null, null, null,
                null, null, null, machine2, hopper2.containerId(), "EMPTY"));
        counts.saveLine(count, bucket2.clientLineKey(), new CountLineInput(null, "CONTAINER", null, null, null,
                null, null, null, machine2, bucket2.containerId(), "EMPTY"));
        counts.saveLine(count, "B-bags", new CountLineInput(null, "FULL_BAGS", null, granule, null,
                new BigDecimal("2"), new BigDecimal("25"), null, null, null, null));
        counts.saveLine(count, "W-open", new CountLineInput(null, "WEIGHED", "OPEN_BAG", granule, null, null, null,
                new BigDecimal("7.3"), null, null, null));
        ApiException badNote = assertThrows(ApiException.class, () -> counts.saveLine(count, "W-bad",
                new CountLineInput(null, "FULL_BAGS", "OPEN_BAG", granule, null, BigDecimal.ONE, BigDecimal.TEN, null,
                        null, null, null)));
        assertNotNull(badNote);
        CountDetail detail = counts.detail(count);
        assertEquals(0, detail.missingContainerCount());
        assertEquals(0, detail.missingMaterialCount());

        // 提交: 期末 25 + 12.5 + 50 + 7.3 = 94.8, 实际 = 200 - 94.8 = 105.2, 当场过 21 型出库到在制
        PeriodView counted = counts.submit(count, new VersionRequest(detail.rowVersion(), key("submit")));
        assertEquals("COUNTED", counted.status());
        UUID line = periodLine(shop.firstPeriod(), granule);
        Map<String, Object> figures = db.queryForMap("""
                SELECT opening_qty, transfer_in_qty, closing_qty, actual_qty, cost_basis
                FROM workshop_material_period_lines WHERE id = ?""", line);
        money("0", (BigDecimal) figures.get("opening_qty"));
        money("200", (BigDecimal) figures.get("transfer_in_qty"));
        money("94.8", (BigDecimal) figures.get("closing_qty"));
        money("105.2", (BigDecimal) figures.get("actual_qty"));
        assertEquals("OWN", figures.get("cost_basis"));
        Map<String, Object> movement = db.queryForMap("""
                SELECT movement.movement_type, movement.direction, movement.qty, event.known_value_local,
                       node.owner_kind, node.owner_id
                FROM workshop_material_count_postings posting
                JOIN stock_movements movement ON movement.id = posting.movement_id
                JOIN stock_value_events event ON event.movement_id = movement.id
                JOIN stock_value_nodes node ON node.id = event.result_node_id
                WHERE posting.period_line_id = ? AND posting.kind = 'CONSUME'""", line);
        assertEquals(21, ((Number) movement.get("movement_type")).intValue());
        assertEquals(-1, ((Number) movement.get("direction")).intValue());
        money("105.2", (BigDecimal) movement.get("qty"));
        money("1052", (BigDecimal) movement.get("known_value_local"));
        assertEquals("WIP", movement.get("owner_kind"));
        assertEquals(line, movement.get("owner_id"));
        money("94.8", db.queryForObject("SELECT fn_workshop_material_book_as_of(?, ?, NULL)", BigDecimal.class,
                shop.firstPeriod(), granule));
        balance(shop.bin(), granule, "94.8");
        // 提交后盘点单不能再改
        ApiException locked = assertThrows(ApiException.class, () -> counts.saveLine(count, "W-late",
                new CountLineInput(null, "WEIGHED", null, granule, null, null, null, BigDecimal.ONE, null, null, null)));
        assertTrue(locked.getMessage().contains("已经提交"), locked.getMessage());
    }

    @Test
    void zeroRestRecordsTheRemainingMaterialsAndSameKeyReplayDoesNotPostTwice() {
        Shop shop = shop("zero", BusinessTime.today());
        UUID used = granule(shop, "颗粒完");
        UUID left = granule(shop, "颗粒剩");
        fixture.loginAs(shop.warehouseUser());
        otherIn(shop, used, "100", "10");
        otherIn(shop, left, "100", "10");
        issue(shop, used, "40", "used");
        issue(shop, left, "30", "left");

        fixture.loginAs(shop.counterA());
        StartCountResult started = periods.startCount(shop.firstPeriod(), new StartCountRequest(0L, null, key("start")));
        UUID count = started.count().id();
        counts.saveLine(count, "W-left", new CountLineInput(null, "WEIGHED", "LOOSE", left, null, null, null,
                new BigDecimal("12"), null, null, null));
        var zero = counts.zeroRest(count, new ZeroRestRequest(key("zero")));
        assertEquals(1, zero.lines().size(), "只给还没录的料记 0");
        assertEquals(used, zero.lines().getFirst().goodsId());
        money("0", zero.lines().getFirst().qtyBase());

        VersionRequest submit = new VersionRequest(countVersion(count), key("submit"));
        PeriodView first = counts.submit(count, submit);
        PeriodView replay = counts.submit(count, submit);
        assertEquals(first.id(), replay.id());
        assertEquals(first.rowVersion(), replay.rowVersion());
        money("40", netConsume(periodLine(shop.firstPeriod(), used)));
        money("18", netConsume(periodLine(shop.firstPeriod(), left)));
        assertEquals(2, db.queryForObject("""
                SELECT count(*) FROM workshop_material_count_postings posting
                JOIN workshop_material_period_lines line ON line.id = posting.period_line_id
                WHERE line.period_id = ?""", Integer.class, shop.firstPeriod()));
        balance(shop.bin(), used, "0");
        balance(shop.bin(), left, "12");
    }

    // =============================================================================================
    // 更正盘点: 过账调整规则对称
    // =============================================================================================

    @Test
    void correctionsReverseAlongTheOriginalPathSymmetrically() {
        Shop shop = shop("correct", BusinessTime.today());
        UUID granule = granule(shop, "颗粒正");
        fixture.loginAs(shop.warehouseUser());
        otherIn(shop, granule, "300", "10");
        issue(shop, granule, "100", "issue");

        // 第 1 版: 实盘比账上多 5 (期末 105, 实际 -5) → 22 型盘盈 5
        fixture.loginAs(shop.counterA());
        StartCountResult started = periods.startCount(shop.firstPeriod(), new StartCountRequest(0L, null, key("start")));
        UUID first = started.count().id();
        weighed(first, "W-1", granule, "105");
        PeriodView counted = counts.submit(first, new VersionRequest(countVersion(first), key("submit-1")));
        UUID line = periodLine(shop.firstPeriod(), granule);
        assertEquals(List.of("GAIN:5"), postings(line));
        balance(shop.bin(), granule, "105");

        // 更正为多用 10 (期末 90): 先原路冲回盘盈 5, 再出 10 (不是出 15)
        CountDetail second = counts.correct(shop.firstPeriod(), new CorrectCountRequest(counted.rowVersion(),
                "料斗那台看错了", key("correct-1")));
        assertEquals(2, second.version());
        assertEquals(1, second.lines().size(), "预置上一版全部行");
        CountLineView copied = second.lines().getFirst();
        counts.saveLine(second.id(), copied.clientLineKey(), new CountLineInput(copied.rowVersion(), "WEIGHED", null,
                granule, null, null, null, new BigDecimal("90"), null, null, null));
        counts.submit(second.id(), new VersionRequest(countVersion(second.id()), key("submit-2")));
        assertEquals(sorted("GAIN:5", "GAIN_REVERSE:5", "CONSUME:10"), postings(line));
        money("10", netConsume(line));
        money("0", netGain(line));
        balance(shop.bin(), granule, "90");
        assertEquals("SUPERSEDED", db.queryForObject("SELECT status FROM workshop_material_counts WHERE id = ?",
                String.class, first));

        // 再更正为盘盈 5: 先原路冲回耗用 10, 再记盘盈 5
        long periodVersion = db.queryForObject("SELECT row_version FROM workshop_material_periods WHERE id = ?",
                Long.class, shop.firstPeriod());
        CountDetail third = counts.correct(shop.firstPeriod(), new CorrectCountRequest(periodVersion,
                "袋料其实没拆", key("correct-2")));
        CountLineView again = third.lines().getFirst();
        counts.saveLine(third.id(), again.clientLineKey(), new CountLineInput(again.rowVersion(), "WEIGHED", null,
                granule, null, null, null, new BigDecimal("105"), null, null, null));
        counts.submit(third.id(), new VersionRequest(countVersion(third.id()), key("submit-3")));
        assertEquals(sorted("GAIN:5", "GAIN_REVERSE:5", "CONSUME:10", "CONSUME_REVERSE:10", "GAIN:5"),
                postings(line));
        // 冲回只冲同类、原路冲: 盘盈冲回指向第 1 版的盘盈, 耗用冲回指向第 2 版的耗用
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM workshop_material_count_postings reversal
                JOIN workshop_material_count_postings original ON original.id = reversal.reverses_posting_id
                WHERE reversal.period_line_id = ? AND original.kind <> replace(reversal.kind, '_REVERSE', '')""",
                Integer.class, line));
        money("0", netConsume(line));
        money("5", netGain(line));
        balance(shop.bin(), granule, "105");

        // 更正要写原因; 已有更正中的草稿时不能再开一张
        ApiException noReason = assertThrows(ApiException.class, () -> counts.correct(shop.firstPeriod(),
                new CorrectCountRequest(0L, " ", key("no-reason"))));
        assertEquals(ErrorCode.VALIDATION_FAILED, noReason.getCode());
    }

    // =============================================================================================
    // 结算被拦的通知: 发给该补的人、条数不变不重发、处理完一起撤卡; 没有绑定的段开工与报工不受影响
    // =============================================================================================

    @Test
    void closeBlockedNoticesReachTheRightPeopleOnceAndResolveTogether() {
        Shop shop = shop("notice", BusinessTime.today());
        UUID bomKeeper = fixture.createUserWithPerms(shop.world(), "bom-" + UUID.randomUUID().toString().substring(0, 8),
                "notice:read", "goods:bom:edit");
        db.update("INSERT INTO warehouse_keepers(warehouse_id, employee_id) SELECT ?, employee_id FROM users WHERE id = ?",
                shop.leaf(), shop.warehouseUser());
        UUID period = shop.firstPeriod();
        UUID weight = UUID.nameUUIDFromBytes((period + ":WEIGHT").getBytes(java.nio.charset.StandardCharsets.UTF_8));
        UUID stockAggregate = UUID.nameUUIDFromBytes((period + ":STOCK").getBytes(java.nio.charset.StandardCharsets.UTF_8));

        notices.closeBlocked(period, List.of(new WorkshopMaterialNoticePort.Blocker(
                WorkshopMaterialNoticePort.BLOCKER_MISSING_WEIGHT, 2, List.of("产品甲", "产品乙")),
                new WorkshopMaterialNoticePort.Blocker(WorkshopMaterialNoticePort.BLOCKER_PREVIOUS_PERIOD_OPEN, 1, List.of())));
        String content = db.queryForObject("""
                SELECT content FROM notices WHERE audience_user_id = ? AND aggregate_id = ? AND resolved_at IS NULL""",
                String.class, bomKeeper, weight);
        assertTrue(content.contains("2 个产品") && content.contains("产品甲"), content);
        assertFalse(content.matches(".*[A-Z_]{6,}.*"), "通知正文不带代号: " + content);
        assertEquals(0, openNotices(shop.warehouseUser(), weight), "缺单重不通知仓库");
        // 同一期同一种类条数不变: 不重发
        notices.closeBlocked(period, List.of(new WorkshopMaterialNoticePort.Blocker(
                WorkshopMaterialNoticePort.BLOCKER_MISSING_WEIGHT, 2, List.of("产品甲", "产品乙"))));
        assertEquals(1, allNotices(bomKeeper, weight));
        // 条数变了: 旧卡撤掉发新卡; 有理论没进过料的通知内料仓所在主仓的仓管与本车间的认料人
        notices.closeBlocked(period, List.of(
                new WorkshopMaterialNoticePort.Blocker(WorkshopMaterialNoticePort.BLOCKER_MISSING_WEIGHT, 1,
                        List.of("产品甲")),
                new WorkshopMaterialNoticePort.Blocker(WorkshopMaterialNoticePort.BLOCKER_THEORY_WITHOUT_STOCK, 1,
                        List.of("颗粒甲"))));
        assertEquals(2, allNotices(bomKeeper, weight));
        assertEquals(1, openNotices(bomKeeper, weight));
        assertEquals(1, openNotices(shop.warehouseUser(), stockAggregate));
        assertEquals(1, openNotices(shop.counterB(), stockAggregate));
        // 生产部默认授予认料, 车间成员都收到; 不在这个车间、也不管这个仓的人不收
        assertEquals(1, openNotices(shop.counterA(), stockAggregate));
        assertEquals(0, openNotices(bomKeeper, stockAggregate));
        // 缺单重补好了、还剩没进过料: 缺单重的卡撤掉
        notices.closeBlocked(period, List.of(new WorkshopMaterialNoticePort.Blocker(
                WorkshopMaterialNoticePort.BLOCKER_THEORY_WITHOUT_STOCK, 1, List.of("颗粒甲"))));
        assertEquals(0, openNotices(bomKeeper, weight));
        // 结算完成: 全部撤卡; 连续失败通知设置负责人
        notices.closeResolved(period);
        assertEquals(0, openNotices(shop.warehouseUser(), stockAggregate));
        notices.closeFailing(period, "库存价值还在处理中");
        UUID failing = UUID.nameUUIDFromBytes((period + ":FAILING").getBytes(java.nio.charset.StandardCharsets.UTF_8));
        assertEquals(1, openNotices(shop.warehouseUser(), failing));

        // 段还没绑定内料仓: 开工状态"原样", 没有拦截文案; 报工截止不拦
        assertEquals(WorkshopMaterialStatePort.NO_BIN, state.state(UUID.randomUUID()));
        assertTrue(state.startBlockMessage(UUID.randomUUID()).isEmpty());
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status ->
                reportGuard.lockAndCheck(null, BusinessTime.today(), List.of(UUID.randomUUID()),
                        WorkshopMaterialReportGuardPort.Operation.APPROVE));
        fixture.loginAs(shop.counterA());
        assertTrue(choices.pending(List.of(UUID.randomUUID())).isEmpty());
    }

    // =============================================================================================
    // 期间详情 (盘点页只拿到期间) 与机台卡片的「在用料」预选
    // =============================================================================================

    @Test
    void periodDetailFindsTheCurrentCountAndMachineCardsPreselectTheLastMaterialInUse() {
        Shop shop = shop("detail", BusinessTime.today());
        UUID granule = granule(shop, "颗粒预选");
        fixture.loginAs(shop.warehouseUser());
        MachineList created = machines.createBatch(new MachineBatchCreate(shop.workshop(), 2, "P", 1, List.of(
                new ContainerSpec("干燥机料斗", new BigDecimal("50"))), key("machines")));
        assertEquals(2, created.machines().size());
        otherIn(shop, granule, "100", "10");
        issue(shop, granule, "60", "issue");

        fixture.loginAs(shop.counterA());
        PeriodView open = countController.period(shop.firstPeriod());
        assertEquals("OPEN", open.status());
        assertEquals(shop.bin(), open.binWarehouseId());
        assertNull(open.currentCountId(), "还没开始盘点");
        assertNull(open.currentCountStatus());
        assertTrue(open.allowedActions().contains("START_COUNT"));

        StartCountResult started = periods.startCount(shop.firstPeriod(), new StartCountRequest(0L, null,
                key("start")));
        UUID count = started.count().id();
        assertTrue(started.count().machines().stream().allMatch(card -> card.lastGoodsId() == null),
                "第一次盘点没有上一次在用的料");
        PeriodView counting = countController.period(shop.firstPeriod());
        assertEquals(count, counting.currentCountId());
        assertEquals("DRAFT", counting.currentCountStatus());

        ContainerSlot hopper1 = started.count().machines().get(0).containers().get(0);
        ContainerSlot hopper2 = started.count().machines().get(1).containers().get(0);
        UUID machine1 = started.count().machines().get(0).machineId();
        UUID machine2 = started.count().machines().get(1).machineId();
        counts.saveLine(count, hopper1.clientLineKey(), new CountLineInput(null, "CONTAINER", null, granule, null,
                null, null, null, machine1, hopper1.containerId(), "FULL"));
        counts.saveLine(count, hopper2.clientLineKey(), new CountLineInput(null, "CONTAINER", null, null, null,
                null, null, null, machine2, hopper2.containerId(), "EMPTY"));
        counts.submit(count, new VersionRequest(countVersion(count), key("submit")));
        PeriodView counted = countController.period(shop.firstPeriod());
        assertEquals("COUNTED", counted.status());
        assertEquals(count, counted.currentCountId());
        assertEquals("SUBMITTED", counted.currentCountStatus());

        // 更正盘点: 新草稿的机台卡片预选上一版里在用的料; 停机全空的那台没有在用料
        CountDetail correction = counts.correct(shop.firstPeriod(), new CorrectCountRequest(counted.rowVersion(),
                "漏盘了一袋料", key("correct")));
        assertEquals(granule, correction.machines().stream().filter(card -> card.machineId().equals(machine1))
                .findFirst().orElseThrow().lastGoodsId());
        assertNull(correction.machines().stream().filter(card -> card.machineId().equals(machine2))
                .findFirst().orElseThrow().lastGoodsId());
        PeriodView correcting = countController.period(shop.firstPeriod());
        assertEquals(correction.id(), correcting.currentCountId(), "有草稿时给草稿");
        assertEquals("DRAFT", correcting.currentCountStatus());

        // 对象范围: 别的车间的人看不到这个车间的期间; 没有查看权限的人进不了接口
        Object otherAssignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment",
                "wm-other-" + UUID.randomUUID().toString().substring(0, 8));
        UUID otherWorkshop = ReflectionTestUtils.invokeMethod(otherAssignment, "workshopId");
        UUID outsider = fixture.createUserWithPerms(shop.world(), "out-" + UUID.randomUUID().toString().substring(0, 8),
                "notice:read", "workshop_material:view", "workshop_material:count");
        db.update("UPDATE employees SET department_id = ? WHERE id = (SELECT employee_id FROM users WHERE id = ?)",
                otherWorkshop, outsider);
        fixture.loginAs(outsider);
        ApiException foreign = assertThrows(ApiException.class, () -> countController.period(shop.firstPeriod()));
        assertEquals(ErrorCode.FORBIDDEN, foreign.getCode());
        UUID noView = fixture.createUserWithPerms(shop.world(), "nv-" + UUID.randomUUID().toString().substring(0, 8),
                "notice:read");
        fixture.loginAs(noView);
        assertThrows(org.springframework.security.access.AccessDeniedException.class,
                () -> countController.period(shop.firstPeriod()));
    }

    // =============================================================================================
    // 夹具
    // =============================================================================================

    private Shop shop(String tag, LocalDate goLive) {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String unique = tag + "-" + UUID.randomUUID().toString().substring(0, 8);
        var world = fixture.seedWorld("wm-count-" + unique);
        fixture.loginAs(world.superAdminUserId());
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "wm-count-" + unique);
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment, "workshopId");
        UUID worker = ReflectionTestUtils.invokeMethod(assignment, "workerId");
        UUID kg = UUID.randomUUID();
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'千克','使用')",
                kg, 900_000_000 + ThreadLocalRandom.current().nextInt(90_000_000), "KG-" + unique);
        db.update("""
                INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,canonical_unit_id,to_canonical_factor,provenance)
                VALUES (?,'MASS',?,1,'MANUAL_GOVERNANCE')""", kg, kg);
        UUID warehouseUser = fixture.createUserWithPerms(world, "wh-" + unique, "notice:read",
                "workshop_material:view", "workshop_material:issue", "workshop_material:count",
                "workshop_material:setup");
        UUID counterA = fixture.createUserWithPerms(world, "ca-" + unique, "notice:read",
                "workshop_material:view", "workshop_material:count", "workshop_material:request");
        UUID counterB = fixture.createUserWithPerms(world, "cb-" + unique, "notice:read",
                "workshop_material:view", "workshop_material:count", "workshop_material:choose");
        for (UUID counter : List.of(counterA, counterB)) {
            db.update("UPDATE employees SET department_id = ? WHERE id = (SELECT employee_id FROM users WHERE id = ?)",
                    workshop, counter);
        }
        fixture.loginAs(warehouseUser);
        var view = settings.update(workshop, new SettingsRequest(0L, true, world.warehouseId(), goLive, List.of(),
                key("enable")));
        return new Shop(world, world.superAdminUserId(), workshop, worker, kg, world.warehouseId(), warehouseUser,
                counterA, counterB, view.binWarehouseId(), view.currentPeriod().id());
    }

    private UUID granule(Shop shop, String name) {
        UUID id = UUID.randomUUID();
        int legacy = db.queryForObject("SELECT legacy_id FROM units WHERE id=?", Integer.class, shop.kg());
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,
                                  issue_method,periodic_cost_basis,bulk_package_qty,owning_warehouse_id,min_qty)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),
                        'PERIODIC','OWN',25,?,0)""",
                id, "WM-" + id.toString().substring(0, 8), name + "-" + id.toString().substring(0, 4), shop.kg(), legacy,
                shop.leaf());
        return id;
    }

    private void otherIn(Shop shop, UUID goods, String qty, String price) {
        UUID previous = currentUser();
        fixture.loginAs(shop.admin());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(shop.leaf());
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(shop.kg());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal(price));
        line.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal(price)));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
        if (previous != null) fixture.loginAs(previous);
    }

    private void issue(Shop shop, UUID goods, String qty, String tag) {
        UUID previous = currentUser();
        fixture.loginAs(shop.warehouseUser());
        requisitions.directIssue(new DirectIssueRequest(shop.workshop(), shop.worker(),
                List.of(new DirectIssueLine(goods, null, null, new BigDecimal(qty), shop.leaf())), null, key(tag)));
        if (previous != null) fixture.loginAs(previous);
    }

    private void weighed(UUID count, String key, UUID goods, String qty) {
        counts.saveLine(count, key, new CountLineInput(null, "WEIGHED", null, goods, null, null, null,
                new BigDecimal(qty), null, null, null));
    }

    private UUID currentUser() {
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        return authentication != null && authentication.getPrincipal() instanceof com.uten.imp.security.AuthUser user
                ? user.getId() : null;
    }

    private int openNotices(UUID user, UUID aggregate) {
        return db.queryForObject("""
                SELECT count(*) FROM notices WHERE audience_user_id = ? AND aggregate_id = ? AND resolved_at IS NULL""",
                Integer.class, user, aggregate);
    }

    private int allNotices(UUID user, UUID aggregate) {
        return db.queryForObject("SELECT count(*) FROM notices WHERE audience_user_id = ? AND aggregate_id = ?",
                Integer.class, user, aggregate);
    }

    private long countVersion(UUID count) {
        return db.queryForObject("SELECT row_version FROM workshop_material_counts WHERE id = ?", Long.class, count);
    }

    private UUID periodLine(UUID period, UUID goods) {
        return db.queryForObject("""
                SELECT id FROM workshop_material_period_lines WHERE period_id = ? AND goods_id = ? AND color_id IS NULL""",
                UUID.class, period, goods);
    }

    /** 这一行的全部过账 (种类:数量), 按文字排序; 同一事务里的几笔没有先后。 */
    private List<String> postings(UUID line) {
        return db.queryForList("""
                SELECT posting.kind || ':' || trim(to_char(posting.qty, 'FM999999990.####'), '.')
                FROM workshop_material_count_postings posting
                WHERE posting.period_line_id = ? AND posting.movement_id IS NOT NULL
                """, String.class, line).stream().sorted().toList();
    }

    private static List<String> sorted(String... postings) {
        return java.util.Arrays.stream(postings).sorted().toList();
    }

    private BigDecimal netConsume(UUID line) {
        return db.queryForObject("""
                SELECT COALESCE(sum(CASE kind WHEN 'CONSUME' THEN qty WHEN 'CONSUME_REVERSE' THEN -qty ELSE 0 END), 0)
                FROM workshop_material_count_postings WHERE period_line_id = ?""", BigDecimal.class, line);
    }

    private BigDecimal netGain(UUID line) {
        return db.queryForObject("""
                SELECT COALESCE(sum(CASE kind WHEN 'GAIN' THEN qty WHEN 'GAIN_REVERSE' THEN -qty ELSE 0 END), 0)
                FROM workshop_material_count_postings WHERE period_line_id = ?""", BigDecimal.class, line);
    }

    private void balance(UUID warehouse, UUID goods, String qty) {
        BigDecimal actual = db.queryForObject("""
                SELECT COALESCE((SELECT qty FROM stock_balances WHERE warehouse_id = ? AND goods_id = ? AND color_id IS NULL), 0)""",
                BigDecimal.class, warehouse, goods);
        money(qty, actual);
    }

    private static String key(String tag) {
        return "wm-" + tag + "-" + UUID.randomUUID();
    }

    private static void money(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), () -> "expected " + expected + ", actual " + actual);
    }
}
