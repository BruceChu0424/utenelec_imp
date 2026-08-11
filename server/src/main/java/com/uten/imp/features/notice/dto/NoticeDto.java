package com.uten.imp.features.notice.dto;

import java.time.Instant;
import java.util.List;

/**
 * 通知出参（列表/详情/发布回执共用）。
 * isRead/readAt 是当前用户维度；attachments 为文件名数组。
 *
 * <p>互动字段（V224 新增）：interactionMode 派生自 type（none/acknowledge/bless），
 * 庆典字段（subjectName/eventLabel/blessingTemplates）仅 bless 类有值；
 * 计数/我的状态/最近列表用于角标与按钮态，对列表页逐条查询可接受（默认上限 MAX_LIST_ITEMS）。
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
        Instant taskCompletedAt,
        // ---- V224：互动 + 庆典字段（追加在末尾，保持原 19 字段顺序与签名兼容）----
        String interactionMode,
        String subjectName,
        String eventLabel,
        long ackCount,
        long blessingCount,
        boolean myAcked,
        String myBlessing,
        List<String> recentAckers,
        List<NoticeBlessingDto> recentBlessings,
        List<String> blessingTemplates) {
}
