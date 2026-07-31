package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;

/**
 * Physical-count quantity rules.
 *
 * <p>The client may display an adjustment preview, but the server owns both
 * the book snapshot and the final adjustment. A count is safe to approve only
 * while the current balance still equals the snapshot captured with the draft.
 */
final class StockCountPolicy {

    private StockCountPolicy() {}

    static BigDecimal requireCountQuantity(BigDecimal countQty, int lineNo) {
        if (countQty == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "第 " + lineNo + " 行必须填写实盘数量");
        }
        if (countQty.signum() < 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "第 " + lineNo + " 行实盘数量不能小于 0");
        }
        return countQty;
    }

    static BigDecimal adjustment(BigDecimal bookQty, BigDecimal countQty) {
        BigDecimal safeBook = bookQty == null ? BigDecimal.ZERO : bookQty;
        BigDecimal safeCount = countQty == null ? BigDecimal.ZERO : countQty;
        return safeCount.subtract(safeBook);
    }

    static void requireSnapshotUnchanged(
            BigDecimal snapshotQty, BigDecimal currentQty, int lineNo) {
        BigDecimal safeSnapshot = snapshotQty == null ? BigDecimal.ZERO : snapshotQty;
        BigDecimal safeCurrent = currentQty == null ? BigDecimal.ZERO : currentQty;
        if (safeSnapshot.compareTo(safeCurrent) != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "第 " + lineNo + " 行盘点期间库存已变化：快照 "
                            + plain(safeSnapshot) + "，当前 " + plain(safeCurrent)
                            + "。请刷新账面数量并重新核对实盘数后再审核");
        }
    }

    private static String plain(BigDecimal value) {
        return value.stripTrailingZeros().toPlainString();
    }
}
