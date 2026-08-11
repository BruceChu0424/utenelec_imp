package com.uten.imp.features.production.schedule.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/** 待排产 BOM 缺失转发工程研发部请求（POST /api/production/schedule/forward-rd）。 */
public record ForwardBomGapRequest(
        @NotNull UUID orderItemId,
        @Size(max = 1000) String note) {
}
