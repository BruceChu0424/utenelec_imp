package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.*;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
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
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementInspectionPendingSummaryPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
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

    @BeforeAll
    static void setup() {
        DB.start();
        var ds = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(ds);
        jdbc.execute("CREATE TABLE units(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE colors(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE warehouses(id uuid PRIMARY KEY, name text)");
        jdbc.execute("""
                CREATE TABLE goods(id uuid PRIMARY KEY, code text, name text, unit_id uuid)
                """);
        jdbc.execute("""
                CREATE TABLE procurement_inspection_items(id uuid, receipt_type text, receipt_id uuid,
                    goods_id uuid, color_id uuid, status text,
                    received_base_qty numeric(18,4), passed_base_qty numeric(18,4),
                    failed_base_qty numeric(18,4), warehouse_id uuid, received_at timestamptz,
                    pre_stocked_warehouse_id uuid, pre_stocked_place text, pre_stocked_at timestamptz)
                """);
        jdbc.execute("CREATE TABLE suppliers(id uuid PRIMARY KEY, name text)");
        for (String prefix : new String[]{"purchase", "subcontract"}) {
            jdbc.execute("CREATE TABLE " + prefix + "_receipts(id uuid PRIMARY KEY, legacy_id integer,"
                    + " is_deleted boolean, bill_no text, bill_date date, supplier_id uuid)");
        }
        jdbc.update("INSERT INTO units VALUES (?, '个'), (?, '只')", PIECE_UNIT, BAG_UNIT);
        jdbc.update("INSERT INTO colors VALUES (?, '蓝色')", BLUE);
        jdbc.update("INSERT INTO goods VALUES (?, 'WL001', '盒装零件', ?)", BOX_GOODS, PIECE_UNIT);
        jdbc.update("INSERT INTO goods VALUES (?, 'WL002', '编织袋', ?)", BAG_GOODS, BAG_UNIT);
        jdbc.update("INSERT INTO suppliers VALUES (?, '华东供应商')", SUPPLIER);
        jdbc.update("INSERT INTO purchase_receipts VALUES (?, NULL, FALSE, 'CJ20261008000001', ?::date, ?)",
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
        // 两条待检明细：盒装零件(个)剩 30、编织袋(只)剩 10；一条已结案明细必须被排除。
        insertPendingItem(UUID.randomUUID(), BOX_GOODS, BLUE, "PENDING",
                new BigDecimal("48"), new BigDecimal("12"), new BigDecimal("6"));
        insertPendingItem(UUID.randomUUID(), BAG_GOODS, null, "PARTIAL",
                new BigDecimal("10"), BigDecimal.ZERO, BigDecimal.ZERO);
        insertPendingItem(UUID.randomUUID(), BOX_GOODS, BLUE, "RESOLVED",
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
            UUID id, UUID goods, UUID color, String status,
            BigDecimal received, BigDecimal passed, BigDecimal failed) {
        jdbc.update("""
                INSERT INTO procurement_inspection_items(id, receipt_type, receipt_id, goods_id, color_id,
                    status, received_base_qty, passed_base_qty, failed_base_qty, received_at)
                VALUES (?, 'PURCHASE', ?, ?, ?, ?, ?, ?, ?, now())
                """, id, RECEIPT, goods, color, status, received, passed, failed);
    }
}
