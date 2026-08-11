package com.uten.imp.features.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.production.report.ProductionReportService;
import com.uten.imp.features.purchase.report.PurchaseReportService;
import com.uten.imp.features.subcontract.report.SubcontractReportService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class RetainedListReportBoundaryTest {

    private EntityManager entityManager;
    private Query query;
    private SystemSettingsService settings;

    @BeforeEach
    void setUp() {
        entityManager = mock(EntityManager.class);
        query = mock(Query.class);
        settings = mock(SystemSettingsService.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
    }

    @Test
    void aggregateListEndpointsClampOversizedAndNonPositiveLimits() {
        new ProductionReportService(entityManager, settings)
                .monthly(null, null, null, Integer.MAX_VALUE);
        new PurchaseReportService(entityManager, settings)
                .monthly(null, null, null, Integer.MAX_VALUE);
        new PurchaseReportService(entityManager, settings)
                .pending(Integer.MAX_VALUE);
        new SubcontractReportService(entityManager, settings)
                .monthly(null, null, null, Integer.MAX_VALUE);

        verify(query, times(4)).setParameter("limit", 2000);

        clearInvocations(query);
        new PurchaseReportService(entityManager, settings).pending(0);
        verify(query).setParameter("limit", 1);
    }

    @Test
    void dailyDetailUsesLongOffsetAndClampsPageSize() {
        new ProductionReportService(entityManager, settings).dailyDetail(
                null, null, null, null, null,
                Integer.MAX_VALUE, Integer.MAX_VALUE);

        verify(query).setParameter("limit", 500);
        verify(query).setParameter("offset", 1_073_741_823_000L);
    }
}
