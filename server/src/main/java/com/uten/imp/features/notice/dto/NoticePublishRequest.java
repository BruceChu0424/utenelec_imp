package com.uten.imp.features.notice.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
// title 不再 @NotBlank：bless 类通知允许空标题由服务层按 subjectName+eventLabel 自动补全；
// 非 bless 类的空标题校验仍在服务层 publish() 中保留。

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * 发布通知请求。type 默认 announcement；priority 默认 normal。
 * attachments 可选（文件名数组，当前仅展示用）。
 *
 * <p>V224 新增：{@code subjectEmployeeId}（庆典对象，bless 类必填）+
 * {@code blessingTemplates}（发布时预设祝福语模板数组，可选）。
 */
public record NoticePublishRequest(
        @Size(max = RequestLimits.NOTICE_TITLE_LENGTH) String title,
        @NotBlank
        @Size(max = RequestLimits.NOTICE_CONTENT_LENGTH) String content,
        String type,
        Boolean topPriority,
        String priority,
        @Size(max = RequestLimits.NOTICE_ATTACHMENTS) List<String> attachments,
        String audienceScope,
        @Size(max = RequestLimits.NOTICE_AUDIENCE_TARGETS) List<UUID> departmentIds,
        @Size(max = RequestLimits.NOTICE_AUDIENCE_TARGETS) List<UUID> employeeIds,
        String kind,
        @Size(max = 500) String actionRoute,
        Instant dueAt,
        UUID subjectEmployeeId,
        @Size(max = RequestLimits.NOTICE_ATTACHMENTS) List<String> blessingTemplates) {

    /** 兼容模块内测试和旧调用方；旧请求一律按普通通知处理（庆典字段传 null）。 */
    public NoticePublishRequest(
            String title,
            String content,
            String type,
            Boolean topPriority,
            String priority,
            List<String> attachments,
            String audienceScope,
            List<UUID> departmentIds,
            List<UUID> employeeIds) {
        this(title, content, type, topPriority, priority, attachments,
                audienceScope, departmentIds, employeeIds, "NORMAL", null, null, null, null);
    }
}
