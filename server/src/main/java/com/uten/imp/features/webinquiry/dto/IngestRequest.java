package com.uten.imp.features.webinquiry.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 官网询盘推送载荷（POST /api/website-inquiries/ingest）。
 * 字段与官网 inquiries 表一一对应；sourceId 为官网记录 id，重推幂等。
 */
public record IngestRequest(
        @NotBlank @Size(max = 64) String sourceId,
        @NotBlank @Size(max = 80) String name,
        @Size(max = 40) String phone,
        @Size(max = 160) String email,
        @Size(max = 160) String company,
        @Size(max = 120) String market,
        @Size(max = 32) String customerType,
        @Size(max = 160) String requiredStandard,
        @Size(max = 240) String productInterest,
        @Size(max = 32) String requestType,
        @Size(max = 120) String estimatedQuantity,
        @Size(max = 120) String targetSchedule,
        @Size(max = 80) String preferredContact,
        @NotBlank @Size(max = 3000) String message,
        @Size(max = 24) String source,
        @Size(max = 8) String locale
) {
}
