package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.report.FinanceReportColumnOptions;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class GlComputedHeadersTest {
    private static Map<String,Object> row(Object... pairs){
        return com.uten.imp.support.KeyValueTestData.map(pairs);
    }
    private static ReportTableResponse response(List<ReportColumn> columns,List<Map<String,Object>> rows){
        return new ReportTableResponse(columns,rows,Map.of(),1,Math.max(1,rows.size()),rows.size(),rows.isEmpty()?0:1,
                List.of(),"complete-authorised-calculation","fixed-source-time",Set.of());
    }
    private static FinanceReportColumnOptions search(String key,String value){
        return new FinanceReportColumnOptions(Map.of("search."+key,value),null,null);
    }

    @Test void balanceLeafMatchKeepsActualFixedAncestorsAndExactOriginalAmountsWithoutRecalculation(){
        BigDecimal exact=new BigDecimal("9007199254740993.0001");
        var unrelated=row("lineNo",1,"item","货币资金","end",new BigDecimal("25"));
        var parent=row("lineNo",9,"item","存货","end",new BigDecimal("1000.1234567890123456789"));
        var leaf=row("lineNo",12,"item","其中:库存商品","end",exact);
        var section=row("lineNo",15,"item","流动资产合计","end",new BigDecimal("777.125"));
        var total=row("lineNo",29,"item","资产总计","end",new BigDecimal("1234567890.0123"));
        var original=response(List.of(ReportColumn.number("lineNo","行次"),ReportColumn.text("item","项目"),ReportColumn.money("end","期末")),
                List.of(unrelated,parent,leaf,section,total));
        var result=GlComputedHeaders.apply("gl/balance-sheet",original,search("end",exact.toPlainString()));
        assertThat(result.rows()).extracting(record->record.get("lineNo")).containsExactly(9,12,15,29);
        assertThat(result.rows().get(1)).isSameAs(leaf);
        assertThat(result.rows().get(1).get("end")).isSameAs(exact);
        assertThat(result.rows().get(1).get("endExact")).isEqualTo(exact.toPlainString());
        assertThat(result.rows().get(0).get("end")).isEqualTo(new BigDecimal("1000.1234567890123456789"));
        assertThat(result.rows().getLast().get("end")).isEqualTo(new BigDecimal("1234567890.0123"));
        assertThat(original.rows()).hasSize(5);assertThat(result.total()).isEqualTo(4);
        assertThat(result.readScopeVersion()).isEqualTo("complete-authorised-calculation");
        assertThat(result.statisticsGeneratedAt()).isEqualTo("fixed-source-time");
    }

    @Test void unknownAndUnparseableNumbersDoNotMatchNotEqualZeroAndTextSymbolsRemainLiteral(){
        var precise=row("item","业务_% A","amount",new BigDecimal("0.000000000000000000001"));
        var nullAmount=row("item","业务未知","amount",null);
        var unresolved=row("item","业务待核验","amount","待核验");
        var zero=row("item","业务零","amount",BigDecimal.ZERO);
        var wildcardLookalike=row("item","业务XX A","amount",BigDecimal.ZERO);
        var original=response(List.of(ReportColumn.text("item","项目"),ReportColumn.money("amount","金额")),
                List.of(precise,nullAmount,unresolved,zero,wildcardLookalike));
        assertThat(GlComputedHeaders.apply("gl/pivot",original,search("amount","!=0")).rows()).containsExactly(precise);
        assertThat(GlComputedHeaders.apply("gl/pivot",original,search("item","_% A")).rows()).containsExactly(precise);
        assertThat(GlComputedHeaders.apply("gl/pivot",original,search("item","x' OR TRUE;--")).rows()).isEmpty();
        assertThat(nullAmount.get("amount")).isNull();assertThat(unresolved.get("amount")).isEqualTo("待核验");
        assertThat(original.rows()).hasSize(5);
    }

    @Test void balanceSidesUseTheCompleteVisibleDictionaryAndExactSelectionWhileCountsExcludeOnlyTheirOwnCondition(){
        var asset=row("lineNo",1,"item","货币资金","side","资产","periodEnd",new BigDecimal("25"));
        var liability=row("lineNo",33,"item","应付账款","side","负债和所有者权益","periodEnd",new BigDecimal("25"));
        var tax=row("lineNo",36,"item","应交税费","side","负债和所有者权益","periodEnd",new BigDecimal("99"));
        var original=response(List.of(ReportColumn.number("lineNo","行次"),ReportColumn.text("item","项目"),ReportColumn.text("side","类别"),ReportColumn.money("periodEnd","期末")),List.of(asset,liability,tax));
        var selected=GlComputedHeaders.apply("gl/balance-sheet",original,new FinanceReportColumnOptions(Map.of("side","资产","search.periodEnd","25"),null,null));
        assertThat(selected.rows()).containsExactly(asset);
        assertThat(selected.facets().get("side")).extracting(com.uten.imp.features.finance.report.ReportFacet::value).containsExactly("资产","负债和所有者权益");
        assertThat(selected.facets().get("side")).extracting(com.uten.imp.features.finance.report.ReportFacet::count).containsExactly(1L,1L);
        var located=GlComputedHeaders.apply("gl/balance-sheet",original,new FinanceReportColumnOptions(Map.of("side","资产","search.item","货币资金"),null,null));
        assertThat(located.facets().get("side")).extracting(com.uten.imp.features.finance.report.ReportFacet::count).containsExactly(1L,0L);
        assertThat(GlComputedHeaders.apply("gl/balance-sheet",original,new FinanceReportColumnOptions(Map.of("side","负债和所有者权益"),null,null)).rows()).containsExactly(liability,tax);
    }

    @Test void profitContextUsesExactFinancialIdentitiesAndNeverSortsOrRebuildsNamedSubtotals(){
        var other=row("item","某公司营业成本备注","amount",new BigDecimal("77"));
        var income=row("item","一、营业收入","amount",new BigDecimal("1000.0001"));
        var cost=row("item","减：营业成本","amount",new BigDecimal("100"));
        var operating=row("item","二、营业利润","amount",new BigDecimal("900.0001"));
        var profit=row("item","三、利润总额","amount",new BigDecimal("920.0001"));
        var tax=row("item","减：所得税费用","amount",new BigDecimal("20"));
        var net=row("item","四、净利润","amount",new BigDecimal("900.0001"));
        var original=response(List.of(ReportColumn.text("item","项目"),ReportColumn.money("amount","金额")),
                List.of(other,income,cost,operating,profit,tax,net));
        var selected=GlComputedHeaders.apply("gl/profit-annual",original,search("item","减：营业成本"));
        assertThat(selected.rows()).containsExactly(cost,operating,profit,net);
        assertThat(selected.rows()).extracting(record->record.get("amount")).containsExactly(new BigDecimal("100"),
                new BigDecimal("900.0001"),new BigDecimal("920.0001"),new BigDecimal("900.0001"));
        assertThat(GlComputedHeaders.apply("gl/profit-monthly",original,search("item","某公司")).rows()).containsExactly(other);
        assertThatThrownBy(()->GlComputedHeaders.apply("gl/profit-annual",original,
                new FinanceReportColumnOptions(Map.of(),"amount","desc"))).isInstanceOf(ApiException.class)
                .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThat(original.rows()).containsExactly(other,income,cost,operating,profit,tax,net);
    }
}
