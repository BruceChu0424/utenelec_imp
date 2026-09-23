package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-101 + ADR-103 委外「只有一个叶子子件」形态(路线 B)的真库全链: 下单前的锁 → 批准派活
 * → 分批发料。ADR-085 §五点名的那条用例在仓库里搜不到, 这一段至今没有任何端到端覆盖, 本轮补上。
 *
 * <p>覆盖用户口径 (ADR-103): 子件仓里一件都没有时连委外订货单都建不了 (建单/送审/批准同一把锁);
 * 子件入库了不管多少都解锁; 只能发这么多就先发这么多, 界面要直接看得到可发数量; 发完第一批不会
 * 被系统自己开的第二张草稿顶回去; 后续到货由库存内核 (StockService 每笔入库) 自动叫醒, 不靠任何
 * 入库单据记得去调。
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
    void childStockLocksOrderingThenUnlocksWarehouseWorkAndIssuesInBatchesWithAServerSideIssuableQuantity() {
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

        // ① ADR-103 路线 B 的锁: 子件仓里一件都没有, 连委外订货单都建不了, 文案要说清
        //    哪张委外件在等哪颗子件、什么时候会自动解锁。
        ApiException locked = assertThrows(ApiException.class,
                () -> orders.create(orderRequest(w, "10")),
                "子件一件都没有时不得建委外订货单 (ADR-103 建单/送审/批准同一把锁)");
        assertEquals(ErrorCode.CONFLICT, locked.getCode());
        assertTrue(locked.getMessage().contains("仓里还一件都没有"), locked.getMessage());
        assertTrue(locked.getMessage().contains("入库后任务中心会自动解锁"), locked.getMessage());
        assertEquals(0, db.queryForObject(
                "SELECT COUNT(*) FROM subcontract_order_items WHERE goods_id=?",
                Integer.class, w.goodsE()), "被锁的建单不能留下半张单");

        // ② 子件到货 6 个(少于订货量)。按用户口径「不管数量多少就解锁」: 这时才能订 10 个委外件,
        //    允许损耗 10%; 送审、批准同样放行。(此刻还没有委外计划, 入库内核的叫醒是空跑。)
        receiveChildStock(w, "6");
        UUID orderId = orders.create(orderRequest(w, "10")).getId();
        UUID orderItemId = db.queryForObject(
                "SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());

        // ③ 批准落的是「发子件」的计划行：货品是子件、父件仍是委外件。
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

        // ④ ADR-101: 批准时子件已有 6 个, 系统按此刻可动用量给仓库开一张发得出去的草稿——
        //    量按仓里现货截断, 不是整笔计划量 10。
        assertEquals(1, draftCount(planItemId), "子件有货时批准就该自动出现一张能发得出去的草稿");
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

        // ⑥ 子件再到 4 个 → 再解锁一次，把剩下的发完。ADR-103: 这里**不手工叫醒**——
        //    其它入库单审核走 StockService 的入库分支, 库存内核在同一事务里自动叫醒。
        receiveChildStock(w, "4");
        UUID secondDraft = draftId(planItemId);
        assertNotNull(secondDraft, "后续到货必须由库存内核自动再解锁一批, 不靠入库单据记得去调");
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
