package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;

/** Converts a reviewed total-coverage intent into the existing incremental write contract. */
final class MaterialOrderQuantity {
    private MaterialOrderQuantity() { }

    static boolean skipClaims(String method, boolean legacy) {
        if (method==null) return legacy;
        return switch(method) {
            case "ORDER_ALL" -> true;
            case "AVAILABLE_ONLY", "AVAILABLE_THEN_ORDER" -> false;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED,"下单方式不正确");
        };
    }

    static boolean availableOnly(String method) {
        skipClaims(method,false);
        return "AVAILABLE_ONLY".equals(method);
    }

    /** Legacy quantities order only the new external shortage; their existing root-stock
     * handover is independent. Explicit coverage totals bound both operations. */
    static BigDecimal existingRootStockCeiling(BigDecimal requested,String mode,BigDecimal required) {
        if(mode==null)return required;
        if(!"COVERAGE_TOTAL".equals(mode))throw new ApiException(ErrorCode.VALIDATION_FAILED,"下单数量口径不正确");
        return requested;
    }

    static BigDecimal physicalClaimCeiling(BigDecimal requested,String mode,BigDecimal required,BigDecimal uncoveredBeforeShared) {
        if(mode==null)return requested;
        if(!"COVERAGE_TOTAL".equals(mode))throw new ApiException(ErrorCode.VALIDATION_FAILED,"下单数量口径不正确");
        if(uncoveredBeforeShared==null)throw new ApiException(ErrorCode.CONFLICT,"缺少本行已落实覆盖的权威数量，请刷新后重新核对");
        return requested.subtract(required.subtract(uncoveredBeforeShared).max(BigDecimal.ZERO)).max(BigDecimal.ZERO);
    }

    static BigDecimal incremental(BigDecimal requested, String mode, BigDecimal required, BigDecimal uncovered) {
        return incremental(requested,mode,required,uncovered,null);
    }

    static BigDecimal incremental(BigDecimal requested, String mode, BigDecimal required, BigDecimal uncovered,String method) {
        if (mode == null) return requested;
        if (!"COVERAGE_TOTAL".equals(mode)) throw new ApiException(ErrorCode.VALIDATION_FAILED,"下单数量口径不正确");
        if ("ORDER_ALL".equals(method)) return requested;
        if (required == null || uncovered == null) throw new ApiException(ErrorCode.CONFLICT,"缺少权威需求覆盖数量，请刷新后重新核对");
        // Existing private stock and effective orders already satisfy this demand. A row policy
        // may skip NEW public adoption, but never releases or duplicates existing ownership.
        BigDecimal covered = required.subtract(uncovered).max(BigDecimal.ZERO);
        return requested.subtract(covered).max(BigDecimal.ZERO);
    }
}
