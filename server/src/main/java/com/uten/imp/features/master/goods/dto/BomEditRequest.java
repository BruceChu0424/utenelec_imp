package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/** An ordered edit draft. Preview and commit always carry the same complete draft. */
public record BomEditRequest(
        @NotEmpty @Size(max = 500) List<@Valid @NotNull Operation> operations,
        @NotEmpty @Size(max = 500) List<@Valid @NotNull Snapshot> snapshots,
        @Size(max = 100) String previewToken,
        Boolean confirmSharedChanges) {

    public enum Type { CREATE, UPDATE, DELETE, MOVE, UPDATE_GOODS }

    public record Snapshot(@NotNull UUID goodsId, @NotBlank @Size(max = 64) String fingerprint) { }

    public record Operation(
            @NotNull Type type,
            UUID goodsId,
            UUID itemId,
            UUID clientItemId,
            @Valid BomItemSaveRequest body,
            @Size(max = 500) List<@NotNull UUID> itemIds,
            @Size(max = 500) List<BomMoveRequest.@Valid @NotNull Move> moves,
            @Min(0) Long goodsVersion,
            @Size(max = 4) Map<String, JsonNode> goodsChanges) {
        public Operation(Type type, UUID goodsId, UUID itemId, UUID clientItemId,
                         BomItemSaveRequest body, List<UUID> itemIds, List<BomMoveRequest.Move> moves) {
            this(type, goodsId, itemId, clientItemId, body, itemIds, moves, null, null);
        }
    }
}
