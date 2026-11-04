package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.report.*;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinancialStatementPresentationTest {
    @Test void paperAndExportPairAllFiftyThreeItemsWithoutRecalculatingOrRounding() {
        var source=source();var paired=FinancialStatementPresentation.apply("BALANCE","template",source);
        Set<Integer> numbers=new HashSet<>();
        for(var row:paired.rows())for(String prefix:List.of("asset","liability")) {
            if(row.get(prefix+"LineNo") instanceof Integer number) {
                numbers.add(number);
                assertThat(row.get(prefix+"End")).isSameAs(source.rows().get(number-1).get("periodEnd"));
                assertThat(row.get(prefix+"EndExact")).isEqualTo("9007199254740993.1234");
            }
        }
        assertThat(numbers).hasSize(53).contains(1,18,19,20,30,31,47,48,53);
        assertThat(paired.rows()).hasSize(32);
        assertThat(paired.rows().getLast()).containsEntry("assetLineNo",30).containsEntry("liabilityLineNo",53);
    }
    @Test void incompleteFilteredScopeCannotMasqueradeAsAFullPaperStatement() {
        var full=source();
        var partial=new ReportTableResponse(full.columns(),full.rows().subList(0,1),Map.of(),1,1,1,1);
        assertThatThrownBy(()->FinancialStatementPresentation.apply("BALANCE","template",partial)).isInstanceOf(ApiException.class);
    }
    @Test void originalLabelIndentAndSevenIndividualGrayCellsDoNotShadeEitherWholeSide() {
        var paper=FinancialStatementPresentation.apply("BALANCE","template",source());
        Set<String> actual=new HashSet<>();
        for(int index=0;index<paper.rows().size();index++) {
            var row=paper.rows().get(index);
            if(row.get("__cellStyles") instanceof Map<?,?> styles)for(var entry:styles.entrySet()) {
                assertThat(entry.getValue()).isEqualTo(Map.of("fillRgb","808080"));
                actual.add(index+":"+entry.getKey());
            }
        }
        assertThat(actual).containsExactlyInAnyOrder("0:assetItem","0:liabilityItem","12:liabilityItem","16:assetItem","18:liabilityItem","31:assetItem","31:liabilityItem");
        assertThat(paper.rows().get(1).get("assetItem").toString()).startsWith("  ");
        assertThat(paper.rows().stream().filter(r->Integer.valueOf(11).equals(r.get("assetLineNo"))).findFirst().orElseThrow().get("assetItem").toString()).startsWith("     ");
        assertThat(paper.rows().get(25)).doesNotContainKey("__cellStyles");
    }
    private static ReportTableResponse source() {
        List<Map<String,Object>> rows=new ArrayList<>();
        for(var line:FinancialStatementCatalog.BALANCE) {
            Map<String,Object> row=new LinkedHashMap<>();row.put("item",line.label());row.put("lineNo",line.number());
            row.put("periodEnd",new BigDecimal("9007199254740993.1234"));row.put("yearStart",BigDecimal.ZERO);row.put("basis","");rows.add(row);
        }
        return new ReportTableResponse(List.of(),rows,Map.of(),1,53,53,1);
    }
}
