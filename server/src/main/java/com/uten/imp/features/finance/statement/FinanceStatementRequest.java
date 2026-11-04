package com.uten.imp.features.finance.statement;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.web.*;
import java.util.UUID;

/** Shared context for interactive reads and callers retaining the legacy controller signatures. */
public final class FinanceStatementRequest {
    private FinanceStatementRequest() { }
    static boolean template() {
        String layout=parameter("layout");
        if(layout==null||layout.isBlank())return false;
        if(!"template".equals(layout))throw invalid("对账单表样无效");
        return true;
    }
    static UUID id(String key) {
        String raw=parameter(key);if(raw==null||raw.isBlank())return null;
        try{return UUID.fromString(raw);}catch(IllegalArgumentException ex){throw invalid("请选择有效的往来对象或币别");}
    }
    static boolean allMaterialContexts(){return allMaterialContexts(parameter("allMaterialContexts"));}
    public static boolean allMaterialContexts(String raw){
        if(raw==null||raw.isBlank())return true;
        if("true".equalsIgnoreCase(raw.trim()))return true;
        if("false".equalsIgnoreCase(raw.trim()))return false;
        throw invalid("材料原表分组范围无效，请明确选择原范围");
    }
    private static String parameter(String key) {
        var request=ColumnKeywordSearch.currentRequest();if(request==null)return null;
        String[] values=request.getParameterValues(key);
        if(values!=null&&values.length!=1)throw invalid("对账单参数不能重复："+key);
        return values==null?null:values[0];
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
