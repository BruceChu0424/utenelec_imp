package com.uten.imp.features.finance.gl;

import com.uten.imp.common.finance.FinancialSourceAllocationGuard;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;

import com.uten.imp.features.finance.report.*;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinanceExpenseReportsTest {
    @Test void originalHeadersAndRowCountsMatchAndCostIncludesOnlyOriginalComponents(){
        assertThat(FinanceExpenseReports.pivotColumns("manufacturingExpense",2026)).hasSize(14);
        assertThat(FinanceExpenseReports.operatingColumns(9)).hasSize(30);
        assertThat(FinanceSalesExpenseReport.columns()).extracting(c->c.label()).containsExactly("月份","销售费用项目","工资","社保","运费","其他","差旅费","招待费","货代/报关费","展会费","装柜/拖车费","物料消耗/赠品","佣金/返利冲销","业务提成经济补偿金","费用月合计金额","本月销售额","当月费用与销售占比");
        assertThat(GlReportLine.MANUFACTURING).hasSize(16);assertThat(GlReportLine.ADMIN).hasSize(38);
        var definitions=FinanceExpenseTemplateCatalog.operatingRows();assertThat(definitions).hasSize(90);
        var source=new HashMap<String,BigDecimal[]>();var names=new HashMap<String,List<String>>();
        for(var row:definitions)if(!row.total()&&row.sourceRow()!=3){source.put(row.key(),FinanceExpenseReports.zero());names.put(row.key(),List.of("明确来源"));}
        source.get("OP_MATERIAL_4")[1]=new BigDecimal("10.1234");source.get("LABOR_DIRECT")[1]=new BigDecimal("20.0001");source.get("OP_RENT")[1]=new BigDecimal("3.0001");
        var report=FinanceExpenseReports.operating(1,source,new GlReportLineSource.Bindings(names),revenue("100"),Set.of(1),Map.of("OP_RENT",Map.of("remark","保留备注","varianceReason","保留差异","version",7)),FinanceReportColumnOptions.NONE,1,200,null);
        assertThat(report.rows()).hasSize(90);amount(find(report,"OP_PRIMARY_TOTAL"),"m1","10.1234");amount(find(report,"OP_COST_TOTAL"),"m1","33.1236");amount(find(report,"OP_PROFIT"),"m1","66.8764");
        assertThat(find(report,"OP_RENT")).containsEntry("remark","保留备注").containsEntry("__noteVersion",7);
        assertThat(find(report,"OP_PROFIT")).containsEntry("m2",null).containsEntry("__pending",false);
    }
    @Test void productionOutputExcludedAndUnknownOrUncoveredCostsCannotBeConfirmedIntoZero(){
        Map<String,BigDecimal[]> source=new HashMap<>();Set<String> zero=new HashSet<>();for(var line:GlReportLine.MANUFACTURING){source.put(line.key(),FinanceExpenseReports.zero());if(line.configurable())zero.add(line.key());}
        source.get("MFG_OUTPUT")[1]=new BigDecimal("1000");source.get("LABOR_DIRECT")[1]=new BigDecimal("50");zero.remove("LABOR_DIRECT");
        var bindings=new GlReportLineSource.Bindings(Map.of("LABOR_DIRECT",List.of("来源")),zero);
        var report=FinanceExpenseReports.pivot("manufacturingExpense",2026,GlReportLine.MANUFACTURING,List.of(),source,bindings,Set.of(1),FinanceReportColumnOptions.NONE);
        amount(find(report,"MFG_TOTAL"),"m1","50");
        source.put("__MFG_COVERAGE",FinanceExpenseReports.zero());source.get("__MFG_COVERAGE")[1]=null;
        report=FinanceExpenseReports.pivot("manufacturingExpense",2026,GlReportLine.MANUFACTURING,List.of(),source,bindings,Set.of(1),FinanceReportColumnOptions.NONE);
        assertThat(find(report,"MFG_TOTAL")).containsEntry("m1",null).containsEntry("yearTotal",null);
        source.remove("__MFG_COVERAGE");source.get("LABOR_DIRECT")[1]=null;
        report=FinanceExpenseReports.pivot("manufacturingExpense",2026,GlReportLine.MANUFACTURING,List.of(),source,bindings,Set.of(1),FinanceReportColumnOptions.NONE);
        assertThat(find(report,"MFG_TOTAL")).containsEntry("m1",null);
    }
    @Test void adminRatioUsesAnnualTotalsAndZeroDenominatorIsNotApplicable()throws Exception {
        Map<String,BigDecimal[]> source=new HashMap<>();Map<String,List<String>> names=new HashMap<>();for(var line:GlReportLine.ADMIN){source.put(line.key(),FinanceExpenseReports.zero());if(line.configurable())names.put(line.key(),List.of("来源"));}
        var fee=GlReportLine.ADMIN.stream().filter(l->l.configurable()).findFirst().orElseThrow();source.get(fee.key())[1]=new BigDecimal("10");source.get(fee.key())[2]=new BigDecimal("50");source.get("ADM_SALES")[1]=new BigDecimal("100");source.get("ADM_SALES")[2]=new BigDecimal("1000");
        assertThatThrownBy(()->FinanceExpenseReports.pivot("adminExpense",2026,GlReportLine.ADMIN,List.of(),source,new GlReportLineSource.Bindings(names),Set.of(),FinanceReportColumnOptions.NONE)).isInstanceOf(BusinessPrecisionRequiredException.class);
        try(var choice=BusinessPrecisionContext.use(Map.of("report.percentage",new BusinessPrecisionContext.Choice(2,"HALF_UP")))){
            var report=FinanceExpenseReports.pivot("adminExpense",2026,GlReportLine.ADMIN,List.of(),source,new GlReportLineSource.Bindings(names),Set.of(),FinanceReportColumnOptions.NONE);var ratio=find(report,"ADM_RATIO");
            amount(ratio,"m1","10");amount(ratio,"m2","5");amount(ratio,"yearTotal","5.45");assertThat(ratio).containsEntry("m3",null).containsEntry("__ratioRow",true);
            assertThat(BusinessPrecisionContext.usedChoices()).containsKey("report.percentage");
        }
    }
    @Test void absentOriginalMaterialMappingMakesCostsAndProfitUnknown(){
        var report=FinanceExpenseReports.operating(1,Map.of(),new GlReportLineSource.Bindings(Map.of()),revenue("100"),Set.of(1),Map.of(),FinanceReportColumnOptions.NONE,1,200,null);
        assertThat(find(report,"OP_MATERIAL_4")).containsEntry("m1",null);assertThat(find(report,"OP_COST_TOTAL")).containsEntry("m1",null);assertThat(find(report,"OP_PROFIT")).containsEntry("m1",null);
    }
    @Test void salaryAndSalesConserveDirectionPoolsWithoutNetZeroOffsetLoophole(){
        assertThatThrownBy(()->FinancialSourceAllocationGuard.singleSource(new BigDecimal("10"),List.of(new BigDecimal("15"),new BigDecimal("-5")))).hasMessageContaining("方向");
        assertThatThrownBy(()->FinancialSourceAllocationGuard.separatePools(new BigDecimal("100"),new BigDecimal("100"),new BigDecimal("110"),BigDecimal.ZERO,new BigDecimal("110"),BigDecimal.ZERO)).hasMessageContaining("分别");
        FinancialSourceAllocationGuard.separatePools(new BigDecimal("100"),new BigDecimal("100"),new BigDecimal("60"),new BigDecimal("40"),new BigDecimal("70"),new BigDecimal("30"));
        assertThat(FinancialSourceAllocationGuard.amount("0.000000000000000000000000000001",false)).isEqualByComparingTo("1e-30");
        assertThatThrownBy(()->FinancialSourceAllocationGuard.amount("0.0000000000000000000000000000001",false)).hasMessageContaining("无损");
    }
    @Test void annualSalesRatioUsesRevenueOnceAndNegativeRefundRemainsSigned()throws Exception {
        var a=UUID.randomUUID();var b=UUID.randomUUID();List<FinanceSalesExpenseReport.Group> groups=new ArrayList<>();Map<Integer,FinanceSalesExpenseReport.MonthInput> months=new HashMap<>();Map<Integer,FinancialStatementRevenue.Value> revenue=new HashMap<>();
        for(int m=1;m<=12;m++){groups.add(new FinanceSalesExpenseReport.Group(a,m,"原人员A",new BigDecimal("40"),true,true));groups.add(new FinanceSalesExpenseReport.Group(b,m,"原人员B",new BigDecimal("60"),true,true));revenue.put(m,new FinancialStatementRevenue.Value(new BigDecimal("100"),true,"同源"));months.put(m,new FinanceSalesExpenseReport.MonthInput(new BigDecimal("10"),true,Map.of(a,Map.of("FREIGHT",new BigDecimal("15")),b,Map.of("FREIGHT",new BigDecimal("-5")))));}
        assertThatThrownBy(()->FinanceSalesExpenseReport.build(2026,groups,months,revenue,true)).isInstanceOf(BusinessPrecisionRequiredException.class);
        try(var choice=BusinessPrecisionContext.use(Map.of("report.percentage",new BusinessPrecisionContext.Choice(2,"DOWN")))){
            var report=FinanceSalesExpenseReport.build(2026,groups,months,revenue,true);var annual=find(report,"SALES_YEAR_TOTAL");amount(annual,"salesAmount","1200");amount(annual,"expenseTotal","120");amount(annual,"salesRatio","10");
            assertThat(report.rows().stream().filter(r->b.toString().equals(r.get("__lineKey"))).findFirst().orElseThrow().get("FREIGHT")).isEqualTo(new BigDecimal("-5"));
            assertThat(BusinessPrecisionContext.usedChoices()).containsKey("report.percentage");
        }
    }
    @Test void operatingAverageKeepsFiniteTwentyFourPlacesAndExcludesFutureMonths(){
        var source=operatingInputs();source.get("OP_RENT")[1]=new BigDecimal("1e-24");source.get("OP_RENT")[2]=new BigDecimal("3e-24");
        var report=operating(source,new BigDecimal("100"),new BigDecimal("100"));var rent=find(report,"OP_RENT");
        amount(rent,"r1","1e-24");amount(rent,"r2","3e-24");amount(rent,"averageRatio","2e-24");
        assertThat(rent).containsEntry("r3",null).containsEntry("m3",null);
    }
    @Test void operatingAverageUsesOriginalMonthlyFractionsAndItsOwnExplicitChoice()throws Exception {
        var source=operatingInputs();source.get("OP_RENT")[1]=BigDecimal.ONE;source.get("OP_RENT")[2]=BigDecimal.ONE.negate();
        var monthly=Map.of("report.percentage",new BusinessPrecisionContext.Choice(2,"DOWN"));
        try(var choice=BusinessPrecisionContext.use(monthly)){
            assertThatThrownBy(()->operating(source,new BigDecimal("3"),new BigDecimal("6"))).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,error->assertThat(error.details()).containsEntry("calculationKey","finance.operating.averageRatio"));
        }
        try(var choice=BusinessPrecisionContext.use(Map.of("report.percentage",monthly.get("report.percentage"),"finance.operating.averageRatio",new BusinessPrecisionContext.Choice(2,"HALF_UP")))){
            var rent=find(operating(source,new BigDecimal("3"),new BigDecimal("6")),"OP_RENT");
            amount(rent,"r1","33.33");amount(rent,"r2","-16.66");amount(rent,"averageRatio","8.33");
            assertThat(BusinessPrecisionContext.usedChoices()).containsKeys("report.percentage","finance.operating.averageRatio");
        }
    }
    @Test void operatingAverageRemainsUnknownForZeroOrMissingMonthlyRevenue(){
        var source=operatingInputs();source.get("OP_RENT")[1]=BigDecimal.ONE;source.get("OP_RENT")[2]=BigDecimal.TEN;
        assertThat(find(operating(source,new BigDecimal("100"),BigDecimal.ZERO),"OP_RENT")).containsEntry("averageRatio",null).containsEntry("r2",null);
        assertThat(find(operating(source,new BigDecimal("100"),null),"OP_RENT")).containsEntry("averageRatio",null).containsEntry("r2",null);
    }
    private static Map<String,BigDecimal[]> operatingInputs(){var source=new HashMap<String,BigDecimal[]>();for(var row:FinanceExpenseTemplateCatalog.operatingRows()){if(!row.total()&&row.sourceRow()!=3)source.put(row.key(),FinanceExpenseReports.zero());}return source;}
    private static ReportTableResponse operating(Map<String,BigDecimal[]> source,BigDecimal first,BigDecimal second){
        var names=new HashMap<String,List<String>>();source.keySet().forEach(key->names.put(key,List.of("明确来源")));
        var revenue=new HashMap<Integer,FinancialStatementRevenue.Value>();if(first!=null){revenue.put(1,new FinancialStatementRevenue.Value(first,true,"同源"));}if(second!=null)revenue.put(2,new FinancialStatementRevenue.Value(second,true,"同源"));
        return FinanceExpenseReports.operating(2,source,new GlReportLineSource.Bindings(names),revenue,Set.of(1,2),Map.of(),FinanceReportColumnOptions.NONE,1,200,null);
    }
    private static Map<Integer,FinancialStatementRevenue.Value> revenue(String value){return Map.of(1,new FinancialStatementRevenue.Value(new BigDecimal(value),true,"同源"));}
    private static Map<String,Object> find(ReportTableResponse report,String key){return report.rows().stream().filter(r->key.equals(r.get("__lineKey"))).findFirst().orElseThrow();}
    private static void amount(Map<String,Object> row,String key,String value){assertThat((BigDecimal)row.get(key)).as(key).isEqualByComparingTo(value);}
}
