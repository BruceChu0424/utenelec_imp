package com.uten.imp.businesschain;

import com.uten.imp.businesschain.WorkshopMaterialClosePostgresTest.CloseBench;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.Result;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind;
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

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.businesschain.WorkshopMaterialClosePostgresTest.money;
import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 §7.5 附件8 换源 (包 S3): 塑料耗用明细改读车间内料仓的结算结果, 列名列序保持会计模板原样并在末尾加
 * "其它耗用、期间、内料仓"; 按月查询列出期末日落在该月的已结算各期; "安装挑选不良"第一期恒为 0 并在表头注明;
 * 附件 8-1/8-2/8-3 分别取内料仓发料、退回流水与已结算的理论明细。
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
class PlasticUsageAttachmentPostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired WorkshopMaterialCloseService closes;
    @Autowired FinanceCostService finance;

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void attachmentEightReadsTheClosedPeriodsWithTheTemplateColumnsInOrder() {
        // 一期: 发 3 公斤、退回 0.5、盘剩 1.3 → 实际 1.2; 报工 5 件 x 0.2 公斤 → 理论 1.0
        CloseBench bench = CloseBench.create(beans, "plastic");
        UUID granule = bench.granule("塑料颗粒", "OWN");
        bench.edge(bench.world.goodsA(), granule, "0.2");
        bench.stockIn(granule, "10", "10");
        bench.enable(List.of());
        bench.issue(granule, "3", null);
        bench.returned(granule, "0.5");
        LocalDate cutoff = BusinessTime.today().minusDays(1);
        UUID count = bench.startCount(bench.firstPeriod, cutoff);
        bench.weighed(count, "granule", granule, "1.3");
        bench.submit(count);
        assertEquals(Result.CLOSED, closes.attempt(bench.firstPeriod, TriggerKind.AFTER_COUNT, bench.admin));
        String code = db.queryForObject("SELECT code FROM goods WHERE id = ?", String.class, granule);
        String binName = db.queryForObject("SELECT name FROM warehouses WHERE id = ?", String.class, bench.bin);

        LocalDate monthStart = cutoff.withDayOfMonth(1);
        LocalDate monthEnd = cutoff.withDayOfMonth(cutoff.lengthOfMonth());
        ReportTableResponse table = finance.plasticUsage(code, monthStart, monthEnd, 1, 50);
        assertEquals(List.of("goodsCode", "goodsName", "prevBalance", "drawQty", "returnQty", "rejectQty",
                        "finishedWeight", "bookBalance", "checkQty", "diff", "usageRatio",
                        "otherIssueQty", "periodLabel", "binName"),
                table.columns().stream().map(ReportColumn::key).toList(), "原 11 列顺序不变, 新列在末尾");
        assertEquals(List.of("材料编码", "材料名称", "上月结存", "本月仓库领用", "退料", "安装挑选不良(待不良数上线)",
                        "产品入库数", "账面结存", "实际盘点数", "差异", "成品占材料比例%",
                        "其它耗用", "期间", "内料仓"),
                table.columns().stream().map(ReportColumn::label).toList());
        assertEquals(1, table.rows().size());
        Map<String, Object> row = table.rows().getFirst();
        assertEquals(code, row.get("goodsCode"));
        money("0", row.get("prevBalance"));
        money("3", row.get("drawQty"));
        money("0.5", row.get("returnQty"));
        money("0", row.get("rejectQty"));
        money("1", row.get("finishedWeight"));
        money("1.5", row.get("bookBalance"));
        money("1.3", row.get("checkQty"));
        money("-0.2", row.get("diff"));
        money("83.33", row.get("usageRatio"));
        money("0", row.get("otherIssueQty"));
        assertEquals(CloseBench.GO_LIVE + " 至 " + cutoff, row.get("periodLabel"));
        assertEquals(binName, row.get("binName"));

        // 期末日不在所选月份的期不出; 没结算的期不出
        LocalDate earlier = monthStart.minusMonths(1);
        assertTrue(finance.plasticUsage(code, earlier, earlier.withDayOfMonth(earlier.lengthOfMonth()), 1, 50)
                .rows().isEmpty());

        // 附件 8-1 领料明细: 内料仓发料流水
        ReportTableResponse issued = finance.plasticDetail("issue", code, BusinessTime.today(), BusinessTime.today(),
                1, 50);
        assertEquals(1, issued.rows().size());
        money("3", issued.rows().getFirst().get("qty"));
        assertTrue(issued.rows().getFirst().get("planNo").toString().startsWith("ZL"));
        assertNotNull(issued.rows().getFirst().get("billNo"));

        // 附件 8-2 退料明细: 内料仓退回流水 (实退数量为正)
        ReportTableResponse returned = finance.plasticDetail("return", code, BusinessTime.today(),
                BusinessTime.today(), 1, 50);
        assertEquals(1, returned.rows().size());
        money("0.5", returned.rows().getFirst().get("qty"));

        // 附件 8-3 产品入库明细: 已结算的理论明细 (重量 = 良品 x 单个重量)
        String productCode = db.queryForObject("SELECT code FROM goods WHERE id = ?", String.class,
                bench.world.goodsA());
        String materialName = db.queryForObject("SELECT name FROM goods WHERE id = ?", String.class, granule);
        ReportTableResponse finished = finance.plasticDetail("finished", productCode, LocalDate.of(2026, 1, 1),
                LocalDate.of(2026, 1, 31), 1, 50);
        List<Map<String, Object>> ours = finished.rows().stream()
                .filter(line -> materialName.equals(line.get("material")))
                .toList();
        assertEquals(1, ours.size());
        money("1", ours.getFirst().get("weight"));
        money("5", ours.getFirst().get("qty"));
    }
}
