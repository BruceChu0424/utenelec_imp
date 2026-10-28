package com.uten.imp.features.finance.report;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 往来月度汇总后台排水（B2）。每隔数秒按 (side, party, month) 全序批量重算
 * 脏键；读取路径另有同步自愈，本调度只负责预热与积压收敛，失败下一轮重试
 * （脏键未删即未完成，天然可重放）。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class PartyMonthlySummaryScheduler {

    private final PartyMonthlySummaryService summaries;

    @Value("${uten.finance.party-summary.drain-batch:25}")
    private int drainBatch;

    @Scheduled(
            fixedDelayString = "${uten.finance.party-summary.drain-interval-ms:5000}",
            initialDelayString = "${uten.finance.party-summary.initial-delay-ms:15000}")
    public void drain() {
        try {
            summaries.drain(drainBatch);
        } catch (Exception e) {
            // 并发重算同一脏键可能撞行锁/死锁检测；脏键仍在，下一轮继续，无需告警升级。
            log.debug("往来月度汇总排水本轮未完成，下一轮重试: {}", e.toString());
        }
    }
}
