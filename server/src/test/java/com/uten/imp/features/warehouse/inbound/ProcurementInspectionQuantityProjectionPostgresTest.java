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

import java.util.Properties;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/** Runs the real read query and DTO mapping; source packages are not IQC units. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementInspectionQuantityProjectionPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static EntityManagerFactory emf;
    private static ProcurementInspectionController controller;
    private static JdbcTemplate jdbc;
    private static final UUID RECEIPT = UUID.randomUUID();
    private static final UUID BASE_UNIT = UUID.randomUUID();
    private static final UUID SOURCE_UNIT = UUID.randomUUID();
    private static final UUID GOODS = UUID.randomUUID();

    @BeforeAll
    static void setup() {
        DB.start();
        var ds = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(ds);
        jdbc.execute("CREATE TABLE units(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE goods(id uuid PRIMARY KEY, code text, name text, unit_id uuid)");
        jdbc.execute("CREATE TABLE colors(id uuid PRIMARY KEY, name text)");
        jdbc.execute("""
                CREATE TABLE procurement_inspection_items(id uuid, receipt_type text, receipt_id uuid,
                    receipt_item_id uuid, goods_id uuid, color_id uuid, unit_id uuid, unit_rate numeric,
                    received_base_qty numeric, passed_base_qty numeric, failed_base_qty numeric,
                    status text, warehouse_id uuid, received_weight numeric, received_at timestamptz)
                """);
        for (String prefix : new String[]{"purchase", "subcontract"}) {
            jdbc.execute("CREATE TABLE " + prefix + "_receipt_items(id uuid PRIMARY KEY, order_item_id uuid)");
            jdbc.execute("CREATE TABLE " + prefix + "_order_items(id uuid PRIMARY KEY, order_id uuid)");
            jdbc.execute("CREATE TABLE " + prefix + "_orders(id uuid PRIMARY KEY, bill_no text)");
        }
        jdbc.update("INSERT INTO units VALUES (?, '个'), (?, '箱')", BASE_UNIT, SOURCE_UNIT);
        jdbc.update("INSERT INTO goods VALUES (?, 'G-BOX', '盒装零件', ?)", GOODS, BASE_UNIT);
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
                mock(com.uten.imp.application.port.ProcurementInventoryValuePort.class));
        controller = new ProcurementInspectionController(service);
    }

    @AfterAll
    static void close() {
        if (emf != null) emf.close();
        DB.stop();
    }

    @Test
    void purchaseAndSubcontractKeepConvertedQuantitiesWithAuthoritativeUnitAndSource() {
        for (String prefix : new String[]{"purchase", "subcontract"}) {
            UUID order = UUID.randomUUID();
            UUID orderItem = UUID.randomUUID();
            UUID receiptItem = UUID.randomUUID();
            UUID inspection = UUID.randomUUID();
            String type = prefix.toUpperCase(java.util.Locale.ROOT);
            jdbc.update("INSERT INTO " + prefix + "_orders VALUES (?, ?)", order, prefix + "-001");
            jdbc.update("INSERT INTO " + prefix + "_order_items VALUES (?, ?)", orderItem, order);
            jdbc.update("INSERT INTO " + prefix + "_receipt_items VALUES (?, ?)", receiptItem, orderItem);
            jdbc.update("""
                    INSERT INTO procurement_inspection_items(id, receipt_type, receipt_id, receipt_item_id,
                        goods_id, unit_id, unit_rate, received_base_qty, passed_base_qty, failed_base_qty, status, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, 24, 48, 12, 6, 'PARTIAL', now())
                    """, inspection, type, RECEIPT, receiptItem, GOODS, SOURCE_UNIT);
            var rows = controller.list(type, RECEIPT);
            assertThat(rows).hasSize(1);
            var row = rows.getFirst();
            assertThat(row.receiptItemId()).isEqualTo(receiptItem);
            assertThat(row.sourceOrderNo()).isEqualTo(prefix + "-001");
            assertThat(row.unitId()).isEqualTo(SOURCE_UNIT);
            assertThat(row.sourceUnitName()).isEqualTo("箱");
            assertThat(row.baseUnitId()).isEqualTo(BASE_UNIT);
            assertThat(row.baseUnitName()).isEqualTo("个");
            assertThat(row.unitRate()).isEqualByComparingTo("24");
            assertThat(row.receivedBaseQty()).isEqualByComparingTo("48");
            assertThat(row.passedBaseQty()).isEqualByComparingTo("12");
            assertThat(row.failedBaseQty()).isEqualByComparingTo("6");
            assertThat(row.remainingBaseQty()).isEqualByComparingTo("30");
        }
    }
}
