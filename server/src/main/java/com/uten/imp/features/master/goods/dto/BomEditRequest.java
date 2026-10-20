package com.uten.imp.features.master.goods.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** An ordered edit draft. Preview and commit always carry the same complete draft. */
public record BomEditRequest(
        @NotEmpty @Size(max = 500) List<@Valid @NotNull Operation> operations,
        @NotEmpty @Size(max = 500) List<@Valid @NotNull Snapshot> snapshots,
        @Size(max = 100) String previewToken,
        Boolean confirmSharedChanges) {

    public enum Type { CREATE, UPDATE, DELETE, MOVE }

    public record Snapshot(@NotNull UUID goodsId, @NotBlank @Size(max = 64) String fingerprint) { }

    public record Operation(
            @NotNull Type type,
            UUID goodsId,
            UUID itemId,
            UUID clientItemId,
            @Valid BomItemSaveRequest body,
            @Size(max = 500) List<@NotNull UUID> itemIds,
            @Size(max = 500) List<BomMoveRequest.@Valid @NotNull Move> moves) { }
}
