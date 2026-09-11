package com.uten.imp.features.production.quality;

import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.saleschain.SalesOrderChainSql;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** FQC FAIL contribution rollback and traceable replacement-attempt capacity. */
@Service
@RequiredArgsConstructor
public class ProductionFqcRecoveryService implements ProductionFqcRecoveryPort {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionFqcReplenishmentMaterialService materialRecovery;
    private final ProductionQualityMutationFootprintService mutationFootprint;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyFailureAdjustment(
            UUID inspectionId,
            UUID decisionEventId,
            BigDecimal failQty,
            String dispositionCode) {
        tx.bind();
        if (inspectionId == null || decisionEventId == null
                || failQty == null || failQty.signum() <= 0) {
            throw validation("FQC 失败贡献回退缺少有效来源或数量");
        }
        mutationFootprint.requireInspection(inspectionId);
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT adjustment.adjusted_qty,
                                       recovery_auth.authorized_qty,
                                       adjustment.inspection_id,
                                       recovery_auth.disposition_code
                                FROM production_fqc_contribution_adjustments adjustment
                                JOIN production_fqc_recovery_authorizations recovery_auth
                                  ON recovery_auth.source_decision_event_id =
                                     adjustment.decision_event_id
                                WHERE adjustment.decision_event_id = :decisionId
                                """)
                        .setParameter("decisionId", decisionEventId));
        if (!replay.isEmpty()) {
            if (decimal(replay.getFirst()[0]).compareTo(failQty) != 0
                    || decimal(replay.getFirst()[1]).compareTo(failQty) != 0
                    || !inspectionId.equals(replay.getFirst()[2])
                    || !java.util.Objects.equals(
                            dispositionCode, replay.getFirst()[3])) {
                throw conflict("FQC 失败决定已绑定不同的贡献回退数量");
            }
            return;
        }

        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT inspection.source_report_item_id,
                                       inspection.source_plan_item_id,
                                       inspection.execution_segment_id,
                                       inspection.execution_segment_sales_allocation_id,
                                       inspection.warehouse_id,
                                       inspection.goods_id, inspection.color_id,
                                       inspection.unit_id, inspection.unit_rate,
                                       decision.fail_qty,
                                       decision.disposition_code
                                FROM production_fqc_inspections inspection
                                JOIN production_fqc_decision_events decision
                                  ON decision.id = :decisionId
                                 AND decision.inspection_id = inspection.id
                                JOIN production_plan_items plan_item
                                  ON plan_item.id = inspection.source_plan_item_id
                                 AND plan_item.is_deleted = FALSE
                                WHERE inspection.id = :inspectionId
                                FOR UPDATE OF inspection, decision, plan_item
                                """)
                        .setParameter("inspectionId", inspectionId)
                        .setParameter("decisionId", decisionEventId));
        if (rows.size() != 1
                || decimal(rows.getFirst()[9]).compareTo(failQty) != 0
                || !java.util.Objects.equals(rows.getFirst()[10], dispositionCode)) {
            throw conflict("FQC 失败决定与原报工身份或数量不一致");
        }
        Object[] source = rows.getFirst();
        UUID planItemId = (UUID) source[1];
        int planUpdated = em.createNativeQuery("""
                        UPDATE production_plan_items
                        SET fqty = COALESCE(fqty, 0) - :qty
                        WHERE id = :planItemId
                          AND COALESCE(fqty, 0) >= :qty
                        """)
                .setParameter("qty", failQty)
                .setParameter("planItemId", planItemId)
                .executeUpdate();
        if (planUpdated != 1) {
            throw conflict("生产计划有效报工累计不足，FQC 失败未回退");
        }

        UUID salesAllocationId = (UUID) source[3];
        if (salesAllocationId != null) {
            List<Object[]> links = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT allocation.plan_order_item_link_id,
                                           allocation.sales_order_item_id,
                                           order_item.order_id
                                    FROM execution_segment_sales_allocations allocation
                                    JOIN plan_order_item_links link
                                      ON link.id = allocation.plan_order_item_link_id
                                     AND link.is_deleted = FALSE
                                    JOIN sales_order_items order_item
                                      ON order_item.id = allocation.sales_order_item_id
                                    WHERE allocation.id = :allocationId
                                    """)
                            .setParameter("allocationId", salesAllocationId));
            if (links.size() != 1) {
                throw conflict("FQC 失败数量缺少精确销售分摊");
            }
            List<?> lockedSales = em.createNativeQuery("""
                            SELECT order_item.id
                            FROM sales_order_items order_item
                            JOIN sales_orders order_header
                              ON order_header.id = order_item.order_id
                            WHERE order_item.id = :orderItemId
                              AND order_header.id = :orderId
                            ORDER BY order_header.id, order_item.id
                            FOR UPDATE OF order_header, order_item
                            """)
                    .setParameter("orderItemId", links.getFirst()[1])
                    .setParameter("orderId", links.getFirst()[2])
                    .getResultList();
            List<?> lockedLinks = em.createNativeQuery("""
                            SELECT id
                            FROM plan_order_item_links
                            WHERE id = :linkId AND is_deleted = FALSE
                            FOR UPDATE
                            """)
                    .setParameter("linkId", links.getFirst()[0])
                    .getResultList();
            if (lockedSales.size() != 1 || lockedLinks.size() != 1) {
                throw conflict("FQC 失败数量的销售订单或分摊已并发失效");
            }
            int linkUpdated = em.createNativeQuery("""
                            UPDATE plan_order_item_links
                            SET produced_qty = COALESCE(produced_qty, 0) - :qty,
                                updated_at = now()
                            WHERE id = :linkId
                              AND COALESCE(produced_qty, 0) >= :qty
                            """)
                    .setParameter("qty", failQty)
                    .setParameter("linkId", links.getFirst()[0])
                    .executeUpdate();
            if (linkUpdated != 1) {
                throw conflict("销售分摊有效报工累计不足，FQC 失败未回退");
            }
            // V545 统一派生：仍有有效报工量则留在 5，否则退回已排产；其余分支按数量收敛。
            em.createNativeQuery("UPDATE sales_order_items order_item SET chain_status = "
                            + SalesOrderChainSql.chainStatusCaseSql(
                                    SalesOrderChainSql.ChainStatusInputs.of("order_item")
                                            .producing(SalesOrderChainSql.hasReportedQtySql("order_item")))
                            + " WHERE order_item.id = :orderItemId")
                    .setParameter("orderItemId", links.getFirst()[1])
                    .executeUpdate();
        }

        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_contribution_adjustments(
                            id, inspection_id, decision_event_id,
                            source_report_item_id, source_plan_item_id,
                            execution_segment_sales_allocation_id,
                            adjusted_qty, created_by)
                        VALUES (
                            gen_random_uuid(), :inspectionId, :decisionId,
                            :reportItemId, :planItemId, :salesAllocationId,
                            :qty, :actorId)
                        """)
                .setParameter("inspectionId", inspectionId)
                .setParameter("decisionId", decisionEventId)
                .setParameter("reportItemId", source[0])
                .setParameter("planItemId", planItemId)
                .setParameter("salesAllocationId", salesAllocationId)
                .setParameter("qty", failQty)
                .setParameter("actorId", actorId)
                .executeUpdate();
        UUID authorizationId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_recovery_authorizations(
                            id, source_inspection_id,
                            source_decision_event_id, source_report_item_id,
                            source_plan_item_id, execution_segment_id,
                            execution_segment_sales_allocation_id,
                            warehouse_id,
                            goods_id, color_id, unit_id, unit_rate,
                            authorized_qty, disposition_code,
                            idempotency_key, created_by)
                        VALUES (
                            :authorizationId, :inspectionId,
                            :decisionId, :reportItemId, :planItemId,
                            :segmentId, :salesAllocationId,
                            :warehouseId, :goodsId, :colorId, :unitId, :unitRate,
                            :qty, :dispositionCode, :key, :actorId)
                        """)
                .setParameter("authorizationId", authorizationId)
                .setParameter("inspectionId", inspectionId)
                .setParameter("decisionId", decisionEventId)
                .setParameter("reportItemId", source[0])
                .setParameter("planItemId", planItemId)
                .setParameter("segmentId", source[2])
                .setParameter("salesAllocationId", salesAllocationId)
                .setParameter("warehouseId", source[4])
                .setParameter("goodsId", source[5])
                .setParameter("colorId", source[6])
                .setParameter("unitId", source[7])
                .setParameter("unitRate", source[8])
                .setParameter("qty", failQty)
                .setParameter("dispositionCode", dispositionCode)
                .setParameter("key", "FQC-RECOVERY:" + decisionEventId)
                .setParameter("actorId", actorId)
                .executeUpdate();
        if ("SCRAP".equals(dispositionCode)
                || "REJECT".equals(dispositionCode)) {
            em.createNativeQuery("""
                            INSERT INTO production_fqc_replenishment_tasks(
                                id, authorization_id, created_by)
                            VALUES (gen_random_uuid(), :authorizationId, :actorId)
                            """)
                    .setParameter("authorizationId", authorizationId)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void allocateApprovedRecoveryReportItem(
            UUID reportItemId,
            UUID authorizationId,
            BigDecimal quantity) {
        tx.bind();
        if (reportItemId == null || authorizationId == null
                || quantity == null || quantity.signum() <= 0) {
            throw validation("返工/补产报工缺少恢复授权或数量");
        }
        em.createNativeQuery("""
                        INSERT INTO production_fqc_recovery_allocation_events(
                            id, authorization_id, recovery_report_item_id,
                            event_type, qty, idempotency_key, created_by)
                        VALUES (
                            gen_random_uuid(), :authorizationId, :reportItemId,
                            'ALLOCATE', :qty, :key, :actorId)
                        ON CONFLICT DO NOTHING
                        """)
                .setParameter("authorizationId", authorizationId)
                .setParameter("reportItemId", reportItemId)
                .setParameter("qty", quantity)
                .setParameter("key", "FQC-RECOVERY-ALLOCATE:" + reportItemId)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        List<Object[]> persisted = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT allocation.authorization_id,
                                       allocation.recovery_report_item_id,
                                       allocation.qty, allocation.event_type
                                FROM production_fqc_recovery_allocation_events allocation
                                WHERE allocation.recovery_report_item_id = :reportItemId
                                  AND allocation.event_type = 'ALLOCATE'
                                """)
                        .setParameter("reportItemId", reportItemId));
        if (persisted.size() != 1
                || !authorizationId.equals(persisted.getFirst()[0])
                || !reportItemId.equals(persisted.getFirst()[1])
                || decimal(persisted.getFirst()[2]).compareTo(quantity) != 0
                || !"ALLOCATE".equals(persisted.getFirst()[3])) {
            throw conflict("返工/补产报工幂等键已绑定不同的恢复授权或数量");
        }
    }

    @Override
    @Transactional(readOnly = true, propagation = Propagation.MANDATORY)
    public BigDecimal effectiveContribution(
            UUID reportItemId,
            BigDecimal declaredQuantity) {
        if (reportItemId == null || declaredQuantity == null) {
            throw validation("报工红冲缺少明细或数量");
        }
        Object adjusted = em.createNativeQuery("""
                        SELECT COALESCE(SUM(adjustment.adjusted_qty), 0)
                        FROM production_fqc_contribution_adjustments adjustment
                        WHERE adjustment.source_report_item_id = :reportItemId
                        """)
                .setParameter("reportItemId", reportItemId)
                .getSingleResult();
        BigDecimal result = declaredQuantity.subtract(decimal(adjusted));
        if (result.signum() < 0) {
            throw conflict("FQC 失败回退超过原报工数量");
        }
        return result;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseReportEffects(UUID reportId) {
        tx.bind();
        UUID actorId = currentUser.requireId();
        List<Object[]> allocations = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT allocation.id, allocation.authorization_id,
                                       allocation.recovery_report_item_id,
                                       allocation.qty
                                FROM production_fqc_recovery_allocation_events allocation
                                JOIN production_daily_report_items item
                                  ON item.id = allocation.recovery_report_item_id
                                WHERE item.report_id = :reportId
                                  AND allocation.event_type = 'ALLOCATE'
                                  AND NOT EXISTS (
                                      SELECT 1
                                      FROM production_fqc_recovery_allocation_events release
                                      WHERE release.source_allocation_event_id = allocation.id
                                        AND release.event_type = 'RELEASE')
                                ORDER BY allocation.id
                                """)
                        .setParameter("reportId", reportId));
        for (Object[] allocation : allocations) {
            em.createNativeQuery("""
                            INSERT INTO production_fqc_recovery_allocation_events(
                                id, authorization_id, recovery_report_item_id,
                                event_type, qty, source_allocation_event_id,
                                idempotency_key, created_by)
                            VALUES (
                                gen_random_uuid(), :authorizationId, :reportItemId,
                                'RELEASE', :qty, :sourceId, :key, :actorId)
                            """)
                    .setParameter("authorizationId", allocation[1])
                    .setParameter("reportItemId", allocation[2])
                    .setParameter("qty", allocation[3])
                    .setParameter("sourceId", allocation[0])
                    .setParameter("key", "FQC-RECOVERY-RELEASE:" + allocation[0])
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
        List<UUID> childAuthorizations = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT recovery_auth.id
                                FROM production_fqc_recovery_authorizations recovery_auth
                                JOIN production_daily_report_items source_item
                                  ON source_item.id = recovery_auth.source_report_item_id
                                WHERE source_item.report_id = :reportId
                                  AND NOT EXISTS (
                                      SELECT 1 FROM production_fqc_recovery_cancellation_events c
                                      WHERE c.authorization_id = recovery_auth.id)
                                ORDER BY recovery_auth.id
                                """, UUID.class)
                        .setParameter("reportId", reportId), UUID.class);
        for (UUID authorizationId : childAuthorizations) {
            materialRecovery.beforeAuthorizationCancellation(authorizationId);
            em.createNativeQuery("""
                            INSERT INTO production_fqc_recovery_cancellation_events(
                                id, authorization_id, source_report_id,
                                reason_code, idempotency_key, created_by)
                            VALUES (
                                gen_random_uuid(), :authorizationId, :reportId,
                                'SOURCE_REPORT_REVERSED', :key, :actorId)
                            """)
                    .setParameter("authorizationId", authorizationId)
                    .setParameter("reportId", reportId)
                    .setParameter("key", "FQC-RECOVERY-CANCEL:" + authorizationId)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
    }

    @Override
    @Transactional(readOnly = true, propagation = Propagation.MANDATORY)
    public void requireLegacyExemption(UUID reportItemId) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_fqc_legacy_exemptions
                        WHERE source_report_item_id = :reportItemId
                        """)
                .setParameter("reportItemId", reportItemId)
                .getSingleResult();
        if (count == null || count.longValue() != 1) {
            throw conflict("缺少 FQC inspection 且不属于 V414 历史豁免，禁止继续");
        }
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
