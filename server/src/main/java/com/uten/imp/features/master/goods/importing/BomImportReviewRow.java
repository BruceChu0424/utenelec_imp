package com.uten.imp.features.master.goods.importing;

import java.util.List;
import java.util.UUID;

/** A stable, selectable BOM-edge difference in the uploaded workbook. */
public record BomImportReviewRow(
        String rowKey, int rowNum, UUID goodsId, String code, String name,
        String categoryPath, String matchType, String scope, String seq, UUID parentGoodsId,
        List<Change> changes) {
    public BomImportReviewRow { changes = List.copyOf(changes); }

    public boolean hasConflict() {
        return changes.stream().anyMatch(change -> "CONFLICT".equals(change.kind()));
    }

    public record Change(String field, String label, String oldValue, String newValue, String kind) {}
}
