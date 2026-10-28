package com.uten.imp.common.report;

import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.util.TaskKeywordSearch;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

/** Typed report controls over explicitly approved expressions at the owning report's row/aggregate grain. */
public final class ReportColumnSearch {
    private ReportColumnSearch() { }
    /** Hidden business values fail before grammar parsing or any source query. */
    public static void requireVisibleSearches(Map<String,String> filters,java.util.function.Predicate<String> hidden){
        if(filters==null)return;
        for(var entry:filters.entrySet())if(entry.getKey().startsWith("search.")&&entry.getValue()!=null&&!entry.getValue().isBlank()
                &&hidden.test(entry.getKey().substring(7)))
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"无权按隐藏的报表字段检索");
    }
    public static Set<String> apply(ReportQueryKit.WhereBuilder where,Map<String,String> filters,
            Map<String,String> columnTypes,Map<String,String> expressions,Map<String,JpaColumnSearch.Kind> dateKinds) {
        Set<String> supported=new LinkedHashSet<>();
        for(var column:columnTypes.entrySet()) {
            String key=column.getKey(),type=column.getValue(),expression=expressions.get(key);
            if(key.startsWith("__")||expression==null||!Set.of("text","date","number","money").contains(type))continue;
            var dateKind=dateKinds.get(key);
            if(type.equals("date")&&dateKind==null)continue;
            supported.add(key);
        }
        Map<String,String> requested=new java.util.LinkedHashMap<>();
        if(filters!=null)filters.forEach((key,value)->{if(key.startsWith("search."))requested.put(key.substring(7),value);});
        var validated=com.uten.imp.common.util.ColumnKeywordSearch.validate(requested,supported);
        for(String key:supported){
            String type=columnTypes.get(key),expression=expressions.get(key);
            var dateKind=dateKinds.get(key);
            String input=validated.get(key);
            if(input==null||input.isBlank())continue;
            if(type.equals("number")||type.equals("money")) {
                ReportQueryKit.addNumericColumnFilter(where,filters,key,expression);
            } else if(type.equals("date")) {
                SqlColumnSearch.Field field=switch(dateKind) {
                    case DATE->SqlColumnSearch.Field.calendarDate("("+expression+")");
                    case INSTANT->SqlColumnSearch.Field.instant("("+expression+")");
                    default->throw new IllegalArgumentException("Report date kind must be DATE or INSTANT");
                };
                var criteria=SqlColumnSearch.criteria(Map.of(key,input),Map.of(key,field),"report_date_"+key+"_");
                where.add(criteria.predicate(),null,null);
                criteria.parameters().forEach((parameter,value)->where.add(null,parameter,value));
            } else {
                String parameter="column_text_"+key;
                where.add(TaskKeywordSearch.conditionParameter(parameter,"CAST(("+expression+") AS text)"),
                        parameter,KeywordSearch.phrase(input));
            }
        }
        return Set.copyOf(supported);
    }
}
