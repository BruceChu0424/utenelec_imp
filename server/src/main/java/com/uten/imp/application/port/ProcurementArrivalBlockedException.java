package com.uten.imp.application.port;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/**
 * Signals that receipt posting was stopped after a durable finance-review task
 * was written. Receipt approval uses noRollbackFor for this exact exception only.
 */
public final class ProcurementArrivalBlockedException extends ApiException {

    public ProcurementArrivalBlockedException(String message) {
        super(ErrorCode.ARRIVAL_EXCEPTION_PENDING, message);
    }
}
