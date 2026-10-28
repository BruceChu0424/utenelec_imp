package com.uten.imp.common.report;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.*;
import java.util.function.Predicate;

/** Header conditions for already-authorised, completely calculated report facts. No business sums or ordering. */
public final class ReportRecordHeaders {
    private ReportRecordHeaders() { }
    public record Compiled(Set<String> keys,Predicate<Map<String,Object>> predicate) {
        public boolean matches(Map<String,Object> row){return predicate.test(row);}
    }
    public static Compiled compile(Map<String,String> types,Map<String,String> filters,Set<String> facetKeys) {
        Set<String> keys=new LinkedHashSet<>();
        types.forEach((key,type)->{if(!key.startsWith("__")&&Set.of("text","number","money","count").contains(type))keys.add(key);});
        Map<String,String> requested=new LinkedHashMap<>();
        if(filters!=null)filters.forEach((key,value)->{if(key.startsWith("search."))requested.put(key.substring(7),value);});
        Map<String,String> validated=ColumnKeywordSearch.validate(requested,keys);
        List<Predicate<Map<String,Object>>> predicates=new ArrayList<>();
        validated.forEach((key,input)->{
            if(types.get(key).equals("text"))predicates.add(row->KeywordSearch.matches(input,text(row.get(key))));
            else {
                var number=NumericColumnFilter.parse(input);
                predicates.add(row->number.matches(decimal(row.get(key))));
            }
        });
        if(filters!=null)filters.forEach((key,value)->{
            if(key.startsWith("search."))return;
            if(!facetKeys.contains(key)||!keys.contains(key))throw new ApiException(ErrorCode.VALIDATION_FAILED,"此报表列不支持候选筛选："+key);
            if(value==null||value.isBlank())return;
            predicates.add(row->value.equals("__null__")?row.get(key)==null:Objects.equals(value,text(row.get(key))));
        });
        return new Compiled(Set.copyOf(keys),row->predicates.stream().allMatch(predicate->predicate.test(row)));
    }
    private static String text(Object value){return value==null?null:value.toString();}
    private static BigDecimal decimal(Object value) {
        if(value==null)return null;
        if(value instanceof BigDecimal decimal)return decimal;
        try{return new BigDecimal(value.toString());}catch(NumberFormatException malformed){return null;}
    }
}
