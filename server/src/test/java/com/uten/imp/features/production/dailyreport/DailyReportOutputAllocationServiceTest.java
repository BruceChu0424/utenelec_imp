package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class DailyReportOutputAllocationServiceTest {
    @Test void nullAndInvalidQuantityFailBeforeAnyDatabaseAccess() {
        var em=org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        var service=new DailyReportOutputAllocationService(em);
        assertThrows(ApiException.class,()->service.split(java.util.UUID.randomUUID(),java.util.Arrays.asList((DailyReportItemLine)null)));
        var invalid=new DailyReportItemLine();invalid.setQty(new BigDecimal("0.00001"));
        assertThrows(ApiException.class,()->service.split(java.util.UUID.randomUUID(),List.of(invalid)));
        org.mockito.Mockito.verifyNoInteractions(em);
    }
    @Test void draftReservationCannotBeReclassifiedAsActualSurplus() {
        var capacity=new DailyReportOutputAllocationService.Capacity(new BigDecimal("100"),new BigDecimal("40"));
        assertThrows(ApiException.class,()->capacity.take(new BigDecimal("120")));
        assertEquals(new BigDecimal("40"),capacity.take(new BigDecimal("40")));
    }
    @Test void approvedRemainingIsConsumedBeforeNewPhysicalSurplus() {
        var capacity=new DailyReportOutputAllocationService.Capacity(new BigDecimal("100"),new BigDecimal("100"));
        assertEquals(new BigDecimal("60"),capacity.take(new BigDecimal("60")));
        assertEquals(new BigDecimal("40"),capacity.take(new BigDecimal("80")));
        assertEquals(BigDecimal.ZERO,capacity.take(new BigDecimal("20")));
    }
    @Test void splitWeightPreservesOriginalTotalIncludingRoundingResidual() {
        var original=new DailyReportItemLine();original.setQty(new BigDecimal("3"));original.setWeight(BigDecimal.ONE);
        var first=new DailyReportItemLine();first.setQty(BigDecimal.ONE);
        var second=new DailyReportItemLine();second.setQty(BigDecimal.ONE);
        var last=new DailyReportItemLine();last.setQty(BigDecimal.ONE);
        DailyReportOutputAllocationService.distributeWeight(original,List.of(first,second,last));
        assertEquals(new BigDecimal("0.3333"),first.getWeight());
        assertEquals(new BigDecimal("0.3333"),last.getWeight());
        assertEquals(0,BigDecimal.ONE.compareTo(first.getWeight().add(second.getWeight()).add(last.getWeight())));
    }
    @Test void tinyWeightSplitNeverProducesANegativeLastSlice() {
        var original=new DailyReportItemLine();original.setQty(new BigDecimal("4"));original.setWeight(new BigDecimal("0.0002"));
        var pieces=new java.util.ArrayList<DailyReportItemLine>();
        for(int index=0;index<4;index++){var item=new DailyReportItemLine();item.setQty(BigDecimal.ONE);pieces.add(item);}
        DailyReportOutputAllocationService.distributeWeight(original,pieces);
        assertTrue(pieces.stream().allMatch(piece->piece.getWeight().signum()>=0));
        assertEquals(0,original.getWeight().compareTo(pieces.stream().map(DailyReportItemLine::getWeight).reduce(BigDecimal.ZERO,BigDecimal::add)));
    }
    @Test void nonBasicUnitMultiLineTransferDebitsEachActualRoundedLedgerQuantity() {
        BigDecimal remaining=new BigDecimal("0.0006");
        for(int index=0;index<3;index++) {
            BigDecimal actualBase=DailyReportOutputAllocationService.transferBaseQuantity(new BigDecimal("0.0001"),new BigDecimal("1.5"));
            assertEquals(new BigDecimal("0.0002"),actualBase);
            remaining=remaining.subtract(actualBase);
        }
        assertEquals(0,remaining.signum(),"three separately posted lines must exhaust the same base-quantity budget");
        assertEquals(new BigDecimal("1.0000"),DailyReportOutputAllocationService.transferBaseQuantity(new BigDecimal("3"),new BigDecimal("0.333333")));
    }
}
