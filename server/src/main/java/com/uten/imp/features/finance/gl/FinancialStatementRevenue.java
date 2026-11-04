package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.FinanceCompanyReportAccess;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.common.web.*;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** PL1 is the one revenue basis: main and other operating income, including confirmed Jinben income. */
public final class FinancialStatementRevenue {
    private FinancialStatementRevenue() { }
    public record Value(BigDecimal amount,boolean complete,String basis) { }
    /** Caller owns the same read-only repeatable-read report snapshot; this method never opens another. */
    public static Map<Integer,Value> months(EntityManager em,FinanceDocumentAccessPolicy access,int year,int throughMonth) {
        FinanceCompanyReportAccess.require(access);
        if(year<1||year>9999||throughMonth<1||throughMonth>12)throw new ApiException(ErrorCode.VALIDATION_FAILED,"会计年/月不正确");
        GlReportSourceScopes.assertUnambiguous(em);
        Map<Integer,Value> values=new LinkedHashMap<>();
        new FinancialStatementService(em).revenueMonths(year,throughMonth).forEach((month,value)->
                values.put(month,new Value(value.complete()?value.amount():null,value.complete(),value.basis())));
        return Collections.unmodifiableMap(values);
    }
    public static Value read(EntityManager em,FinanceDocumentAccessPolicy access,int year,int month){return months(em,access,year,month).get(month);}
}
