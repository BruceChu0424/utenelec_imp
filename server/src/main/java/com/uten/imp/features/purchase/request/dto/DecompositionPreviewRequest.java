package com.uten.imp.features.purchase.request.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** Selected purchase-demand lines to validate before procurement decomposes them into orders. */
public record DecompositionPreviewRequest(
        @NotNull
        @Size(min = 1, max = 200, message = "采购申请明细数量须为 1 至 200 条")
        List<@NotNull UUID> itemIds) {
}
