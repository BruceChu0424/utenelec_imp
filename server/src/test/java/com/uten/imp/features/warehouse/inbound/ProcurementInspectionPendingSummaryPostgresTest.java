package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.*;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Properties;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/**
 * 待检单聚合投影（pending-receipts）的真库回归：2026-10-08 起 DTO 携带
 * goodsSummary「名称 (编号 · 颜色)、…」与 pendingQtyText「qty 单位 · qty 单位」，
 * 供待检处置队列「货品名称/待检数量」两列——此前 IQC 收货单行整列显示「—」。
 *
 * <p>2026-10-09 起从真实迁移目录克隆 schema（{@link MigratedSchemaBaseline}），
 * 不再手写最小 DDL：迁移加列零维护，满足 fixture 漂移守卫的根治口径。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementInspectionPendingSummaryPostgresTest {
    /** 本类独享的全量迁移容器；兼容 API 由本类负责停止。 */
    private static final PostgreSQLContainer<?> DB =
            MigratedSchemaBaseline.startMigratedContainer("iqc_pending_summary");
    private static EntityManagerFactory emf;
    private static ProcurementInspectionController controller;
    private static JdbcTemplate jdbc;
    private static final UUID RECEIPT = UUID.randomUUID();
    private static final UUID SUPPLIER = UUID.randomUUID();
    private static final UUID PIECE_UNIT = UUID.randomUUID();
    private static final UUID BAG_UNIT = UUID.randomUUID();
    private static final UUID BOX_GOODS = UUID.randomUUID();
    private static final UUID BAG_GOODS = UUID.randomUUID();
    private static final UUID BLUE = UUID.randomUUID();
    private static UUID warehouse;

    @BeforeAll
    static void setup() {
        var ds = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(ds);
        // 真实 schema 的必填列与外键都要如实满足：供应商要分类，待检明细要仓库。
        UUID category = UUID.randomUUID();
        warehouse = UUID.randomUUID();
        jdbc.update("INSERT INTO supplier_categories(id, code, name) VALUES (?, 'IQC-PENDING-CAT', '待检汇总测试分类')", category);
        jdbc.update("INSERT INTO units(id, code, name) VALUES (?, 'IQC-U-PIECE', '个')", PIECE_UNIT);
        jdbc.update("INSERT INTO units(id, code, name) VALUES (?, 'IQC-U-BAG', '只')", BAG_UNIT);
        jdbc.update("INSERT INTO colors(id, code, name) VALUES (?, 'IQC-C-BLUE', '蓝色')", BLUE);
        jdbc.update("INSERT INTO warehouses(id, code, name, parent_id, status) VALUES (?, 'IQC-W-PENDING', '待检测试仓', NULL, '使用')", warehouse);
        jdbc.update("INSERT INTO goods(id, code, name, unit_id, code_sequence) VALUES (?, 'WL001', '盒装零件', ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))", BOX_GOODS, PIECE_UNIT);
        jdbc.update("INSERT INTO goods(id, code, name, unit_id, code_sequence) VALUES (?, 'WL002', '编织袋', ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))", BAG_GOODS, BAG_UNIT);
        jdbc.update("INSERT INTO suppliers(id, code, name, status, category_id, code_sequence) VALUES (?, 'IQC-S-1', '华东供应商', '使用', ?, 1)", SUPPLIER, category);
        jdbc.update("INSERT INTO purchase_receipts(id, is_deleted, bill_no, bill_date, supplier_id) VALUES (?, FALSE, 'CJ20261008000001', ?::date, ?)",
                RECEIPT, LocalDate.of(2026, 10, 8), SUPPLIER);
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(ds);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        var properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "none");
        factory.setJpaProperties(properties);
        factory.afterPropertiesSet();
        emf = factory.getObject();
        var service = new ProcurementInspectionService(SharedEntityManagerCreator.createSharedEntityManager(emf),
                mock(StockService.class), mock(SecurityContextCurrentUser.class), mock(TxSessionVars.class),
                mock(ProductionSupplyTransitionPort.class), mock(ProductionSubcontractSupplyTransitionPort.class),
                mock(BusinessEventPublisher.class), mock(ProcurementIqcRejectionPort.class), mock(ChainNoticeService.class),
                org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                mock(com.uten.imp.common.finance.ProcurementReceiptConsiderationService.class),
                mock(com.uten.imp.application.port.ProcurementInventoryValuePort.class),
                mock(ProcurementIqcStockInService.class),
                mock(com.uten.imp.application.port.ProductionInspectionStockInPort.class));
        controller = new ProcurementInspectionController(service);
    }

    @AfterAll
    static void close() {
        if (emf != null) emf.close();
        DB.stop();
    }

    @Test
    void pendingSummaryCarriesGoodsSummaryAndUnitGroupedQtyText() {
        // 两条待检明细：盒装零件(个)剩 30、编织袋(只)已检 2 剩 10；一条已结案明细必须被排除。
        // 数量组合受 procurement_inspection_items_status_projection_chk 约束（PENDING 未检、PARTIAL 部分检）。
        insertPendingItem(UUID.randomUUID(), BOX_GOODS, PIECE_UNIT, BLUE, "PENDING",
                new BigDecimal("30"), BigDecimal.ZERO, BigDecimal.ZERO);
        insertPendingItem(UUID.randomUUID(), BAG_GOODS, BAG_UNIT, null, "PARTIAL",
                new BigDecimal("12"), new BigDecimal("2"), BigDecimal.ZERO);
        insertPendingItem(UUID.randomUUID(), BOX_GOODS, PIECE_UNIT, BLUE, "RESOLVED",
                new BigDecimal("100"), new BigDecimal("100"), BigDecimal.ZERO);

        var summaries = controller.pendingReceipts();
        assertThat(summaries).hasSize(1);
        var row = summaries.getFirst();
        assertThat(row.receiptId()).isEqualTo(RECEIPT);
        assertThat(row.supplierName()).isEqualTo("华东供应商");
        assertThat(row.itemCount()).isEqualTo(2);
        assertThat(row.pendingBaseQty()).isEqualByComparingTo(new BigDecimal("40"));
        // string_agg(DISTINCT …) 无 ORDER BY，两件货品摘要的先后不保证——分别断言包含。
        assertThat(row.goodsSummary()).contains("盒装零件 (WL001 · 蓝色)");
        assertThat(row.goodsSummary()).contains("编织袋 (WL002)");
        // 待检数量按货品基本单位分组（跨单位不相加），结案行不计入。
        assertThat(row.pendingQtyText()).contains("30 个");
        assertThat(row.pendingQtyText()).contains("10 只");
        assertThat(row.pendingQtyText()).doesNotContain("100");
    }

    private static void insertPendingItem(
            UUID id, UUID goods, UUID unit, UUID color, String status,
            BigDecimal received, BigDecimal passed, BigDecimal failed) {
        // receipt_item_id 无外键（投影只按 receipt 头聚合），仓库来自上面建好的真实仓库行。
        jdbc.update("""
                INSERT INTO procurement_inspection_items(id, receipt_type, receipt_id, receipt_item_id, warehouse_id,
                    goods_id, color_id, unit_id, unit_rate, status, received_base_qty, passed_base_qty,
                    failed_base_qty, received_at)
                VALUES (?, 'PURCHASE', ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, now())
                """, id, RECEIPT, UUID.randomUUID(), warehouse, goods, color, unit, status, received, passed, failed);
    }
}
