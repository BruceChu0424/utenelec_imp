package com.uten.imp.features.report;

import com.uten.imp.common.web.CompleteReadBatchPlan;
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


    @BeforeEach
    void setUp() {
        entityManager = mock(EntityManager.class);
        query = mock(Query.class);

        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
    }

    @Test
    void aggregateListEndpointsClampOversizedAndNonPositiveLimits() {
        new ProductionReportService(entityManager)
                .monthly(null, null, null, Integer.MAX_VALUE);
        new PurchaseReportService(entityManager)
                .monthly(null, null, null, Integer.MAX_VALUE);
        new PurchaseReportService(entityManager)
                .pending(Integer.MAX_VALUE);
        new SubcontractReportService(entityManager)
                .monthly(null, null, null, Integer.MAX_VALUE);

        verify(query, times(4)).setParameter("limit", 2000);

        clearInvocations(query);
        new PurchaseReportService(entityManager).pending(0);
        verify(query).setParameter("limit", 1);
    }

    @Test
    void dailyDetailUsesLongOffsetAndClampsPageSize() {
        new ProductionReportService(entityManager).dailyDetail(
                null, null, null, null, null,
                Integer.MAX_VALUE, Integer.MAX_VALUE);

        // 2026-11-09 合同：单次页上限 200→1000（CompleteReadBatchPlan.MAX_BATCH_SIZE），
        // dailyDetail 的夹取与长 offset 随共享上限推导，不再钉独立 500。
        verify(query).setParameter("limit", CompleteReadBatchPlan.MAX_BATCH_SIZE);
        verify(query).setParameter("offset",
                (long) (Integer.MAX_VALUE - 1) * CompleteReadBatchPlan.MAX_BATCH_SIZE);
    }
}
