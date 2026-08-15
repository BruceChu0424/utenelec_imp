package com.uten.imp.features.webinquiry.dto;

import java.time.Instant;
import java.util.UUID;

/** 官网询盘列表行。 */
public record WebsiteInquiryListItem(
        UUID id,
        String name,
        String company,
        String phone,
        String email,
        String market,
        String customerType,
        String productInterest,
        String requestType,
        String source,
        String locale,
        String status,
        UUID assigneeEmployeeId,
        String assigneeName,
        UUID clientId,
        Instant receivedAt
) {
}
