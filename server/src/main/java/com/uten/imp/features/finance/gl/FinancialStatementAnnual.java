package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.report.ReportColumn;
import java.math.*;
import java.util.*;

/** Presentation totals use the same twelve monthly facts; an unknown month never disappears into SUM. */
final class FinancialStatementAnnual {
    private FinancialStatementAnnual() { }
    static List<ReportColumn> columns(int year) {
        List<ReportColumn> columns=new ArrayList<>();columns.add(ReportColumn.text("item",FinanceTemplateContract.header("annualProfit",0),280));
        for(int month=1;month<=12;month++)columns.add(ReportColumn.money("m"+month,FinanceTemplateContract.header("annualProfit",month)));
        columns.add(ReportColumn.money("yearTotal",year+"年全年合计"));
        columns.add(ReportColumn.number("profitRatio",FinanceTemplateContract.header("annualProfit",14)).withUnitLabel("%"));
        return columns;
    }
    static void totals(List<Map<String,Object>> rows) {
        totals(rows,12);
    }
    static void totals(List<Map<String,Object>> rows,int throughMonth) {
        if(throughMonth<1||throughMonth>12)throw new IllegalArgumentException("throughMonth");
        for(var row:rows) {
            BigDecimal total=BigDecimal.ZERO;boolean complete=true;
            for(int month=1;month<=throughMonth;month++) {
                if(row.get("m"+month) instanceof BigDecimal value)total=total.add(value);else complete=false;
            }
            row.put("yearTotal",complete?total:null);
        }
        Object revenue=rows.stream().filter(row->Integer.valueOf(1).equals(row.get("lineNo")))
                .map(row->row.get("yearTotal")).filter(Objects::nonNull).findFirst().orElse(null);
        for(var row:rows)if(Integer.valueOf(32).equals(row.get("lineNo"))) {
            BigDecimal value=row.get("yearTotal") instanceof BigDecimal v?v:null;
            row.put("profitRatio",value!=null&&revenue instanceof BigDecimal base&&base.signum()!=0
                    ?com.uten.imp.common.finance.MoneyPolicy.percentOf(value,base):null);
            row.put("__ratioBasis","按原文件O25：全年净利润÷全年营业收入；收入为0时不适用");
        }
    }
}
