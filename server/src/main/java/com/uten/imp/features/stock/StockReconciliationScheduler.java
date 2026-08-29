package com.uten.imp.features.stock;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 库存余额↔流水每日对账（P0 数据准确性防线）。
 *
 * <p>每天 08:51 跑一次（错开 08:23 延期预警 / 08:37 预留持有扫描）。只读校验、只告警，
 * 绝不自动改账；漂移修复必须走 CHECK 盘点或授权余额调整单等永久留痕途径。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class StockReconciliationScheduler {

    private final StockReconciliationService reconciliation;

    @Scheduled(cron = "0 51 8 * * *", zone = "Asia/Shanghai")
    public void scan() {
        try {
            reconciliation.scanAndWarn();
        } catch (Exception e) {
            log.warn("库存对账扫描失败(不影响业务): {}", e.toString());
        }
    }
}
