package com.uten.imp.common.finance;
import com.uten.imp.common.web.*;

/** A cash-out allocation is either a period expense or explicitly configured manufacturing cost. */
public enum AccountingExpensePurpose {
    ORDINARY_EXPENSE,MANUFACTURING_COST;
    public static AccountingExpensePurpose parse(String raw){if(raw==null||raw.isBlank())return ORDINARY_EXPENSE;try{return valueOf(raw);}catch(Exception e){throw new ApiException(ErrorCode.VALIDATION_FAILED,"支出类型不正确");}}
}
