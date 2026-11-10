package com.uten.imp.features.attachment;

import java.util.UUID;

/**
 * 附件通过授权被取用（下载授权、本地原件下载、在线预览）的领域事件。
 *
 * <p>发布点在权限校验与审计写好之后；消费方（如 {@link AttachmentUsageRecorder}
 * 推进 {@code attachments.last_used_at} 供冷热分层判定访问热度）通过监听器跟进，
 * 与下载主链解耦——下载/预览仍是只读语义，任何热度记录失败不影响下载。
 */
public record AttachmentAccessedEvent(UUID attachmentId) {
}
