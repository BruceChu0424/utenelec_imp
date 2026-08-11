package com.uten.imp.features.notice.dto;

/** 发布前由服务端重算的接收范围摘要。 */
public record NoticeAudiencePreviewDto(
        String summary,
        int recipientCount) {
}
