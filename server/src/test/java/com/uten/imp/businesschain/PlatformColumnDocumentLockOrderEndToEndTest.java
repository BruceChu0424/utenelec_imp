package com.uten.imp.businesschain;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.BeanWrapperImpl;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import com.uten.imp.support.MigratedSchemaBaseline;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

/** Real saves preserve conflicting business lock order and compatible period-close foreign keys. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.workshop-material.auto-close.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = PlatformColumnDocumentLockOrderEndToEndTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class PlatformColumnDocumentLockOrderEndToEndTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) throws Exception {
        database = MigratedSchemaBaseline.openDatabase("document_lock");
        properties.add("spring.datasource.url", database::getJdbcUrl);
        properties.add("spring.datasource.username", database::getUsername);
        properties.add("spring.datasource.password", database::getPassword);
        properties.add("uten.jwt.secret", () -> SECRET);
        properties.add("uten.crypto.pgp-master-key", () -> SECRET);
        properties.add("uten.crypto.hmac-key", () -> SECRET);
        properties.add("uten.bootstrap.admin-login", () -> "document-lock-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) throws Exception { if (database != null) database.close(); }
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired PlatformTransactionManager transactions;
    @Autowired FulfillmentMutationLocks locks;
    @Autowired com.uten.imp.common.concurrency.ProcurementMutationLocks procurementLocks;
    @Autowired PurchaseReceiptService receipts;
    @Autowired com.uten.imp.features.purchase.request.PurchaseRequestService requests;
    @Autowired com.uten.imp.features.purchase.order.PurchaseOrderService orders;
    @Autowired com.uten.imp.features.production.dailyreport.ProductionDailyReportService reports;
    @Autowired com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService closes;
    @Autowired com.fasterxml.jackson.databind.ObjectMapper json;
    @org.springframework.test.context.bean.override.mockito.MockitoSpyBean
    org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate namedSql;
    @Autowired List<com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter> adapters;
    private FullChainEndToEndTest harness;

    @BeforeEach void harness() { harness = new FullChainEndToEndTest(); beans.autowireBean(harness); }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test
    void purchaseReceiptEditAndDeleteUseInventoryBeforeHeader() throws Exception {
        var world = harness.seedWorld("receipt-field-prefix");
        harness.loginAs(world.superAdminUserId());
        UUID receipt = receipts.create(request(world, world.goodsB(), "3")).getId();
        ReceiptSaveRequest replacement = request(world, world.goodsE(), "4");
        CountDownLatch held = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger waiterPid = new AtomicInteger();
        var workers = Executors.newFixedThreadPool(2);
        try {
            var deleting = workers.submit(() -> {
                harness.loginAs(world.superAdminUserId());
                try {
                    new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                        procurementLocks.receipt("PURCHASE", receipt);
                        held.countDown();
                        await(release);
                        receipts.delete(receipt);
                    });
                } finally { SecurityContextHolder.clearContext(); }
            });
            assertTrue(held.await(20, TimeUnit.SECONDS));
            var editing = workers.submit(() -> {
                harness.loginAs(world.superAdminUserId());
                try {
                    return assertThrows(ApiException.class, () -> new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                        waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                        receipts.update(receipt, replacement);
                    }));
                } finally { SecurityContextHolder.clearContext(); }
            });
            awaitInventoryWait(waiterPid);
            release.countDown();
            deleting.get(20, TimeUnit.SECONDS);
            assertEquals(ErrorCode.NOT_FOUND, editing.get(20, TimeUnit.SECONDS).getCode());
        } finally {
            release.countDown(); workers.shutdownNow();
            assertTrue(workers.awaitTermination(25, TimeUnit.SECONDS));
        }
        assertEquals(Boolean.TRUE, jdbc.queryForObject("SELECT is_deleted FROM purchase_receipts WHERE id=?", Boolean.class, receipt));
        assertEquals(0, jdbc.queryForObject("SELECT qty FROM purchase_receipt_items WHERE receipt_id=?", BigDecimal.class, receipt).compareTo(new BigDecimal("3")));
        assertEquals(world.goodsB(), jdbc.queryForObject("SELECT goods_id FROM purchase_receipt_items WHERE receipt_id=?", UUID.class, receipt));
    }

    @Test
    void purchaseReceiptIncomingGoodsLockAlsoPrecedesHeader() throws Exception {
        var world = harness.seedWorld("receipt-field-new-goods");
        harness.loginAs(world.superAdminUserId());
        UUID receipt = receipts.create(request(world, world.goodsB(), "3")).getId();
        ReceiptSaveRequest replacement = request(world, world.goodsE(), "4");
        CountDownLatch held = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger waiterPid = new AtomicInteger();
        var workers = Executors.newFixedThreadPool(2);
        try {
            var holder = workers.submit(() -> new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                lockGoods(world.goodsE()); held.countDown(); await(release);
            }));
            assertTrue(held.await(20, TimeUnit.SECONDS));
            var editing = workers.submit(() -> {
                harness.loginAs(world.superAdminUserId());
                try {
                    return new TransactionTemplate(transactions).execute(tx -> {
                        waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                        return receipts.update(receipt, replacement);
                    });
                } finally { SecurityContextHolder.clearContext(); }
            });
            awaitInventoryWait(waiterPid);
            new TransactionTemplate(transactions).executeWithoutResult(tx -> assertEquals(receipt,
                    jdbc.queryForObject("SELECT id FROM purchase_receipts WHERE id=? FOR UPDATE NOWAIT", UUID.class, receipt)));
            release.countDown(); holder.get(20, TimeUnit.SECONDS);
            assertEquals(receipt, editing.get(20, TimeUnit.SECONDS).getId());
        } finally {
            release.countDown(); workers.shutdownNow();
            assertTrue(workers.awaitTermination(25, TimeUnit.SECONDS));
        }
        assertEquals(0, jdbc.queryForObject("SELECT qty FROM purchase_receipt_items WHERE receipt_id=?", BigDecimal.class, receipt).compareTo(new BigDecimal("4")));
        assertEquals(world.goodsE(), jdbc.queryForObject("SELECT goods_id FROM purchase_receipt_items WHERE receipt_id=?", UUID.class, receipt));
        assertEquals(0, jdbc.queryForObject("SELECT status FROM purchase_receipts WHERE id=?", Integer.class, receipt));
    }

    @ParameterizedTest(name = "{0} incoming goods participate in the registered business prefix")
    @MethodSource("documentRequests")
    void everyAffectedDomainAcquiresIncomingGoodsBeforeLookingUpHeader(
            String scope, Class<?> requestType, Class<?> lineType) throws Exception {
        var world = harness.seedWorld("new-goods-" + scope);
        Object request = requestType.getConstructor().newInstance();
        var line = new BeanWrapperImpl(lineType.getConstructor().newInstance());
        line.setPropertyValue("goodsId", world.goodsE());
        line.setPropertyValue("qty", new BigDecimal("4"));
        var header = new BeanWrapperImpl(request);
        header.setPropertyValue("items", List.of(line.getWrappedInstance()));
        if (header.isWritableProperty("warehouseId")) header.setPropertyValue("warehouseId", world.warehouseId());
        var adapter = adapters.stream().filter(value -> value.scope().equals(scope)).findFirst().orElseThrow();
        CountDownLatch held = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger waiterPid = new AtomicInteger();
        var workers = Executors.newFixedThreadPool(2);
        try {
            var holder = workers.submit(() -> new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                lockGoods(world.goodsE()); held.countDown(); await(release);
            }));
            assertTrue(held.await(20, TimeUnit.SECONDS));
            var missing = workers.submit(() -> {
                harness.loginAs(world.superAdminUserId());
                try {
                    return assertThrows(ApiException.class, () -> new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                        waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                        adapter.lockDocumentSave(UUID.randomUUID(), request);
                    }));
                } finally { SecurityContextHolder.clearContext(); }
            });
            // Even an absent header must be looked up after the requested inventory prefix.
            // This exercises every real Spring registration and domain discovery, not a mock callback.
            awaitInventoryWait(waiterPid);
            release.countDown(); holder.get(20, TimeUnit.SECONDS);
            assertEquals(ErrorCode.NOT_FOUND, missing.get(20, TimeUnit.SECONDS).getCode());
        } finally {
            release.countDown(); workers.shutdownNow();
            assertTrue(workers.awaitTermination(25, TimeUnit.SECONDS));
        }
    }

    static Stream<Arguments> documentRequests() {
        return Stream.of(
                Arguments.of("production_plan_item", com.uten.imp.features.production.plan.dto.PlanSaveRequest.class,
                        com.uten.imp.features.production.plan.dto.PlanItemLine.class),
                Arguments.of("purchase_receipt_item", ReceiptSaveRequest.class, ReceiptItemLine.class),
                Arguments.of("purchase_return_item", com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest.class,
                        com.uten.imp.features.purchase.ret.dto.ReturnItemLine.class),
                Arguments.of("subcontract_receipt_item", com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest.class,
                        com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine.class),
                Arguments.of("subcontract_return_item", com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest.class,
                        com.uten.imp.features.subcontract.ret.dto.ReturnItemLine.class),
                Arguments.of("subcontract_material_issue_item", com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest.class,
                        com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine.class),
                Arguments.of("subcontract_material_return_item", com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest.class,
                        com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine.class));
    }

    @Test
    void invalidSaveShapeAndForeignLineRemainConflictsWithoutBusinessWrites() {
        var world = harness.seedWorld("receipt-field-invalid");
        harness.loginAs(world.superAdminUserId());
        var original = receipts.create(request(world, world.goodsB(), "3"));
        UUID receipt = original.getId(), originalLine = original.getItems().getFirst().getId();
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class, () -> receipts.update(receipt, null)).getCode());
        var absentItems = request(world, world.goodsE(), "4");
        absentItems.setItems(null);
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class, () -> receipts.update(receipt, absentItems)).getCode());
        var foreignLine = request(world, world.goodsE(), "4");
        foreignLine.getItems().getFirst().setPlatformFields(
                new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(UUID.randomUUID(), 0, List.of()));
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class, () -> receipts.update(receipt, foreignLine)).getCode());
        assertEquals(originalLine, jdbc.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=?", UUID.class, receipt));
        assertEquals(world.goodsB(), jdbc.queryForObject("SELECT goods_id FROM purchase_receipt_items WHERE receipt_id=?", UUID.class, receipt));
        assertEquals(0, jdbc.queryForObject("SELECT qty FROM purchase_receipt_items WHERE receipt_id=?", BigDecimal.class, receipt).compareTo(new BigDecimal("3")));
        assertEquals(0, jdbc.queryForObject("SELECT status FROM purchase_receipts WHERE id=?", Integer.class, receipt));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?", Integer.class, receipt));
    }

    @Test
    void incomingPurchaseOrderContributesItsGoodsEvenWhenRequestDoesNotSupplyThem() throws Exception {
        var world = harness.seedWorld("receipt-field-order-source");
        harness.loginAs(world.superAdminUserId());
        UUID orderItem = requestedOrder(world);
        var incoming = request(world, null, "4");
        incoming.getItems().getFirst().setOrderItemId(orderItem);
        CountDownLatch held = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger waiterPid = new AtomicInteger();
        var workers = Executors.newFixedThreadPool(2);
        try {
            var holder = workers.submit(() -> new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                lockGoods(world.goodsE()); held.countDown(); await(release);
            }));
            assertTrue(held.await(20, TimeUnit.SECONDS));
            var missing = workers.submit(() -> {
                harness.loginAs(world.superAdminUserId());
                try {
                    return assertThrows(ApiException.class, () -> new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                        waiterPid.set(jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                        // Test discovery only: ordinary HTTP validation still rejects a missing goodsId.
                        receipts.lockPlatformColumnSave(UUID.randomUUID(), incoming);
                    }));
                } finally { SecurityContextHolder.clearContext(); }
            });
            awaitInventoryWait(waiterPid);
            release.countDown(); holder.get(20, TimeUnit.SECONDS);
            assertEquals(ErrorCode.NOT_FOUND, missing.get(20, TimeUnit.SECONDS).getCode());
        } finally {
            release.countDown(); workers.shutdownNow();
            assertTrue(workers.awaitTermination(25, TimeUnit.SECONDS));
        }
        assertEquals(0, jdbc.queryForObject("SELECT received_qty FROM purchase_order_items WHERE id=?", BigDecimal.class, orderItem).signum());
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM purchase_receipt_items WHERE order_item_id=?", Integer.class, orderItem));
    }

    private UUID requestedOrder(FullChainEndToEndTest.World world) {
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setWarehouseId(world.warehouseId());
        request.setDepartmentId(world.departmentId()); request.setApplicantId(world.employeeId());
        var requested = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(world.goodsE()); requested.setUnitId(world.unitId()); requested.setUnitRate(BigDecimal.ONE);
        requested.setQty(new BigDecimal("10")); request.setItems(List.of(requested));
        var source = requests.create(request); requests.approve(source.getId());
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today()); order.setSupplierId(world.supplierId()); order.setWarehouseId(world.warehouseId());
        order.setCurrencyId(world.currencyId()); order.setExchangeRate(BigDecimal.ONE); order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(jdbc.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' ORDER BY id LIMIT 1", UUID.class));
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(world.goodsE()); line.setUnitId(world.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("10")); line.setPrice(new BigDecimal("5"));
        line.setRequestItemId(source.getItems().getFirst().getId()); order.setItems(List.of(line));
        return orders.create(order).getItems().getFirst().getId();
    }

    @Test
    void closingPeriodAndOldApprovedReportEditDoNotInvertForeignKeyHeaderLocks() throws Exception {
        var bench = countedReport("field-period-cycle");
        var request = reportRequest(bench);
        long originalVersion = request.getExpectedVersion();
        CountDownLatch periodHeld = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger closePid = new AtomicInteger();
        // Control scheduling immediately after the real SELECT acquires the period lock.
        // The waiting SQL and a third connection's KEY SHARE probe establish the actual
        // runtime lock relationship instead of inferring it from JPA lock-mode names.
        org.mockito.Mockito.doAnswer(invocation -> {
            Object result = invocation.callRealMethod();
            String sql = invocation.getArgument(0);
            java.util.Map<?, ?> parameters = invocation.getArgument(1);
            if (sql.contains("FROM workshop_material_periods") && sql.contains("FOR UPDATE SKIP LOCKED")
                    && bench.firstPeriod.equals(parameters.get("id"))) {
                closePid.set(jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                periodHeld.countDown(); await(release);
            }
            return result;
        }).when(namedSql).query(org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.<String, Object>anyMap(),
                org.mockito.ArgumentMatchers.<org.springframework.jdbc.core.RowMapper<Object>>any());
        var workers = Executors.newFixedThreadPool(2);
        try {
            var closing = workers.submit(() -> {
                bench.login();
                try {
                    return closes.attempt(bench.firstPeriod,
                            com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind.AFTER_COUNT, bench.admin);
                } finally { SecurityContextHolder.clearContext(); }
            });
            assertTrue(periodHeld.await(20, TimeUnit.SECONDS));
            AtomicInteger editPid = new AtomicInteger();
            var editing = workers.submit(() -> {
                bench.login();
                try {
                    return assertThrows(ApiException.class, () -> new TransactionTemplate(transactions).executeWithoutResult(tx -> {
                        editPid.set(jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                        reports.update(bench.report, request);
                    }));
                } finally { SecurityContextHolder.clearContext(); }
            });
            awaitBlockedBy(editPid, closePid.get());
            assertTrue(jdbc.queryForObject("SELECT query FROM pg_stat_activity WHERE pid=?", String.class, editPid.get())
                    .contains("workshop_material_periods"), "the save must actually wait for the period, not a previously locked report row");
            boolean headerKeyShareAvailable = canTakeReportKeyShare(bench.report);
            System.out.println("REPORT_SAVE_LOCK_PROBE waiterIsPeriod=true; headerKeyShareAvailable=" + headerKeyShareAvailable);
            release.countDown();
            assertEquals(com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.Result.CLOSED,
                    closing.get(40, TimeUnit.SECONDS));
            ApiException rejected = editing.get(40, TimeUnit.SECONDS);
            assertEquals(ErrorCode.CONFLICT, rejected.getCode());
            assertTrue(rejected.getMessage().contains("已经结算"));
            assertTrue(headerKeyShareAvailable, "the waiting save must not block the close's report foreign key");
        } finally {
            release.countDown();
            workers.shutdownNow(); assertTrue(workers.awaitTermination(45, TimeUnit.SECONDS));
        }
        assertEquals("CLOSED", jdbc.queryForObject("SELECT status FROM workshop_material_periods WHERE id=?", String.class, bench.firstPeriod));
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM workshop_material_period_closes WHERE period_id=?", Integer.class, bench.firstPeriod));
        assertTrue(jdbc.queryForObject("SELECT count(*) FROM workshop_material_close_theory_lines WHERE report_id=?", Integer.class, bench.report) > 0);
        assertEquals(1, jdbc.queryForObject("SELECT status FROM production_daily_reports WHERE id=?", Integer.class, bench.report));
        assertEquals(originalVersion, jdbc.queryForObject("SELECT row_version FROM production_daily_reports WHERE id=?", Long.class, bench.report));
        assertEquals(0, jdbc.queryForObject("SELECT sum(qty) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted", BigDecimal.class, bench.report).compareTo(new BigDecimal("5")));
    }

    @Test
    void staleReportRouteIsRejectedBeforeWaitingForItsPeriodWithoutWrites() throws Exception {
        var bench = countedReport("field-period-stale-route");
        var request = reportRequest(bench);
        var line = json.readValue("{\"destination\":\"WORKSHOP\"}",
                com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine.class);
        line.setGoodsId(bench.world.goodsA()); line.setQty(new BigDecimal("5")); line.setExecutionSegmentId(bench.segment);
        request.setItems(List.of(line));
        var workers = Executors.newSingleThreadExecutor();
        try (var gate = database.openConnection()) {
            gate.setAutoCommit(false);
            try (var statement = gate.prepareStatement("SELECT id FROM workshop_material_periods WHERE id=? FOR UPDATE")) {
                statement.setObject(1, bench.firstPeriod); statement.executeQuery().close();
            }
            var rejected = workers.submit(() -> {
                bench.login();
                try { return assertThrows(ApiException.class, () -> reports.update(bench.report, request)); }
                finally { SecurityContextHolder.clearContext(); }
            });
            assertEquals(ErrorCode.MALFORMED_REQUEST, rejected.get(5, TimeUnit.SECONDS).getCode());
            gate.rollback();
        } finally {
            workers.shutdownNow(); assertTrue(workers.awaitTermination(15, TimeUnit.SECONDS));
        }
        assertEquals("COUNTED", jdbc.queryForObject("SELECT status FROM workshop_material_periods WHERE id=?", String.class, bench.firstPeriod));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM workshop_material_period_closes WHERE period_id=?", Integer.class, bench.firstPeriod));
        assertEquals(request.getExpectedVersion(), jdbc.queryForObject("SELECT row_version FROM production_daily_reports WHERE id=?", Long.class, bench.report));
        assertEquals(1, jdbc.queryForObject("SELECT status FROM production_daily_reports WHERE id=?", Integer.class, bench.report));
    }

    private WorkshopMaterialClosePostgresTest.CloseBench countedReport(String tag) {
        var bench = WorkshopMaterialClosePostgresTest.CloseBench.create(beans, tag);
        UUID material = bench.granule("锁序回归颗粒", "OWN");
        bench.edge(bench.world.goodsA(), material, "0.2");
        bench.stockIn(material, "10", "10");
        bench.confirmInboundAndDrain();
        bench.enable(List.of()); bench.issue(material, "3", null);
        InventoryValueWorkTestSupport.drain(bench.valueWork, jdbc,
                List.of(bench.world.goodsA(), bench.world.goodsB(), bench.world.goodsE(), material));
        UUID count = bench.startCount(bench.firstPeriod, BusinessTime.today().minusDays(1));
        bench.weighed(count, "own", material, "1.8");
        assertEquals("COUNTED", bench.submit(count).status());
        return bench;
    }

    private com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest reportRequest(
            WorkshopMaterialClosePostgresTest.CloseBench bench) {
        var request = new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        request.setBillDate(jdbc.queryForObject("SELECT bill_date FROM production_daily_reports WHERE id=?", java.time.LocalDate.class, bench.report));
        request.setExpectedVersion(jdbc.queryForObject("SELECT row_version FROM production_daily_reports WHERE id=?", Long.class, bench.report));
        var line = new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();
        line.setGoodsId(bench.world.goodsA()); line.setQty(new BigDecimal("5")); line.setExecutionSegmentId(bench.segment);
        line.setPlanItemId(bench.planItem); line.setSalesOrderItemId(bench.orderItem); request.setItems(List.of(line));
        return request;
    }

    private void awaitBlockedBy(AtomicInteger waiter, int holder) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(12);
        while (System.nanoTime() < deadline) {
            if (waiter.get() != 0 && Boolean.TRUE.equals(jdbc.queryForObject(
                    "SELECT ?=ANY(pg_blocking_pids(?))", Boolean.class, holder, waiter.get()))) return;
            Thread.sleep(20);
        }
        throw new AssertionError("the actual report save did not queue behind the closing period");
    }

    private boolean canTakeReportKeyShare(UUID report) throws Exception {
        try (var connection = database.openConnection()) {
            connection.setAutoCommit(false);
            try (var query = connection.prepareStatement("SELECT id FROM production_daily_reports WHERE id=? FOR KEY SHARE NOWAIT")) {
                query.setObject(1, report);
                try (var rows = query.executeQuery()) { assertTrue(rows.next()); }
                return true;
            } catch (java.sql.SQLException failure) {
                if ("55P03".equals(failure.getSQLState())) return false;
                throw failure;
            } finally { connection.rollback(); }
        }
    }

    private void lockGoods(UUID goods) {
        locks.acquire(() -> FulfillmentMutationLockPlan.declared(Set.of(), Set.of(new InventoryDimension(goods, null)), Set.of())).verifyUnchanged();
    }

    private void awaitInventoryWait(AtomicInteger pid) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(12);
        while (System.nanoTime() < deadline) {
            if (pid.get() != 0 && Boolean.TRUE.equals(jdbc.queryForObject(
                    "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=? AND locktype='advisory' AND NOT granted)", Boolean.class, pid.get()))) return;
            Thread.sleep(20);
        }
        fail("the actual save must wait on the complete inventory prefix");
    }

    private static void await(CountDownLatch latch) {
        try { if (!latch.await(20, TimeUnit.SECONDS)) throw new AssertionError("prefix holder timeout"); }
        catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new AssertionError(failure); }
    }

    private static ReceiptSaveRequest request(FullChainEndToEndTest.World world, UUID goods, String quantity) {
        var request = new ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(world.supplierId());
        request.setWarehouseId(world.warehouseId()); request.setCurrencyId(world.currencyId());
        request.setExchangeRate(BigDecimal.ONE); request.setTaxRate(BigDecimal.ZERO);
        var line = new ReceiptItemLine();
        line.setGoodsId(goods); line.setUnitId(world.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity)); line.setPrice(new BigDecimal("5"));
        request.setItems(List.of(line));
        return request;
    }
}
