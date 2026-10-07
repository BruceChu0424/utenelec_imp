package com.uten.imp.features.ai.job;

import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.chat.AiChatActionProposalService;
import com.uten.imp.features.ai.chat.AiChatOperationMemoryService;
import com.uten.imp.features.ai.gateway.AiCallLogService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * AI 数据清理(ADR-133), 每 10 分钟一次, 每步一个短事务:
 * <ul>
 *   <li>排队超过 {@code pending-timeout-minutes}(默认 30 分钟)还没开始的任务判失败并清空上传文件;</li>
 *   <li>结果: 结束超过 {@code result-retention-hours}(默认 48 小时)的清空(被单据采用的结果在采用时已清空);</li>
 *   <li>任务行: 已结束且超过 {@code job-retention-days}(默认 7 天)的删除;</li>
 *   <li>调用技术记录: 超过 {@code call-log-retention-days}(默认 180 天)的删除;</li>
 *   <li>AI 确认卡(ADR-150): 过了 10 分钟还没确认的标成已过期; 发出超过 {@code job-retention-days} 的删除
 *       (谁在什么时候确认/取消了什么仍留在审计日志)。</li>
 *   <li>个人操作记忆(ADR-163): 超过 {@code operation-memory-retention-days}(默认 90 天)没再使用的删除
 *       (本人随时可在设置里自行清除)。</li>
 *   <li>用量日汇总(ADR-164): 把 ai_call_logs 按人按日归档进 ai_usage_daily(终日回填 + 昨天/今日重算,
 *       昨天重算并入跨天尾巴), 在调用记录归档之前跑, 支撑月/年视图。</li>
 * </ul>
 * 业务数据清空期间由排水调度器自动跳过本轮。
 */
@Slf4j
@Component
@Profile("!cloud")
public class AiJobHousekeeping {

    private final AiJobRepository repository;
    private final AiCallLogService callLogs;
    private final AiProperties properties;
    private final TransactionTemplate tx;
    private final AiChatActionProposalService proposals;
    private final AiChatOperationMemoryService operationMemory;
    private final com.uten.imp.features.ai.usage.AiUsageDailyService usageDaily;

    public AiJobHousekeeping(AiJobRepository repository, AiCallLogService callLogs, AiProperties properties,
                             PlatformTransactionManager transactionManager, AiChatActionProposalService proposals,
                             AiChatOperationMemoryService operationMemory,
                             com.uten.imp.features.ai.usage.AiUsageDailyService usageDaily) {
        this.repository = repository;
        this.callLogs = callLogs;
        this.properties = properties;
        this.proposals = proposals;
        this.operationMemory = operationMemory;
        this.usageDaily = usageDaily;
        this.tx = new TransactionTemplate(transactionManager);
        this.tx.setTimeout(30);
    }

    @Scheduled(fixedDelayString = "${uten.ai.housekeeping-delay-ms:600000}",
            initialDelayString = "${uten.ai.housekeeping-initial-delay-ms:120000}")
    public void purge() {
        int stale = inTx(() -> repository.failStalePending(Math.max(1, properties.getPendingTimeoutMinutes())));
        int purged = inTx(() -> repository.purgeResults(Math.max(1, properties.getResultRetentionHours())));
        int deleted = 0;
        for (int batch = 0; batch < 50; batch++) {
            int count = inTx(() -> repository.deleteFinishedOlderThan(Math.max(1, properties.getJobRetentionDays())));
            deleted += count;
            if (count < 1000) {
                break;
            }
        }
        // 用量日汇总(ADR-164)在调用记录归档之前跑: 归档目前是软删(行保留、也计入), 但先汇总再清理
        // 让「即使将来改成硬删」也不丢当日用量。
        var usage = usageDaily.rollup();
        int logs = callLogs.purgeOlderThanDays(Math.max(1, properties.getCallLogRetentionDays()));
        int cards = proposals.expireAndPurge(Math.max(1, properties.getJobRetentionDays()));
        int forgotten = operationMemory.purgeUnused(Math.max(1, properties.getOperationMemoryRetentionDays()));
        if (stale + purged + deleted + logs + cards + forgotten > 0 || usage.backfilled() > 0) {
            log.info("AI history retention: {} stale queued job(s) failed, {} result-bearing job(s) archived, {} job(s) archived,"
                    + " {} call log(s) archived, {} confirmation card(s) expired or removed, {} operation memory row(s) forgotten;"
                    + " {} usage day(s) backfilled, {} user(s) usage refreshed today; contents preserved",
                    stale, purged, deleted, logs, cards, forgotten, usage.backfilled(), usage.refreshed());
        }
    }

    private int inTx(java.util.function.IntSupplier work) {
        Integer value = tx.execute(status -> work.getAsInt());
        return value == null ? 0 : value;
    }
}
