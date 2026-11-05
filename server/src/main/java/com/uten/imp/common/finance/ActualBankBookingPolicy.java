package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.time.Instant;
import java.time.OffsetDateTime;

/** Actual money may only be approved after its recorded bank instant has occurred. */
public final class ActualBankBookingPolicy {
    private ActualBankBookingPolicy() { }

    /** Invoke at the actual approval/posting boundary, never while saving a draft. */
    public static void requireOccurred(OffsetDateTime bookedAt,String label) {
        requireOccurred(bookedAt,Instant.now(),label);
    }

    static void requireOccurred(OffsetDateTime bookedAt,Instant now,String label) {
        String field=label==null||label.isBlank()?"银行实际记账时间":label;
        if(bookedAt==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,field+"必须填写");
        if(bookedAt.toInstant().isAfter(now))throw new ApiException(ErrorCode.VALIDATION_FAILED,
                field+"尚未发生，不能审核为实际收付款；原输入已保留，请在实际发生后再审核");
    }
}
