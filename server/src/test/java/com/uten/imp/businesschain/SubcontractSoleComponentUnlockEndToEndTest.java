package com.uten.imp.businesschain;

import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundPlanLine;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-101 委外「只有一个叶子子件」形态的出仓段真库全链。ADR-085 §五点名的那条用例在仓库里
 * 搜不到，这一段(批准 → 派活 → 分批发料)至今没有任何端到端覆盖，本轮补上。
 *
 * <p>覆盖用户口径：子件没到货就不该给仓库派活；子件入库了不管多少都解锁；只能发这么多就先发
 * 这么多，界面要直接看得到可发数量；发完第一批不会被系统自己开的第二张草稿顶回去。
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
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractSoleComponentUnlockEndToEndTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired SubcontractMaterialIssueService materialIssues;
    @Autowired SubcontractMaterialPlanService materialPlans;
    @Autowired StockDocService stockDocs;
    @Autowired org.springframework.transaction.PlatformTransactionManager txManager;

    FullChainEndToEndTest fixture;

    @BeforeEach
    void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    @Test
    void childStockUnlocksWarehouseWorkAndIssuesInBatchesWithAServerSideIssuableQuantity() {
        var w = fixture.seedWorld("sc-sole-component");
        fixture.loginAs(w.superAdminUserId());
        // 委外件 goodsE 挂唯一一条 PER_UNIT 叶子边到采购件 goodsD：每 1 个 goodsE 吃 1 个 goodsD。
        // goodsD 自己没有 BOM，所以命中 fn_subcontract_sole_component_goods。
        db.update("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, sort_order,
                    control_stage, consumption_basis, basis_output_qty, allow_partial_package, hard_gate)
                VALUES (?, ?, ?, 1, 1, 'START', 'PER_UNIT', 1, TRUE, TRUE)
                """, UUID.randomUUID(), w.goodsE(), w.goodsD());
        assertTrue(Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_subcontract_sole_component_goods(?)", Boolean.class, w.goodsE())),
                "夹具必须命中「只有一个叶子子件」判据，否则测的是别的形态");

        // ① 订 10 个委外件，允许损耗 10%。子件一件都没有。
        UUID orderId = orders.create(orderRequest(w, "10")).getId();
        UUID orderItemId = db.queryForObject(
                "SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());

        // ② 批准落的是「发子件」的计划行：货品是子件、父件仍是委外件。
        UUID planItemId = db.queryForObject("""
                SELECT id FROM subcontract_material_plan_items
                WHERE order_item_id=? AND is_deleted=FALSE
                """, UUID.class, orderItemId);
        assertEquals("COMPONENT_OUTBOUND", db.queryForObject(
                "SELECT flow_mode FROM subcontract_material_plan_items WHERE id=?", String.class, planItemId));
        assertEquals(w.goodsD(), db.queryForObject(
                "SELECT goods_id FROM subcontract_material_plan_items WHERE id=?", UUID.class, planItemId));
        assertEquals(w.goodsE(), db.queryForObject(
                "SELECT parent_goods_id FROM subcontract_material_plan_items WHERE id=?", UUID.class, planItemId));

        // ③ ADR-101 的核心：子件还在采购路上时**不给仓库派活**——不建草稿、不通知。
        assertEquals(0, draftCount(planItemId),
                "子件一件都没有时不得生成出仓草稿；此前这里会开一张满量草稿，仓库白跑一趟");
        OutboundPlanLine idle = outboundLine(planItemId);
        assertEquals(0, BigDecimal.ZERO.compareTo(idle.issuableQty()),
                "可发数量必须是确定的 0，不能是 null——null 会让客户端回落成计划余量");
        assertEquals(0, BigDecimal.ZERO.compareTo(idle.stockAvailableQty()));

        // ④ 子件到货 6 个(少于订货量)。按用户口径「不管数量多少就可以解锁、可以分批发货」。
        receiveChildStock(w, "6");
        wakeAfterChildStockIn(w);

        assertEquals(1, draftCount(planItemId), "子件一入库就该自动出现一张能发得出去的草稿");
        UUID firstDraft = draftId(planItemId);
        assertEquals(0, new BigDecimal("6").compareTo(draftQty(firstDraft)),
                "草稿量必须按该仓此刻的可动用量截断，不是整笔计划量");
        OutboundPlanLine unlocked = outboundLine(planItemId);
        assertEquals(w.warehouseId(), unlocked.stockWarehouseId(),
                "服务端要替仓库指出这批料在哪个仓");
        // 草稿一建就把这 6 个预留掉了，所以「还空着的可动用量」与「还能再填多少」都是 0。
        // 仓库在界面上看到的「仓内可动用」是这个数加回本草稿自己占的量。
        assertEquals(0, BigDecimal.ZERO.compareTo(unlocked.stockAvailableQty()));
        assertEquals(0, BigDecimal.ZERO.compareTo(unlocked.issuableQty()));

        // ⑤ 先发这 6 个。审核之后系统会为剩余 4 个续生草稿——子件还没到，占不上库存，
        //    此前这一步会抛 409 把刚审核的这 6 个一起回滚，分批发料根本走不通。
        materialIssues.approve(firstDraft);
        assertEquals(0, new BigDecimal("6").compareTo(db.queryForObject(
                "SELECT issued_qty FROM subcontract_material_plan_items WHERE id=?",
                BigDecimal.class, planItemId)), "第一批 6 个必须真的发出去");
        assertEquals(0, draftCount(planItemId),
                "剩余 4 个还没有料，不该再开一张发不出去的草稿");

        // ⑥ 子件再到 4 个 → 再解锁一次，把剩下的发完。
        receiveChildStock(w, "4");
        wakeAfterChildStockIn(w);
        UUID secondDraft = draftId(planItemId);
        assertNotNull(secondDraft, "后续到货必须能再解锁一批");
        assertEquals(0, new BigDecimal("4").compareTo(draftQty(secondDraft)));
        materialIssues.approve(secondDraft);
        assertEquals(0, new BigDecimal("10").compareTo(db.queryForObject(
                "SELECT issued_qty FROM subcontract_material_plan_items WHERE id=?",
                BigDecimal.class, planItemId)), "两批合计必须等于订货量折算的子件量");
        assertEquals(0, draftCount(planItemId), "发完之后不再留未审草稿");

        // ⑦ 发出去的是子件、供应商处台账记的也是子件；委外件自己一件都没动过库存。
        assertEquals(0, new BigDecimal("10").compareTo(db.queryForObject("""
                SELECT COALESCE(SUM(at_supplier_qty),0) FROM subcontract_material_issue_items
                WHERE order_item_id=? AND is_deleted=FALSE
                """, BigDecimal.class, orderItemId)));
        assertEquals(0, BigDecimal.ZERO.compareTo(onHand(w.goodsE(), w.warehouseId())),
                "委外件要等加工回厂并质检入库才会有库存");
        assertEquals(0, BigDecimal.ZERO.compareTo(onHand(w.goodsD(), w.warehouseId())),
                "子件已经全部发给委外商");
    }

    // ===================== 夹具 =====================

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w, String qty) {
        var request = new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setDeliverDate(BusinessTime.today().plusDays(3));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        var line = new OrderItemLine();
        line.setGoodsId(w.goodsE());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("10"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        line.setAllowedLossPct(new BigDecimal("10"));
        request.setItems(List.of(line));
        return request;
    }

    /** 子件按普通采购件入库(期初/其它入库)，模拟「采购件到货了」。 */
    private void receiveChildStock(FullChainEndToEndTest.World w, String qty) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(LocalDate.of(2026, 1, 1));
        request.setWarehouseId(w.warehouseId());
        request.setRemark("委外子件到货 " + qty);
        var line = new StockDocItemLine();
        line.setGoodsId(w.goodsD());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("10"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        var doc = stockDocs.create(request);
        stockDocs.approve(doc.getId());
    }

    /**
     * 唤醒是 {@code MANDATORY} 传播——生产里它跑在「仓库确认 IQC 合格品入库」那个事务内
     * ({@code ProcurementIqcStockInService.confirmOne} 写完库存之后)。这里用同样的方式把它
     * 包进一个事务，调的是同一个方法、同一个入参形状。
     */
    private void wakeAfterChildStockIn(FullChainEndToEndTest.World w) {
        new org.springframework.transaction.support.TransactionTemplate(txManager).executeWithoutResult(
                status -> materialPlans.wakeOutboundAfterStockIn(List.of(
                        new SubcontractOutboundWakePort.StockedDimension(
                                w.goodsD(), null, w.warehouseId()))));
    }

    private OutboundPlanLine outboundLine(UUID planItemId) {
        UUID planId = db.queryForObject(
                "SELECT plan_id FROM subcontract_material_plan_items WHERE id=?", UUID.class, planItemId);
        return materialPlans.taskDetail(planId).lines().stream()
                .filter(line -> planItemId.equals(line.planItemId()))
                .findFirst().orElseThrow();
    }

    private int draftCount(UUID planItemId) {
        Integer count = db.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                WHERE item.plan_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                """, Integer.class, planItemId);
        return count == null ? 0 : count;
    }

    private UUID draftId(UUID planItemId) {
        return db.query("""
                SELECT issue.id FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                WHERE item.plan_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                ORDER BY issue.created_at DESC LIMIT 1
                """, rs -> rs.next() ? rs.getObject(1, UUID.class) : null, planItemId);
    }

    private BigDecimal draftQty(UUID issueId) {
        return db.queryForObject(
                "SELECT COALESCE(SUM(qty),0) FROM subcontract_material_issue_items WHERE issue_id=?",
                BigDecimal.class, issueId);
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId) {
        BigDecimal qty = db.queryForObject("""
                SELECT COALESCE(SUM(qty),0) FROM stock_balances
                WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, goodsId, warehouseId);
        return qty == null ? BigDecimal.ZERO : qty;
    }
}
