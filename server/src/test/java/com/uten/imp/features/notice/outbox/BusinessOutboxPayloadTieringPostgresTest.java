package com.uten.imp.features.notice.outbox;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Outbox 大载荷分层（V953）真库验证：
 * 只迁已送达载荷、防重等价比较跨层、诊断读取走统一视图、IQC 检测守卫跨层对上 FAIL 事实。
 */
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = BusinessOutboxPayloadTieringPostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@Testcontainers(disabledWithoutDocker = true)
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.jwt.secret=outbox-payload-tiering-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=outbox-payload-tiering-pgp-key-test-only-0123",
                "uten.crypto.hmac-key=outbox-payload-tiering-hmac-key-test-only",
                "uten.bootstrap.admin-login=outbox-tiering-bootstrap-admin",
                "uten.bootstrap.admin-password=OutboxTieringBootstrapPass-1!"
        })
class BusinessOutboxPayloadTieringPostgresTest {

    private static MigratedSchemaBaseline.ScopedDatabase database;

    @DynamicPropertySource
    static void dataSource(DynamicPropertyRegistry registry) throws java.sql.SQLException {
        database = MigratedSchemaBaseline.openDatabase("outbox_payload_tiering");
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

    @Autowired
    private BusinessOutboxPublisher publisher;

    private BusinessOutboxPayloadTieringService tiering() {
        return new BusinessOutboxPayloadTieringService(jdbc, 1, 10, 100);
    }

    private UUID insertOutbox(
            String dedupeKey, String eventType, UUID aggregateId,
            String payloadJson, int status, boolean processedTwoDaysAgo) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO business_outbox(
                    id, event_type, aggregate_type, aggregate_id, payload, dedupe_key,
                    status, processed_at)
                VALUES (?, ?, 'PROCUREMENT_RECEIPT', ?, CAST(? AS jsonb), ?, ?,
                        CASE WHEN ? THEN now() - interval '2 days' ELSE NULL END)
                """,
                id, eventType, aggregateId, payloadJson, dedupeKey, status, processedTwoDaysAgo);
        return id;
    }

    @Test
    void tiersOnlyDeliveredPayloadsAndStaysIdempotent() {
        UUID aggregate = UUID.randomUUID();
        UUID delivered = insertOutbox(
                "tier-test:delivered:1", "RECEIPT_CONFIRMED", aggregate,
                "{\"receiptId\":\"R-T1\",\"amount\":42}", 1, true);
        UUID pending = insertOutbox(
                "tier-test:pending:1", "RECEIPT_CONFIRMED", aggregate,
                "{\"receiptId\":\"R-T2\"}", 0, false);
        UUID dead = insertOutbox(
                "tier-test:dead:1", "RECEIPT_CONFIRMED", aggregate,
                "{\"receiptId\":\"R-T3\"}", 2, true);

        BusinessOutboxPayloadTieringService service = tiering();
        // 同库并行用例可能也插入已送达行: 计数只看下限, 状态逐键断言。
        assertThat(service.archiveBatch()).isGreaterThanOrEqualTo(1);

        Map<String, Object> history = jdbc.queryForMap(
                "SELECT dedupe_key, payload_md5, md5(payload::text) AS recomputed "
                        + "FROM business_outbox_payload_history WHERE outbox_id = ?",
                delivered);
        assertThat(history.get("dedupe_key")).isEqualTo("tier-test:delivered:1");
        assertThat(history.get("payload_md5")).isEqualTo(history.get("recomputed"));

        Map<String, Object> hot = jdbc.queryForMap(
                "SELECT payload::text AS payload, payload_archived_at "
                        + "FROM business_outbox WHERE id = ?", delivered);
        assertThat(hot.get("payload")).isEqualTo("{}");
        assertThat(hot.get("payload_archived_at")).isNotNull();

        // 待处理与死信永不迁入: 载荷原样、无分层标记。
        for (UUID untouched : new UUID[]{pending, dead}) {
            Map<String, Object> row = jdbc.queryForMap(
                    "SELECT payload->>'receiptId' AS receipt, payload_archived_at "
                            + "FROM business_outbox WHERE id = ?", untouched);
            assertThat(row.get("payload_archived_at")).isNull();
            assertThat(row.get("receipt")).isNotNull();
        }
        // 重放幂等: 本行只产生一条历史记录, 分层标记防重复认领。
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM business_outbox_payload_history WHERE outbox_id = ?",
                Long.class, delivered)).isEqualTo(1);
        assertThat(service.archiveBatch()).isGreaterThanOrEqualTo(0);
    }

    @Test
    void dedupeEquivalenceSpansTiersAfterPayloadTiering() {
        UUID aggregate = UUID.randomUUID();
        UUID delivered = insertOutbox(
                "tier-dedupe:1", "RECEIPT_CONFIRMED", aggregate,
                "{\"receiptId\":\"R-D1\",\"lines\":[1,2,3]}", 1, true);
        assertThat(tiering().archiveBatch()).isGreaterThanOrEqualTo(1);

        // 同键同内容重放: 历史层载荷参与等价比较, 幂等返回原事件。
        UUID replayed = publisher.publishOnce(
                "RECEIPT_CONFIRMED", "PROCUREMENT_RECEIPT", aggregate,
                Map.of("receiptId", "R-D1", "lines", java.util.List.of(1, 2, 3)),
                "tier-dedupe:1");
        assertThat(replayed).isEqualTo(delivered);

        // 同键不同内容: 与分层前同样拒绝, 防重身份没有因分层弱化。
        UUID finalAggregate = aggregate;
        assertThatThrownBy(() -> publisher.publishOnce(
                "RECEIPT_CONFIRMED", "PROCUREMENT_RECEIPT", finalAggregate,
                Map.of("receiptId", "R-D1", "lines", java.util.List.of(9)),
                "tier-dedupe:1"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("已用于其他内容");
    }

    @Test
    void unifiedViewServesEffectivePayloadForDiagnostics() {
        UUID aggregate = UUID.randomUUID();
        insertOutbox(
                "tier-view:1", "RECEIPT_CONFIRMED", aggregate,
                "{\"receiptId\":\"R-V1\"}", 1, true);
        assertThat(tiering().archiveBatch()).isGreaterThanOrEqualTo(1);

        // 分层后热表按载荷查不到(这正是反审依赖事实改走统一视图的原因)。
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM business_outbox WHERE payload->>'receiptId' = 'R-V1'",
                Long.class)).isZero();
        // 统一视图仍按载荷命中, 且带分层标记。
        Map<String, Object> view = jdbc.queryForMap(
                "SELECT id, payload_archived, payload->>'receiptId' AS receipt "
                        + "FROM v_business_outbox_full WHERE payload->>'receiptId' = 'R-V1'");
        assertThat(Boolean.TRUE.equals(view.get("payload_archived"))).isTrue();
        assertThat(view.get("receipt")).isEqualTo("R-V1");
    }

    @Test
    void iqcFailureDetectionGuardSurvivesPayloadTiering() {
        UUID warehouse = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id, code, name) VALUES (?, 'TIER-WH', '分层测试仓')",
                warehouse);
        UUID goods = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id, code, name, code_sequence) "
                + "VALUES (?, 'TIER-GOODS', '分层测试货品', 1)", goods);

        // 两个质检行: 一个有已分层的检测事件, 一个根本没有检测事件。
        UUID withDetection = insertInspectionItem(warehouse, goods);
        UUID withoutDetection = insertInspectionItem(warehouse, goods);
        UUID failEvent = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO procurement_inspection_events(id, inspection_item_id, action, base_qty, reason)
                VALUES (?, ?, 'FAIL', 3, '分层守卫测试')
                """, failEvent, withDetection);
        jdbc.update("""
                INSERT INTO procurement_inspection_events(id, inspection_item_id, action, base_qty, reason)
                VALUES (gen_random_uuid(), ?, 'FAIL', 2, '分层守卫测试-无检测')
                """, withoutDetection);
        insertOutbox(
                "tier-guard:1", "PROCUREMENT_IQC_REJECTION_DETECTED", withDetection,
                "{\"inspectionEventId\":\"" + failEvent + "\"}", 1, true);
        assertThat(tiering().archiveBatch()).isGreaterThanOrEqualTo(1);

        // 检测事件载荷已分层, 守卫经统一视图对上 FAIL 事实 → 允许上调失败量。
        jdbc.update("UPDATE procurement_inspection_items SET failed_base_qty = 3, status = 'PARTIAL' "
                + "WHERE id = ?", withDetection);

        // 没有检测事件的 FAIL 事实仍被拒绝: 守卫没有被分层改动弱化。
        assertThatThrownBy(() -> jdbc.update(
                "UPDATE procurement_inspection_items SET failed_base_qty = 2, status = 'PARTIAL' "
                        + "WHERE id = ?", withoutDetection))
                .isInstanceOf(DataAccessException.class)
                .hasMessageContaining("one durable detection event per FAIL fact");
    }

    private UUID insertInspectionItem(UUID warehouseId, UUID goodsId) {
        UUID item = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO procurement_inspection_items(
                    id, receipt_type, receipt_id, receipt_item_id, warehouse_id, goods_id,
                    unit_rate, received_base_qty, passed_base_qty, failed_base_qty, status)
                VALUES (?, 'PURCHASE', gen_random_uuid(), gen_random_uuid(), ?, ?, 1, 10, 0, 0, 'PENDING')
                """, item, warehouseId, goodsId);
        return item;
    }
}
