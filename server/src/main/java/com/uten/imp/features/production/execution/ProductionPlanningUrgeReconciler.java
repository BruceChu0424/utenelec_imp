package com.uten.imp.features.production.execution;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 车间催计划(ADR-117)的后台兜底核对：每 5 分钟看一批在催记录，计划已下够单或任务已结束的办结，
 * 并撤回发给计划员的待办卡。计划员在物料分析页下单后页面会立即核对一次，这里兜住不经物料分析页
 * 的变化(采购 / 委外模块直接改单、到货入库、任务完工或取消)。
 *
 * <p>只动催办记录与通知，不改任何数量。一轮失败只记警告，下一轮继续。
 */
@Slf4j
@Component
@Profile("!cloud")
public class ProductionPlanningUrgeReconciler {
    static final int BATCH_SIZE = 50;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transactions;
    private final ProductionPlanningUrgeService urges;
    @Value("${uten.production.planning-urge-reconcile.enabled:true}")
    private boolean enabled = true;

    public ProductionPlanningUrgeReconciler(JdbcTemplate jdbc, PlatformTransactionManager transactionManager,
                                            ProductionPlanningUrgeService urges) {
        this.jdbc = jdbc;
        this.urges = urges;
        this.transactions = new TransactionTemplate(transactionManager);
        this.transactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.transactions.setTimeout(30);
    }

    /** 由既有 DrainAwareTaskScheduler 控制清空业务数据期间的准入。 */
    @Scheduled(initialDelay = 120_000, fixedDelay = 300_000)
    public void reconcile() {
        if (enabled) runBatch();
    }

    public synchronized int runBatch() {
        try {
            // 开发者可能先启动新代码再迁移：表还没有时安静跳过。
            if (!Boolean.TRUE.equals(jdbc.queryForObject(
                    "SELECT to_regclass('public.production_planning_urges') IS NOT NULL", Boolean.class))) {
                return 0;
            }
            Integer resolved = transactions.execute(ignored -> {
                jdbc.queryForObject("SELECT set_config('lock_timeout','2s',true)", String.class);
                return urges.reconcileOpen(BATCH_SIZE);
            });
            return resolved == null ? 0 : resolved;
        } catch (RuntimeException error) {
            log.warn("车间催计划核对本轮未完成，错误类型 {}，下一轮继续", error.getClass().getSimpleName());
            return 0;
        }
    }
}
