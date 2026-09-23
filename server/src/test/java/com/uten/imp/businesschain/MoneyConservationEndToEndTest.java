package com.uten.imp.businesschain;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * ADR-112 金额守恒真库验收: 金额只按 MoneyPolicy 的精确乘积与累计分摊形成, 多批次合计恰好等于来源,
 * 全额退货后应付两种币都归零, 直发与订货发货的本币同一规则, 草稿金额就是审核后的金额,
 * 请求体不能再带金额。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
@Import(ProductionJdbcMeasurement.Configuration.class)
class MoneyConservationEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired MockMvc mockMvc;
    @Autowired SalesShipmentService shipments;
    @Autowired PurchaseRequestService purchaseRequests;
    @Autowired PurchaseOrderService purchaseOrders;
    @Autowired PurchaseReceiptService purchaseReceipts;
    @Autowired PurchaseReturnService purchaseReturns;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService iqcStockIn;
    @Autowired jakarta.persistence.EntityManager em;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test
    void threeShipmentsOfAHundredForThreePiecesPostExactlyAHundredOfReceivables() {
        FullChainEndToEndTest.World w = fixture.seedWorld("money-100-3");
        UUID orderItem = producedOrderItem(w, "3");
        UUID order = jdbc.queryForObject("SELECT order_id FROM sales_order_items WHERE id=?", UUID.class, orderItem);
        // 一口价订单行: 3 件共 100(不是数量 × 单价的乘积), 旧口径逐批四舍五入合计只有 99.9999。
        jdbc.update("UPDATE sales_order_items SET amount_original=100.0000 WHERE id=?", orderItem);
        jdbc.update("UPDATE sales_orders SET total_original=100.0000 WHERE id=?", order);
        fixture.loginAs(w.superAdminUserId());

        List<UUID> shipped = new ArrayList<>();
        long[] createStatements = new long[3];
        for (int i = 0; i < 3; i++) {
            ShipmentSaveRequest request = invoke("shipmentRequest", w, orderItem, w.goodsA(), "1");
            request.setBillDate(BusinessTime.today());
            var sample = ProductionJdbcMeasurement.begin();
            UUID id;
            try {
                id = shipments.create(request).getId();
            } finally {
                ProductionJdbcMeasurement.end();
            }
            createStatements[i] = sample.logicalStatements;
            fixture.shipThroughWarehouse(id);
            shipped.add(id);
        }

        List<BigDecimal> amounts = shipped.stream().map(id -> jdbc.queryForObject(
                "SELECT amount_original FROM sales_shipment_items WHERE shipment_id=?", BigDecimal.class, id)).toList();
        assertThat(amounts).extracting(BigDecimal::toPlainString).containsExactly("33.3333", "33.3334", "33.3333");
        BigDecimal receivable = jdbc.queryForObject("""
                SELECT SUM(amount_original) FROM ar_ap_ledger
                WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id IN (?,?,?) AND status=1
                """, BigDecimal.class, shipped.get(0), shipped.get(1), shipped.get(2));
        assertThat(receivable).isEqualByComparingTo("100");
        BigDecimal rate = jdbc.queryForObject("SELECT exchange_rate FROM sales_shipments WHERE id=?",
                BigDecimal.class, shipped.getFirst());
        BigDecimal receivableLocal = jdbc.queryForObject("""
                SELECT SUM(amount_original_local) FROM ar_ap_ledger
                WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id IN (?,?,?) AND status=1
                """, BigDecimal.class, shipped.get(0), shipped.get(1), shipped.get(2));
        assertThat(receivableLocal).isEqualByComparingTo(MoneyPolicy.local(new BigDecimal("100"), rate));
        // SQL 巡检: 已发完的订单行, 出货原币合计与订单行金额不一致的行数必须为 0。
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM sales_order_items item
                WHERE item.id=? AND item.shipped_qty >= item.qty
                  AND item.amount_original <> (SELECT SUM(line.amount_original)
                      FROM sales_shipment_items line JOIN sales_shipments doc ON doc.id=line.shipment_id
                      WHERE line.order_item_id=item.id AND doc.status=1 AND NOT line.is_deleted)
                """, Long.class, orderItem)).isZero();
        System.out.printf("[money-e2e] shipment.create logicalStatements=%d,%d,%d%n",
                createStatements[0], createStatements[1], createStatements[2]);
    }

    @Test
    void directAndOrderShipmentsDeriveTheSameLocalReceivableFromTheSameInput() {
        FullChainEndToEndTest.World w = fixture.seedWorld("money-direct-vs-order");
        UUID orderItem = producedOrderItem(w, "1");
        jdbc.update("UPDATE sales_order_items SET price=12.3456, discount=1, amount_original=12.3456 WHERE id=?", orderItem);
        jdbc.update("UPDATE sales_orders SET total_original=12.3456 WHERE id=(SELECT order_id FROM sales_order_items WHERE id=?)",
                orderItem);
        ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", w, "1");
        fixture.loginAs(w.superAdminUserId());
        jdbc.update("UPDATE currencies SET exchange_rate=7.123456 WHERE id=?", w.currencyId());

        ShipmentSaveRequest direct = invoke("directCustomerShipmentRequest", w, "CHARGED", "1");
        direct.getItems().getFirst().setPrice(new BigDecimal("12.3456"));
        UUID directId = shipments.create(direct).getId();
        shipments.confirmSales(directId, 0L);
        fixture.shipThroughWarehouse(directId);

        ShipmentSaveRequest ordered = invoke("shipmentRequest", w, orderItem, w.goodsA(), "1");
        ordered.setBillDate(BusinessTime.today());
        UUID orderedId = shipments.create(ordered).getId();
        fixture.shipThroughWarehouse(orderedId);

        BigDecimal expected = MoneyPolicy.local(new BigDecimal("12.3456"), new BigDecimal("7.123456"));
        for (UUID id : List.of(directId, orderedId)) {
            assertThat(jdbc.queryForObject("SELECT amount_original FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",
                    BigDecimal.class, id)).isEqualByComparingTo("12.3456");
            assertThat(jdbc.queryForObject("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",
                    BigDecimal.class, id)).as("直发与订货发货同一本币规则, 完整乘积不舍入").isEqualByComparingTo(expected);
        }
    }

    @Test
    void foreignReceiptDraftIsTheApprovedAmountAndAFullReturnClearsBothPayableBalances() {
        FullChainEndToEndTest.World w = fixture.seedWorld("money-receipt-return");
        fixture.loginAs(w.superAdminUserId());
        UUID orderItem = approvedPurchaseOrderItem(w, "3", "41.15226", "7.123456");

        UUID receiptId = purchaseReceipts.create(receiptRequest(w, orderItem, "3", "41.15226", "7.123456")).getId();
        var draft = purchaseReceipts.detail(receiptId).getItems().getFirst();
        BigDecimal original = MoneyPolicy.exactProduct(new BigDecimal("3"), new BigDecimal("41.15226"));
        BigDecimal local = MoneyPolicy.local(original, new BigDecimal("7.123456"));
        assertThat(draft.getAmountOriginal()).isEqualByComparingTo(original).isEqualByComparingTo("123.45678");
        assertThat(draft.getAmountLocal()).isEqualByComparingTo(local);
        purchaseReceipts.approve(receiptId);
        var approved = purchaseReceipts.detail(receiptId).getItems().getFirst();
        assertThat(approved.getAmountOriginal()).as("草稿值 = 审核后的权威值").isEqualByComparingTo(draft.getAmountOriginal());
        assertThat(approved.getAmountLocal()).isEqualByComparingTo(draft.getAmountLocal());
        ReflectionTestUtils.invokeMethod(fixture, "passAndStockPurchaseReceipt", w, receiptId, new BigDecimal("3"));

        var returned = new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();
        returned.setBillDate(BusinessTime.today());
        returned.setSupplierId(w.supplierId());
        returned.setWarehouseId(w.warehouseId());
        returned.setCurrencyId(w.currencyId());
        returned.setExchangeRate(new BigDecimal("7.123456"));
        returned.setTaxRate(BigDecimal.ZERO);
        returned.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "purchaseOrderSettlementMethodOf", orderItem));
        var line = new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();
        line.setGoodsId(w.goodsD());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("3"));
        line.setPrice(new BigDecimal("41.15226"));
        line.setOrderItemId(orderItem);
        line.setReceiptItemId(approved.getId());
        returned.setItems(List.of(line));
        UUID returnId = purchaseReturns.create(returned).getId();
        purchaseReturns.approve(returnId);

        var returnTotals = jdbc.queryForMap("SELECT total_original,total_local FROM purchase_returns WHERE id=?", returnId);
        assertThat((BigDecimal) returnTotals.get("total_original")).isEqualByComparingTo("123.45678");
        assertThat((BigDecimal) returnTotals.get("total_local")).isEqualByComparingTo(local);
        var payable = jdbc.queryForMap("""
                SELECT SUM(amount_original) AS original, SUM(amount_original_local) AS local
                FROM ar_ap_ledger WHERE direction='AP' AND status=1 AND source_doc_id IN (?,?)
                """, receiptId, returnId);
        assertThat((BigDecimal) payable.get("original")).as("收货应付原币与退货贷项相抵为 0").isZero();
        assertThat((BigDecimal) payable.get("local")).as("本币同样恰好为 0, 没有 4 位舍入尾差").isZero();
    }

    /**
     * 评审 blocker 用例(ADR-112): 1 箱 = 3 件、一箱 100 元的收货, 分别「先判 1 件不合格再判其余合格」与
     * 「先判 2 件合格再判其余不合格」。仓库放行价值、分批入库价值、财务不合格金额、退货可退额度同一口径:
     * 放行 + 不合格 = 收货金额, 可退额度 = 放行价值; 库级守卫(V446/V449 的 ROUND(.., 4))与同一公式逐位一致,
     * 分两批入库时库存价值切片也与之相同(事务能提交)。
     */
    @Test
    void iqcReleaseFailedAmountAndReturnableLimitSplitOneReceiptWithOneRuleInEitherOrder() {
        for (boolean failFirst : List.of(true, false)) {
            FullChainEndToEndTest.World w = fixture.seedWorld(failFirst ? "money-iqc-fail-first" : "money-iqc-pass-first");
            fixture.loginAs(w.superAdminUserId());
            UUID box = UUID.randomUUID();
            jdbc.update("insert into units(id,code,name) values (?,?,'box')", box, "MONEY-BOX-" + box);
            UUID orderItem = approvedPurchaseOrderItem(w, "1", "100", "1", box, "3");
            UUID receiptId = purchaseReceipts.create(receiptRequest(w, orderItem, "1", "100", "1", box, "3")).getId();
            purchaseReceipts.approve(receiptId);
            UUID inspection = jdbc.queryForObject(
                    "select id from procurement_inspection_items where receipt_type='PURCHASE' and receipt_id=?",
                    UUID.class, receiptId);
            var sample = ProductionJdbcMeasurement.begin();
            try {
                if (failFirst) {
                    dispose(receiptId, inspection, "FAIL", "1");
                    dispose(receiptId, inspection, "PASS", null);
                } else {
                    dispose(receiptId, inspection, "PASS", "2");
                    dispose(receiptId, inspection, "FAIL", null);
                }
            } finally {
                ProductionJdbcMeasurement.end();
            }
            fixture.loginAs(ReflectionTestUtils.invokeMethod(fixture, "createIqcWarehouseConfirmer", w,
                    "money-iqc-stock-" + receiptId));
            for (int batch = 1; batch <= 2; batch++) {
                com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest request =
                        ReflectionTestUtils.invokeMethod(fixture, "latestIqcStockInRequest", "PURCHASE", receiptId,
                                inspection, BigDecimal.ONE, "money-iqc-stock-" + batch + "-" + receiptId, "MONEY-IQC");
                iqcStockIn.confirm("PURCHASE", receiptId, request);
            }
            fixture.loginAs(w.superAdminUserId());

            BigDecimal released = jdbc.queryForObject("""
                    select released_amount_local from procurement_inspection_events
                    where inspection_item_id=? and action='PASS'
                    """, BigDecimal.class, inspection);
            var events = new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(
                    status -> com.uten.imp.common.finance.ProcurementIqcAmountSplit.events(em, inspection));
            BigDecimal failed = com.uten.imp.common.finance.ProcurementIqcAmountSplit.failedSlices(
                    new BigDecimal("100"), new BigDecimal("3"), events, BigDecimal.ONE);
            // 两种处置顺序切出的数一样: 放行 66.6667 + 不合格 33.3333 = 100。
            assertThat(released).isEqualByComparingTo("66.6667");
            assertThat(failed).isEqualByComparingTo("33.3333");
            assertThat(released.add(failed)).as("仓库放行 + 财务不合格 = 收货金额").isEqualByComparingTo("100");
            assertThat(jdbc.queryForObject("""
                    select sum(amount_local) from procurement_iqc_stock_in_batch_items where inspection_item_id=?
                    """, BigDecimal.class, inspection)).as("分两批入库, 末批取余, 合计 = 放行价值").isEqualByComparingTo(released);

            UUID receiptItem = jdbc.queryForObject("select id from purchase_receipt_items where receipt_id=?",
                    UUID.class, receiptId);
            var returnable = new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(
                    status -> com.uten.imp.common.finance.ProcurementReturnQualityPolicy.lockAndLimit(
                            em, "PURCHASE", receiptItem, BigDecimal.ONE, new BigDecimal("3"),
                            new BigDecimal("100"), new BigDecimal("100")));
            assertThat(returnable.amountOriginal()).as("可退额度 = 收货金额 − 不合格金额 = 放行价值")
                    .isEqualByComparingTo(released);
            assertThat(returnable.amountLocal()).isEqualByComparingTo(released);
            assertThat(failed.add(returnable.amountOriginal())).as("不合格贷项 + 合格件全退 恰好冲平应付")
                    .isEqualByComparingTo("100");
            System.out.printf("[money-e2e] iqc %s two dispositions logicalStatements=%d%n",
                    failFirst ? "fail-first" : "pass-first", sample.logicalStatements);
        }
    }

    private void dispose(UUID receiptId, UUID inspection, String action, String qty) {
        inspections.dispose("PURCHASE", receiptId, inspection,
                new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                        action, qty == null ? null : new BigDecimal(qty), "金额口径验收",
                        "money-iqc-" + action.toLowerCase() + "-" + receiptId));
    }

    @Test
    void threeTimesZeroPointOneAtSevenPointOneIsExactlyTwoPointOneThreeFromDraftToApproval() {
        FullChainEndToEndTest.World w = fixture.seedWorld("money-draft-213");
        fixture.loginAs(w.superAdminUserId());
        UUID orderItem = approvedPurchaseOrderItem(w, "3", "0.1", "7.1");
        UUID receiptId = purchaseReceipts.create(receiptRequest(w, orderItem, "3", "0.1", "7.1")).getId();
        var draft = purchaseReceipts.detail(receiptId);
        assertThat(draft.getItems().getFirst().getAmountLocal()).isEqualByComparingTo("2.13");
        assertThat(draft.getTotalLocal()).isEqualByComparingTo("2.13");
        assertThat(jdbc.queryForObject("SELECT amount_local::text FROM purchase_receipt_items WHERE receipt_id=?",
                String.class, receiptId)).isEqualTo("2.1300");
        purchaseReceipts.approve(receiptId);
        var approved = purchaseReceipts.detail(receiptId);
        assertThat(approved.getItems().getFirst().getAmountLocal()).isEqualByComparingTo("2.13");
        assertThat(approved.getTotalLocal()).isEqualByComparingTo(draft.getTotalLocal());
    }

    @Test
    void requestBodiesCarryingAmountFieldsAreRejected() throws Exception {
        FullChainEndToEndTest.World w = fixture.seedWorld("money-no-client-amounts");
        fixture.loginAs(w.superAdminUserId());
        var actor = SecurityContextHolder.getContext().getAuthentication();
        String withAmount = """
                {"billDate":"2026-09-23","clientId":"%s","warehouseId":"%s",
                 "items":[{"orderItemId":"%s","goodsId":"%s","qty":1,"amountOriginal":999999}]}
                """.formatted(w.clientId(), w.warehouseId(), UUID.randomUUID(), w.goodsA());
        var rejected = mockMvc.perform(post("/api/sales/shipments").contentType(MediaType.APPLICATION_JSON)
                .content(withAmount).with(authentication(actor))).andReturn().getResponse();
        assertThat(rejected.getStatus()).isEqualTo(400);
        assertThat(rejected.getContentAsString()).contains("MALFORMED_REQUEST");

        String receiptLocal = """
                {"billDate":"2026-09-23","supplierId":"%s","warehouseId":"%s",
                 "items":[{"goodsId":"%s","qty":1,"price":1,"amountLocal":7}]}
                """.formatted(w.supplierId(), w.warehouseId(), w.goodsD());
        assertThat(mockMvc.perform(post("/api/purchase/receipts").contentType(MediaType.APPLICATION_JSON)
                .content(receiptLocal).with(authentication(actor))).andReturn().getResponse().getStatus()).isEqualTo(400);

        String withoutAmount = withAmount.replace(",\"amountOriginal\":999999", "");
        var parsed = mockMvc.perform(post("/api/sales/shipments").contentType(MediaType.APPLICATION_JSON)
                .content(withoutAmount).with(authentication(actor))).andReturn().getResponse();
        assertThat(parsed.getContentAsString()).as("不带金额的同一请求能正常解析(业务上因订单行不存在被拒)")
                .doesNotContain("MALFORMED_REQUEST");
    }

    private UUID producedOrderItem(FullChainEndToEndTest.World w, String qty) {
        Object production = ReflectionTestUtils.invokeMethod(fixture, "produceFinishedFromOpeningInputs",
                w, w.goodsA(), qty, qty);
        return ReflectionTestUtils.invokeMethod(production, "orderItemId");
    }

    /** 采购申请 → 订货(指定单价与汇率) → 财务批准, 返回订货明细。 */
    private UUID approvedPurchaseOrderItem(FullChainEndToEndTest.World w, String qty, String price, String rate) {
        return approvedPurchaseOrderItem(w, qty, price, rate, w.unitId(), "1");
    }

    private UUID approvedPurchaseOrderItem(FullChainEndToEndTest.World w, String qty, String price, String rate,
                                           UUID unitId, String unitRate) {
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(w.warehouseId());
        request.setDepartmentId(w.departmentId());
        request.setApplicantId(w.employeeId());
        var requested = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(w.goodsD());
        requested.setUnitId(unitId);
        requested.setUnitRate(new BigDecimal(unitRate));
        requested.setQty(new BigDecimal(qty));
        request.setItems(List.of(requested));
        var savedRequest = purchaseRequests.create(request);
        purchaseRequests.approve(savedRequest.getId());
        var orderRequest = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderRequest.setBillDate(BusinessTime.today());
        orderRequest.setSupplierId(w.supplierId());
        orderRequest.setWarehouseId(w.warehouseId());
        orderRequest.setCurrencyId(w.currencyId());
        orderRequest.setExchangeRate(new BigDecimal(rate));
        orderRequest.setTaxRate(BigDecimal.ZERO);
        orderRequest.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        var ordered = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        ordered.setGoodsId(w.goodsD());
        ordered.setUnitId(unitId);
        ordered.setUnitRate(new BigDecimal(unitRate));
        ordered.setQty(new BigDecimal(qty));
        ordered.setPrice(new BigDecimal(price));
        ordered.setRequestItemId(savedRequest.getItems().getFirst().getId());
        orderRequest.setItems(List.of(ordered));
        var order = purchaseOrders.create(orderRequest);
        assertThat(order.getItems().getFirst().getAmountLocal())
                .isEqualByComparingTo(MoneyPolicy.local(MoneyPolicy.exactProduct(new BigDecimal(qty), new BigDecimal(price)),
                        new BigDecimal(rate)));
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("PURCHASE", order.getId());
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("PURCHASE", order.getId());
        fixture.loginAs(w.superAdminUserId());
        return order.getItems().getFirst().getId();
    }

    private com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest receiptRequest(
            FullChainEndToEndTest.World w, UUID orderItem, String qty, String price, String rate) {
        return receiptRequest(w, orderItem, qty, price, rate, w.unitId(), "1");
    }

    private com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest receiptRequest(
            FullChainEndToEndTest.World w, UUID orderItem, String qty, String price, String rate,
            UUID unitId, String unitRate) {
        var request = new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(new BigDecimal(rate));
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "purchaseOrderSettlementMethodOf", orderItem));
        var line = new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        line.setGoodsId(w.goodsD());
        line.setOrderItemId(orderItem);
        line.setUnitId(unitId);
        line.setUnitRate(new BigDecimal(unitRate));
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal(price));
        request.setItems(List.of(line));
        return request;
    }

    @SuppressWarnings("unchecked")
    private <T> T invoke(String method, Object... arguments) {
        return (T) ReflectionTestUtils.invokeMethod(fixture, method, arguments);
    }
}
