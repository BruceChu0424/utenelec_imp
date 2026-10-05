package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.stock.weight.GoodsWeightEstimateService;
import com.uten.imp.features.stock.weight.StockWeightAdjustmentService;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
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
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 两次真实保存 -> 审核 -> 红冲, 使用完整 Flyway 和真实预留唯一约束。ADR-143: 委外件 E 发外的是它的直属物料 M,
 * 出仓草稿由委外人员提交领料生成(带 requested_qty), 仓库拣货只能改少。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"
})
class SubcontractDraftIdentityPostgresTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired GoodsWeightEstimateService weights;
    @Autowired StockWeightAdjustmentService weightAdjustments;

    @AfterEach
    void clearPrincipal() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void repeatedDraftSavePreservesItemIdentityAndReservationHistoryThroughApproveAndReverse() {
        var fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        var world = fixture.seedWorld("stable-issue-row");
        fixture.loginAs(world.superAdminUserId());
        UUID material = fixture.ensureSubcontractDirectMaterial(world, world.goodsE());
        fixture.receiveSubcontractMaterial(world, material, "1000");
        weightAdjustments.setWeight(new StockWeightAdjustmentService.SetWeightCommand(
                StockWeightAdjustmentService.KIND_MANUAL, world.warehouseId(), material, null,
                new BigDecimal("20"), null, false, null, null, null, java.time.OffsetDateTime.now(),
                "出仓预填测试核重", "draft-weight-" + UUID.randomUUID(), world.superAdminUserId()));
        var references = weights.params(List.of(
                new WeightParamsRequest.Line("actual", material, null, world.warehouseId(), null),
                new WeightParamsRequest.Line("other-warehouse", material, null, UUID.randomUUID(), null),
                new WeightParamsRequest.Line("other-color", material, null, world.warehouseId(), UUID.randomUUID())));
        assertThat(references.getFirst().stockBalance().qtyBase()).isEqualByComparingTo("1000");
        assertThat(references.getFirst().stockBalance().weightKg()).isEqualByComparingTo("20");
        assertThat(references.get(1).stockBalance()).isNull();
        assertThat(references.get(2).stockBalance()).isNull();
        var submitted = fixture.submitLeafSubcontractForFinance(world, new BigDecimal("1000"));
        fixture.loginAs(submitted.reviewerUserId());
        call(fixture, "approvePendingFinance", "SUBCONTRACT", submitted.orderId());
        fixture.loginAs(world.superAdminUserId());
        UUID orderItem = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",
                UUID.class, submitted.orderId());
        // 委外人员领满 1000 套 → 仓库待发草稿 M 1000(requested_qty 1000)。
        UUID issueId = fixture.submitSubcontractDraw(orderItem, new BigDecimal("1000"), "stable-issue-draw-" + orderItem)
                .getFirst();
        var original = issues.detail(issueId).getItems().getFirst();
        var createdAt = db.queryForObject("SELECT created_at FROM subcontract_material_issue_items WHERE id=?",
                java.sql.Timestamp.class, original.getId());
        UUID removedItem = UUID.randomUUID();
        db.update("""
                INSERT INTO subcontract_material_issue_items(
                    id,bill_no,bill_date,line_no,issue_id,plan_item_id,order_item_id,goods_id,color_id,unit_id,unit_rate,qty,
                    requested_qty,parent_goods_id,parent_color_id,goods_code_snapshot,goods_name_snapshot,
                    goods_snapshot_source,parent_goods_code_snapshot,parent_goods_name_snapshot,
                    parent_goods_snapshot_source,is_deleted)
                SELECT ?,bill_no,bill_date,line_no,issue_id,plan_item_id,order_item_id,goods_id,color_id,unit_id,unit_rate,qty,
                    requested_qty,parent_goods_id,parent_color_id,goods_code_snapshot,goods_name_snapshot,
                    goods_snapshot_source,parent_goods_code_snapshot,parent_goods_name_snapshot,
                    parent_goods_snapshot_source,TRUE
                FROM subcontract_material_issue_items WHERE id=?
                """, removedItem, original.getId());
        assertThat(issues.detail(issueId).getItems()).hasSize(1);
        var request = new MaterialIssueSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(world.warehouseId());
        request.setSupplierId(world.supplierId());
        var line = new MaterialIssueItemLine();
        line.setPlanItemId(original.getPlanItemId());
        line.setGoodsId(original.getGoodsId());
        line.setUnitId(original.getUnitId());
        line.setUnitRate(original.getUnitRate());
        line.setQty(new BigDecimal("600"));
        line.setWeight(new BigDecimal("12"));
        request.setItems(List.of(line));

        var first = issues.update(issueId, request);
        assertThat(first.getItems().getFirst().getId()).isEqualTo(original.getId());
        // 旧客户端只给 planItemId, 新客户端再明确给最新 ID, 两条路径都必须保持身份。
        line.setId(original.getId());
        line.setQty(new BigDecimal("500"));
        line.setWeight(new BigDecimal("10"));
        var second = issues.update(issueId, request);

        assertThat(second.getItems().getFirst().getId()).isEqualTo(original.getId());
        assertThat(second.getItems().getFirst().getWeight()).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT created_at FROM subcontract_material_issue_items WHERE id=?",
                java.sql.Timestamp.class, original.getId())).isEqualTo(createdAt);
        assertThat(db.queryForObject("SELECT count(*) FROM subcontract_material_issue_items WHERE issue_id=? AND NOT is_deleted",
                Integer.class, issueId)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT is_deleted FROM subcontract_material_issue_items WHERE id=?",
                Boolean.class, removedItem)).isTrue();
        List<String> keys = db.queryForList("""
                SELECT idempotency_key FROM stock_reservations
                WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND source_doc_id=?
                ORDER BY created_at, id
                """, String.class, issueId);
        assertThat(keys).hasSize(3).doesNotHaveDuplicates();
        assertThat(db.queryForObject("""
                SELECT count(*) FROM stock_reservations WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT'
                AND source_doc_id=? AND status=1 AND released_qty=qty
                """, Integer.class, issueId)).isEqualTo(2);
        assertThat(db.queryForObject("""
                SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations
                WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND source_doc_id=? AND status=0
                """, BigDecimal.class, issueId)).isEqualByComparingTo("500");

        var approved = issues.approve(issueId);
        assertThat(approved.getItems().getFirst().getId()).isEqualTo(original.getId());
        assertThat(balance(world.warehouseId(), material)).isEqualByComparingTo("500");
        assertThat(balanceWeight(world.warehouseId(), material)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT issued_qty FROM subcontract_material_plan_items WHERE id=?",
                BigDecimal.class, original.getPlanItemId())).isEqualByComparingTo("500");
        assertThat(db.queryForObject("""
                SELECT source_item_id FROM stock_movements WHERE source_doc_id=? AND direction=-1
                """, UUID.class, issueId)).isEqualTo(original.getId());
        assertThat(db.queryForObject("SELECT counterpart_kind FROM goods_weight_observations WHERE source_item_id=?",
                String.class, original.getId())).isEqualTo("SUBCONTRACTOR");
        issues.reverse(issueId);
        assertThat(balance(world.warehouseId(), material)).isEqualByComparingTo("1000");
        assertThat(balanceWeight(world.warehouseId(), material)).isEqualByComparingTo("20");
        assertThat(db.queryForObject("SELECT issued_qty FROM subcontract_material_plan_items WHERE id=?",
                BigDecimal.class, original.getPlanItemId())).isZero();
        assertThat(db.queryForObject("""
                SELECT count(*) FROM subcontract_outbound_issue_reservation_allocations
                WHERE issue_item_id=? AND status='REVERSED'
                """, Integer.class, original.getId())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT stage FROM goods_weight_observations WHERE source_item_id=?",
                String.class, original.getId())).isEqualTo("REVERSED");
    }

    private BigDecimal balance(UUID warehouse, UUID goods) {
        return db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class, warehouse, goods);
    }

    private BigDecimal balanceWeight(UUID warehouse, UUID goods) {
        return db.queryForObject("SELECT weight FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class, warehouse, goods);
    }

    private static <T> T call(Object target, String method, Object... args) {
        return ReflectionTestUtils.invokeMethod(target, method, args);
    }
}
