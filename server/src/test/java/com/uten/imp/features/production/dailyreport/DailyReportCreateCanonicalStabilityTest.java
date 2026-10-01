package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class DailyReportCreateCanonicalStabilityTest {
    @Test void fullProofPreservesTextIdentityAndCellSetOrderWithoutChangingNativeV3() {
        var request=new DailyReportSaveRequest();request.setBillDate(LocalDate.of(2020,1,2));
        var line=new DailyReportItemLine();line.setGoodsId(UUID.randomUUID());line.setQty(BigDecimal.ONE);request.setItems(List.of(line));
        var first=new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(UUID.randomUUID(),"001");
        var second=new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(UUID.randomUUID(),"原备注");
        var nativeHash=ProductionDailyReportService.createRequestHash(request);
        line.setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,List.of(first,second)));
        String complete=ProductionDailyReportService.createFullPayloadHash(request);
        request.setBillNo("ignored-server-number");request.setExpectedVersion(123L);
        assertEquals(complete,ProductionDailyReportService.createFullPayloadHash(request));
        assertEquals(nativeHash,ProductionDailyReportService.createRequestHash(request));
        line.setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,List.of(second,first)));
        assertEquals(complete,ProductionDailyReportService.createFullPayloadHash(request));
        assertEquals(nativeHash,ProductionDailyReportService.createRequestHash(request));
        line.setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,List.of(second,
                new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(first.columnId(),"1"))));
        assertNotEquals(complete,ProductionDailyReportService.createFullPayloadHash(request));
        assertEquals(nativeHash,ProductionDailyReportService.createRequestHash(request));
    }

    @Test void originalExplicitDateAndDefaultFieldsHashIdenticallyAcrossBusinessDays() {
        var request=new DailyReportSaveRequest();
        request.setIdempotencyKey("original-create-day");
        request.setBillDate(LocalDate.of(2020,1,2));
        request.setWorkerId(UUID.randomUUID());
        var line=new DailyReportItemLine();line.setGoodsId(UUID.randomUUID());
        line.setQty(new BigDecimal("4.0000")); request.setItems(List.of(line));
        String original;
        String fullOriginal;
        try(var time=Mockito.mockStatic(BusinessTime.class)) {
            time.when(BusinessTime::today).thenReturn(LocalDate.of(2026,10,1));
            original=ProductionDailyReportService.createRequestHash(request);
            fullOriginal=ProductionDailyReportService.createFullPayloadHash(request);
            time.verifyNoInteractions();
        }
        request.setWorkerIds(List.of(request.getWorkerId()));
        line.setLineNo(1);line.setQty(new BigDecimal("4"));line.setDefectQty(BigDecimal.ZERO);
        try(var time=Mockito.mockStatic(BusinessTime.class)) {
            time.when(BusinessTime::today).thenReturn(LocalDate.of(2030,7,5));
            assertEquals(original,ProductionDailyReportService.createRequestHash(request));
            assertEquals(fullOriginal,ProductionDailyReportService.createFullPayloadHash(request));
            time.verifyNoInteractions();
        }
        request.setBillDate(LocalDate.of(2020,1,3));
        assertNotEquals(original,ProductionDailyReportService.createRequestHash(request));
    }
}
