package com.uten.imp.features.stock.allocation;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class DailyReportMaterialFifoReviewTest {
    @Test void consumptionUsesBlockedEarlierIssueBeforeAnEligibleLaterIssue() {
        var blocked=source("4","后续批次承接");var free=source("6",null);
        var first=ProductionDailyReportMaterialWriteAdapter.projectFifo(List.of(blocked,free),new BigDecimal("5"));
        qty("10",first.available());qty("5",first.returnable());assertNull(first.blockedReason());
        var swapped=ProductionDailyReportMaterialWriteAdapter.projectFifo(List.of(free,blocked),new BigDecimal("5"));
        qty("10",swapped.available());qty("1",swapped.returnable());assertEquals("后续批次承接",swapped.blockedReason());
    }
    @Test void pendingReturnExcludedInSourceAvailableIsNeverReturnedAgainAndZeroUseKeepsBalances() {
        var projection=ProductionDailyReportMaterialWriteAdapter.projectFifo(List.of(source("0",null),source("2.1000",null)),BigDecimal.ZERO);
        qty("2.1",projection.available());qty("2.1",projection.returnable());
        var fullyUsed=ProductionDailyReportMaterialWriteAdapter.projectFifo(List.of(source("0.0001",null)),new BigDecimal("0.0001"));
        qty("0",fullyUsed.returnable());
    }
    private ProductionDailyReportMaterialWriteAdapter.IssueReviewSource source(String qty,String blocked) {
        return new ProductionDailyReportMaterialWriteAdapter.IssueReviewSource(UUID.randomUUID(),new BigDecimal(qty),blocked);
    }
    private void qty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
