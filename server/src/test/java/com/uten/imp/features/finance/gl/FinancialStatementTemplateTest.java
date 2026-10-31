package com.uten.imp.features.finance.gl;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import java.util.stream.Collectors;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.assertThat;

class FinancialStatementTemplateTest {
    @Test void templatesHaveStableNumbersAndDetailContext() {
        assertThat(FinancialStatementCatalog.BALANCE).extracting(FinancialStatementCatalog.Line::number)
                .containsExactlyElementsOf(IntStream.rangeClosed(1,53).boxed().toList());
        assertThat(FinancialStatementCatalog.PROFIT).extracting(FinancialStatementCatalog.Line::number)
                .containsExactly(1,2,3,11,14,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32);
        assertThat(FinancialStatementCatalog.context("BALANCE",19)).containsExactlyInAnyOrder(19,20,29,30);
        assertThat(FinancialStatementCatalog.context("PROFIT",25)).containsExactlyInAnyOrder(25,24,30,32);
    }
    @Test void depreciationReducesAssetsAndRetainedProfitWithoutCountingDetailTwice() {
        var values=FinancialStatementService.calculate("BALANCE",snapshot("BALANCE",Map.of(
                "BS_18","100000","BS_19","20000","BS_48","100000","__PL","-20000")),1);
        amount(values,20,"80000");amount(values,30,"80000");amount(values,53,"80000");
        var inventory=FinancialStatementService.calculate("BALANCE",snapshot("BALANCE",Map.of(
                "BS_9","50","BS_10","100","BS_12","200")),1);
        amount(inventory,9,"350");amount(inventory,15,"350");amount(inventory,30,"350");
    }
    @Test void investmentTaxAndNonOperatingLossesFlowThroughProfitOnlyOnce() {
        var values=FinancialStatementService.calculate("PROFIT",snapshot("PROFIT",Map.ofEntries(
                Map.entry("PL_1","1000"),Map.entry("PL_2","400"),Map.entry("PL_14","100"),
                Map.entry("PL_FINANCE","20"),Map.entry("PL_19","5"),Map.entry("PL_20","50"),
                Map.entry("PL_22","10"),Map.entry("PL_23","3"),Map.entry("PL_24","7"),
                Map.entry("PL_25","4"),Map.entry("PL_31","9"))),1);
        amount(values,18,"25");amount(values,21,"525");amount(values,30,"527");amount(values,32,"518");
    }
    @Test void missingMappingsAndUnmappedFactsNeverProduceAnApparentlyCompleteNetProfit() {
        var empty=new FinancialStatementService.Snapshot(Map.of(),Set.of(),Set.of(),Set.of());
        assertThat(FinancialStatementService.calculate("PROFIT",empty,1).get(32).complete()).isFalse();
        var complete=snapshot("PROFIT",Map.of());
        var unmapped=new FinancialStatementService.Snapshot(complete.amounts(),complete.configured(),Set.of(),Set.of(1));
        assertThat(FinancialStatementService.calculate("PROFIT",unmapped,1).get(32).complete()).isFalse();
        var contradicted=new FinancialStatementService.Snapshot(Map.of("PL_31",Map.of(1,BigDecimal.ONE)),Set.of(),Set.of("PL_31"),Set.of());
        assertThat(FinancialStatementService.calculate("PROFIT",contradicted,1).get(31).complete()).isFalse();
    }
    @Test void aConfirmedZeroRemainderDoesNotSuppressExplicitDetailFacts() {
        var source=snapshot("PROFIT",Map.of("PL_25","5"));
        var confirmed=new FinancialStatementService.Snapshot(source.amounts(),source.configured(),Set.of("PL_24"),Set.of());
        amount(FinancialStatementService.calculate("PROFIT",confirmed,1),24,"5");
    }
    private static FinancialStatementService.Snapshot snapshot(String sheet,Map<String,String> input) {
        Map<String,Map<Integer,BigDecimal>> amounts=new HashMap<>();
        input.forEach((key,value)->amounts.put(key,Map.of(1,new BigDecimal(value))));
        return new FinancialStatementService.Snapshot(amounts,
                FinancialStatementCatalog.lines(sheet).stream().filter(FinancialStatementCatalog.Line::direct)
                        .map(FinancialStatementCatalog.Line::key).collect(Collectors.toSet()),Set.of(),Set.of());
    }
    private static void amount(Map<Integer,FinancialStatementService.Value> values,int number,String expected) {
        assertThat(values.get(number).complete()).isTrue();
        assertThat(values.get(number).amount()).isEqualByComparingTo(expected);
    }
}
