package com.uten.imp.features.admin.serverstatus;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 治理任务完成回执写穿（V954）的纯内存行为验证：
 * 只有持久证据任务落库、高频任务不落、写库失败不影响任务执行本身。
 */
class ScheduledTaskRunPersistenceTest {

    /** 记录调用并可选抛错的假持久层。 */
    private static final class RecordingStore extends ScheduledTaskRunStore {
        final AtomicInteger appended = new AtomicInteger();
        String failMessage;

        RecordingStore() {
            super(null);
        }

        @Override
        public void append(String taskKey, Instant startedAt, Instant finishedAt,
                           Long durationMs, String errorType) {
            if (failMessage != null) {
                throw new IllegalStateException(failMessage);
            }
            appended.incrementAndGet();
        }

        @Override
        public Map<String, PersistedRun> latestRuns(java.util.Collection<String> taskKeys) {
            return Map.of();
        }
    }

    private static void runOnce(ScheduledTaskRunRegistry registry, String key,
                                Throwable failure) {
        registry.started(key, Instant.now().minusSeconds(5));
        registry.finished(key, Instant.now(), failure);
    }

    @Test
    void durableGovernanceTasksPersistTheirCompletedRuns() {
        RecordingStore store = new RecordingStore();
        ScheduledTaskRunRegistry registry = new ScheduledTaskRunRegistry();
        org.springframework.test.util.ReflectionTestUtils.setField(registry, "runStore", store);

        runOnce(registry, "AuditRetentionScheduler.runScheduled", null);
        runOnce(registry, "BusinessOutboxPayloadTieringScheduler.tierDeliveredPayloads",
                new IllegalStateException("模拟分层失败"));
        runOnce(registry, "BusinessOutboxScheduler.drain", null);

        // 只有目录登记的持久证据任务写穿; 高频派发不写。
        assertThat(store.appended.get()).isEqualTo(2);
        // 注册表自身的内存观测语义不受写穿影响。
        assertThat(registry.snapshot().stream()
                .filter(run -> run.name().equals("BusinessOutboxScheduler.drain"))
                .findFirst().orElseThrow().runs()).isEqualTo(1L);
    }

    @Test
    void persistenceFailureNeverBreaksTheObservedTask() {
        RecordingStore store = new RecordingStore();
        store.failMessage = "数据库暂时不可用";
        ScheduledTaskRunRegistry registry = new ScheduledTaskRunRegistry();
        org.springframework.test.util.ReflectionTestUtils.setField(registry, "runStore", store);

        runOnce(registry, "StockMonthlyVerificationScheduler.verifyChunk", null);
        // 写穿抛错被吞掉: finished() 正常返回, 内存注册表照常更新。
        assertThat(registry.snapshot()).hasSize(1);
        assertThat(store.appended.get()).isZero();
    }

    @Test
    void durableSetStaysWithinCatalogEntries() {
        for (String key : ScheduledTaskCatalog.durableEvidenceTasks()) {
            assertThat(ScheduledTaskCatalog.describe(key))
                    .as("持久证据任务 %s 必须同时登记在目录里", key)
                    .isPresent();
        }
        // 目录登记的持久证据任务必须真实存在 @Scheduled 方法（由 ScheduledTaskCatalogTest 全量对账）。
        List<String> durable = List.copyOf(ScheduledTaskCatalog.durableEvidenceTasks());
        assertThat(durable).contains(
                "AuditRetentionScheduler.runScheduled",
                "BusinessOutboxPayloadTieringScheduler.tierDeliveredPayloads",
                "BusinessArchiveEligibilityScheduler.scan");
    }
}
