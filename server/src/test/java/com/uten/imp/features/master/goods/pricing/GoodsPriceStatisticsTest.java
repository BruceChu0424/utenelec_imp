package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static org.assertj.core.api.Assertions.*;

class GoodsPriceStatisticsTest {
    private static final LocalDate TODAY=LocalDate.of(2026,10,13);
    private static final ObjectMapper JSON=new ObjectMapper().findAndRegisterModules();
    @Test void oneExtremeOrderDoesNotSetTheReferenceAndMeanRemainsActualAmountOverQuantity(){
        var rows=List.of(row("10","10",0),row("10","10",1),row("10","10",2),row("1000","1",3));
        var r=GoodsPriceStatistics.calculate(rows,TODAY,null,true);
        assertThat(r.status()).isEqualTo("READY");assertThat(r.reference()).isEqualByComparingTo("10");
        assertThat(r.average()).isEqualByComparingTo(new BigDecimal("1300").divide(new BigDecimal("31"),java.math.MathContext.DECIMAL128));
        assertThat(r.upper()).isLessThan(new BigDecimal("12"));assertThat(r.lower()).isGreaterThan(new BigDecimal("8"));
    }
    @Test void twentySplitLinesOfOneOrderDoNotBecomeTwentyIndependentSamples(){
        UUID order=UUID.randomUUID();List<Observation> rows=new ArrayList<>();
        for(int i=0;i<20;i++)rows.add(row(order,"10","1",0,true));
        var r=GoodsPriceStatistics.calculate(rows,TODAY,null,true);
        assertThat(r.orders()).isEqualTo(1);assertThat(r.samples()).isEqualTo(20);assertThat(r.status()).isEqualTo("INSUFFICIENT");
    }
    @Test void duplicateContractPriceHasNonzeroBandAndNoPennyAlert(){
        var r=GoodsPriceStatistics.calculate(List.of(row("10","1",0),row("10","1",1),row("10","1",2)),TODAY,null,true);
        assertThat(r.upper()).isGreaterThan(new BigDecimal("10.01"));assertThat(r.lower()).isLessThan(new BigDecimal("9.99"));
    }
    @Test void approvedTinyPositiveAmountsNeverTurnIntoZeroOrNaN(){
        var rows=List.of(row("0.000000000000000001","1",0),row("0.000000000000000001","1",1),row("0.000000000000000001","1",2));
        var r=GoodsPriceStatistics.calculate(rows,TODAY,null,true);
        assertThat(r.reference()).isEqualByComparingTo("0.000000000000000001");assertThat(r.average()).isEqualByComparingTo(r.reference());
        assertThat(r.lower()).isPositive();assertThat(r.upper()).isPositive();
    }
    @Test void tinyPriceBulkOrdersStillFlagHugeRelativeSpikes(){
        var r=GoodsPriceStatistics.calculate(List.of(row("0.000001","1000000",0),row("0.000001","1000000",1),row("0.000001","1000000",2)),TODAY,new BigDecimal("1000000"),true);
        assertThat(r.status()).isEqualTo("READY");assertThat(new BigDecimal("0.00009")).isGreaterThan(r.upper());
    }
    @Test void oldEvidenceDoesNotBecomeTodaysMarketPrice(){
        var r=GoodsPriceStatistics.calculate(List.of(row("10","1",100),row("10","1",101),row("10","1",102)),TODAY,null,true);
        assertThat(r.status()).isEqualTo("STALE");assertThat(r.reasons()).contains("STALE_HISTORY");
    }
    @Test void fixedObservationsDoNotInventDailyDrift(){
        var rows=List.of(row("10","1",0),row("11","1",1),row("12","1",2));
        var a=GoodsPriceStatistics.calculate(rows,TODAY,null,true);var b=GoodsPriceStatistics.calculate(rows,TODAY.plusDays(10),null,true);
        assertThat(a.reference()).isEqualByComparingTo(b.reference());
    }
    @Test void outOfContextOrUnapprovedEvidenceNeverAffectsReference(){
        var rows=List.of(row("10","1",0),row("10","1",1),row("10","1",2),row(UUID.randomUUID(),"1000","9999",0,false));
        var r=GoodsPriceStatistics.calculate(rows,TODAY,null,true);
        assertThat(r.reference()).isEqualByComparingTo("10");assertThat(r.average()).isEqualByComparingTo("10");assertThat(r.samples()).isEqualTo(3);
    }
    @Test void incompleteSearchProducesNoStatisticsRatherThanSilentlyTruncating(){
        var r=GoodsPriceStatistics.calculate(List.of(row("10","1",0)),TODAY,null,false);
        assertThat(r.status()).isEqualTo("LIMIT_EXCEEDED");assertThat(r.reference()).isNull();assertThat(r.average()).isNull();
    }
    @Test void highlyUnequalBatchEvidenceIsNotPresentedAsStrongSupport(){
        var r=GoodsPriceStatistics.calculate(List.of(row("10","1",0),row("9","10000",1),row("8","100000",2)),TODAY,BigDecimal.ONE,true);
        assertThat(r.status()).isEqualTo("INSUFFICIENT");assertThat(r.reasons()).contains("LOW_EFFECTIVE_SAMPLE_SIZE");
    }
    @Test void allEquallyDistantBulkOrdersDoNotFalselySupportOnePiecePrice(){
        var r=GoodsPriceStatistics.calculate(List.of(row("10","10000",0),row("10","10000",1),row("10","10000",2)),TODAY,BigDecimal.ONE,true);
        assertThat(r.effective()).isGreaterThan(2.5);assertThat(r.status()).isEqualTo("INSUFFICIENT");assertThat(r.reasons()).contains("QUANTITY_CONTEXT_WEAK");
    }
    static Observation row(String price,String qty,int days){return row(UUID.randomUUID(),price,qty,days,true);}
    static Observation row(UUID order,String price,String qty,int days,boolean comparable){
        Map<String,Object> v=new HashMap<>();v.put("sourceId",order);v.put("sourceItemId",UUID.randomUUID());v.put("quantity",qty);v.put("unitPrice",price);
        v.put("amount",new BigDecimal(price).multiply(new BigDecimal(qty)).toPlainString());v.put("businessDate",TODAY.minusDays(days));v.put("comparable",comparable);
        return JSON.convertValue(v,Observation.class);
    }
}
