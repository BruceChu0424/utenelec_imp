package com.uten.imp.features.master.goods.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** Only the selected goods' direct canonical relations are maintained. */
public record BomBatchMaintenanceRequest(
        @NotNull Action action,
        @NotEmpty @Size(max = 50) List<@NotNull UUID> targetGoodsIds,
        @Size(max = 200) List<@Valid @NotNull BomItemSaveRequest> items,
        @Size(max = 500) List<@NotNull UUID> componentGoodsIds) {
    public enum Action { ADD, REMOVE, OVERWRITE }
}
