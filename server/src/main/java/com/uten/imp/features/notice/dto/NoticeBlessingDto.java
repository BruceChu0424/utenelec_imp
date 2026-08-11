package com.uten.imp.features.notice.dto;

import java.time.Instant;

/**
 * 通知祝福列表项。{@code mine=true} 表示属于当前登录用户（前端高亮「我」、提供撤回按钮）。
 */
public record NoticeBlessingDto(
        String id,
        String senderName,
        String content,
        Instant createdAt,
        boolean mine) {
}
