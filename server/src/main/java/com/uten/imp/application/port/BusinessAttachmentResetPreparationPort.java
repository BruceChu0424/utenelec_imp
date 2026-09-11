package com.uten.imp.application.port;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/** Test-reset preparation only: reviewed deletion intents, never direct file deletion. */
public interface BusinessAttachmentResetPreparationPort {
    record Item(String type, UUID id, String ownerType, UUID ownerId, String fileName,
                String state, Instant waitUntil, String message) {}
    record Preview(String database, String fingerprint, long blockingCount,
                   List<Item> items, boolean hasMore) {}
    record Confirmation(String database, String fingerprint) {}

    /**
     * 清空前置分类：自动清理（标删→物理删除→完成证明）无法自行消化的一组阻塞项——
     * 按原因分组计数并附前几个文件名，供 409 文案与处置指引使用。
     */
    record UnpurgeableGroup(String reason, long count, List<String> sampleFileNames) {}

    Preview preview(UUID operatorId);
    Preview prepare(UUID operatorId, String operatorAccount, Confirmation confirmation);

    /**
     * 自动清理无法处理的阻塞项（空列表 = 全部可自动清理）：附件非 CLEAN 状态或存储
     * 提供方不在 internal/local；上传凭证尚未到期；删除任务 FAILED 且尝试次数已达告警阈值。
     * 清空业务数据在排水之前调用，命中即快速失败，不进入排水与清理循环。
     */
    List<UnpurgeableGroup> unpurgeableBlockers(UUID operatorId);

    /**
     * 同步排水一条附件对象删除队列任务（含本轮 prepare 入队与历史失败任务）；
     * 返回 false 表示队列已空。清空业务数据在 prepare 之后循环调用，直到空或超时。
     */
    boolean drainNextDeletion();

    /** 删除队列累计已完成（SUCCEEDED 且有完成时间）的对象删除数；清空前后相减即本次物理删除文件数。 */
    long succeededDeletionCount();

    /** 清空成功后清理内部存储遗留的私有临时文件（仅 provider=internal 时有效，否则返回 0）。 */
    int cleanupAbandonedScratch();
}
