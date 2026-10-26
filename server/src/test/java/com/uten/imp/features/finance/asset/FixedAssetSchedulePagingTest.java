package com.uten.imp.features.finance.asset;

import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class FixedAssetSchedulePagingTest {
    @Test void bothSchedulesPageTheMasterBeforeReadingItsPostedHistoryAndSkipUnrequestedCount() {
        for (boolean fixed : new boolean[]{true, false}) {
            EntityManager em = mock(EntityManager.class);
            Query query = mock(Query.class);
            List<String> sql = new ArrayList<>();
            when(em.createNativeQuery(anyString())).thenAnswer(call -> { sql.add(call.getArgument(0)); return query; });
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of());
            var service = new FixedAssetService(em, mock(TxSessionVars.class));
            try (var ignored = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
                var response = fixed ? service.depreciationSchedule(Integer.MAX_VALUE, Integer.MAX_VALUE)
                        : service.amortizationSchedule(Integer.MAX_VALUE, Integer.MAX_VALUE);
                assertThat(response.total()).isEqualTo(-1);
                assertThat(response.totalPages()).isEqualTo(-1);
                assertThat(response.rows()).isEmpty();
            }
            assertThat(sql).hasSize(1);
            assertThat(sql.getFirst()).contains("ORDER BY code,id LIMIT :__limit OFFSET :__offset) a",
                    "LEFT JOIN LATERAL", "COUNT(*) AS posted_months", "COALESCE(SUM(l.amount),0)",
                    "l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false");
            verify(query).setParameter("__limit", 500);
            verify(query).setParameter("__offset", 1_073_741_823_000L);
            verify(query, never()).getSingleResult();
        }
    }

    @Test void requestedScheduleCountUsesTheSameActiveMasterPredicate() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> { sql.add(call.getArgument(0)); return query; });
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(501L);
        var response = new FixedAssetService(em, mock(TxSessionVars.class)).depreciationSchedule(3, 20);
        assertThat(response.total()).isEqualTo(501);
        assertThat(response.totalPages()).isEqualTo(26);
        assertThat(sql).hasSize(2);
        assertThat(sql.getLast()).isEqualTo("SELECT COUNT(*) FROM fixed_assets WHERE is_deleted=false");
        verify(query).setParameter("__offset", 40L);
    }
}
