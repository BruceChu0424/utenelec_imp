package com.uten.imp.features.purchase.order;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class PurchaseOrderSourcePrecisionTest {
    @Test void finiteTwentyFourPlaceSourceQuantitiesAreNeverCutBackToFour(){
        var sources=List.of(source("0.5"),source("0.5"));
        var result=PurchaseOrderService.allocateSourceShares(sources,n("0.000000000000000000000002"),n("0.999999999999999999999998"));
        assertThat(result).hasSize(2);
        for(var row:result){assertThat(row.allocQty()).isEqualByComparingTo("0.000000000000000000000001");assertThat(row.allocQty().add(row.allocGiftQty())).isEqualByComparingTo("0.5");}
    }
    @Test void aRepeatingShareRequiresAChoiceAndTheActualFinalRemainderIsConserved()throws Exception {
        var sources=List.of(source("1"),source("2"));
        assertThatThrownBy(()->PurchaseOrderService.allocateSourceShares(sources,n("1"),n("2"))).isInstanceOf(BusinessPrecisionRequiredException.class);
        try(var ignored=BusinessPrecisionContext.use(Map.of("quantity.share",new BusinessPrecisionContext.Choice(2,"DOWN")))){
            var result=PurchaseOrderService.allocateSourceShares(sources,n("1"),n("2"));
            assertThat(result.getFirst().allocQty()).isEqualByComparingTo("0.33");assertThat(result.getLast().allocQty()).isEqualByComparingTo("0.67");
            assertThat(result.getFirst().allocGiftQty()).isEqualByComparingTo("0.67");assertThat(result.getLast().allocGiftQty()).isEqualByComparingTo("1.33");
        }
    }
    @Test void aCoarseChoiceCannotSilentlyIncreaseItsScaleOrOverfillTheTinyLastSource()throws Exception {
        var sources=List.of(source("1"),source("0.00001"));
        try(var ignored=BusinessPrecisionContext.use(Map.of("quantity.share",new BusinessPrecisionContext.Choice(4,"DOWN")))){
            var caught=catchThrowable(()->PurchaseOrderService.allocateSourceShares(sources,n("1"),n("0.00001")));
            assertThat(caught).isInstanceOf(BusinessPrecisionRequiredException.class);
            var failure=(BusinessPrecisionRequiredException)caught;assertThat(failure.details()).containsEntry("selectionRejected",true).containsEntry("notWritten",true).containsEntry("calculationKey","quantity.share");
        }
        try(var ignored=BusinessPrecisionContext.use(Map.of("quantity.share",new BusinessPrecisionContext.Choice(5,"DOWN")))){
            var result=PurchaseOrderService.allocateSourceShares(sources,n("1"),n("0.00001"));
            assertThat(result.getFirst().allocQty()).isEqualByComparingTo("0.99999");assertThat(result.getLast().allocQty()).isEqualByComparingTo("0.00001");
            assertThat(result.stream().map(PurchaseOrderService.SourceSplit::allocQty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("1");
        }
    }
    private static PurchaseOrderService.PhysicalShare source(String quantity){return new PurchaseOrderService.PhysicalShare(UUID.randomUUID(),n(quantity));}
    private static BigDecimal n(String value){return new BigDecimal(value);}
}
