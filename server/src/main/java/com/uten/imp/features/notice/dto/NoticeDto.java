package com.uten.imp.features.notice.dto;

import java.time.Instant;
import java.util.List;

/**
 * 通知出参（列表/详情/发布回执共用）。
 * isRead/readAt 是当前用户维度；attachments 为文件名数组。
 */
public record NoticeDto(
        String id,
        String title,
        String content,
        String type,
        String publisher,
        Instant publishedAt,
        boolean isRead,
        Instant readAt,
        boolean topPriority,
        String priority,
        List<String> attachments,
        String audienceScope,
        String audienceSummary,
        Integer audienceCount,
        String kind,
        String actionRoute,
        Instant dueAt,
        boolean taskCompleted,
        Instant taskCompletedAt) {
}
