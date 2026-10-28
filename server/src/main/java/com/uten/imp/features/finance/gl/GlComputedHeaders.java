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
            for(Object id:identities)closure.addAll(BALANCE_CONTEXT.getOrDefault(((Number)id).intValue(),List.of()));
            identities=closure;
        } else if(report.equals("gl/profit-annual")||report.equals("gl/profit-monthly")) {
            Set<Object> closure=new LinkedHashSet<>(identities);
            for(Object id:identities)closure.addAll(PROFIT_CONTEXT.getOrDefault(id.toString(),List.of()));
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
        if(report.equals("gl/balance-sheet"))return row.get("lineNo");
        return report.equals("gl/profit-annual")||report.equals("gl/profit-monthly")?row.get("item"):row;
    }

    // These are the existing fixed line identities and formulas in balanceSheet(), not label heuristics.
    private static final Map<Integer,List<Integer>> BALANCE_CONTEXT=Map.ofEntries(
            Map.entry(1,List.of(15,29)),Map.entry(4,List.of(15,29)),Map.entry(8,List.of(15,29)),
            Map.entry(9,List.of(15,29)),Map.entry(12,List.of(9,15,29)),Map.entry(14,List.of(15,29)),
            Map.entry(15,List.of(29)),Map.entry(24,List.of(29)),Map.entry(33,List.of(41,52)),
            Map.entry(36,List.of(41,52)),Map.entry(39,List.of(41,52)),Map.entry(41,List.of(52)),
            Map.entry(47,List.of(51,52)),Map.entry(50,List.of(51,52)),Map.entry(51,List.of(52)));
    // profitRows() already uses these exact identities to calculate the named subtotals.
    private static final Map<String,List<String>> PROFIT_CONTEXT=profitContext();
    private static Map<String,List<String>> profitContext(){
        Map<String,List<String>> result=new LinkedHashMap<>();
        for(String key:List.of("一、营业收入","减：营业成本","营业税金及附加","销售费用","管理费用","财务费用"))
            result.put(key,List.of("二、营业利润","三、利润总额","四、净利润"));
        result.put("二、营业利润",List.of("三、利润总额","四、净利润"));
        result.put("加：营业外收入",List.of("三、利润总额","四、净利润"));
        result.put("减：营业外支出",List.of("三、利润总额","四、净利润"));
        result.put("三、利润总额",List.of("四、净利润"));result.put("减：所得税费用",List.of("四、净利润"));
        return Map.copyOf(result);
    }
}
