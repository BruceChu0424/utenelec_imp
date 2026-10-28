package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Read-only displayed physical fields, evaluated after the original visible-item relation. */
final class WarehousePhysicalDetailHeaders {
    private WarehousePhysicalDetailHeaders() { }
    private static final Set<String> TEXT=Set.of("goodsName","goodsCode","colorName","unitName","baseUnitName",
            "stockPlace","place","lotId","sourceReportItemId","stockDocumentNos","decisionReason");
    private static final Set<String> NUMBERS=Set.of("quantity","orderedQty","acceptedQty","approvedRemainingQty",
            "requestedQuantity","issuedQuantity","countedQty","giftQty","unacceptedQty","passedBaseQty",
            "failedBaseQty","stockedBaseQty","weightKg","weight");

    static SqlColumnSearch.Criteria criteria(Map<String,String> filters,String json) {
        Map<String,SqlColumnSearch.Field> fields=new LinkedHashMap<>();
        TEXT.forEach(key->fields.put(key,SqlColumnSearch.Field.text("coalesce("+text(json,key)+",'—')")));
        NUMBERS.forEach(key->fields.put(key,SqlColumnSearch.Field.decimal(number(json,key))));
        return SqlColumnSearch.criteria(filters,fields,"warehouse_detail_");
    }
    static String order(String column,String direction,String json) {
        if(direction!=null&&!Set.of("asc","desc").contains(direction.toLowerCase(java.util.Locale.ROOT)))throw invalid();
        String fallback="CAST(coalesce("+json+"->>'lineNo',"+json+"->>'line_no') AS integer) NULLS LAST,"+json+"->>'id'";
        if(column==null||column.isBlank())return fallback;
        String expression=NUMBERS.contains(column)?number(json,column):TEXT.contains(column)?text(json,column):null;
        if(expression==null)throw invalid();
        return expression+("desc".equalsIgnoreCase(direction)?" DESC":" ASC")+" NULLS LAST,"+fallback;
    }
    private static String number(String json,String key) {
        return "CASE WHEN jsonb_typeof("+json+"->'"+key+"')='number' THEN CAST("+json+"->>'"+key+"' AS numeric) END";
    }
    private static String text(String json,String key) {
        if(!key.equals("stockDocumentNos"))return json+"->>'"+key+"'";
        return "CASE WHEN jsonb_typeof("+json+"->'stockDocumentNos')='array' THEN (SELECT string_agg(document_no,'、' ORDER BY ordinal)"
                +" FROM jsonb_array_elements_text("+json+"->'stockDocumentNos') WITH ORDINALITY numbers(document_no,ordinal))"
                +" ELSE "+json+"->>'stockDocumentNos' END";
    }
    private static ApiException invalid(){return new ApiException(ErrorCode.VALIDATION_FAILED,"仓库实物明细排序字段或方向无效");}
}
