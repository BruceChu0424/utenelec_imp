package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawItemRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitRequest;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterResult;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * 2026-11-08 口径修订: 委外催收与完结以「订货量」为准, 允许损耗只放宽登记上限。
 * 订量收齐(领料可含损耗备料弹性)后, 仓库任务中心不再出现「委外待登记到货」任务,
 * expectation CLOSED; 登记容量仍允许收到订量×(1+损耗)(不超过物理容量); 少收仍催
 * 订量−已收; 已结案损耗扣减目标; 红冲后目标回升。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractOrderedTargetCollectionEndToEndTest extends SubcontractFullChainTestContext {
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractDrawCommandService draws;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired SubcontractReceiptService receipts;
    @Autowired ProcurementArrivalControlService arrivalControl;
    SubcontractStepDrawEndToEndTest h;

    @BeforeEach void setup() {
        h = new SubcontractStepDrawEndToEndTest();
        beans.autowireBean(h);
        h.setup();
    }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    /** (a)+(b) 订量 1000、允许损耗 10%、领料 1100: 到货 1000 = 订量 → 任务完结; 容量仍可收到 1100。 */
    @Test
    void receivingTheOrderedQuantityClosesTheCollectionAndKeepsTheLossAllowanceCapacity() {
        Case c = ready("collect-close", "1000", "10", "1100");
        // 修订前基准: LEAST(GREATEST(1100−0),1100)=1100 → 催 1100; 修订后催订量 1000。
        var before = arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId());
        assertEquals(1, before.getTotal(), "收货前预计到货任务在列");
        assertEquals(0, new BigDecimal("1000").compareTo(before.getItems().getFirst().remainingQty()),
                "催收目标 = 订量, 不是订量×(1+损耗)");

        UUID receipt = receive(c, "1000", "close");
        assertEquals("CLOSED", status(c.order()), "订量收齐 → expectation CLOSED(行动卡按既有流程撤回)");
        assertEquals(0, arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId()).getTotal(),
                "订量收齐 → 不再有「委外待登记到货」任务");

        // 登记容量不动: 订量收齐后仍可收到订量×(1+损耗)=1100(物理容量 1100 未超)。
        assertEquals("SUBMITTED_FOR_INSPECTION", register(c, "100", "allowance").outcome());
        amount("1100", "SELECT received_qty FROM subcontract_order_items WHERE id=?", c.item());
        assertEquals(0, arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId()).getTotal(),
                "损耗内的多到货不重新催收");
        // 超过订量×(1+损耗) 才走既有超量隔离, 不入库。
        assertEquals("EXCESS_QUARANTINED", register(c, "0.0001", "beyond").outcome());
        amount("1100", "SELECT received_qty FROM subcontract_order_items WHERE id=?", c.item());
        amount("1", "SELECT COUNT(*) FROM procurement_arrival_exceptions WHERE order_item_id=?", c.item());
    }

    /** (c) 到货 400 < 订量 1000 → 仍催订量−已收 = 600(修订前会催 1100−400 = 700)。 */
    @Test
    void belowTheOrderedQuantityKeepsCollectingOrderMinusReceived() {
        Case c = ready("collect-short", "1000", "10", "1100");
        receive(c, "400", "short");
        assertEquals("OPEN", status(c.order()));
        var pending = arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId());
        assertEquals(1, pending.getTotal(), "未收满订量仍催收(开放短交案件不抑制催收)");
        assertEquals(0, new BigDecimal("600").compareTo(pending.getItems().getFirst().remainingQty()),
                "催收目标 = 订量 1000 − 已收 400");
    }

    /**
     * (d) 到货 950、结案认损 50: 1000−950−50 = 0 → 催收完结(修订前 1100−950−50 = 100 仍催)。
     * 领料按计划量 1100 发齐——短交案件只在「料已发完」后评估(FACT_SQL.material_fully_issued),
     * 发 1050 会让案件不触发、认损无从落账。
     */
    @Test
    void settledLossDischargesTheOrderedQuantityCollectionTarget() {
        Case c = ready("collect-loss", "1000", "10", "1100");
        receive(c, "950", "loss");
        var collecting = arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId());
        assertEquals(1, collecting.getTotal(), "认损前仍催 1000−950 = 50");
        assertEquals(0, new BigDecimal("50").compareTo(collecting.getItems().getFirst().remainingQty()));

        List<Map<String, Object>> open = db.queryForList(
                "SELECT id, version FROM subcontract_short_delivery_cases WHERE order_item_id=?"
                        + " AND status IN('PENDING_OWNER','WAITING_MORE') ORDER BY detected_at DESC", c.item());
        assertEquals(1, open.size(), "低于订量触发短交案件(V1098)");
        stockPrecision(() -> h.shortDelivery.decide((UUID) open.getFirst().get("id"),
                new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                        "ACCEPT_LOSS", null, "委外商确认 50 件加工报废",
                        ((Number) open.getFirst().get("version")).longValue())));
        ReflectionTestUtils.invokeMethod(h.fixture, "drainCosts", c.world());
        amount("50", "SELECT fn_subcontract_settled_loss_qty(?)", c.item());
        assertEquals(0, arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId()).getTotal(),
                "已收 950 + 已结案损耗 50 = 订量 1000 → 催收完结");
    }

    /** (e) 订量收齐完结后红冲: 已收回 0 → expectation 重新 OPEN、催收目标回升到订量。 */
    @Test
    void reversingTheReceiptRestoresTheCollectionTarget() {
        Case c = ready("collect-reverse", "1000", "10", "1100");
        UUID receipt = receive(c, "1000", "reverse");
        assertEquals("CLOSED", status(c.order()));
        assertEquals(0, arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId()).getTotal());

        ReflectionTestUtils.invokeMethod(h, "passIqc", "SUBCONTRACT", receipt, c.tag() + "-pass");
        receipts.reverse(receipt);
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork, db, List.of(c.product(), c.material()));
        amount("0", "SELECT received_qty FROM subcontract_order_items WHERE id=?", c.item());
        assertEquals("OPEN", status(c.order()), "红冲后 expectation 重新 OPEN");
        var restored = arrivalControl.expectations(1, 20, "SUBCONTRACT", null, c.world().supplierId());
        assertEquals(1, restored.getTotal(), "冲回后催收任务回归");
        assertEquals(0, new BigDecimal("1000").compareTo(restored.getItems().getFirst().remainingQty()),
                "催收目标回升到订量(退货/IQC 退回的回冲项同一口径)");
    }

    // ===================== helpers(与 SubcontractActualReceiptAllowanceEndToEndTest 同构) =====================

    /** 认损结案走与 SubcontractShortDeliveryEndToEndTest 相同的精度上下文, 避免库存价值区间抖动。 */
    @SuppressWarnings("try")
    private static <T> T stockPrecision(java.util.function.Supplier<T> operation) {
        try (var choice = com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of("stock.value.interval",
                new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(30, "DOWN")))) {
            return operation.get();
        } catch (RuntimeException | Error failure) {
            throw failure;
        } catch (Exception failure) {
            throw new AssertionError(failure);
        }
    }

    private String status(UUID order) {
        return db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='SUBCONTRACT' AND order_id=?",
                String.class, order);
    }

    private Case ready(String tag, String target, String lossPct, String issued) {
        var w = h.fixture.seedWorld(tag);
        h.fixture.loginAs(w.superAdminUserId());
        db.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                SELECT ?,id,'grant' FROM permissions WHERE code IN
                    ('subcontract_order:view','subcontract_order:draw','subcontract:view:all')
                """, w.superAdminUserId());
        UUID p = ReflectionTestUtils.invokeMethod(h, "goods", w, tag, "P", "委外");
        UUID a = ReflectionTestUtils.invokeMethod(h, "goods", w, tag, "A", "自制");
        h.fixture.insertBom(p, a, "1");
        UUID order = ReflectionTestUtils.invokeMethod(h, "subcontractOrder", w, p, target,
                com.uten.imp.common.time.BusinessTime.today().plusDays(5), new BigDecimal(lossPct));
        ReflectionTestUtils.invokeMethod(h, "approveSubcontract", w, order);
        UUID item = ReflectionTestUtils.invokeMethod(h, "itemOf", order);
        ReflectionTestUtils.invokeMethod(h, "otherIn", w, w.warehouseId(), a, null, issued, "10");
        UUID issue = draws.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item, null)), tag + "-draw-" + item))
                .issueIds().getFirst();
        issues.approve(issue);
        return new Case(w, order, item, p, a, tag);
    }

    private WarehouseArrivalRegisterRequest request(Case c, String actual, String suffix) {
        return new WarehouseArrivalRegisterRequest(c.tag() + "-" + suffix + "-" + c.item(), "SUBCONTRACT",
                com.uten.imp.common.time.BusinessTime.today(), c.world().supplierId(), c.world().warehouseId(),
                null, c.world().employeeId(), null,
                List.of(new ArrivalLine(c.product(), new BigDecimal(actual), c.item(), null,
                        c.world().unitId(), BigDecimal.ONE, null, null)));
    }

    private WarehouseArrivalRegisterResult register(Case c, String actual, String suffix) {
        return arrivals.register(request(c, actual, suffix));
    }

    private UUID receive(Case c, String actual, String suffix) {
        var original = request(c, actual, suffix);
        WarehouseArrivalRegisterResult result;
        try {
            result = arrivals.register(original);
        } catch (ApiException confirmation) {
            if (confirmation.getCode() != ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED) throw confirmation;
            result = arrivals.register(new WarehouseArrivalRegisterRequest(original.idempotencyKey(),
                    original.orderType(), original.billDate(), original.supplierId(), original.warehouseId(),
                    original.purchaserId(), original.receiverEmployeeId(), original.remark(), original.items(),
                    null, true));
        }
        assertEquals("SUBMITTED_FOR_INSPECTION", result.outcome(),
                "到货 " + actual + " 在订量/容量内必须照常登记");
        return result.receiptId();
    }

    private void amount(String expected, String sql, Object... args) {
        BigDecimal actual = db.queryForObject(sql, BigDecimal.class, args);
        org.junit.jupiter.api.Assertions.assertNotNull(actual, sql + " must return a known authoritative quantity");
        assertEquals(0, new BigDecimal(expected).compareTo(actual), sql + " expected " + expected + " actual " + actual);
    }

    private record Case(FullChainEndToEndTest.World world, UUID order, UUID item, UUID product, UUID material, String tag) {}
}
