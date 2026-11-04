package com.uten.imp.features.finance.gl;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.report.*;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Original employee/channel by fee-class matrix over reviewed allocations of immutable GL facts. */
final class FinanceSalesExpenseReport {
    private FinanceSalesExpenseReport() { }
    static final List<String> FEES=List.of("SALARY","SOCIAL","FREIGHT","OTHER","TRAVEL","ENTERTAIN","AGENCY","EXHIBITION","LOADING","MATERIAL","REBATE","COMPENSATION");
    static List<ReportColumn> columns() {
        var result=new ArrayList<ReportColumn>();result.add(ReportColumn.text("month",FinanceTemplateContract.header("salesExpense",0),90));
        result.add(ReportColumn.text("item",FinanceTemplateContract.header("salesExpense",1),240));
        for(int i=0;i<FEES.size();i++)result.add(ReportColumn.money(FEES.get(i),FinanceTemplateContract.header("salesExpense",i+2)));
        result.add(ReportColumn.money("expenseTotal",FinanceTemplateContract.header("salesExpense",14)));
        result.add(ReportColumn.money("salesAmount",FinanceTemplateContract.header("salesExpense",15)));
        result.add(ReportColumn.number("salesRatio",FinanceTemplateContract.header("salesExpense",16)).withUnitLabel("%"));return List.copyOf(result);
    }
    record Group(UUID id,int month,String label,BigDecimal sales,boolean salesConfirmed,boolean reviewed) { }
    record MonthInput(BigDecimal amount,boolean complete,Map<UUID,Map<String,BigDecimal>> allocations) { }
    static ReportTableResponse read(EntityManager em,GlReportLineSource lineSource,int year,Map<Integer,FinancialStatementRevenue.Value> revenue) {
        return read(em,lineSource,year,12,revenue);
    }
    static ReportTableResponse read(EntityManager em,GlReportLineSource lineSource,int year,int throughMonth,Map<Integer,FinancialStatementRevenue.Value> revenue) {
        List<Group> groups=new ArrayList<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,substring(period FROM 6 FOR 2)::int,label_snapshot,sales_amount_local,sales_confirmed,reviewed
                FROM finance_sales_expense_groups WHERE period BETWEEN :from AND :to ORDER BY period,sort_order,id
                """).setParameter("from","%04d-01".formatted(year)).setParameter("to","%04d-12".formatted(year))))
            groups.add(new Group((UUID)row[0],((Number)row[1]).intValue(),row[2].toString(),(BigDecimal)row[3],(Boolean)row[4],(Boolean)row[5]));
        Map<Integer,Map<UUID,Map<String,BigDecimal>>> amounts=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT substring(period FROM 6 FOR 2)::int,group_id,fee_key,SUM(amount_local)
                FROM v_finance_sales_expense_allocation_facts WHERE period BETWEEN :from AND :to GROUP BY 1,2,3
                """).setParameter("from","%04d-01".formatted(year)).setParameter("to","%04d-12".formatted(year))))
            amounts.computeIfAbsent(((Number)row[0]).intValue(),k->new HashMap<>()).computeIfAbsent((UUID)row[1],k->new HashMap<>()).put(row[2].toString(),(BigDecimal)row[3]);
        Map<Integer,MonthInput> months=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT substring(period FROM 6 FOR 2)::int,amount_local,pending
                FROM v_finance_sales_expense_period_coverage WHERE period BETWEEN :from AND :to
                """).setParameter("from","%04d-01".formatted(year)).setParameter("to","%04d-12".formatted(year)))) {
            int month=((Number)row[0]).intValue();months.put(month,new MonthInput((BigDecimal)row[1],!Boolean.TRUE.equals(row[2]),amounts.getOrDefault(month,Map.of())));
        }
        var bindings=lineSource.bindings(List.of("SALES_FEE"));
        var coverage=FinancialLedgerReadScope.months(em,year,throughMonth);
        for(int month=1;month<=throughMonth;month++)if(!coverage.get(month).complete())months.put(month,new MonthInput(null,false,Map.of()));
        return build(year,throughMonth,groups,months,revenue,bindings.bound("SALES_FEE")&&!bindings.conflicting("SALES_FEE"));
    }    static ReportTableResponse build(int year,List<Group> groups,Map<Integer,MonthInput> months,
            Map<Integer,FinancialStatementRevenue.Value> revenue,boolean scopeKnown) {
        return build(year,12,groups,months,revenue,scopeKnown);
    }
    static ReportTableResponse build(int year,int throughMonth,List<Group> groups,Map<Integer,MonthInput> months,
            Map<Integer,FinancialStatementRevenue.Value> revenue,boolean scopeKnown) {
        List<Map<String,Object>> output=new ArrayList<>(),monthTotals=new ArrayList<>();
        for(int month=1;month<=12;month++) {
            final int selectedMonth=month;List<Group> selected=groups.stream().filter(g->g.month()==selectedMonth).toList();
            boolean draft=selected.isEmpty();
            if(draft) {
                List<Group> raw=new ArrayList<>();for(var source:FinanceTemplateContract.template("salesExpense").required("sourceGroups"))
                    if(source.required("month").asInt()==month)raw.add(new Group(null,month,source.required("label").asText(),null,false,false));
                selected=List.copyOf(raw);
            }
            var summary=months.getOrDefault(month,new MonthInput(BigDecimal.ZERO,true,Map.of()));
            boolean future=month>throughMonth,allocated=!future&&scopeKnown&&!draft&&summary.complete();
            Map<UUID,Map<String,BigDecimal>> amounts=summary.allocations();BigDecimal whole=future?null:summary.amount();            if(selected.stream().anyMatch(g->!g.reviewed()))allocated=false;
            var base=revenue.get(month);BigDecimal sales=base!=null&&base.complete()?base.amount():null;
            BigDecimal groupSales=BigDecimal.ZERO;boolean salesScope=!draft&&selected.stream().allMatch(g->g.salesConfirmed()&&g.sales()!=null);
            for(var group:selected)if(group.sales()!=null)groupSales=groupSales.add(group.sales());
            salesScope&=sales!=null&&groupSales.compareTo(sales)==0;
            Map<String,BigDecimal> totals=new LinkedHashMap<>();for(String fee:FEES)totals.put(fee,allocated?BigDecimal.ZERO:null);
            for(var group:selected) {
                Map<String,Object> row=new LinkedHashMap<>();row.put("month","%02d月".formatted(month));row.put("item",group.label());
                row.put("__lineKey",group.id()==null?"SALES_DRAFT_"+month+"_"+output.size():group.id().toString());
                row.put("__groupId",group.id());row.put("__month",month);
                BigDecimal total=BigDecimal.ZERO;
                for(String fee:FEES) {
                    BigDecimal amount=allocated?amounts.getOrDefault(group.id(),Map.of()).getOrDefault(fee,BigDecimal.ZERO):null;
                    row.put(fee,amount);total=FinanceExpenseReports.add(total,amount);
                    totals.put(fee,FinanceExpenseReports.add(totals.get(fee),amount));
                }
                row.put("expenseTotal",total);row.put("salesAmount",!future&&group.salesConfirmed()?group.sales():null);
                row.put("salesRatio",FinanceExpenseReports.percent(total,!future&&group.salesConfirmed()?group.sales():null));
                row.put("__pending",!future&&(!allocated||!salesScope));row.put("__notApplicable",future);row.put("__basis",draft?"原稿分组仅供复刻，尚未对应本期间真实人员/渠道和费用":
                        !allocated?"来源分录尚未完整分配、已变化或分组未核对":!salesScope?"分组销售额尚未与同源营业收入对齐":"已核对来源分录、期间分组及同源销售基数");
                row.put("__context",List.of("SALES_TOTAL_"+month,"SALES_YEAR_TOTAL"));output.add(row);
            }
            Map<String,Object> total=new LinkedHashMap<>();total.put("month",FinanceExpenseTemplateCatalog.text("salesExpense","monthTotalLabel"));
            total.put("item","");total.put("__lineKey","SALES_TOTAL_"+month);total.put("__month",month);total.putAll(totals);
            total.put("expenseTotal",scopeKnown?whole:null);total.put("salesAmount",sales);total.put("salesRatio",FinanceExpenseReports.percent(scopeKnown?whole:null,sales));
            total.put("__pending",!future&&(!allocated||!salesScope));total.put("__notApplicable",future);total.put("__basis",!scopeKnown?"销售费用科目范围未配置或未确认无业务":!allocated?"月费用总额来自源分录；费用类别/人员分配未核对完整":!salesScope?"分组销售额与同源营业收入未对齐":"月合计仅汇总一次，不重复累计分组显示的销售额");
            total.put("__context",List.of("SALES_YEAR_TOTAL"));output.add(total);if(!future)monthTotals.add(total);
            if(!future&&whole==null)total.put("__basis","该月包含接续前缺失历史或失效来源，金额待核；已记账金额不因核证状态被抹去");
        }
        Map<String,Object> annual=new LinkedHashMap<>();annual.put("month",FinanceExpenseTemplateCatalog.text("salesExpense","yearTotalPattern").replace("{year}",Integer.toString(year)));
        annual.put("item","");annual.put("__lineKey","SALES_YEAR_TOTAL");
        for(String key:java.util.stream.Stream.concat(FEES.stream(),java.util.stream.Stream.of("expenseTotal","salesAmount")).toList()) {
            BigDecimal sum=BigDecimal.ZERO;for(var row:monthTotals)sum=FinanceExpenseReports.add(sum,FinanceExpenseReports.decimal(row.get(key)));annual.put(key,sum);
        }
        annual.put("salesRatio",FinanceExpenseReports.percent(FinanceExpenseReports.decimal(annual.get("expenseTotal")),FinanceExpenseReports.decimal(annual.get("salesAmount"))));
        annual.put("__pending",monthTotals.stream().anyMatch(row->Boolean.TRUE.equals(row.get("__pending"))));annual.put("__basis","全年比率按全年费用合计÷全年营业收入，不能合计月比率");output.add(annual);
        return FinanceExpenseReports.filtered("gl/sales-expense",columns(),output,FinanceReportColumnOptions.NONE);
    }
}
