package com.uten.imp.features.notice.outbox;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 每日低峰执行 Outbox 大载荷分层（B3）。
 *
 * <p>03:53（错开 03:17 审计归档、03:41 库存分块核对）按批推进，单日封顶
 * {@code max-rows-per-run} 行，控制单次 WAL 与锁持有时长；单批失败下一轮
 * 从头可重放（payload_archived_at 过滤天然幂等），不影响业务投递。
 */
@Slf4j
@Component
@Profile("!cloud")
public class BusinessOutboxPayloadTieringScheduler {

    private final BusinessOutboxPayloadTieringService tiering;
    private final boolean enabled;

    public BusinessOutboxPayloadTieringScheduler(
            BusinessOutboxPayloadTieringService tiering,
            @Value("${uten.outbox.payload-tiering.enabled:true}") boolean enabled) {
        this.tiering = tiering;
        this.enabled = enabled;
    }

    @Scheduled(cron = "0 53 3 * * *", zone = "Asia/Shanghai")
    public void tierDeliveredPayloads() {
        if (!enabled) {
            return;
        }
        try {
            runOnce();
        } catch (Exception e) {
            log.warn("业务事件载荷分层失败(下一轮自动重放,不影响投递): {}", e.toString());
        }
    }

    /** 分层直至无合格行或到达单日上限；返回本次实际迁出行数（测试/运维可直接调用）。 */
    public int runOnce() {
        int total = 0;
        while (total < tiering.maxRowsPerRun()) {
            int archived = tiering.archiveBatch();
            total += archived;
            if (archived < tiering.batchSize()) {
                break;
            }
        }
        if (total > 0) {
            log.info("业务事件载荷分层完成：本次迁出 {} 行，剩余可分层 {} 行",
                    total, tiering.pendingEligibleCount());
        }
        return total;
    }
}
