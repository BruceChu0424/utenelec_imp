package com.uten.imp.features.purchase.order;

import com.uten.imp.common.finance.ProcurementQuantities;
import com.uten.imp.common.web.ApiException;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PurchaseOrderGiftAllocationTest {
    private static BigDecimal n(String value){return new BigDecimal(value);}
    private static PurchaseOrderService.PhysicalShare source(String quantity){
        return new PurchaseOrderService.PhysicalShare(UUID.randomUUID(),n(quantity));
    }
    @Test void sourceRemainderRetainsEveryPhysicalGiftAndChargedQuantityIsSeparate(){
        var sources=List.of(source("1"),source("1"),source("1"));
        var splits=PurchaseOrderService.allocateSourceShares(sources,n("2"),n("1"));
        assertEquals(List.of(n("0.6666"),n("0.6666"),n("0.6668")),splits.stream().map(PurchaseOrderService.SourceSplit::allocQty).toList());
        assertConserved(sources,splits,n("2"),n("1"));
    }
    @Test void onlyGiftRetainsItsExplicitPrincipalSourceAndNeverCreatesPaidAllocation(){
        var sources=List.of(source("1.25"));
        var splits=PurchaseOrderService.allocateSourceShares(sources,n("0"),n("1.25"));
        assertEquals(0,splits.getFirst().allocGiftQty().compareTo(n("1.25")));
        assertEquals(0,splits.getFirst().allocQty().signum());
        assertConserved(sources,splits,n("0"),n("1.25"));
        var quantity=ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,n("0"),n("1.25"),n("2"));
        assertEquals(0,quantity.physicalBase().compareTo(n("2.5")));
        assertEquals(0,quantity.chargedBase().signum());
    }
    @Test void manualDocumentCreatesNoFakeUpstreamGiftShare(){
        assertTrue(PurchaseOrderService.allocateSourceShares(List.of(),n("10"),n("1")).isEmpty());
    }
    @Test void mixedFreeResidualAndPaidSourceKeepTheirOwnPhysicalOwnership(){
        var sources=List.of(source("1"),source("10"));
        var splits=PurchaseOrderService.allocateSourceShares(sources,n("10"),n("1"));
        assertConserved(sources,splits,n("10"),n("1"));
        assertEquals(0,splits.getFirst().allocQty().compareTo(n("0.9090")));
        assertEquals(0,splits.getFirst().allocGiftQty().compareTo(n("0.0910")));
    }
    @Test void allFreeMergedSourcesRetainEverySource(){
        var sources=List.of(source("1"),source("2"));
        var splits=PurchaseOrderService.allocateSourceShares(sources,n("0"),n("3"));
        assertConserved(sources,splits,n("0"),n("3"));
        assertEquals(0,splits.get(0).allocGiftQty().compareTo(n("1")));
        assertEquals(0,splits.get(1).allocGiftQty().compareTo(n("2")));
    }
    @Test void aThousandSmallestSourcesCannotOverflowTheLastSourceWithRoundingRemainders(){
        var sources=java.util.stream.IntStream.range(0,1000).mapToObj(index->source("0.0001")).toList();
        var splits=PurchaseOrderService.allocateSourceShares(sources,n("0.0999"),n("0.0001"));
        assertConserved(sources,splits,n("0.0999"),n("0.0001"));
    }
    @Test void everyPaidFreeCombinationOfTinySourcesPreservesFourPlaceCapacity(){
        for(int count=1;count<=25;count++){
            var sources=java.util.stream.IntStream.range(0,count).mapToObj(index->source("0.0001")).toList();
            BigDecimal physical=n("0.0001").multiply(BigDecimal.valueOf(count));
            for(int paidUnits=0;paidUnits<=count;paidUnits++){
                BigDecimal paid=n("0.0001").multiply(BigDecimal.valueOf(paidUnits));
                var splits=PurchaseOrderService.allocateSourceShares(sources,paid,physical.subtract(paid));
                assertConserved(sources,splits,paid,physical.subtract(paid));
            }
        }
    }
    @Test void inconsistentOrZeroPhysicalSourceCannotBeSavedAsAConservedAllocation(){
        assertThrows(ApiException.class,()->PurchaseOrderService.allocateSourceShares(List.of(source("1")),n("1"),n("1")));
        assertThrows(ApiException.class,()->PurchaseOrderService.allocateSourceShares(List.of(source("0"),source("1")),n("1"),n("0")));
    }
    private static void assertConserved(List<PurchaseOrderService.PhysicalShare> sources,List<PurchaseOrderService.SourceSplit> splits,BigDecimal paid,BigDecimal gift){
        assertEquals(sources.size(),splits.size());
        for(int index=0;index<sources.size();index++){
            var split=splits.get(index);assertEquals(sources.get(index).requestItemId(),split.requestItemId());
            assertTrue(split.allocQty().signum()>=0);assertTrue(split.allocGiftQty().signum()>=0);
            assertEquals(0,split.allocQty().add(split.allocGiftQty()).compareTo(sources.get(index).physicalQty()));
            assertTrue(split.allocQty().scale()<=4);assertTrue(split.allocGiftQty().scale()<=4);
        }
        assertEquals(0,splits.stream().map(PurchaseOrderService.SourceSplit::allocQty).reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(paid));
        assertEquals(0,splits.stream().map(PurchaseOrderService.SourceSplit::allocGiftQty).reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(gift));
    }
    @Test void oldRecordedGiftKeepsPhysicalQuantityAndNewModeAddsIt(){
        assertEquals("10",ProcurementQuantities.physicalText(ProcurementQuantities.LEGACY,n("10"),n("1")));
        assertEquals("11",ProcurementQuantities.physicalText(ProcurementQuantities.EXTRA_GIFT,n("10"),n("1")));
        assertThrows(ApiException.class,()->ProcurementQuantities.of(ProcurementQuantities.LEGACY,n("0"),n("1"),n("1")));
        assertThrows(ApiException.class,()->ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,n("0"),n("0"),n("1")));
        assertThrows(ApiException.class,()->ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,n("10"),n("-1"),n("1")));
    }
}
