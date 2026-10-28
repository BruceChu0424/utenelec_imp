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

import java.math.BigDecimal;
import java.util.*;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GlOperatingPlStreamingTest {
    private static final BigDecimal COST = new BigDecimal("0.123456789012345678");
    private final List<Long> offsets = new ArrayList<>();

    @AfterEach void clear() {
        TransactionSynchronizationManager.clear();SecurityContextHolder.clearContext();
    }

    private GlReportService service() {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);var query = mock(Query.class);Map<String,Object> parameters = new HashMap<>();
            when(query.setParameter(anyString(), any())).thenAnswer(binding -> {
                parameters.put(binding.getArgument(0), binding.getArgument(1));return query;
            });
            when(query.getSingleResult()).thenReturn(sql.contains("subcontract_receipt_items")
                    ? new BigDecimal("7.25") : new BigDecimal("1000"));
            when(query.getResultList()).thenAnswer(read -> {
                if (!sql.contains("v_stock_actual_cogs_postings")) return List.of();
                assertThat(sql).contains("ORDER BY 2 DESC,1", "LIMIT :__groupLimit OFFSET :__groupOffset");
                long offset = ((Number) parameters.get("__groupOffset")).longValue();offsets.add(offset);
                assertThat(parameters.get("__groupLimit")).isEqualTo(500);
                return IntStream.range((int) offset, Math.min(501, (int) offset + 500))
                        .mapToObj(value -> new Object[]{String.format("类别-%04d",value), COST, value == 500}).toList();
            });
            return query;
        });
        GlReportLineSource lines = mock(GlReportLineSource.class);
        when(lines.bindings(anyCollection())).thenReturn(new GlReportLineSource.Bindings(Map.of()));
        when(lines.styleMonthly(anyCollection(), anyString(), any(), any())).thenReturn(Map.of());
        when(lines.payrollMonthly(anyCollection(), anyInt(), any())).thenReturn(Map.of());
        when(lines.depreciationMonthly(anyCollection(), anyString(), anyString())).thenReturn(Map.of());
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

    @Test void sameAuthorityPreservesAllDynamicCategoriesExactTotalAndTheFixedTailAcrossBothOutputs() {
        var service = service();
        var first = service.operatingPlPage(2026,10,1,500);
        var second = service.operatingPlPage(2026,10,2,500);
        List<Map<String,Object>> expected = new ArrayList<>(first.rows());expected.addAll(second.rows());
        assertThat(first.total()).isEqualTo(expected.size());assertThat(first.rows()).hasSize(500);
        assertThat(expected.stream().filter(row -> "库存价值".equals(row.get("sub")))).hasSize(501);
        assertThat(expected).anySatisfy(row -> {
            assertThat(row.get("sub")).isEqualTo("销售成本合计");
            assertThat((BigDecimal) row.get("amount")).isEqualByComparingTo(COST.multiply(new BigDecimal("501")));
        });
        context();offsets.clear();List<ExportPayload> pages = new ArrayList<>();
        try (var sink = ExportPageSink.open(pages::add)) {
            var streamed = service.exportInCurrentSnapshot("gl/operating-pl", null, 2026,10,1000);
            assertThat(streamed.rows()).isEmpty();assertThat(streamed.total()).isEqualTo(expected.size());
        }
        assertThat(offsets).containsExactly(0L,500L);
        assertThat(pages).allSatisfy(page -> assertThat(page.rows().size()).isLessThanOrEqualTo(500));
        assertThat(pages.stream().flatMap(page -> page.rows().stream())).containsExactlyElementsOf(expected);
        assertThat(pages.getLast().rows().getLast().get("sub")).isEqualTo("管理费合计");
    }

    @Test void rowBudgetIncludesTheLeadingRowAndFixedTailAndNeverReportsAPartialSuccess() {
        var service = service();context();List<ExportPayload> pages = new ArrayList<>();
        try (var sink = ExportPageSink.open(pages::add)) {
            assertThatThrownBy(() -> service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,500))
                    .isInstanceOf(ApiException.class).hasMessageContaining("500");
        }
        assertThat(pages).hasSize(1);assertThat(pages.getFirst().rows()).hasSize(500);
    }

    @Test void headersMatchAfterAllFiveHundredAndOneCategoriesAndRetainTheOriginalSubtotalBeforePagingAndExport() {
        var service=service();
        var options=new com.uten.imp.features.finance.report.FinanceReportColumnOptions(
                Map.of("search.item","类别-0500","search.amount",COST.toPlainString()),null,null);
        var first=service.operatingPlPage(2026,10,1,1,options);
        var second=service.operatingPlPage(2026,10,2,1,options);
        assertThat(first.total()).isEqualTo(2);assertThat(first.rows().getFirst()).containsEntry("item","类别-0500").containsEntry("amountExact",COST.toPlainString());
        assertThat(second.rows().getFirst()).containsEntry("sub","销售成本合计");
        assertThat((BigDecimal)second.rows().getFirst().get("amount")).isEqualByComparingTo(COST.multiply(new BigDecimal("501")));
        assertThat(first.columnSearchKeys()).containsExactlyInAnyOrder("category","sub","item","amount","salesRatio","basis");
        assertThat(service.operatingPlPage(2026,10,3,1,options).rows()).isEmpty();
        assertThat(service.operatingPlPage(2026,10,1,10,new com.uten.imp.features.finance.report.FinanceReportColumnOptions(
                Map.of("search.item","OP-unmatched","search.amount","!=0"),null,null)).total()).isZero();
        context();var pages=new ArrayList<ExportPayload>();
        try(var sink=ExportPageSink.open(pages::add)) {
            var report=service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,1000,options);
            assertThat(report.total()).isEqualTo(2);
        }
        assertThat(pages.stream().flatMap(page->page.rows().stream())).containsExactly(first.rows().getFirst(),second.rows().getFirst());
    }
}
