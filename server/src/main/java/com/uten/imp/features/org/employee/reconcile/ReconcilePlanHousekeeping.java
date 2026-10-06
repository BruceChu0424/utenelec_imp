package com.uten.imp.features.org.employee.reconcile;

import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.OffsetDateTime;

/**
 * 员工资料核对计划的定时清理(V810/ADR-160), 每 10 分钟一次, 每步一个短事务:
 * <ul>
 *   <li>超过 24 小时有效期还没执行完的计划以 EXPIRED 关闭, 未执行项的旧值/新值/候选密文一并清掉;</li>
 *   <li>卡死的更正轮(APPLYING 超过 applying_until)回收: 计划回 OPEN、RUNNING 回执置 INTERRUPTED。</li>
 * </ul>
 * 已执行项是更正记录, 与员工档案一样长期保留, 本任务不删。业务数据清空期间由排水调度器自动跳过本轮。
 */
@Slf4j
@Component
public class ReconcilePlanHousekeeping {

    private final ReconcilePlanStore store;
    private final TransactionTemplate tx;

    public ReconcilePlanHousekeeping(ReconcilePlanStore store, PlatformTransactionManager transactionManager) {
        this.store = store;
        this.tx = new TransactionTemplate(transactionManager);
        this.tx.setTimeout(30);
    }

    @Scheduled(fixedDelayString = "${uten.employee-reconcile.housekeeping-delay-ms:600000}",
            initialDelayString = "${uten.employee-reconcile.housekeeping-initial-delay-ms:120000}")
    public void purge() {
        OffsetDateTime now = OffsetDateTime.now();
        int expired = inTx(() -> store.purgeExpired(now));
        int reclaimed = inTx(() -> store.reclaimStaleApplying(now));
        if (expired + reclaimed > 0) {
            log.info("员工资料核对计划清理: {} 个过期计划已关闭并清掉未执行项密文, {} 个卡死的更正轮已回收; 已执行的更正记录保留",
                    expired, reclaimed);
        }
    }

    private int inTx(java.util.function.IntSupplier work) {
        Integer value = tx.execute(status -> work.getAsInt());
        return value == null ? 0 : value;
    }
}
