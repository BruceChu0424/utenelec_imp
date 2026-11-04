package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;

/** A finite assigned book part; the exact source ratio and remainder remain the authority. */
public final class FinancialBookAllocation {
    private FinancialBookAllocation() {}
    public static BigDecimal part(BigDecimal original,BigDecimal beforeOriginal,BigDecimal beforeLocal) {
        if(original==null||beforeOriginal==null||beforeLocal==null||original.signum()<0
                ||beforeOriginal.signum()<=0||beforeLocal.signum()<0||original.compareTo(beforeOriginal)>0)
            throw new ApiException(ErrorCode.CONFLICT,"账面分摊超过同一来源的原币或本币余额");
        if(original.compareTo(beforeOriginal)==0)return FinancialExactAmount.book(beforeLocal,"账面剩余金额");
        return FinancialExactAmount.book(BusinessPrecisionContext.divide(beforeLocal.multiply(original),beforeOriginal,"money.book-share","本次账面金额分摊",FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS),"已确认账面份额");
    }
}
