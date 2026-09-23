package com.uten.imp.businesschain;

import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmEntry;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmResult;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
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
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.businesschain.WarehouseIqcScaleFixture.RECEIPT_QTY;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 质检三个热点命令的触发器调用剖面(ADR-106，审计 perf-warehouse-quality-06 的验收口径)。
 *
 * <p>一张 7 行采购收货单与一张 7 行委外收货单(每行不同货品，全部走真实服务准备)：
 * 采购单「提交报告」(decide-batch，每行部分合格部分不合格)、委外单整单合格(pass-batch)、
 * 两单 14 行合格数一次仓库确认入库(IQC confirm)。每个命令是一笔事务，统计该事务里每个触发器函数
 * 被调了几次、延迟校验耗时与提交耗时；把总数钉在预算内，谁把无关更新又接回校验上要先在这里红。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@Import(ProductionJdbcMeasurement.Configuration.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = IqcTriggerProfileEndToEndTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class IqcTriggerProfileEndToEndTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();
    private static final int LINES = 7;
    private static final BigDecimal PASSED = new BigDecimal("0.75");
    private static final BigDecimal FAILED = new BigDecimal("0.50");

    /**
     * 预算(触发器函数调用总数，含审计触发器 fn_audit / fn_audit_classify_row)。2026-09-23 同一剖面实测
     * (ADR-106 §三)：提交报告 V645 1023 次 → V652 808 次，整单合格 507 → 383，两单 14 行确认入库 2729 → 2191。
     * 预算在 V652 实测值上留约 8% 余量。
     */
    private static final long DECIDE_BATCH_BUDGET = 870;
    private static final long PASS_BATCH_BUDGET = 415;
    private static final long CONFIRM_BUDGET = 2360;

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url", DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username", DATABASE::getUsername);
        properties.add("spring.datasource.password", DATABASE::getPassword);
        properties.add("uten.jwt.secret", () -> SECRET);
        properties.add("uten.crypto.pgp-master-key", () -> SECRET);
        properties.add("uten.crypto.hmac-key", () -> SECRET);
        properties.add("uten.bootstrap.admin-login", () -> "iqc-trigger-profile-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }

    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired PlatformTransactionManager manager;

    @AfterEach
    void cleanup() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test
    void qualityDecisionsAndStockInKeepTriggerCallsInsideBudget() {
        String tag = "iqc-tp-" + UUID.randomUUID().toString().substring(0, 8);
        var scenario = new WarehouseIqcMultiLineFixture(beans, jdbc).prepare(2, LINES, tag);
        var actor = new FullChainEndToEndTest();
        beans.autowireBean(actor);
        var purchase = scenario.receipts().stream().filter(row -> row.type().equals("PURCHASE")).toList();
        var subcontract = scenario.receipts().stream().filter(row -> row.type().equals("SUBCONTRACT")).toList();
        assertEquals(LINES, purchase.size());
        assertEquals(LINES, subcontract.size());

        actor.loginAs(scenario.world().superAdminUserId());
        var decide = TriggerCallProfile.measure(jdbc, manager, () -> inspections.decideBatch("PURCHASE",
                purchase.getFirst().id(), new BatchInspectionDecideRequest(purchase.stream()
                        .map(row -> new BatchInspectionDecideRequest.Item(row.inspectionId(), RECEIPT_QTY, PASSED,
                                FAILED, "tp-decide-" + row.inspectionId()))
                        .toList(), "剖面用批量品质报告")));
        System.out.println(decide.line("decide-batch", LINES));

        var pass = TriggerCallProfile.measure(jdbc, manager, () -> inspections.passBatch("SUBCONTRACT",
                subcontract.getFirst().id(), new BatchInspectionPassRequest(subcontract.stream()
                        .map(row -> new BatchInspectionPassRequest.Item(row.inspectionId(), RECEIPT_QTY,
                                "tp-pass-" + row.inspectionId()))
                        .toList(), null)));
        System.out.println(pass.line("pass-batch", LINES));

        Map<UUID, List<ConfirmItem>> items = new LinkedHashMap<>();
        Map<UUID, String> types = new LinkedHashMap<>();
        for (var row : scenario.receipts()) {
            UUID passEvent = jdbc.queryForObject(
                    "SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",
                    UUID.class, row.inspectionId());
            BigDecimal qty = row.type().equals("PURCHASE") ? PASSED : RECEIPT_QTY;
            items.computeIfAbsent(row.id(), ignored -> new ArrayList<>()).add(new ConfirmItem(passEvent, qty, qty, "TP-A01"));
            types.put(row.id(), row.type());
        }
        List<BatchConfirmEntry> entries = new ArrayList<>();
        items.forEach((receipt, lines) -> entries.add(new BatchConfirmEntry(types.get(receipt), receipt,
                "tp-store-" + receipt, List.copyOf(lines))));
        actor.loginAs(scenario.confirmer());
        BatchConfirmResult[] confirmed = new BatchConfirmResult[1];
        var confirm = TriggerCallProfile.measure(jdbc, manager,
                () -> confirmed[0] = stockIn.batchConfirm(new BatchConfirmRequest(List.copyOf(entries))));
        System.out.println(confirm.line("iqc-confirm", 2 * LINES));
        perRow("iqc-confirm", confirm, 2 * LINES);

        assertEquals(2, confirmed[0].confirmedReceipts());
        assertEquals(2 * LINES, confirmed[0].confirmedItemCount());
        for (var profile : List.of(decide, pass, confirm)) {
            assertEquals(1, profile.sample().commits, "每个命令必须是一笔事务，剖面才有意义");
            assertEquals(0, profile.calls("fn_lock_goods_quantity_unit_from_references"),
                    "货品单位锁已改为改单位时按需检查，写业务行不再走语句级触发器");
        }
        assertTrue(decide.triggerCalls() <= DECIDE_BATCH_BUDGET, decide.line("decide-batch", LINES));
        assertTrue(pass.triggerCalls() <= PASS_BATCH_BUDGET, pass.line("pass-batch", LINES));
        assertTrue(confirm.triggerCalls() <= CONFIRM_BUDGET, confirm.line("iqc-confirm", 2 * LINES));
    }

    /** 每个延迟校验函数平均每行被调几次(审计验收口径：N 行入库 ≤ N × 阶段数)。 */
    private static void perRow(String phase, TriggerCallProfile.Result profile, int rows) {
        StringBuilder line = new StringBuilder("TRIGGER-PER-ROW phase=" + phase + " rows=" + rows);
        profile.calls().entrySet().stream()
                .filter(entry -> TriggerCallProfile.isCheck(entry.getKey()))
                .sorted((a, b) -> Long.compare(b.getValue(), a.getValue()))
                .forEach(entry -> line.append(' ').append(entry.getKey()).append('=')
                        .append(String.format(java.util.Locale.ROOT, "%.2f", entry.getValue() / (double) rows)));
        System.out.println(line);
    }
}
