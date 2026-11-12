package com.uten.imp.features.production.mrp;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Idempotent cancel/reverse command. 原因选填(2026-11-11 口径「弹窗原因不用必填」)：
 * 留空由落库方归一为「未填写」(production_planning_packages.lifecycle_reason 可空)。
 */
public record PlanningPackageLifecycleRequest(
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
        @Size(max = 500) String reason) {
}
