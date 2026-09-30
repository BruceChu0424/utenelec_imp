package com.uten.imp.features.sales.intake;

import java.util.UUID;
import java.util.List;

/**
 * 客户文件识别结果被一张报价单/订货单保存采用(ADR-134)。
 * 由报价/订货保存流程在事务内、明细落库之后发布(userId 为保存人, 须与识别任务提交人相同才能读到结果)。
 * 识别模块在事务提交后(最先执行的提交后回调, 各自独立的事务)读取服务端识别记录里的表格版式并写入学习到的版式;
 * 保存回滚则什么都不做,
 * 学习失败不影响单据保存。版式与列角色一律取服务端识别记录, 不信任请求体。
 */
public record SalesIntakeUsedEvent(UUID jobId, UUID userId, String docType, UUID docId, UUID clientId,
                                   List<String> sourceLineKeys, UUID learningReceiptId) {
    public SalesIntakeUsedEvent(UUID jobId, UUID userId, String docType, UUID docId, UUID clientId, List<String> sourceLineKeys) {
        this(jobId, userId, docType, docId, clientId, sourceLineKeys, null);
    }
    /** Legacy internal producers did not carry selected line keys. */
    public SalesIntakeUsedEvent(UUID jobId, UUID userId, String docType, UUID docId, UUID clientId) {
        this(jobId, userId, docType, docId, clientId, null, null);
    }

    public SalesIntakeUsedEvent {
        sourceLineKeys = sourceLineKeys == null ? null : sourceLineKeys.stream()
                .filter(java.util.Objects::nonNull).filter(key -> !key.isBlank()).distinct().toList();
    }
}
