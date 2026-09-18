package com.uten.imp.features.production.execution;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * 「确认生产路线」请求(V599 / ADR-091)：车间在开工前显式选定
 * FULL_KIT(齐套生产) / BATCH(分批生产) / CONTINUOUS(持续生产)。
 */
public record SegmentRouteConfirmRequest(
        @NotNull Long expectedVersion,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
        @NotNull @Pattern(regexp = "FULL_KIT|BATCH|CONTINUOUS",
                message = "开工路线必须是 FULL_KIT、BATCH 或 CONTINUOUS") String route) {
}
