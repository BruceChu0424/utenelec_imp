package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.ProductionMaterialConsumptionWritePort;
import com.uten.imp.application.port.ProductionMaterialConsumptionWritePort.ConsumptionLine;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

/** 实盘收尾(ADR-129 §2.7)：本次用料 = 审核时的账面可用 − 实际剩余，退仓按实际剩余。 */
@ExtendWith(MockitoExtension.class)
class DailyReportCountedCloseoutTest {
    @Mock private EntityManager em;
    @Mock private ProductionMaterialConsumptionWritePort materialConsumption;
    @Mock private DailyReportOutputAllocationService outputAllocation;
    @Mock private SecurityContextCurrentUser currentUser;
    @InjectMocks private ProductionDailyReportService service;

    private final UUID plan = UUID.randomUUID(), segment = UUID.randomUUID();
    private final UUID counted = UUID.randomUUID(), plain = UUID.randomUUID();

    @Test
    void consumptionIsTheBookAvailableLessTheCountedLeftover() {
        assertDecimal("5.5", ProductionDailyReportService.countedCloseoutConsumption("铝片", new BigDecimal("6"), new BigDecimal("0.5")));
        assertDecimal("0", ProductionDailyReportService.countedCloseoutConsumption("铝片", new BigDecimal("6.0000"), new BigDecimal("6")));
        assertDecimal("6", ProductionDailyReportService.countedCloseoutConsumption("铝片", new BigDecimal("6"), BigDecimal.ZERO));
    }

    @Test
    void aLeftoverAboveTheBookIsRejectedInPlainLanguage() {
        ApiException rejected = assertThrows(ApiException.class, () ->
                ProductionDailyReportService.countedCloseoutConsumption("铝片", new BigDecimal("6.0000"), new BigDecimal("7.5")));
        assertEquals(ErrorCode.CONFLICT, rejected.getCode());
        assertEquals("「铝片」实际剩余 7.5 超过账面可用 6，请先核对之前报工登记的用料", rejected.getMessage());
        ApiException nothingIssued = assertThrows(ApiException.class, () ->
                ProductionDailyReportService.countedCloseoutConsumption(null, BigDecimal.ZERO, new BigDecimal("0.1")));
        assertTrue(nothingIssued.getMessage().contains("「物料」实际剩余 0.1 超过账面可用 0"));
    }

    @Test
    void countedLeftoverIsOptionalNonNegativeAndHasAtMostFourDecimals() {
        assertDoesNotThrow(() -> ProductionDailyReportService.requireValidMaterialLine(line(counted, "3", null)));
        assertDoesNotThrow(() -> ProductionDailyReportService.requireValidMaterialLine(line(counted, "3", "0")));
        assertDoesNotThrow(() -> ProductionDailyReportService.requireValidMaterialLine(line(counted, "3", "1.2340000")));
        ApiException negative = assertThrows(ApiException.class, () ->
                ProductionDailyReportService.requireValidMaterialLine(line(counted, "3", "-0.1")));
        assertEquals(ErrorCode.VALIDATION_FAILED, negative.getCode());
        assertEquals("实际剩余不能为负", negative.getMessage());
        ApiException precise = assertThrows(ApiException.class, () ->
                ProductionDailyReportService.requireValidMaterialLine(line(counted, "3", "0.00001")));
        assertEquals("实际剩余最多 4 位小数", precise.getMessage());
        assertThrows(ApiException.class, () -> ProductionDailyReportService.requireValidMaterialLine(line(counted, null, "1")));
    }

    @Test
    void approvalOverwritesTheCountedLineBeforePostingAndThenReturnsTheSurplus() {
        Query update = stubRows(row(counted, "5.9", "0.5"), row(plain, "3", null));
        when(materialConsumption.bookAvailableByDemand(plan, segment)).thenReturn(Map.of(counted, new BigDecimal("6")));

        settle(report(true));

        verify(update).setParameter("qty", new BigDecimal("5.5"));
        verify(update).setParameter("demandId", counted);
        verify(update, times(1)).executeUpdate();
        verify(outputAllocation).requireMaterialDeclarations(any());
        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<ConsumptionLine>> posted = ArgumentCaptor.forClass(List.class);
        verify(materialConsumption).consumeForDailyReport(eq(plan), eq(segment), any(), anyString(), anyString(), posted.capture());
        assertEquals(2, posted.getValue().size());
        assertEquals(counted, posted.getValue().get(0).demandId());
        assertDecimal("5.5", posted.getValue().get(0).qtyBase());
        assertEquals(plain, posted.getValue().get(1).demandId());
        assertDecimal("3", posted.getValue().get(1).qtyBase());
        verify(materialConsumption).requestSurplusReturnForDailyReport(eq(plan), eq(segment), any(), anyString(), anyString());
    }

