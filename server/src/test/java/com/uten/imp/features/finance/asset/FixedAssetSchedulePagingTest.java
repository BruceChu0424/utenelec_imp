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

// 2026-11-04 财务整合（0aaffa3aa）后折旧/摊销清单改由 FinanceAssetTemplateReport 生成：
// 原表模板列 + v_finance_asset_report_facts 物化事实 + LEFT JOIN LATERAL 计提/账簿投影，
// 分页与计数仍经 FinanceProjectedReportTable 的 __limit/__offset 与 COUNT 包装。
class FixedAssetSchedulePagingTest {
    @Test void bothSchedulesPageTheComputedBookProjectionAndSkipUnrequestedCount() {
        for (boolean fixed : new boolean[]{true, false}) {
            EntityManager em = mock(EntityManager.class);
            Query query = mock(Query.class);
            List<String> sql = new ArrayList<>();
            when(em.createNativeQuery(anyString())).thenAnswer(call -> { sql.add(call.getArgument(0)); return query; });
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of());
            var service = new FixedAssetService(em, mock(TxSessionVars.class),com.uten.imp.support.FinanceReportTestAccess.company());
            try (var ignored = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
                var response = fixed ? service.depreciationSchedule(Integer.MAX_VALUE, Integer.MAX_VALUE)
                        : service.amortizationSchedule(Integer.MAX_VALUE, Integer.MAX_VALUE);
                assertThat(response.total()).isEqualTo(-1);
                assertThat(response.totalPages()).isEqualTo(-1);
                assertThat(response.rows()).isEmpty();
            }
            assertThat(sql).hasSize(1);
            assertThat(sql.getFirst())
                    .contains("WITH template_facts AS MATERIALIZED (SELECT * FROM v_finance_asset_report_facts)")
                    .contains("SELECT report.* FROM (")
                    .contains("LEFT JOIN LATERAL")
                    .contains("v_finance_asset_posting_facts")
                    .contains("COALESCE(sum(f.amount_local) FILTER(WHERE NOT f.pending),0)")
                    .contains("ORDER BY report.\"assetName\",report.\"__assetId\"")
                    .contains("LIMIT :__limit OFFSET :__offset");
            verify(query).setParameter("__limit", 500);
            verify(query).setParameter("__offset", 1_073_741_823_000L);
            verify(query, never()).getSingleResult();
        }
    }

    @Test void requestedScheduleCountUsesTheSameTemplateFactsSource() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> { sql.add(call.getArgument(0)); return query; });
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(501L);
        try(var ignored=ReportReadPlan.open(new ReportReadPlan(true,false,false))) {
            var response = new FixedAssetService(em,mock(TxSessionVars.class),com.uten.imp.support.FinanceReportTestAccess.company()).depreciationSchedule(3,20);
            assertThat(response.total()).isEqualTo(501);
            assertThat(response.totalPages()).isEqualTo(26);
        }
        assertThat(sql).hasSize(2);
        // 计数包装与数据页同源：同一 template_facts 投影、同一活动资产谓词，不允许另起一套口径。
        assertThat(sql.getLast())
                .contains("SELECT COUNT(*) FROM (SELECT report.* FROM (WITH template_facts")
                .contains("WHERE NOT a.is_deleted");
        verify(query).setParameter("__offset", 40L);
    }
}
