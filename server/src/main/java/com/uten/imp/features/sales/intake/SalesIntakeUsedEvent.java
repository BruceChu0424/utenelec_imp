package com.uten.imp.features.sales.intake;

import java.util.UUID;

/**
 * 客户文件识别结果被一张报价单/订货单保存采用(ADR-134)。
 * 由报价/订货保存流程在事务内发布; 识别模块在提交后(AFTER_COMMIT)据此学习表格版式,
 * 学习失败不影响单据保存。版式与列角色一律取服务端识别记录, 不信任请求体。
 */
public record SalesIntakeUsedEvent(UUID jobId, UUID userId, String docType, UUID docId, UUID clientId) {
}
