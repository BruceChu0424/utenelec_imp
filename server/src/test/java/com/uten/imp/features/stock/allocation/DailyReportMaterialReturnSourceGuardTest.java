package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class DailyReportMaterialReturnSourceGuardTest {
    @Test
    void foreignReportCannotRequestAnyReturnsOrSelectedReturns() {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(false);
        var returns = mock(ProductionMaterialReturnRequestService.class);
        var service = new ProductionDailyReportMaterialWriteAdapter(em,
                mock(ProductionMaterialSettlementService.class), returns,
                mock(SecurityContextCurrentUser.class), mock(ProductionMaterialTaskAccessPolicy.class));
        UUID plan = UUID.randomUUID(), segment = UUID.randomUUID(), report = UUID.randomUUID();
        assertThatThrownBy(() -> service.requestSurplusReturnForDailyReport(plan, segment, report, "return-key", "reason"))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.DAILY_REPORT_MATERIAL_REVIEW_CONFLICT));
        assertThatThrownBy(() -> service.requestSelectedSurplusReturnForDailyReport(plan, segment, report,
                "return-selected-key", "reason", List.of(UUID.randomUUID())))
                .isInstanceOf(ApiException.class);
        verify(query, times(2)).setParameter("report", report);
        verify(query, times(2)).setParameter("segment", segment);
        verify(query, times(2)).setParameter("plan", plan);
        verifyNoInteractions(returns);
    }
}
