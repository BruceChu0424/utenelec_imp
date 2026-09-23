package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-101 容差内自动结案跑在「仓库确认入库」的同一个事务里 (真库全链)。
 *
 * <p>这条用例守的是一件事: 仓库账号确认 IQC 合格入库时, 系统替委外把容差内的短交自动结案,
 * 而这个结案动作不许反过来把仓库正常的入库搞失败。结案第三步是受控改量, 此前它走的是
 * {@code changeQtyForShortDelivery}, 那条路第一件事就是订货单属主守卫
 * ({@code access.requireWritable(order.getMakerId(), ...)}) —— 仓库账号既不是委外订货单的
 * 制单人, 也没有 subcontract:view:all, 必拿 FORBIDDEN; 而这段异常会把整个入库事务标成只能
 * 回滚, 货根本入不了库。修复新增了 {@code changeQtyForShortDeliveryBySystem}, 只跳过属主
 * 守卫这一条。
 *
 * <p>所以本用例是一正一反两面:
 * 正面 —— 用一个既不是制单人、也没有 subcontract:view:all 的仓库账号走完 IQC 合格入库,
 * 库存真的加上、案件落 ACCEPTED_LOSS、订货明细被受控改量改成实收量、损耗单真的生成;
 * 反面 —— 同一个仓库账号直接调人工自由改量的公开入口 {@code changeQty} 仍然拿 FORBIDDEN,
 * 证明放宽的只有系统自动结案那一条路, 属主守卫没有被拆掉。
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
class SubcontractToleranceAutoSettleEndToEndTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired SubcontractMaterialIssueService materialIssues;
    @Autowired SubcontractShortDeliveryService shortDeliveries;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService iqcStockIn;

    FullChainEndToEndTest fixture;

    @BeforeEach
    void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void warehouseStockInAutoSettlesToleratedShortDeliveryWithoutWeakeningTheManualOwnerGuard() {
        var w = fixture.seedWorld("sc-tolerance-settle");
        fixture.loginAs(w.superAdminUserId());
        // 我方供料是委外件本身 (DIRECT_OUTBOUND): 先把 1000 件铺进仓, 才发得出去。
        ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", w, "1000");

        // ① 订 1000 件、允许损耗 10% -> 允许下限 900。用户口径就是这一组数。
        UUID orderId = orders.create(orderRequest(w, "1000", "10")).getId();
        UUID itemId = db.queryForObject(
                "SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);
        UUID makerId = db.queryForObject(
                "SELECT maker_id FROM subcontract_orders WHERE id=?", UUID.class, orderId);
        assertNotNull(makerId, "订货单必须有制单人, 否则属主守卫这一维根本没在测");

        // ② 财务批准: 受控改量的前提是「仅财务批准后的委外订货单可改量」。
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());

        // ③ 我方供料全部发完。severity 判定的前提是 materialFullyIssued(): 料没发完一律不判短交,
        //    这一步不做的话后面整条自动结案根本不会触发, 用例会假绿。
        UUID issueId = db.queryForObject("""
                SELECT issue.id FROM subcontract_material_issues issue
                JOIN subcontract_material_issue_items item ON item.issue_id=issue.id
                WHERE item.order_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                """, UUID.class, itemId);
        materialIssues.approve(issueId);
        qty("1000", db.queryForObject(
                "SELECT SUM(at_supplier_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",
                BigDecimal.class, itemId));
        assertEquals(0, count("""
                SELECT COUNT(*) FROM subcontract_material_plan_items plan_item
                JOIN subcontract_material_plans plan ON plan.id=plan_item.plan_id
                 AND plan.status='OPEN' AND plan.is_deleted=FALSE
                WHERE plan_item.order_item_id=? AND plan_item.is_deleted=FALSE
                  AND plan_item.issued_qty < LEAST(plan_item.planned_qty, plan_item.prepared_qty)
                """, itemId), "料必须真的全部发完 (与服务端 material_fully_issued 同一口径)");

        // ④ 回厂 950: 950 >= 下限 900 -> WITHIN_TOLERANCE。中性档既不弹窗也不锁入库。
        var receipt = arrivals.register(arrival(w, itemId, "950", "tol-1"));
        assertEquals("SUBMITTED_FOR_INSPECTION", receipt.outcome(), "容差内到货不该要仓库二次确认");
        Map<String, Object> pending = caseRow(itemId);
        UUID caseId = (UUID) pending.get("id");
        assertEquals("PENDING_OWNER", pending.get("status"));
        assertEquals("WITHIN_TOLERANCE", pending.get("severity"));
        qty("900", (BigDecimal) pending.get("floor_qty"));
        qty("950", (BigDecimal) pending.get("delivered_qty"));
        qty("50", (BigDecimal) pending.get("shortfall_qty"));
        assertNull(shortDeliveries.stockInHoldReason(receipt.receiptId()),
                "容差内短交不挂入库闸, 货照常上架");

        // ⑤ 质检合格 (委外跟单员做), 留下一个可入库的放行切片。
        UUID inspectionItemId = db.queryForObject("""
                SELECT id FROM procurement_inspection_items
                WHERE receipt_type='SUBCONTRACT' AND receipt_id=?
                """, UUID.class, receipt.receiptId());
        inspections.dispose("SUBCONTRACT", receipt.receiptId(), inspectionItemId,
                new InspectionDispositionRequest("PASS", null, "回厂件检查合格", "sc-tolerance-pass-1"));
        UUID passEventId = db.queryForObject("""
                SELECT id FROM procurement_inspection_events
                WHERE inspection_item_id=? AND action='PASS'
                """, UUID.class, inspectionItemId);
        BigDecimal passedQty = db.queryForObject(
                "SELECT base_qty FROM procurement_inspection_events WHERE id=?", BigDecimal.class, passEventId);
        qty("950", passedQty);

        // ⑥ 切到仓库账号。它多拿一个 subcontract_order:change_qty 只是为了让第 ⑧ 步的反向断言
        //    能穿过权限点、真正落到属主守卫上; 关键的两条仍然成立: 不是本单制单人、没有
        //    subcontract:view:all (也没有 subcontract_order:view, 拿不到任何委外读范围豁免)。
        UUID keeper = fixture.createUserWithPerms(w, "sc-tolerance-keeper",
                "warehouse_iqc_stock_in:view", "warehouse_iqc_stock_in:confirm",
                "subcontract_order:change_qty");
        UUID keeperEmployeeId = db.queryForObject(
                "SELECT employee_id FROM users WHERE id=?", UUID.class, keeper);
        assertNotEquals(makerId, keeperEmployeeId, "仓库账号不能恰好是本单制单人, 否则属主守卫测不到");
        fixture.loginAs(keeper);
        Set<String> keeperAuthorities = SecurityContextHolder.getContext().getAuthentication()
                .getAuthorities().stream().map(GrantedAuthority::getAuthority).collect(Collectors.toSet());
        assertFalse(keeperAuthorities.contains("subcontract:view:all"),
                "仓库账号必须没有委外全量查看权, 这正是修复前拿 FORBIDDEN 的原因");
        assertFalse(keeperAuthorities.contains("subcontract_order:view"),
                "也不许有委外订货查看权, 否则读范围会被操作级 authority 豁免掉");
        assertTrue(keeperAuthorities.contains("warehouse_iqc_stock_in:confirm"));
        assertFalse(db.queryForObject("SELECT is_super_admin FROM users WHERE id=?", Boolean.class, keeper),
                "超管旁路一切归属判定, 用超管测等于没测");

        // ⑦ 仓库确认入库 —— 修复前这里整笔回滚, 货入不了库。
        BigDecimal onHandBefore = onHand(w.goodsE(), w.warehouseId());
        var confirmed = iqcStockIn.confirm("SUBCONTRACT", receipt.receiptId(),
                new ConfirmRequest("sc-tolerance-stock-in-1",
                        List.of(new ConfirmItem(passEventId, passedQty, passedQty, "SC-TOL-01", w.warehouseId()))));
        assertFalse(confirmed.replayed(), "这是第一次确认, 不该走幂等重放");
        assertEquals(1, count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",
                receipt.receiptId()), "入库批次必须真的落盘");
        assertEquals(0, onHandBefore.add(new BigDecimal("950")).compareTo(onHand(w.goodsE(), w.warehouseId())),
                "库存必须真的加上 950; 修复前这一笔连同结案一起被回滚");

        // 自动结案的三件事: 案件落 ACCEPTED_LOSS、订货明细受控改量到 950、损耗单生成。
        fixture.loginAs(w.superAdminUserId());
        Map<String, Object> settled = caseRow(itemId);
        assertEquals(caseId, settled.get("id"), "结的必须是同一个案件, 不是另开一张");
        assertEquals("ACCEPTED_LOSS", settled.get("status"));
        assertEquals("ACCEPT_LOSS", settled.get("decision"));
        qty("50", (BigDecimal) settled.get("loss_qty"));
        qty("5", (BigDecimal) settled.get("loss_pct"));
        assertEquals(keeperEmployeeId, settled.get("decided_by_employee_id"),
                "结案的发起人就是仓库账号 —— 正是属主守卫此前拦下的那个身份");
        qty("950", db.queryForObject(
                "SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, itemId));
        assertEquals(1, count("""
                SELECT COUNT(*) FROM procurement_order_qty_change_logs
                WHERE order_type='SUBCONTRACT' AND order_item_id=? AND old_qty=1000 AND new_qty=950
                """, itemId), "受控改量必须留下 1000->950 的事实账");
        assertEquals(keeperEmployeeId, db.queryForObject("""
                SELECT changed_by_employee_id FROM procurement_order_qty_change_logs
                WHERE order_type='SUBCONTRACT' AND order_item_id=? ORDER BY changed_at DESC LIMIT 1
                """, UUID.class, itemId), "身份守卫与审计一个不动: 改量记在仓库账号名下");
        // ADR-103 §2.5 实施记录: 自动结案的受控改量照样开财务复核 case (V503 守卫要求同事务开 PENDING 复核)。
        assertNotNull(db.queryForObject("""
                SELECT case_id FROM procurement_order_qty_change_logs
                WHERE order_type='SUBCONTRACT' AND order_item_id=? ORDER BY changed_at DESC LIMIT 1
                """, UUID.class, itemId), "自动结案的改量日志必须挂在财务复核 case 上");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM procurement_order_approval_cases
                WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'
                """, orderId), "自动结案开一条 PENDING 财务复核 (V503 守卫)");
        UUID wasteId = (UUID) settled.get("waste_id");
        assertNotNull(wasteId, "接受损耗结案必须先开一张损耗单核销供应商处剩料");
        assertEquals(1, count("SELECT COUNT(*) FROM subcontract_wastes WHERE id=? AND status=1", wasteId),
                "损耗单必须已审核");
        qty("50", db.queryForObject(
                "SELECT SUM(qty) FROM subcontract_waste_items WHERE waste_id=?", BigDecimal.class, wasteId));
        qty("50", db.queryForObject(
                "SELECT SUM(standard_qty) FROM subcontract_waste_items WHERE waste_id=?", BigDecimal.class, wasteId));
        assertEquals(0, shortDeliveries.list("TOLERANT", null, null, orderId, null, null, 1, 20).getTotal(),
                "结完之后不再挂在「容差内待结案」等人点一下");

        // ⑧ 反向: 同一个仓库账号直接走人工自由改量的公开入口, 属主守卫照旧拦死。
        //    放宽的只有系统自动结案那一条路, 不是把守卫拆了。
        fixture.loginAs(keeper);
        ApiException denied = assertThrows(ApiException.class, () -> orders.changeQty(orderId,
                new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(itemId, new BigDecimal("900"))))));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode(), "人工改量必须仍然是 403");
        assertTrue(denied.getMessage().contains("只能操作本人负责的委外订货单"), denied.getMessage());
        fixture.loginAs(w.superAdminUserId());
        qty("950", db.queryForObject(
                "SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, itemId));
        assertEquals(0, count("""
                SELECT COUNT(*) FROM procurement_order_qty_change_logs
                WHERE order_type='SUBCONTRACT' AND order_item_id=? AND new_qty=900
                """, itemId), "被拒的人工改量一个字节都不许落盘");
    }

    // ===================== 夹具 =====================

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w, String qty, String allowedLossPct) {
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
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        line.setAllowedLossPct(new BigDecimal(allowedLossPct));
        request.setItems(List.of(line));
        return request;
    }

    private WarehouseArrivalRegisterRequest arrival(
            FullChainEndToEndTest.World w, UUID itemId, String qty, String key) {
        return new WarehouseArrivalRegisterRequest(
                "sc-tolerance-arrival-" + key + "-" + itemId, "SUBCONTRACT", BusinessTime.today(),
                w.supplierId(), w.warehouseId(), null, w.employeeId(), null,
                List.of(new ArrivalLine(w.goodsE(), new BigDecimal(qty), itemId, null,
                        w.unitId(), BigDecimal.ONE, null, null)),
                null, null);
    }

    private Map<String, Object> caseRow(UUID itemId) {
        return db.queryForMap("""
                SELECT * FROM subcontract_short_delivery_cases
                WHERE order_item_id=? ORDER BY detected_at DESC LIMIT 1
                """, itemId);
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId) {
        BigDecimal balance = db.queryForObject("""
                SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, goodsId, warehouseId);
        return balance == null ? BigDecimal.ZERO : balance;
    }

    private int count(String sql, Object... args) {
        Integer n = db.queryForObject(sql, Integer.class, args);
        return n == null ? 0 : n;
    }

    private static void qty(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), "expected " + expected + " but was " + actual);
    }
}
