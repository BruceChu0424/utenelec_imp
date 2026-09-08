package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SubcontractOrderPreparationPort;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.UUID;

/**
 * 2026-09-05 委外收敛配套：MAKE_THEN 计划行自动启动补偿器。
 *
 * <p>委外准备中心与手工 start 入口退役后，前置生产分析统一由系统自动创建：
 * 新行在批准/改量事务内同步启动；本补偿器每 10 分钟兜底——覆盖历史存量
 * MAKE_THEN 行（此前依赖计划员手工启动）、以及行创建与自动启动之间进程
 * 崩溃留下的缺口。单行失败不阻塞其余行（下一轮重试），行级幂等由
 * preparation_version CAS 保证。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class SubcontractPreparationAutoStartReconciler {

    private final JdbcTemplate jdbc;
    private final SubcontractOrderPreparationPort preparation;
    private final TransactionTemplate transactions;

    @Scheduled(fixedDelay = 600_000, initialDelay = 120_000)
    public void reconcile() {
        List<UUID> pending = jdbc.queryForList("""
                SELECT plan_item.id
                FROM subcontract_material_plan_items plan_item
                JOIN subcontract_material_plans plan
                  ON plan.id = plan_item.plan_id
                 AND plan.status = 'OPEN'
                 AND plan.is_deleted = FALSE
                WHERE plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND plan_item.preparation_status = 'ACTION_REQUIRED'
                  AND plan_item.preparation_analysis_id IS NULL
                  AND plan_item.is_deleted = FALSE
                ORDER BY plan_item.created_at
                LIMIT 50
                """, UUID.class);
        for (UUID planItemId : pending) {
            try {
                transactions.executeWithoutResult(
                        ignored -> preparation.autoStartPlanLinePreparation(
                                planItemId));
            } catch (RuntimeException error) {
                log.warn(
                        "subcontract preparation auto-start failed for plan item {} (will retry): {}",
                        planItemId, error.getMessage());
            }
        }
    }
}
