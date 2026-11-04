package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.*;
import java.util.*;

/** Original category membership is explicit source evidence, never a numeric-prefix inference. */
final class FinanceChartClassification {
    private FinanceChartClassification() { }
    static final Map<String,String> SOURCE=source();
    static final Map<String,Set<String>> ALLOWED=Map.of("ASSET",Set.of("ACCOUNT"),"COST",Set.of("ACCOUNT"),
            "LIABILITY",Set.of("LIABILITY"),"EQUITY",Set.of("EQUITY"),"PROFIT",Set.of("INCOME","EXPENSE"));
    private static Map<String,String> source() {
        var result=new LinkedHashMap<String,String>();for(var group:FinanceTemplateContract.template("chartCodes").path("classifications")) {
            for(var code:group.path("codes"))result.put(code.asText(),group.path("id").asText());}return Map.copyOf(result);
    }
    static String resolve(String code,String explicit,String category) {
        String value=explicit==null?SOURCE.get(code):explicit;
        if(value==null&&category!=null)value=switch(category){case "INCOME","EXPENSE"->"PROFIT";case "LIABILITY"->"LIABILITY";case "EQUITY"->"EQUITY";default->null;};
        if(value!=null&&!ALLOWED.containsKey(value))throw new ApiException(ErrorCode.VALIDATION_FAILED,"财务类别不正确，请按原表选择资产、负债、权益、成本或损益");
        if(value!=null&&category!=null&&!ALLOWED.get(value).contains(category))throw new ApiException(ErrorCode.VALIDATION_FAILED,"财务类别与核算类别不一致；成本不能当作已结转损益");
        return value;
    }
}
