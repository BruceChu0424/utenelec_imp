package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/** Imported cash facts are historical evidence, never commands to post money again. */
public final class FinanceLegacyRecordGuard {
    private FinanceLegacyRecordGuard() { }

    public static void requireMutable(Integer legacyId) {
        if (legacyId != null) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "历史资金记录仅供核对，不能通过日常操作修改或再次记账；如需更正请先核对历史来源");
        }
    }
}
