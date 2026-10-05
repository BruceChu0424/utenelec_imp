package com.uten.imp.features.ai.job;

import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.chat.AiChatActionProposalService;
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

    public AiJobHousekeeping(AiJobRepository repository, AiCallLogService callLogs, AiProperties properties,
                             PlatformTransactionManager transactionManager, AiChatActionProposalService proposals) {
        this.repository = repository;
        this.callLogs = callLogs;
        this.properties = properties;
        this.proposals = proposals;
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
        int logs = callLogs.purgeOlderThanDays(Math.max(1, properties.getCallLogRetentionDays()));
        int cards = proposals.expireAndPurge(Math.max(1, properties.getJobRetentionDays()));
        if (stale + purged + deleted + logs + cards > 0) {
            log.info("AI history retention: {} stale queued job(s) failed, {} result-bearing job(s) archived, {} job(s) archived,"
                    + " {} call log(s) archived, {} confirmation card(s) expired or removed; contents preserved",
                    stale, purged, deleted, logs, cards);
        }
    }

    private int inTx(java.util.function.IntSupplier work) {
        Integer value = tx.execute(status -> work.getAsInt());
        return value == null ? 0 : value;
    }
}
