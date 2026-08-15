package com.uten.imp.features.webinquiry.dto;

import java.time.Instant;
import java.util.UUID;

/** 官网询盘详情（含完整留言与跟进信息）。 */
public record WebsiteInquiryDetail(
        UUID id,
        String sourceId,
        String name,
        String phone,
        String email,
        String company,
        String market,
        String customerType,
        String requiredStandard,
        String productInterest,
        String requestType,
        String estimatedQuantity,
        String targetSchedule,
        String preferredContact,
        String message,
        String source,
        String locale,
        String status,
        UUID assigneeEmployeeId,
        String assigneeName,
        UUID clientId,
        String clientName,
        String note,
        Instant receivedAt
) {
}
