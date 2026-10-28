package com.uten.imp.features.archive;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 采购订单归档试点（V955）真库验证：
 * 资格口径（结清满候选期/阻碍原因逐条留痕）、完整对象族打包与复制校验、
 * 幂等重放、评估与打包之间的迟到变化拦截。全程不搬移不删除业务数据。
 */
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = BusinessArchivePilotPostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@Testcontainers(disabledWithoutDocker = true)
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.jwt.secret=archive-pilot-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=archive-pilot-pgp-key-test-only-0123456",
                "uten.crypto.hmac-key=archive-pilot-hmac-key-test-only",
                "uten.bootstrap.admin-login=archive-pilot-bootstrap-admin",
                "uten.bootstrap.admin-password=ArchivePilotBootstrapPass-1!"
        })
class BusinessArchivePilotPostgresTest {

    private static MigratedSchemaBaseline.ScopedDatabase database;

    @DynamicPropertySource
    static void dataSource(DynamicPropertyRegistry registry) throws java.sql.SQLException {
        database = MigratedSchemaBaseline.openDatabase("archive_pilot");
        FixtureDatabaseProperties.bindSameRole(registry, database::getJdbcUrl,
                database::getUsername, database::getPassword);
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) throws java.sql.SQLException {
            if (database != null) database.close();
        }
    }

    @Autowired
    private JdbcTemplate jdbc;

    private final ObjectMapper mapper = new ObjectMapper();

    private BusinessArchiveEligibilityService service() {
        return new BusinessArchiveEligibilityService(jdbc, mapper, 24);
    }

    private UUID supplier() {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO suppliers(id, code, name, code_sequence) "
                        + "VALUES (?, ?, '归档试点供应商', ?)",
                id, "SUP" + masterSeq(), masterSeq());
        return id;
    }

    private UUID goods() {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id, code, name, code_sequence) "
                        + "VALUES (?, ?, '归档试点货品', ?)",
                id, "GDS" + masterSeq(), masterSeq());
        return id;
    }

    /** V279 全局单号注册表: 单据标准格式=前缀+YYYYMMDD+6位序列(采购订单 CD/收货 CJ)。 */
    private static final java.util.concurrent.atomic.AtomicLong DOC_SEQ =
            new java.util.concurrent.atomic.AtomicLong(1);
    private static final java.util.concurrent.atomic.AtomicLong MASTER_SEQ =
            new java.util.concurrent.atomic.AtomicLong(900000001L);

    private static String cdNo() {
        return "CD20240501" + String.format("%06d", DOC_SEQ.incrementAndGet());
    }

    private static String cjNo() {
        return "CJ20240430" + String.format("%06d", DOC_SEQ.incrementAndGet());
    }

    private static long masterSeq() {
        return MASTER_SEQ.incrementAndGet();
    }

    private UUID closedOrder(UUID supplierId, UUID goodsId, String billNo) {
        UUID order = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO purchase_orders(id, bill_no, bill_date, supplier_id, status, is_closed)
                VALUES (?, ?, CURRENT_DATE - interval '30 months', ?, 1, TRUE)
                """, order, billNo, supplierId);
        jdbc.update("""
                INSERT INTO purchase_order_items(
                    id, order_id, bill_no, bill_date, goods_id, qty,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
                SELECT gen_random_uuid(), ?, ?, CURRENT_DATE - interval '30 months', ?, 10,
                       g.code, g.name, 'LEGACY_IMPORT', now()
                FROM goods g WHERE g.id = ?
                """, order, billNo, goodsId, goodsId);
        return order;
    }

    /**
     * 已审收货 + 结清台账。V518 对价合同：收货插入即被标记需要对价，每行配一条
     * 守恒分片（base_qty=qty×unit_rate，nominal 与行金额同比例），分片经手人取引导管理员。
     */
    private UUID settledReceipt(UUID orderId, UUID goodsId, String billNo, String monthsAgo) {
        UUID receipt = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO purchase_receipts(id, bill_no, bill_date, supplier_id, status, is_closed)
                VALUES (?, ?, CURRENT_DATE - interval '29 months',
                        (SELECT supplier_id FROM purchase_orders WHERE id = ?), 1, TRUE)
                """, receipt, billNo, orderId);
        // V518 全链合同: 台账先行(金额=分片应付), 分片次之, 收货行最后落库即整链守恒。
        jdbc.update("""
                INSERT INTO ar_ap_ledger(
                    id, direction, supplier_id, source_doc_type, source_doc_id, bill_no, bill_date,
                    amount_original, amount_original_local, amount_settled, amount_balance,
                    is_settled, settled_date)
                VALUES (gen_random_uuid(), 'AP', (SELECT supplier_id FROM purchase_orders WHERE id = ?),
                        'PURCHASE_RECEIPT', ?, ?, CURRENT_DATE - interval '29 months',
                        100, 100, 100, 0, TRUE, CURRENT_DATE - CAST(? AS interval))
                """, orderId, receipt, billNo, monthsAgo);
        UUID itemId = UUID.randomUUID();
        // 对价断言在收货行插入语句后立即执行: 分片先行(分片表对行无外键), 行落下即守恒。
        insertConsiderationPart(receipt, itemId, 10, 100);
        jdbc.update("""
                INSERT INTO purchase_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, goods_id, qty,
                    unit_rate, price, amount_original, amount_local, replacement_intent,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
                SELECT ?, ?, CURRENT_DATE - interval '29 months', ?, oi.id, ?, 10,
                       1, 10, 100, 100, 'NORMAL',
                       g.code, g.name, 'LEGACY_IMPORT', now()
                FROM purchase_order_items oi JOIN goods g ON g.id = oi.goods_id
                WHERE oi.order_id = ?
                """, itemId, billNo, receipt, goodsId, orderId);
        return receipt;
    }

    private void insertConsiderationPart(UUID receipt, UUID itemId, double baseQty, double nominal) {
        jdbc.update("""
                INSERT INTO procurement_receipt_consideration_parts(
                    id, receipt_type, receipt_id, receipt_item_id, billing_mode,
                    base_qty, nominal_original, nominal_local, payable_original, payable_local, created_by)
                SELECT gen_random_uuid(), 'PURCHASE', ?, ?, 'STANDARD', ?, ?, ?, ?, ?,
                       (SELECT id FROM users ORDER BY created_at LIMIT 1)
                """, receipt, itemId, baseQty, nominal, nominal, nominal, nominal);
    }

    /**
     * V518 对价/台账一致性是 DEFERRABLE 约束触发器: 收货-分片-台账整链必须同事务
     * 建立, 提交时统一校验; 测试事务结束时回滚, 不污染同库的其他用例。
     */
    @Test
    @Transactional
    void fullChainEligibilityPackageVerificationAndIdempotentReplay() throws Exception {
        UUID supplierId = supplier();
        UUID goodsId = goods();
        UUID order = closedOrder(supplierId, goodsId, cdNo());
        settledReceipt(order, goodsId, cjNo(), "25 months");
        jdbc.update("""
                INSERT INTO attachments(
                    id, owner_type, owner_id, storage_key, storage_provider, original_name,
                    size_bytes, sha256)
                VALUES (gen_random_uuid(), 'PURCHASE_ORDER', ?, 'arc-pilot-key.bin', 'legacy_unknown',
                        '归档试点原件.bin', 12, 'abc123')
                """, order);

        List<BusinessArchiveEligibilityService.Evaluation> evaluations =
                service().evaluatePurchaseOrders(50);
        BusinessArchiveEligibilityService.Evaluation mine = evaluations.stream()
                .filter(e -> order.equals(e.objectId())).findFirst().orElseThrow();
        assertThat(mine.eligible()).as("结清满24个月的已结案订单应合格: %s", mine.blockedReasons()).isTrue();
        assertThat(mine.finalSettledOn()).isNotNull();

        Map<String, Object> registry = jdbc.queryForMap(
                "SELECT eligible, blocked_reasons, final_settled_on, facts::text AS facts "
                        + "FROM business_archive_eligibility WHERE object_id = ?", order);
        assertThat(registry.get("eligible")).isEqualTo(Boolean.TRUE);

        BusinessArchiveEligibilityService.PackageOutcome first =
                service().packagePurchaseOrder(order);
        assertThat(first.outcome()).isEqualTo("PACKAGED");
        assertThat(first.lineCounts())
                .containsEntry("items", 1L)
                .containsEntry("receipts", 1L)
                .containsEntry("attachments", 1L);

        Map<String, Object> saved = service().latestPackage("PURCHASE_ORDER", order);
        assertThat(saved.get("status")).isEqualTo("VERIFIED");
        assertThat(saved.get("payload_sha256")).isEqualTo(first.payloadSha256());
        JsonNode payload = mapper.readTree((String) saved.get("payload"));
        assertThat(payload.get("family").asText()).isEqualTo("PURCHASE_ORDER");
        assertThat(payload.get("items").size()).isEqualTo(1);
        assertThat(payload.get("receipts").size()).isEqualTo(1);
        assertThat(payload.get("receipts").get(0).get("items").size()).isEqualTo(1);
        assertThat(payload.get("ledger").size()).isEqualTo(1);
        JsonNode refs = mapper.readTree((String) saved.get("attachment_refs"));
        assertThat(refs.size()).isEqualTo(1);
        assertThat(refs.get(0).get("sha256").asText()).isEqualTo("abc123");
        // 原始业务数据一个字节都没动。
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM purchase_orders WHERE id = ? AND is_closed", Long.class, order))
                .isEqualTo(1L);

        // 同摘要幂等: 重放返回 UNCHANGED, 不再新增版本。
        BusinessArchiveEligibilityService.PackageOutcome replay =
                service().packagePurchaseOrder(order);
        assertThat(replay.outcome()).isEqualTo("UNCHANGED");
        assertThat(replay.payloadSha256()).isEqualTo(first.payloadSha256());
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM business_archive_packages WHERE object_id = ?",
                Long.class, order)).isEqualTo(1L);

        // 业务变化后重打包: 新版本顶替旧版本, 旧版转 SUPERSEDED, 全程可追溯。
        jdbc.update("UPDATE purchase_orders SET remark = '归档后备注修订' WHERE id = ?", order);
        BusinessArchiveEligibilityService.PackageOutcome revised =
                service().packagePurchaseOrder(order);
        assertThat(revised.outcome()).isEqualTo("PACKAGED");
        assertThat(revised.payloadSha256()).isNotEqualTo(first.payloadSha256());
        assertThat(jdbc.queryForMap(
                "SELECT status, package_version FROM business_archive_packages "
                        + "WHERE object_id = ? ORDER BY package_version DESC LIMIT 1", order))
                .containsEntry("status", "VERIFIED")
                .containsEntry("package_version", 2);
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM business_archive_packages "
                        + "WHERE object_id = ? AND status = 'SUPERSEDED'", Long.class, order))
                .isEqualTo(1L);
    }

    @Test
    @Transactional
    void blockersAreRecordedPerReasonAndLateChangesStopPackaging() {
        UUID supplierId = supplier();
        UUID goodsId = goods();
        UUID settledOld = closedOrder(supplierId, goodsId, cdNo());
        settledReceipt(settledOld, goodsId, cjNo(), "30 months");
        UUID settledRecent = closedOrder(supplierId, goodsId, cdNo());
        settledReceipt(settledRecent, goodsId, cjNo(), "1 month");
        UUID noLedger = closedOrder(supplierId, goodsId, cdNo());
        UUID draftReceiptOrder = closedOrder(supplierId, goodsId, cdNo());
        UUID draftReceipt = UUID.randomUUID();
        String draftNo = cjNo();
        jdbc.update("""
                INSERT INTO purchase_receipts(id, bill_no, bill_date, supplier_id, status, is_closed)
                VALUES (?, ?, CURRENT_DATE, ?, 0, FALSE)
                """, draftReceipt, draftNo, supplierId);
        jdbc.update("""
                INSERT INTO purchase_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, goods_id, qty,
                    unit_rate, price, amount_original, amount_local, replacement_intent,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
                SELECT gen_random_uuid(), ?, CURRENT_DATE, ?, oi.id, ?, 5,
                       1, 10, 50, 50, 'NORMAL',
                       g.code, g.name, 'LEGACY_IMPORT', now()
                FROM purchase_order_items oi JOIN goods g ON g.id = oi.goods_id WHERE oi.order_id = ?
                """, draftNo, draftReceipt, goodsId, draftReceiptOrder);
        UUID unsettledOrder = closedOrder(supplierId, goodsId, cdNo());
        UUID unsettledReceipt = UUID.randomUUID();
        String unsettledNo = cjNo();
        jdbc.update("""
                INSERT INTO purchase_receipts(id, bill_no, bill_date, supplier_id, status, is_closed)
                VALUES (?, ?, CURRENT_DATE - interval '30 months', ?, 1, TRUE)
                """, unsettledReceipt, unsettledNo, supplierId);
        UUID unsettledItem = UUID.randomUUID();
        // 台账先行(未结清, 金额=分片应付70), 分片次之, 收货行最后。
        jdbc.update("""
                INSERT INTO ar_ap_ledger(
                    id, direction, supplier_id, source_doc_type, source_doc_id, bill_no, bill_date,
                    amount_original, amount_original_local, amount_settled, amount_balance, is_settled)
                VALUES (gen_random_uuid(), 'AP', ?, 'PURCHASE_RECEIPT', ?, ?,
                        CURRENT_DATE - interval '30 months', 70, 70, 0, 70, FALSE)
                """, supplierId, unsettledReceipt, unsettledNo);
        insertConsiderationPart(unsettledReceipt, unsettledItem, 7, 70);
        jdbc.update("""
                INSERT INTO purchase_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, goods_id, qty,
                    unit_rate, price, amount_original, amount_local, replacement_intent,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
                SELECT ?, ?, CURRENT_DATE - interval '30 months', ?, oi.id, ?, 7,
                       1, 10, 70, 70, 'NORMAL',
                       g.code, g.name, 'LEGACY_IMPORT', now()
                FROM purchase_order_items oi JOIN goods g ON g.id = oi.goods_id WHERE oi.order_id = ?
                """, unsettledItem, unsettledNo, unsettledReceipt, goodsId, unsettledOrder);

        java.util.function.Function<UUID, List<String>> reasonsOf = orderId ->
                service().evaluatePurchaseOrders(50).stream()
                        .filter(e -> orderId.equals(e.objectId()))
                        .findFirst().orElseThrow().blockedReasons();
        assertThat(reasonsOf.apply(settledRecent)).containsExactly("SETTLED_TOO_RECENT");
        assertThat(reasonsOf.apply(noLedger)).containsExactly("NO_SETTLED_EVIDENCE");
        assertThat(reasonsOf.apply(draftReceiptOrder)).contains("DRAFT_RECEIPTS");
        assertThat(reasonsOf.apply(unsettledOrder)).containsExactly("UNSETTLED_LEDGER");
        assertThat(reasonsOf.apply(settledOld)).isEmpty();

        // 评估与打包之间出现迟到立账: 打包前即时复核拦下, 不产包。
        UUID lateBlock = closedOrder(supplierId, goodsId, cdNo());
        settledReceipt(lateBlock, goodsId, cjNo(), "30 months");
        List<BusinessArchiveEligibilityService.Evaluation> firstPass =
                service().evaluatePurchaseOrders(50);
        assertThat(firstPass.stream()
                .filter(e -> lateBlock.equals(e.objectId()))
                .findFirst().orElseThrow().eligible()).isTrue();
        // 迟到业务事件（同源台账受 uq_arap_active_source 约束, 用迟到草稿收货表达）:
        // 评估合格之后、打包之前出现新的未审收货, 打包前即时复核拦下, 不产包。
        String lateNo = cjNo();
        UUID lateDraftReceipt = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO purchase_receipts(id, bill_no, bill_date, supplier_id, status, is_closed)
                VALUES (?, ?, CURRENT_DATE, ?, 0, FALSE)
                """, lateDraftReceipt, lateNo, supplierId);
        jdbc.update("""
                INSERT INTO purchase_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, goods_id, qty,
                    unit_rate, price, amount_original, amount_local, replacement_intent,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
                SELECT gen_random_uuid(), ?, CURRENT_DATE, ?, oi.id, ?, 3,
                       1, 10, 30, 30, 'NORMAL',
                       g.code, g.name, 'LEGACY_IMPORT', now()
                FROM purchase_order_items oi JOIN goods g ON g.id = oi.goods_id WHERE oi.order_id = ?
                """, lateNo, lateDraftReceipt, goodsId, lateBlock);
        assertThat(service().packagePurchaseOrder(lateBlock).outcome())
                .isEqualTo("SKIPPED_NOT_ELIGIBLE");
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM business_archive_packages WHERE object_id = ?",
                Long.class, lateBlock)).isZero();
    }
}
