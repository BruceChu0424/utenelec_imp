package com.uten.imp.features.finance.gl;

import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

// 2026-11-04 财务整合（0aaffa3aa）后经营损益表改为固定原表模板行集（附件16 sourceRows 3..92 共 90 行）：
// 不再有 v_stock_actual_cogs_postings 动态类别分组流，取数经 GlReportLineSource 绑定与
// FinanceManufacturingLabor 劳动池归集；本测试按新语义钉分页/导出一致性、行预算失败关闭、
// 未配置行不冒充完整合计与列检索模板闭合。
class GlOperatingPlStreamingTest {

    @AfterEach void clear() {
        TransactionSynchronizationManager.clear();SecurityContextHolder.clearContext();
    }

    private GlReportService service() {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            var query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenAnswer(binding -> query);
            // to_regclass 预检查等标量查询返回非 TRUE 值：账套无接续基线，全部月份视为已知范围。
            when(query.getSingleResult()).thenReturn(new java.math.BigDecimal("1000"));
            when(query.getResultList()).thenReturn(List.of());
            return query;
        });
        GlReportLineSource lines = mock(GlReportLineSource.class);
        when(lines.bindings(anyCollection())).thenReturn(new GlReportLineSource.Bindings(Map.of()));
        when(lines.styleMonthly(anyCollection(), anyString(), any(), any())).thenReturn(Map.of());
        when(lines.payrollMonthly(anyCollection(), anyInt(), any())).thenReturn(Map.of());
        when(lines.depreciationMonthly(anyCollection(), anyString(), anyString(), anyString())).thenReturn(Map.of());
        return new GlReportService(em, lines,com.uten.imp.support.FinanceReportTestAccess.company());
    }

    private void context() {
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "gl-export", Set.of(
                "finance_report:view", "finance_report:export", "finance:view:all"), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    @Test void sameAuthorityPreservesAllTemplateRowsExactTotalAndTheProfitTailAcrossBothOutputs() {
        var service = service();
        var first = service.operatingPlPage(2026,10,1,50);
        var second = service.operatingPlPage(2026,10,2,50);
        List<Map<String,Object>> expected = new ArrayList<>(first.rows());expected.addAll(second.rows());
        assertThat(first.total()).isEqualTo(90);assertThat(first.rows()).hasSize(50);
        assertThat(expected).hasSize(90);
        assertThat(expected.getFirst()).containsEntry("category","应收账款").containsEntry("__lineKey","OP_REVENUE");
        assertThat(expected.getLast()).containsEntry("sub","利润额").containsEntry("__lineKey","OP_PROFIT");
        assertThat(expected.stream().filter(row -> "工费合计".equals(row.get("sub")))).hasSize(1);
        assertThat(expected.stream().filter(row -> "一般管理费合计".equals(row.get("sub")))).hasSize(1);
        context();List<ExportPayload> pages = new ArrayList<>();
        try (var sink = ExportPageSink.open(pages::add)) {
            var streamed = service.exportInCurrentSnapshot("gl/operating-pl", null, 2026,10,1000);
            assertThat(streamed.rows()).isEmpty();assertThat(streamed.total()).isEqualTo(90);
        }
        assertThat(pages).allSatisfy(page -> assertThat(page.rows().size()).isLessThanOrEqualTo(500));
        assertThat(pages.stream().flatMap(page -> page.rows().stream())).containsExactlyElementsOf(expected);
        assertThat(pages.getLast().rows().getLast().get("sub")).isEqualTo("利润额");
    }

    @Test void rowBudgetExceededFailsClosedWithoutReportingAPartialSuccess() {
        var service = service();context();List<ExportPayload> pages = new ArrayList<>();
        try (var sink = ExportPageSink.open(pages::add)) {
            // 行预算必须覆盖全部 90 个模板行（含利润额固定尾行）；89 行预算在第 90 行失败关闭。
            assertThatThrownBy(() -> service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,89))
                    .isInstanceOf(ApiException.class).hasMessageContaining("89");
        }
        assertThat(pages).isEmpty();
    }

    @Test void unconfiguredDetailsCannotBecomeApparentlyCompleteLaborOrAdminTotals() {
        var result = service().operatingPlPage(2026,10,1,500);
        assertThat(result.rows()).hasSize(90);
        for (String subtotal : List.of("工费合计", "一般管理费合计")) {
            var row = result.rows().stream().filter(value -> subtotal.equals(value.get("sub")))
                    .findFirst().orElseThrow();
            assertThat(row.get("m10")).as(subtotal).isNull();
            assertThat(row.get("r10")).as(subtotal).isNull();
            assertThat(row.get("averageRatio")).as(subtotal).isNull();
            assertThat((Boolean) row.get("__pending")).as(subtotal).isTrue();
        }
        var laborDetail = result.rows().stream()
                .filter(value -> "LABOR_DIRECT".equals(value.get("__lineKey"))).findFirst().orElseThrow();
        assertThat(laborDetail.get("m10")).isNull();
        assertThat(laborDetail.get("__basis")).isEqualTo("待配置取数或确认无业务");
    }

    @Test void headersMatchAfterAllTemplateRowsAndRetainTheTemplateClosureBeforePagingAndExport() {
        var service=service();
        var options=new com.uten.imp.features.finance.report.FinanceReportColumnOptions(
                Map.of("search.sub","利润额"),null,null);
        var first=service.operatingPlPage(2026,10,1,1,options);
        assertThat(first.total()).isEqualTo(1);
        assertThat(first.rows().getFirst()).containsEntry("sub","利润额")
                .containsEntry("__lineKey","OP_PROFIT");
        assertThat(service.operatingPlPage(2026,10,2,1,options).rows()).isEmpty();
        assertThat(first.columnSearchKeys()).contains("category","sub","item","m10","r10",
                "averageRatio","remark","varianceReason");
        assertThat(service.operatingPlPage(2026,10,1,10,new com.uten.imp.features.finance.report.FinanceReportColumnOptions(
                Map.of("search.sub","OP-unmatched"),null,null)).total()).isZero();
        context();var pages=new ArrayList<ExportPayload>();
        try(var sink=ExportPageSink.open(pages::add)) {
            var report=service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,1000,options);
            assertThat(report.total()).isEqualTo(1);
        }
        assertThat(pages.stream().flatMap(page->page.rows().stream())).containsExactly(first.rows().getFirst());
    }
}
