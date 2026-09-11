package com.uten.imp.features.attachment;

import java.util.UUID;

/** 附件物理删除完成后清理其派生预览缓存；由删除 Outbox 在成功路径调用。 */
@FunctionalInterface
public interface AttachmentPreviewEvictor {
    void evict(UUID attachmentId);
}
