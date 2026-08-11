package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;

/** Fail-closed close gate for the two corporate posting runs and GL reconciliation. */
public final class AssetPeriodClosePolicy {

    private AssetPeriodClosePolicy() {}

    public static void requireClosable(Evidence evidence) {
        if (!evidence.depreciationPosted() || !evidence.amortizationPosted()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "Both depreciation and amortization require an effective posted run, including zero runs");
        }
        if (evidence.blockingExceptionCount() != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "Posting runs still contain blocking exceptions");
        }
        if (evidence.subledgerAmount().compareTo(evidence.glDebitAmount()) != 0
                || evidence.glDebitAmount().compareTo(evidence.glCreditAmount()) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "Asset subledger does not reconcile with the general ledger");
        }
    }

    public record Evidence(
            boolean depreciationPosted,
            boolean amortizationPosted,
            int blockingExceptionCount,
            BigDecimal subledgerAmount,
            BigDecimal glDebitAmount,
            BigDecimal glCreditAmount) {
        public Evidence {
            if (blockingExceptionCount < 0) throw new IllegalArgumentException("negative exception count");
            if (subledgerAmount == null || glDebitAmount == null || glCreditAmount == null) {
                throw new IllegalArgumentException("reconciliation amounts are required");
            }
        }
    }
}
