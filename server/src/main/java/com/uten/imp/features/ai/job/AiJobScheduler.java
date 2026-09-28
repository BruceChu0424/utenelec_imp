package com.uten.imp.features.ai.job;

import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * AI 识别任务的轮询兜底(ADR-133): 每 5 秒回收过期租约并唤醒后台线程。只做唤醒, 真正的处理在
 * {@link AiJobWorker} 的专用线程上, 不占用共享的定时任务线程; 业务数据清空期间由排水调度器自动跳过。
 */
@Component
@Profile("!cloud")
public class AiJobScheduler {

    private final AiJobWorker worker;

    public AiJobScheduler(AiJobWorker worker) {
        this.worker = worker;
    }

    @Scheduled(fixedDelayString = "${uten.ai.job-poll-delay-ms:5000}",
            initialDelayString = "${uten.ai.job-poll-initial-delay-ms:15000}")
    public void poll() {
        worker.recoverAndWake();
    }
}
