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
    private static PurchaseOrderService.SourceSplit source(String quantity){
        return new PurchaseOrderService.SourceSplit(UUID.randomUUID(),n(quantity));
    }
    @Test void sourceRemainderRetainsEveryGiftAndChargedQuantityIsSeparate(){
        var sources=List.of(source("1"),source("1"),source("1"));
        var gifts=PurchaseOrderService.allocateGifts(sources,n("3"),n("1"));
        assertEquals(List.of(n("0.3333"),n("0.3333"),n("0.3334")),gifts);
        assertEquals(0,gifts.stream().reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(n("1")));
        assertEquals(0,sources.stream().map(PurchaseOrderService.SourceSplit::allocQty)
                .reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(n("3")));
    }
    @Test void onlyGiftRetainsItsExplicitPrincipalSourceAndNeverCreatesPaidAllocation(){
        var sources=List.of(source("0"));
        assertEquals(List.of(n("1.25")),PurchaseOrderService.allocateGifts(sources,n("0"),n("1.25")));
        assertEquals(BigDecimal.ZERO,sources.getFirst().allocQty());
        var quantity=ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,n("0"),n("1.25"),n("2"));
        assertEquals(0,quantity.physicalBase().compareTo(n("2.5")));
        assertEquals(0,quantity.chargedBase().signum());
    }
    @Test void manualDocumentCreatesNoFakeUpstreamGiftShare(){
        assertTrue(PurchaseOrderService.allocateGifts(List.of(),n("10"),n("1")).isEmpty());
    }
    @Test void oldRecordedGiftKeepsPhysicalQuantityAndNewModeAddsIt(){
        assertEquals("10",ProcurementQuantities.physicalText(ProcurementQuantities.LEGACY,n("10"),n("1")));
        assertEquals("11",ProcurementQuantities.physicalText(ProcurementQuantities.EXTRA_GIFT,n("10"),n("1")));
        assertThrows(ApiException.class,()->ProcurementQuantities.of(ProcurementQuantities.LEGACY,n("0"),n("1"),n("1")));
        assertThrows(ApiException.class,()->ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,n("0"),n("0"),n("1")));
        assertThrows(ApiException.class,()->ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,n("10"),n("-1"),n("1")));
    }
}
