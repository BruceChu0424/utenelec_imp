package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class GlReportBoundaryTest {
    @Test void invalidMonthsCannotReachTheDatabaseOrAnUnboundedYearToDateLoop() {
        EntityManager em = mock(EntityManager.class);
        GlReportLineSource lines = mock(GlReportLineSource.class);
        GlReportService service = new GlReportService(em, lines,com.uten.imp.support.FinanceReportTestAccess.company());
        for (int month : new int[]{Integer.MIN_VALUE, -1, 0, 13, Integer.MAX_VALUE}) {
            assertThatThrownBy(() -> service.profitMonthly(2026, month))
                    .isInstanceOfSatisfying(ApiException.class,
                            error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
            assertThatThrownBy(() -> service.operatingPl(2026, month))
                    .isInstanceOfSatisfying(ApiException.class,
                            error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
        verifyNoInteractions(em, lines);
    }

    @Test void monthlyProjectionPreservesCalendarIndexesAndRejectsAnIncompleteArray() {
        java.math.BigDecimal[] months = new java.math.BigDecimal[13];
        months[1] = new java.math.BigDecimal("11.50");
        months[12] = new java.math.BigDecimal("42.75");
        assertThat((java.math.BigDecimal) ReflectionTestUtils.invokeMethod(GlReportService.class, "at", months, 1))
                .isEqualByComparingTo("11.50");
        assertThat((java.math.BigDecimal) ReflectionTestUtils.invokeMethod(GlReportService.class, "at", months, 12))
                .isEqualByComparingTo("42.75");
        assertThat((java.math.BigDecimal) ReflectionTestUtils.invokeMethod(GlReportService.class, "at", months, 2))
                .isEqualByComparingTo(java.math.BigDecimal.ZERO);
        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(
                GlReportService.class, "at", new java.math.BigDecimal[12], 12))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("总账月度取数缺少完整月份");
    }

    @Test void finishedOutputUsesACheckedCalendarYearBoundaryInUtc() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        GlReportService service = new GlReportService(em, mock(GlReportLineSource.class),com.uten.imp.support.FinanceReportTestAccess.company());
        ReflectionTestUtils.invokeMethod(service, "finishedInMonthly", 2026);
        verify(query).setParameter("from", LocalDate.of(2026, 1, 1).atStartOfDay(ZoneOffset.UTC).toOffsetDateTime());
        verify(query).setParameter("to", LocalDate.of(2027, 1, 1).atStartOfDay(ZoneOffset.UTC).toOffsetDateTime());
    }
}
