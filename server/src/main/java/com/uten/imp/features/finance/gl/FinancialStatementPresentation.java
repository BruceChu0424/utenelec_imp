package com.uten.imp.features.finance.gl;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.report.*;
import java.util.*;

/** Presentation only: the paper/API/export template uses the same already-calculated facts. */
public final class FinancialStatementPresentation {
    private FinancialStatementPresentation(){}
    public static ReportTableResponse apply(String sheet,String layout,ReportTableResponse source) {
        if(layout==null||layout.isBlank())return source;
        if(!layout.equals("template"))throw new ApiException(ErrorCode.VALIDATION_FAILED,"报表布局无效");
        Map<Integer,Map<String,Object>> byNumber=new LinkedHashMap<>();
        for(var row:source.rows())byNumber.put(((Number)row.get("lineNo")).intValue(),row);
        if(byNumber.size()!=FinancialStatementCatalog.lines(sheet).size()
                ||FinancialStatementCatalog.lines(sheet).stream().anyMatch(l->!byNumber.containsKey(l.number())))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"模板预览和导出需要完整报表，请先清除列筛选");
        if(sheet.equals("PROFIT")) {
            boolean pending=source.rows().stream().anyMatch(r->r.get("monthAmount")==null||r.get("yearAmount")==null);
            var columns=source.columns().stream().filter(c->pending||!c.key().equals("basis")).toList();
            return new ReportTableResponse(columns,source.rows(),Map.of(),1,source.rows().size(),source.rows().size(),1,
                    source.totals(),source.readScopeVersion(),source.statisticsGeneratedAt(),Set.of());
        }
        List<Object> left=new ArrayList<>(),right=new ArrayList<>();
        left.add("流动资产");for(int n=1;n<=15;n++)left.add(n);
        left.add("非流动资产");for(int n=16;n<=30;n++)left.add(n);
        right.add("流动负债");for(int n=31;n<=41;n++)right.add(n);
        right.add("非流动负债");for(int n=42;n<=47;n++)right.add(n);
        while(right.size()<25)right.add(null);
        right.add("所有者权益（或股东权益）");for(int n=48;n<=53;n++)right.add(n);
        List<ReportColumn> columns=new ArrayList<>();
        for(String prefix:List.of("asset","liability")) {
            columns.add(ReportColumn.text(prefix+"Item",prefix.equals("asset")?"资产":"负债和所有者权益",260));
            columns.add(new ReportColumn(prefix+"LineNo","行次","int",65));
            columns.add(ReportColumn.money(prefix+"End","期末余额").withUnitLabel("元"));
            columns.add(ReportColumn.money(prefix+"Start","年初余额").withUnitLabel("元"));
        }
        if(source.rows().stream().anyMatch(r->r.get("periodEnd")==null||r.get("yearStart")==null))
            columns.add(ReportColumn.text("basis","待确认事项",260));
        List<Map<String,Object>> rows=new ArrayList<>();
        for(int index=0;index<left.size();index++) {
            Map<String,Object> row=new LinkedHashMap<>();List<String> pending=new ArrayList<>();
            add(row,"asset",left.get(index),byNumber,pending);
            add(row,"liability",right.get(index),byNumber,pending);
            row.put("basis",String.join("；",pending));ReportQueryKit.includeDecimalTexts(row);rows.add(row);
        }
        return new ReportTableResponse(columns,rows,Map.of(),1,rows.size(),rows.size(),1,
                List.of(),source.readScopeVersion(),source.statisticsGeneratedAt(),Set.of());
    }
    private static void add(Map<String,Object> row,String prefix,Object token,Map<Integer,Map<String,Object>> facts,List<String> pending) {
        if(token==null)return;
        if(token instanceof String title){row.put(prefix+"Item",title);return;}
        var fact=facts.get((Integer)token);
        row.put(prefix+"Item",fact.get("item"));row.put(prefix+"LineNo",token);
        row.put(prefix+"End",fact.get("periodEnd"));row.put(prefix+"Start",fact.get("yearStart"));
        if(fact.get("periodEnd")==null||fact.get("yearStart")==null)pending.add(fact.get("item")+"："+fact.get("basis"));
    }
}