    @Test
    void linesWithoutACountKeepTheRegisteredUseAndReadNoBook() {
        stubRows(row(plain, "3", null));

        settle(report(false));

        verify(materialConsumption, never()).bookAvailableByDemand(any(), any());
        verify(outputAllocation, never()).requireMaterialDeclarations(any());
        verify(materialConsumption).consumeForDailyReport(eq(plan), eq(segment), any(), anyString(), anyString(),
                eq(List.of(new ConsumptionLine(plain, new BigDecimal("3")))));
        verify(materialConsumption, never()).requestSurplusReturnForDailyReport(any(), any(), any(), anyString(), anyString());
    }

    /** 账上已没有这条料(不在账面可用里)：清点无从抵扣，照登记的用料过账，不能把用料改成 0。 */
    @Test
    void aCountedMaterialWithNothingOnTheBookKeepsItsRegisteredUse() {
        Query update = stubRows(row(counted, "5.9", "0.5"));
        when(materialConsumption.bookAvailableByDemand(plan, segment)).thenReturn(Map.of());

        settle(report(true));

        verify(update, never()).executeUpdate();
        verify(outputAllocation, never()).requireMaterialDeclarations(any());
        verify(materialConsumption).consumeForDailyReport(eq(plan), eq(segment), any(), anyString(), anyString(),
                eq(List.of(new ConsumptionLine(counted, new BigDecimal("5.9")))));
        verify(materialConsumption).requestSurplusReturnForDailyReport(eq(plan), eq(segment), any(), anyString(), anyString());
    }

    @Test
    void aLeftoverAboveTheBookStopsBeforeAnyPosting() {
        stubRows(row(counted, "5.9", "7"));
        when(materialConsumption.bookAvailableByDemand(plan, segment)).thenReturn(Map.of(counted, new BigDecimal("6")));

        ApiException rejected = assertThrows(ApiException.class, () -> settle(report(true)));

        assertTrue(rejected.getMessage().contains("实际剩余 7 超过账面可用 6"));
        verify(materialConsumption, never()).consumeForDailyReport(any(), any(), any(), anyString(), anyString(), any());
        verify(materialConsumption, never()).requestSurplusReturnForDailyReport(any(), any(), any(), anyString(), anyString());
    }

    @Test
    void aCountThatLeavesOutputWithoutAnyConsumptionIsRejectedInPlainLanguage() {
        stubRows(row(counted, "5.9", "6"));
        when(materialConsumption.bookAvailableByDemand(plan, segment)).thenReturn(Map.of(counted, new BigDecimal("6")));
        doThrow(new ApiException(ErrorCode.VALIDATION_FAILED, "请逐项填写本批实际用料"))
                .when(outputAllocation).requireMaterialDeclarations(any());

        ApiException rejected = assertThrows(ApiException.class, () -> settle(report(true)));

        assertEquals(ErrorCode.CONFLICT, rejected.getCode());
        assertTrue(rejected.getMessage().contains("本次报工没有用掉任何物料"));
        verify(materialConsumption, never()).consumeForDailyReport(any(), any(), any(), anyString(), anyString(), any());
    }

    private void settle(ProductionDailyReport report) {
        ReflectionTestUtils.invokeMethod(service, "settleMaterialUsageOnApprove", report);
    }

    private static ProductionDailyReport report(boolean surplusReturn) {
        ProductionDailyReport report = new ProductionDailyReport();
        report.setBillNo("SR-COUNTED");
        report.setSurplusReturnRequested(surplusReturn);
        return report;
    }

    private Object[] row(UUID demand, String qty, String countedLeftover) {
        return new Object[]{plan, segment, demand, new BigDecimal(qty),
                countedLeftover == null ? null : new BigDecimal(countedLeftover), "铝片"};
    }

    /** The usage SELECT returns [rows]; every later native statement is a counted-line UPDATE. */
    private Query stubRows(Object[]... rows) {
        Query select = mock(Query.class);
        when(select.setParameter(anyString(), any())).thenReturn(select);
        when(select.getResultList()).thenReturn(new ArrayList<>(List.of(rows)));
        Query update = mock(Query.class);
        lenient().when(update.setParameter(anyString(), any())).thenReturn(update);
        lenient().when(update.executeUpdate()).thenReturn(1);
        lenient().when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(em.createNativeQuery(anyString())).thenReturn(select, update);
        return update;
    }

    private static DailyReportMaterialUsageLine line(UUID demand, String qty, String countedLeftover) {
        DailyReportMaterialUsageLine line = new DailyReportMaterialUsageLine();
        line.setDemandId(demand);
        line.setQtyBase(qty == null ? null : new BigDecimal(qty));
        line.setCountedLeftoverQty(countedLeftover == null ? null : new BigDecimal(countedLeftover));
        return line;
    }

    private static void assertDecimal(String expected, BigDecimal actual) {
        assertEquals(0, new BigDecimal(expected).compareTo(actual), "expected " + expected + " but was " + actual);
    }
}
