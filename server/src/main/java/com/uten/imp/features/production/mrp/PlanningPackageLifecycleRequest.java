package com.uten.imp.features.production.mrp;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** Idempotent cancel/reverse command. */
public record PlanningPackageLifecycleRequest(
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
        @NotBlank @Size(max = 500) String reason) {
}
