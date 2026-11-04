package com.uten.imp.features.finance.gl;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.report.*;
import java.util.*;

/** Presentation only: the paper/API/export template uses the same already-calculated facts. */
public final class FinancialStatementPresentation {
    private FinancialStatementPresentation(){}
    public static ReportTableResponse forExport(String sheet,String layout,ReportTableResponse source) {
        if("template".equals(layout)&&source.rows().stream().anyMatch(FinancialStatementPresentation::pending))
            throw new ApiException(ErrorCode.CONFLICT,"取数尚未核对完整，请先处理待确认事项，再导出完整财务模板");
        return apply(sheet,layout,source);
    }
    private static boolean pending(Map<String,Object> row) {
        if(Boolean.TRUE.equals(row.get("__pending")))return true;
        return row.containsKey("periodEnd")&&(row.get("periodEnd")==null||row.get("yearStart")==null)
                ||row.containsKey("monthAmount")&&(row.get("monthAmount")==null||row.get("yearAmount")==null);
    }
    public static ReportTableResponse apply(String sheet,String layout,ReportTableResponse source) {
        if(layout==null||layout.isBlank())return source;
        if(!layout.equals("template"))throw new ApiException(ErrorCode.VALIDATION_FAILED,"报表布局无效");
        Map<Integer,Map<String,Object>> byNumber=new LinkedHashMap<>();
        for(var row:source.rows())byNumber.put(((Number)row.get("lineNo")).intValue(),row);
        var expected=sheet.equals("ANNUAL")?FinancialStatementCatalog.mappingLines("PROFIT"):FinancialStatementCatalog.lines(sheet);
        if(byNumber.size()!=expected.size()||source.rows().size()!=expected.size()
                ||expected.stream().anyMatch(l->!byNumber.containsKey(l.number())))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"模板预览和导出需要完整报表，请先清除列筛选");
        if(sheet.equals("PROFIT")||sheet.equals("ANNUAL")) {
            List<Map<String,Object>> presented=new ArrayList<>();
            source.rows().forEach(row->{var copy=new LinkedHashMap<>(row);copy.put("__basis",row.get("basis"));
                copy.put("__pending",pending(row));presented.add(copy);});
            var columns=source.columns().stream().filter(c->!c.key().equals("basis")).toList();
            return new ReportTableResponse(columns,presented,Map.of(),1,source.rows().size(),source.rows().size(),1,
                    source.totals(),source.readScopeVersion(),source.statisticsGeneratedAt(),Set.of());
        }
        List<Object> left=new ArrayList<>(),right=new ArrayList<>();
        left.add(FinanceTemplateContract.section("A5"));for(int n=1;n<=15;n++)left.add(n);
        left.add(FinanceTemplateContract.section("A21"));for(int n=16;n<=30;n++)left.add(n);
        right.add(FinanceTemplateContract.section("E5"));for(int n=31;n<=41;n++)right.add(n);
        right.add(FinanceTemplateContract.section("E17"));for(int n=42;n<=47;n++)right.add(n);
        while(right.size()<25)right.add(null);
        right.add(FinanceTemplateContract.section("E30"));for(int n=48;n<=53;n++)right.add(n);
        List<ReportColumn> columns=new ArrayList<>();
        for(String prefix:List.of("asset","liability")) {
            int start=prefix.equals("asset")?0:4;
            columns.add(ReportColumn.text(prefix+"Item",FinanceTemplateContract.header("balanceSheet",start),260));
            columns.add(new ReportColumn(prefix+"LineNo",FinanceTemplateContract.header("balanceSheet",start+1),"int",65));
            columns.add(ReportColumn.money(prefix+"End",FinanceTemplateContract.header("balanceSheet",start+2)).withUnitLabel("元"));
            columns.add(ReportColumn.money(prefix+"Start",FinanceTemplateContract.header("balanceSheet",start+3)).withUnitLabel("元"));
        }
        List<Map<String,Object>> rows=new ArrayList<>();
        for(int index=0;index<left.size();index++) {
            Map<String,Object> row=new LinkedHashMap<>();List<String> pending=new ArrayList<>();
            add(row,"asset",left.get(index),byNumber,pending);
            add(row,"liability",right.get(index),byNumber,pending);
            applySourceCellStyles(row,index);
            row.put("__basis",String.join("；",pending));row.put("__pending",!pending.isEmpty());
            ReportQueryKit.includeDecimalTexts(row);rows.add(row);
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
    private static void applySourceCellStyles(Map<String,Object> row,int displayRow) {
        var styles=new LinkedHashMap<String,Object>();
        for(var style:FinanceTemplateContract.template("balanceSheet").path("print").path("bodyCellStyles")) {
            if(style.path("displayRow").asInt(-1)!=displayRow)continue;
            String key=style.path("columnKey").asText();
            if(!Set.of("assetItem","assetLineNo","assetEnd","assetStart","liabilityItem","liabilityLineNo","liabilityEnd","liabilityStart").contains(key))
                throw new IllegalStateException("原资产负债表单元格样式列未对应");
            String prefix=style.path("leadingWhitespace").asText("");
            if(!prefix.isEmpty()) {
                if(!key.endsWith("Item")||!prefix.matches("[ \\u3000]{1,24}"))throw new IllegalStateException("原表缩进资料无效");
                if(row.get(key) instanceof String label)row.put(key,prefix+label.stripLeading());
            }
            String fill=style.path("fillRgb").asText("");
            if(!fill.isEmpty()) {
                if(!fill.matches("[0-9A-F]{6}"))throw new IllegalStateException("原表填色资料无效");
                if(!fill.equals("FFFFFF"))styles.put(key,Map.of("fillRgb",fill));
            }
        }
        if(!styles.isEmpty())row.put("__cellStyles",styles);
    }
}
