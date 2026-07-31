package com.uten.imp.features.production.execution;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

public record SegmentTransitionRequest(
        @NotNull Long expectedVersion,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
}
