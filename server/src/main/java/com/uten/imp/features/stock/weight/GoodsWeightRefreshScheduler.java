package com.uten.imp.features.stock.weight;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 单重学习夜间刷新 (ADR-135 §5): 每天 02:13 补算漏掉的货品 (事件派发失败、设置改动) 以及算法升级后
 * 需要重算的货品。单重只随数据变化, 不随日期漂移 (衰减以最近一次称重为基准), 所以这里只是兜底。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class GoodsWeightRefreshScheduler {

    /** 每晚最多重算的货品数, 超出的留到下一晚。 */
    static final int NIGHTLY_LIMIT = 5000;

    private final GoodsWeightEstimateService estimates;

    @Scheduled(cron = "0 13 2 * * *", zone = "Asia/Shanghai")
    public void refresh() {
        try {
            int done = estimates.refreshStale(NIGHTLY_LIMIT);
            if (done > 0) {
                log.info("单重学习夜间刷新: 重算 {} 个货品", done);
            }
        } catch (Exception e) {
            log.warn("单重学习夜间刷新失败(不影响业务): {}", e.toString());
        }
    }
}
