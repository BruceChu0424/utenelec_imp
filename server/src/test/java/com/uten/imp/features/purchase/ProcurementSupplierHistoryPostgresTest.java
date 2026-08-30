package com.uten.imp.features.purchase;

import com.uten.imp.features.purchase.order.PurchaseOrderItemRepository;
import com.uten.imp.features.subcontract.order.SubcontractOrderItemRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/** Real PostgreSQL proof for the goods-to-last-selectable-supplier learning query. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=supplier-history-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=supplier-history-harness-pgp-key-test-only-0123456",
                "uten.crypto.hmac-key=supplier-history-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=supplier-history-bootstrap-admin-test",
                "uten.bootstrap.admin-password=SupplierHistoryAdminPass-1!"
        })
class ProcurementSupplierHistoryPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private PurchaseOrderItemRepository purchaseItems;

    @Autowired
    private SubcontractOrderItemRepository subcontractItems;

    private int supplierCodeSequence = 990000;

    @Test
    void learningQueriesSkipDisabledInternalDeletedAndDeletedOrderSuppliers() {
        UUID supplierCategory = jdbc.queryForObject(
                "SELECT id FROM supplier_categories WHERE is_deleted=false ORDER BY id LIMIT 1",
                UUID.class);
        UUID materialCategory = jdbc.queryForObject(
                "SELECT id FROM material_categories WHERE is_deleted=false ORDER BY id LIMIT 1",
                UUID.class);
        UUID goods = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id,category_id,code,name,status,code_sequence)
                VALUES (?,?,?,?,'使用',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """, goods, materialCategory, "SUP-HIST-" + shortId(goods), "Supplier history goods");

        UUID active = supplier(supplierCategory, "使用", false, false, "active");
        UUID disabled = supplier(supplierCategory, "禁用", false, false, "disabled");
        UUID internal = supplier(supplierCategory, "使用", true, false, "internal");
        UUID deleted = supplier(supplierCategory, "使用", false, true, "deleted");
        UUID activeOnDeletedOrder = supplier(
                supplierCategory, "使用", false, false, "deleted-order");

        OffsetDateTime base = OffsetDateTime.of(
                2026, 8, 29, 8, 0, 0, 0, ZoneOffset.UTC);
        purchase(goods, active, false, base.plusMinutes(1), 1);
        purchase(goods, disabled, false, base.plusMinutes(2), 2);
        purchase(goods, internal, false, base.plusMinutes(3), 3);
        purchase(goods, deleted, false, base.plusMinutes(4), 4);
        purchase(goods, activeOnDeletedOrder, true, base.plusMinutes(5), 5);

        subcontract(goods, active, false, base.plusMinutes(1), 1);
        subcontract(goods, disabled, false, base.plusMinutes(2), 2);
        subcontract(goods, internal, false, base.plusMinutes(3), 3);
        subcontract(goods, deleted, false, base.plusMinutes(4), 4);
        subcontract(goods, activeOnDeletedOrder, true, base.plusMinutes(5), 5);

        assertThat(toMap(purchaseItems.findLastSupplierPerGoods(java.util.List.of(goods))))
                .containsExactly(Map.entry(goods, active));
        assertThat(toMap(subcontractItems.findLastSupplierPerGoods(java.util.List.of(goods))))
                .containsExactly(Map.entry(goods, active));
    }

    private UUID supplier(
            UUID categoryId,
            String status,
            boolean internal,
            boolean deleted,
            String label) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO suppliers(
                    id,category_id,code,name,status,is_internal_workshop,is_deleted,code_sequence)
                VALUES (?,?,?,?,?,?,?,(SELECT COALESCE(max(code_sequence),0)+1 FROM suppliers))
                """, id, categoryId, "GY" + String.format("%06d", supplierCodeSequence++),
                label, status, internal, deleted);
        return id;
    }

    private void purchase(
            UUID goods,
            UUID supplier,
            boolean deleted,
            OffsetDateTime createdAt,
            int sequence) {
        UUID order = UUID.randomUUID();
        String billNo = "CD20260829" + String.format("%06d", 980000 + sequence);
        jdbc.update("""
                INSERT INTO purchase_orders(
                    id,bill_no,bill_date,supplier_id,status,is_deleted,created_at)
                VALUES (?,?,DATE '2026-08-29',?,0,?,?)
                """, order, billNo, supplier, deleted, createdAt);
        jdbc.update("""
                INSERT INTO purchase_order_items(
                    id,bill_no,bill_date,order_id,goods_id,qty,goods_snapshot_source)
                VALUES (?,?,DATE '2026-08-29',?,?,1,'MASTER_AT_SAVE')
                """, UUID.randomUUID(), billNo, order, goods);
    }

    private void subcontract(
            UUID goods,
            UUID supplier,
            boolean deleted,
            OffsetDateTime createdAt,
            int sequence) {
        UUID order = UUID.randomUUID();
        String billNo = "EO20260829" + String.format("%06d", 980000 + sequence);
        jdbc.update("""
                INSERT INTO subcontract_orders(
                    id,bill_no,bill_date,supplier_id,status,is_deleted,created_at)
                VALUES (?,?,DATE '2026-08-29',?,0,?,?)
                """, order, billNo, supplier, deleted, createdAt);
        jdbc.update("""
                INSERT INTO subcontract_order_items(
                    id,bill_no,bill_date,order_id,goods_id,qty,goods_snapshot_source)
                VALUES (?,?,DATE '2026-08-29',?,?,1,'MASTER_AT_SAVE')
                """, UUID.randomUUID(), billNo, order, goods);
    }

    private static Map<UUID, UUID> toMap(java.util.List<Object[]> rows) {
        return rows.stream().collect(Collectors.toMap(
                row -> (UUID) row[0],
                row -> (UUID) row[1]));
    }

    private static String shortId(UUID id) {
        return id.toString().replace("-", "").substring(0, 12).toUpperCase(java.util.Locale.ROOT);
    }

}
