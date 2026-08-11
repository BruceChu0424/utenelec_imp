package com.uten.imp.features.admin.impersonation.dto;

import java.util.UUID;

/** 模拟会话元数据：供前端横幅展示「正以谁的身份 / 剩余时间 / 只读」。 */
public record ImpersonationMeta(
        UUID actorUserId,             // 真实操作人（admin）
        UUID targetUserId,            // 被模拟的目标
        String targetName,
        String department,
        String position,
        long windowExpiresAtEpochMs,  // 模拟窗口到期时间（毫秒）
        boolean readOnly) {
}
