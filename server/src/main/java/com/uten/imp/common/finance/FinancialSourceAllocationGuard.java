package com.uten.imp.common.finance;

import com.uten.imp.common.web.*;
import java.math.BigDecimal;
import java.util.List;

/** One exact-decimal and conservation guard for expense attribution and labor splits. */
public final class FinancialSourceAllocationGuard {
    private FinancialSourceAllocationGuard() { }
    public static BigDecimal amount(String raw,boolean optional){
        if(raw==null||raw.isBlank()){if(optional)return null;throw invalid("金额不能为空");}
        if(raw.length()>256)throw invalid("金额原文过长");
        try{return com.uten.imp.common.util.FinancialExactAmount.book(new BigDecimal(raw),"分配金额");}
        catch(NumberFormatException e){throw invalid("金额须为有效十进制原文");}
    }
    public static void singleSource(BigDecimal source,List<BigDecimal> shares){
        BigDecimal sum=BigDecimal.ZERO;for(var share:shares){if(share==null||source.signum()*share.signum()<0||source.signum()==0&&share.signum()!=0)throw invalid("分配方向须与原分录一致");sum=sum.add(share);}
        if(sum.compareTo(source)!=0)throw invalid("分配合计必须与原分录本币金额完全一致");
    }
    public static void separatePools(BigDecimal positive,BigDecimal negative,BigDecimal directPositive,BigDecimal indirectPositive,BigDecimal directNegative,BigDecimal indirectNegative){
        for(var value:List.of(positive,negative,directPositive,indirectPositive,directNegative,indirectNegative))if(value.signum()<0)throw invalid("正向/红字池请分别填写非负金额");
        if(directPositive.add(indirectPositive).compareTo(positive)!=0||directNegative.add(indirectNegative).compareTo(negative)!=0)
            throw invalid("正向与红字分配须分别等于原工资源池，不能只按净额轧平");
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
