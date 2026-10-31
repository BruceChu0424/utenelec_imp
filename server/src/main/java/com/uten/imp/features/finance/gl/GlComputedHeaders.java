package com.uten.imp.features.finance.gl;

import com.uten.imp.common.report.ReportRecordHeaders;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.report.*;
import java.util.*;

/** View-only conditions on complete GL calculations; financial rows keep their original order and amounts. */
final class GlComputedHeaders {
    private GlComputedHeaders() { }
    static ReportRecordHeaders.Compiled compile(List<ReportColumn> columns,FinanceReportColumnOptions options) {
        if(options.sort()!=null&&!options.sort().isBlank())throw new ApiException(ErrorCode.VALIDATION_FAILED,"固定财务报表保留原行次");
        if(options.order()!=null&&!Set.of("asc","desc").contains(options.order()))throw new ApiException(ErrorCode.VALIDATION_FAILED,"排序方向无效");
        Map<String,String> types=new LinkedHashMap<>();columns.forEach(column->types.put(column.key(),column.type()));
        return ReportRecordHeaders.compile(types,options.filters(),Set.of("side","category"));
    }
    static ReportTableResponse apply(String report,ReportTableResponse original,FinanceReportColumnOptions options) {
        var condition=compile(original.columns(),options);
        original.rows().forEach(ReportQueryKit::includeDecimalTexts);
        Map<String,List<ReportFacet>> facets=facets(original,options);
        List<Map<String,Object>> rows=new ArrayList<>();
        Set<Object> identities=new LinkedHashSet<>();
        for(var row:original.rows())if(condition.matches(row))identities.add(identity(report,row));
        if(report.equals("gl/balance-sheet")) {
            Set<Object> closure=new LinkedHashSet<>(identities);
            for(Object id:identities)closure.addAll(FinancialStatementCatalog.context("BALANCE",((Number)id).intValue()));
            identities=closure;
        } else if(report.equals("gl/profit-annual")||report.equals("gl/profit-monthly")) {
            Set<Object> closure=new LinkedHashSet<>(identities);
            for(Object id:identities)closure.addAll(FinancialStatementCatalog.context("PROFIT",((Number)id).intValue()));
            identities=closure;
        }
        for(var row:original.rows())if(identities.contains(identity(report,row)))rows.add(row);
        return new ReportTableResponse(original.columns(),rows,facets,1,Math.max(1,rows.size()),rows.size(),rows.isEmpty()?0:1,
                original.totals(),original.readScopeVersion(),original.statisticsGeneratedAt(),condition.keys());
    }
    private static Map<String,List<ReportFacet>> facets(ReportTableResponse original,FinanceReportColumnOptions options) {
        if(!com.uten.imp.common.report.ReportReadPlan.current().includeFacets())return Map.of();
        Map<String,List<ReportFacet>> result=new LinkedHashMap<>();
        for(String key:List.of("side","category")) {
            if(original.columns().stream().noneMatch(column->column.key().equals(key)))continue;
            var remaining=new LinkedHashMap<>(options.filters());remaining.remove(key);remaining.remove("search."+key);
            var eligible=compile(original.columns(),new FinanceReportColumnOptions(remaining,null,null));
            var counts=new LinkedHashMap<String,Long>();
            for(var row:original.rows()) {
                String value=row.get(key)==null?null:row.get(key).toString();
                counts.putIfAbsent(value,0L);if(eligible.matches(row))counts.merge(value,1L,Long::sum);
            }
            var values=new ArrayList<ReportFacet>();
            counts.forEach((value,count)->values.add(new ReportFacet(value==null?ReportTableResponse.NULL_FACET:value,value==null?"(空)":value,count)));
            result.put(key,List.copyOf(values));
        }
        return result;
    }
    private static Object identity(String report,Map<String,Object> row){
        if(report.equals("gl/balance-sheet")||report.equals("gl/profit-annual")||report.equals("gl/profit-monthly"))return row.get("lineNo");
        return row;
    }

}
