package com.uten.imp.features.stock;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

/** Revision check, not an authorization or idempotency token. Never exposes cost fields. */
final class StockDocOutboundReviewFingerprint {
    private StockDocOutboundReviewFingerprint() {
    }

    static void requireOutboundType(StockDocument document) {
        if (!"OTHER_OUT".equals(document.getDocType())
                && !"FINISHED_OUT".equals(document.getDocType())) {
            throw new ApiException(ErrorCode.CONFLICT, "仅其它出库和产成品出库支持此核对确认入口");
        }
    }

    static String of(StockDocument document, List<StockDocumentItem> items) {
        requireOutboundType(document);
        List<String> parts = new ArrayList<>();
        add(parts, "header", document.getId(), document.getDocType(), document.getBillNo(),
                document.getBillDate(), document.getWarehouseId(), document.getToWarehouseId(),
                document.getSupplierId(), document.getClientId(), document.getWorkerId(),
                document.getMakerId(), document.getApproverId(), document.getDepartmentId(),
                document.getAssTeam(), document.getStatus(), document.isClosed(), document.isDeleted(),
                document.getPlanNo(), document.getSourceDocNo(), document.getSourceDailyReportId(),
                document.getRemark(), document.getUpdatedAt());
        for (StockDocumentItem item : items) {
            add(parts, "item:" + item.getId(), item.getId(), item.getDocId(), item.getLineNo(),
                    item.getGoodsId(), item.getColorId(), item.getUnitId(), item.getQty(),
                    item.getUnitRate(), item.getBaseQty(), item.getWeight(), item.getGiftQty(),
                    item.getPlace(), item.getUpstreamItemId(), item.getExecutionSegmentId(),
                    item.getExecutionSegmentSalesAllocationId(), item.getSourceDailyReportItemId(),
                    item.getSourceDocNo(), item.getRemark(), item.isDeleted(), item.getUpdatedAt());
        }
        return CanonicalFingerprint.sha256(parts);
    }

    static void requireUnchanged(String expected, StockDocument document,
            List<StockDocumentItem> items) {
        if (expected == null || !expected.matches("[0-9a-f]{64}")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请重新加载出库明细并核对后确认");
        }
        if (document.isClosed() || !expected.equals(of(document, items))) {
            throw new ApiException(ErrorCode.CONFLICT, "出库单据已变化，请刷新后重新核对货品、数量、仓库和来源");
        }
    }

    private static void add(List<String> parts, String prefix, Object... values) {
        for (int index = 0; index < values.length; index++) {
            Object value = values[index];
            String text = value instanceof BigDecimal decimal
                    ? decimal.stripTrailingZeros().toPlainString()
                    : value == null ? "" : value.toString();
            // The null flag keeps null distinct from an empty business value.
            parts.add(prefix + ":" + index + ":" + (value == null ? "null:" : "value:") + text);
        }
    }
}
