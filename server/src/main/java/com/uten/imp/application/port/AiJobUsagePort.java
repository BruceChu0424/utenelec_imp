package com.uten.imp.application.port;

import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * 业务保存路径读取与消费 AI 识别任务结果的出口(ADR-133)。学习与版式登记必须以服务端保存的任务结果为准,
 * 不信任请求体里回传的识别内容。
 */
public interface AiJobUsagePort {

    /**
     * 读取任务结果: 只有提交人本人、任务已成功且结果尚未清空时返回; 其余情况(不存在、不是本人、未成功、
     * 已清空)一律返回空, 不区分原因。返回的是未经读者过滤的完整结果, 只供服务端内部使用。
     */
    Optional<Map<String, Object>> resultFor(UUID jobId, UUID userId);

    /**
     * Pin an owned successful result to one saved document while its confirmed learning is retryable.
     * {@code retryUntil} is the receipt's database-computed deadline; it is bounded in SQL with the same clock/calendar.
     */
    default boolean reserveLearning(UUID jobId, UUID userId, String docType, UUID docId, java.time.OffsetDateTime retryUntil) {
        return false;
    }

    /** Transactional reservation only: validate saved source keys in SQL without returning source contents. */
    default boolean reserveLearningForSave(UUID jobId, UUID userId, String docType, UUID docId,
            java.time.OffsetDateTime retryUntil, java.util.Set<String> sourceKeys, boolean headerUsed) {
        return false;
    }

    /**
     * 标记任务结果已被保存进某张单据({@code docType} 为 {@code quote} 或 {@code order}), 并在同一次写入里
     * 清空结果(result_purged_at)。不是本人的任务静默忽略。没有「采用后仍可读」的保留期: 同一次保存里所有需要
     * 结果的一方必须在标记<b>之前</b>读好(销售保存: 版式登记是最先执行的提交后回调, 主档学习排在最后并最后标记)。
     */
    void markUsed(UUID jobId, UUID userId, String docType, UUID docId);
}
