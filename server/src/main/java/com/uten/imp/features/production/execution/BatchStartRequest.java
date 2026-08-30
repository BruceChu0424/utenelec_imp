package com.uten.imp.features.production.execution;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** Atomic start command for at most one hundred exact execution segments. */
public record BatchStartRequest(
        @NotEmpty @Size(max = 100) List<@Valid @NotNull Item> items) {

    public record Item(
            @NotNull UUID segmentId,
            @NotNull Long expectedVersion,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
    }
}
