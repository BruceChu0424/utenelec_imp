package com.uten.imp.features.warehouse.materialbin.close;

import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间内料仓自动结算的定时补做 (ADR-131 §5.8)。
 *
 * <p>每 10 分钟选已盘点、还没结算的期间逐期尝试结算: 提交盘点后的异步结算因服务重启丢了投递、
 * 被拦的期间补完了单重或报工、撤销结算后保留期到了, 都由这里接上。连续失败 3 次的期间改为每天一次;
 * 同一内料仓按期号顺序尝试, 单期失败不影响其它期。操作人记该期最新一版盘点的提交人。
 */
@Slf4j
@Component
@Profile("!cloud")
public class WorkshopMaterialCloseScheduler {

    static final int BATCH_SIZE = 50;

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialCloseService closes;

    @Value("${uten.workshop-material.auto-close.enabled:true}")
    private boolean enabled = true;

    public WorkshopMaterialCloseScheduler(NamedParameterJdbcTemplate db, WorkshopMaterialCloseService closes) {
        this.db = db;
        this.closes = closes;
    }

    /** 由既有 DrainAwareTaskScheduler 控制清空业务数据期间的准入。 */
    @Scheduled(fixedDelay = 600_000, initialDelay = 180_000)
    public void retry() {
        if (enabled) runBatch();
    }

    /** 补做一轮; 返回尝试的期数。 */
    public int runBatch() {
        List<Map<String, Object>> due;
        try {
            due = db.queryForList("""
                    SELECT period.id,
                           (SELECT counted.submitted_by FROM workshop_material_counts counted
                            WHERE counted.period_id = period.id AND counted.status = 'SUBMITTED'
                            ORDER BY counted.version DESC LIMIT 1) AS actor
                    FROM workshop_material_periods period
                    WHERE period.status = 'COUNTED'
                      AND (period.close_state IN ('QUEUED', 'BLOCKED')
                           OR (period.close_state = 'FAILED'
                               AND (period.close_failures < :backoff
                                    OR period.close_attempted_at IS NULL
                                    OR period.close_attempted_at <= now() - interval '1 day'))
                           OR (period.close_state = 'HELD' AND period.held_until <= now()))
                    ORDER BY period.bin_warehouse_id, period.period_no
                    LIMIT :limit
                    """, Map.of("backoff", WorkshopMaterialCloseService.FAILURE_BACKOFF, "limit", BATCH_SIZE));
        } catch (RuntimeException error) {
            log.warn("车间内料仓自动结算候选读取未完成, 错误类型 {}, 下一轮继续", error.getClass().getSimpleName());
            return 0;
        }
        int attempted = 0;
        for (Map<String, Object> row : due) {
            UUID period = (UUID) row.get("id");
            UUID actor = (UUID) row.get("actor");
            if (actor == null) continue;
            attempted++;
            try {
                closes.attempt(period, TriggerKind.SCHEDULED, actor);
            } catch (RuntimeException error) {
                log.warn("车间内料仓自动结算未完成, 期间 {}, 错误类型 {}", period, error.getClass().getSimpleName());
            }
        }
        return attempted;
    }
}
