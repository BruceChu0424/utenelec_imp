package com.uten.imp.features.production.fulfillment;

import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.UUID;

/** Repairs missed arrival callbacks through the original atomic complete-kit command. */
@Slf4j
@Component
@Profile("!cloud")
public class ProductionReadinessReconciler {
    static final int BATCH_SIZE = 25;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transactions;
    private final TransactionTemplate readTransactions;
    private final ProductionPlanMutationFootprintService footprint;
    private final ProductionExecutionReadinessService readiness;
    @Value("${uten.production.readiness-reconcile.enabled:true}")
    private boolean enabled = true;
    private UUID cursor;

    public ProductionReadinessReconciler(JdbcTemplate jdbc, PlatformTransactionManager transactionManager,
            ProductionPlanMutationFootprintService footprint, ProductionExecutionReadinessService readiness) {
        this.jdbc = jdbc;
        this.footprint = footprint;
        this.readiness = readiness;
        this.transactions = new TransactionTemplate(transactionManager);
        this.transactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.transactions.setTimeout(6);
        this.readTransactions = new TransactionTemplate(transactionManager);
        this.readTransactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.readTransactions.setReadOnly(true);
        this.readTransactions.setTimeout(3);
    }

    /** The existing DrainAwareTaskScheduler controls admission during business-data reset. */
    @Scheduled(initialDelay = 5_000, fixedDelay = 60_000)
    public void reconcile() {
        if (enabled) runBatch();
    }

    public synchronized int runBatch() {
        List<Candidate> candidates;
        try {
            candidates = readTransactions.execute(ignored -> {
                jdbc.queryForObject("SELECT set_config('statement_timeout','2s',true)", String.class);
                return candidates();
            });
        } catch (RuntimeException error) {
            log.warn("本轮自动核对备料候选读取未完成，错误类型 {}，后续轮次继续核对", error.getClass().getSimpleName());
            return 0;
        }
        if (candidates == null) return 0;
        long started = System.nanoTime();
        int processed = 0;
        for (Candidate candidate : candidates) {
            if (processed > 0 && System.nanoTime() - started > 3_000_000_000L) break;
            cursor = candidate.segmentId();
            processed++;
            try {
                transactions.executeWithoutResult(ignored -> {
                    jdbc.queryForObject("SELECT set_config('lock_timeout','500ms',true)", String.class);
                    jdbc.queryForObject("SELECT set_config('statement_timeout','5s',true)", String.class);
                    footprint.lockPlan(candidate.planId(), List.of());
                    readiness.reconcileWaitingSegment(candidate.planId(), candidate.segmentId(), candidate.warehouseId());
                });
            } catch (RuntimeException error) {
                log.warn("自动核对备料暂未完成，执行段 {}，错误类型 {}，后续轮次继续核对",
                        candidate.segmentId(), error.getClass().getSimpleName());
            }
        }
        if (processed == candidates.size() && candidates.size() < BATCH_SIZE) cursor = null;
        return processed;
    }

    private List<Candidate> candidates() {
        // A developer may start new classes before applying their migration.
        // Keep old-schema startup quiet; never attempt partially available system writes.
        if (!Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT to_regprocedure('public.fn_guard_system_readiness_formalize_actor()') IS NOT NULL", Boolean.class))) {
            return List.of();
        }
        return jdbc.query("""
                SELECT segment.id,segment.plan_id,package.warehouse_id
                FROM production_execution_segments segment
                JOIN production_planning_packages package ON package.id=segment.package_id
                    AND package.status='CONFIRMED' AND package.execution_model_version=1 AND NOT package.is_deleted
                JOIN production_plans plan ON plan.id=segment.plan_id AND plan.status=1 AND NOT plan.is_deleted
                    AND NOT COALESCE(plan.is_closed,FALSE) AND NOT COALESCE(plan.is_canceled,FALSE)
                    AND NOT COALESCE(plan.is_stopped,FALSE)
                WHERE segment.status='WAITING' AND segment.auto_promote_when_ready AND NOT segment.is_deleted
                  AND (?::uuid IS NULL OR segment.id>?::uuid)
                  AND EXISTS (
                    SELECT 1 FROM production_material_demands demand
                    JOIN stock_balances stock ON stock.goods_id=demand.goods_id
                        AND stock.color_id IS NOT DISTINCT FROM demand.color_id AND stock.qty>0
                    JOIN warehouses warehouse ON warehouse.id=stock.warehouse_id
                        AND NOT warehouse.is_deleted AND warehouse.is_accountable
                        AND NOT EXISTS (SELECT 1 FROM warehouses child WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)
                    WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
                      AND demand.status NOT IN ('RELEASED','REVERSED')
                      AND (fn_warehouse_same_main(warehouse.id,package.warehouse_id) OR EXISTS (
                        SELECT 1 FROM stock_reservations source
                        JOIN v_preplan_stock_entitlement_beneficiary_balance owned ON owned.stock_reservation_id=source.id
                            AND owned.effective_qty>0 AND owned.beneficiary_analysis_id=plan.material_analysis_id
                            AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,owned.beneficiary_analysis_material_id)
                        WHERE source.warehouse_id=stock.warehouse_id AND source.goods_id=stock.goods_id
                          AND source.color_id IS NOT DISTINCT FROM stock.color_id
                          AND fn_preplan_reservation_has_qualified_origin(source.id))))
                ORDER BY segment.id LIMIT 25
                """, (rs, row) -> new Candidate(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class),
                        rs.getObject(3, UUID.class)), cursor, cursor);
    }

    record Candidate(UUID segmentId, UUID planId, UUID warehouseId) {}
}
