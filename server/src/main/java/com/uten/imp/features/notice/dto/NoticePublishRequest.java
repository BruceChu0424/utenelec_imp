package com.uten.imp.features.notice.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * 发布通知请求。type 默认 announcement；priority 默认 normal。
 * attachments 可选（文件名数组，当前仅展示用）。
 */
public record NoticePublishRequest(
        @NotBlank
        @Size(max = RequestLimits.NOTICE_TITLE_LENGTH) String title,
        @NotBlank
        @Size(max = RequestLimits.NOTICE_CONTENT_LENGTH) String content,
        String type,
        Boolean topPriority,
        String priority,
        @Size(max = RequestLimits.NOTICE_ATTACHMENTS) List<String> attachments,
        String audienceScope,
        @Size(max = RequestLimits.NOTICE_AUDIENCE_TARGETS) List<UUID> departmentIds,
        @Size(max = RequestLimits.NOTICE_AUDIENCE_TARGETS) List<UUID> employeeIds) {
}
