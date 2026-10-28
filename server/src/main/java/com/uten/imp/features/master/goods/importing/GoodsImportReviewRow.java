package com.uten.imp.features.master.goods.importing;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** The server-authoritative, nonblank changes proposed for one existing goods row. */
public record GoodsImportReviewRow(
        String rowKey,
        int rowNum,
        UUID goodsId,
        String code,
        String name,
        String categoryPath,
        String matchType,
        List<Change> changes) {
    public record Change(String field, String label, Object oldValue, Object newValue, String kind) {
        public Change {
            // Review values cross JavaScript's numeric boundary; keep decimal
            // text exact, including significant fractional trailing zeros.
            if (oldValue instanceof BigDecimal decimal) oldValue = decimal.toPlainString();
            if (newValue instanceof BigDecimal decimal) newValue = decimal.toPlainString();
        }
    }
}
