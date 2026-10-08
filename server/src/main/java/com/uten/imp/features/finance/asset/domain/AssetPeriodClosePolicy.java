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
                    "折旧和摊销都要先生成生效的过账批次（金额为 0 也要过账），才能关闭期间");
        }
        if (evidence.blockingExceptionCount() != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "过账批次里还有必须先处理的问题，不能关闭期间");
        }
        if (evidence.subledgerAmount().compareTo(evidence.glDebitAmount()) != 0
                || evidence.glDebitAmount().compareTo(evidence.glCreditAmount()) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "资产明细账与总账对不上，不能关闭期间");
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
