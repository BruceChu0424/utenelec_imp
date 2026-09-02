package com.uten.imp.features.notice.dto;

import java.time.Instant;
import java.util.List;

/**
 * 通知出参（列表/详情/发布回执共用）。
 * isRead/readAt 是当前用户维度；attachments 为文件名数组。
 *
 * <p>互动字段（新增）：interactionMode 派生自 type（none/acknowledge/bless），
 * 庆典字段（subjectName/eventLabel/blessingTemplates）仅 bless 类有值；
 * 计数/我的状态/最近列表用于角标与按钮态，对列表页逐条查询可接受（默认上限 MAX_LIST_ITEMS）。
 *
 * <p>V454：subjects 为主角名单快照（聚合卡逐人姓名+标签，周年年数各自不同；
 * 单人卡一行；非庆典类为空列表）。subjectName/eventLabel 继续作为单人卡主展示，
 * 聚合卡 subjectName 为「张三、李四等 N 人」摘要。
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
        // ---- 互动 + 庆典字段（保持原字段顺序）----
        String interactionMode,
        String subjectName,
        String eventLabel,
        long ackCount,
        long blessingCount,
        boolean myAcked,
        String myBlessing,
        List<String> recentAckers,
        List<NoticeBlessingDto> recentBlessings,
        List<String> blessingTemplates,
        String sourceEvent,
        // ---- V454：主角名单（聚合卡逐人姓名+标签；单人卡一行；非庆典类空列表）----
        List<NoticeCelebrationSubjectDto> subjects) {
}
