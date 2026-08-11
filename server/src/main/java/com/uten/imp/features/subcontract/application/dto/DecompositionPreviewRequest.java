package com.uten.imp.features.subcontract.application.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** Selected subcontract-demand lines to validate before the outsourcing team creates orders. */
public record DecompositionPreviewRequest(
        @NotNull
        @Size(min = 1, max = 200, message = "委外申请明细数量须为 1 至 200 条")
        List<@NotNull UUID> itemIds) {
}
