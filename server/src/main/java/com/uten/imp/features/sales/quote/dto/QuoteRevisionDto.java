package com.uten.imp.features.sales.quote.dto;

import java.time.OffsetDateTime;

/**
 * 报价核价修订记录一行(时间线展示)。actionLabel 是给人看的中文动作名, reason 为退回原因或说明。
 */
public record QuoteRevisionDto(
        int revision,
        String action,
        String actionLabel,
        String actorName,
        String reason,
        OffsetDateTime createdAt,
        com.fasterxml.jackson.databind.JsonNode snapshot) {
}
