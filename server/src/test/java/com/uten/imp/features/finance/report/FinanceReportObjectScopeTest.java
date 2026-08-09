package com.uten.imp.features.finance.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.junit.jupiter.api.Assertions.assertThrows;

class FinanceReportObjectScopeTest {

    private static final String OWNERS_PARAM = "financeReportOwners";

    @Test
    void everyDirectFinanceDocumentQueryAndExportUsesTheSameMakerScopeAndBinding() {
        Set<UUID> visibleOwners = Set.of(UUID.randomUUID(), UUID.randomUUID());
        Fixture fixture = restrictedFixture(visibleOwners);
        FinanceReportService service = fixture.service();
        LocalDate from = LocalDate.of(2026, 1, 1);
        LocalDate to = LocalDate.of(2026, 12, 31);
        service.receiptDetail(null, null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.receiptSummary(null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.paymentDetail(null, null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.paymentSummary(null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.expenseDetail(null, null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.expenseSummary(null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.incomeDetail(null, null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.incomeSummary(null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);
        service.feeOffsetDetail(null, null, null, null, from, to, null,
                Map.of(), 1, 50, null, null);

        // Controller export delegates to export(), which must reuse the scoped report loader.
        service.export("receipt/detail", Map.of("dateFrom", from.toString()), null, null);

        List<CapturedQuery> sensitiveQueries = fixture.queries().stream()
                .filter(query -> directlyReadsFinanceDocument(query.sql()))
                .toList();
        assertThat(sensitiveQueries).hasSizeGreaterThanOrEqualTo(20);
        for (CapturedQuery captured : sensitiveQueries) {
            String alias = ownerAlias(captured.sql());
            assertThat(captured.sql())
                    .as("finance maker scope in SQL: %s", captured.sql())
                    .contains("(" + alias + ".maker_id IS NULL OR " + alias
                            + ".maker_id IN (:" + OWNERS_PARAM + "))");
            verify(captured.query()).setParameter(OWNERS_PARAM, visibleOwners);
        }
        // 9 个页面入口 + 1 个导出入口；导出分页不重复 evaluate scope。
        verify(fixture.access(), times(10)).scope();
    }

    @Test
    void viewAllScopeLeavesFinanceDocumentReportsUnrestrictedAndUnbound() {
        Fixture fixture = viewAllFixture();

        fixture.service().receiptSummary(null, null, null,
                null, null, null, Map.of(), 1, 50, null, null);

        List<CapturedQuery> sensitiveQueries = fixture.queries().stream()
                .filter(query -> directlyReadsFinanceDocument(query.sql()))
                .toList();
        assertThat(sensitiveQueries).hasSize(2);
        for (CapturedQuery captured : sensitiveQueries) {
            assertThat(captured.sql()).contains("AND 1=1");
            verify(captured.query(), never()).setParameter(eq(OWNERS_PARAM), any());
        }
    }

    @Test
    void restrictedScopeFailsClosedBeforeAnyCompanyLevelQueryOrDelegatedExport() {
        Fixture fixture = restrictedFixture(Set.of(UUID.randomUUID()));
        FinanceReportService service = fixture.service();
        List<Executable> companyEntries = List.of(
                () -> service.arApOverview(null, null, null, null, null, null, 1, 50),
                () -> service.arApDetail("AR", null, null, null,
                        null, null, null, Map.of(), 1, 50, null, null),
                () -> service.salesOrderReceivablePlan(
                        null, null, null, null, null, 1, 50, null, null),
                () -> service.arApSummary(
                        "AR", null, null, null, Map.of(), 1, 50, null, null),
                () -> service.receivableSummary(null, null, null, 1, 50),
                () -> service.payableSummary(null, null, null, Map.of(), 1, 50, null, null),
                () -> service.partyStatementFlow(null, "AR", null, null, 1, 50),
                () -> service.partyStatementDetail(null, "AR", null, null, 1, 50),
                () -> service.partyAnnualStatement(null, "AR", 2026, 1, 50),
                () -> service.accountStatement(null, null, null, null, 1, 50),
                () -> service.bankReport("detail"),
                () -> service.export("ar-ap/detail", Map.of("direction", "AR"), null, null),
                () -> service.export("statements/supplier", Map.of(), null, null),
                () -> service.export("cost/product", Map.of(), null, null),
                () -> service.export("gl/trial-balance", Map.of(), null, null),
                () -> service.export("fa/depreciation-schedule", Map.of(), null, null));

        for (Executable entry : companyEntries) {
            ApiException error = assertThrows(ApiException.class, entry);
            assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
            assertThat(error.getMessage()).contains("finance:view:all");
        }

        assertThat(fixture.queries()).isEmpty();
        verify(fixture.access(), times(companyEntries.size())).scope();
    }

    @Test
    void viewAllScopeCanReadCompanyReportsAndDelegatedExportsWithOneScopeCheckPerEntry() {
        Fixture fixture = viewAllFixture();
        FinanceReportService service = fixture.service();
        UUID partyId = UUID.randomUUID();

        service.arApDetail("AR", null, null, null,
                null, null, null, Map.of(), 1, 50, null, null);
        service.arApSummary("AR", null, null, null, Map.of(), 1, 50, null, null);
        service.partyStatementFlow(partyId, "AR", null, null, 1, 50);
        service.accountStatement(UUID.randomUUID(), null, null, null, 1, 50);
        service.bankReport("detail");
        service.export("ar-ap/detail", Map.of("direction", "AR"), null, null);
        service.export("statements/supplier", Map.of(), null, null);
        service.export("cost/product", Map.of(), null, null);
        service.export("gl/trial-balance", Map.of(), null, null);
        service.export("fa/depreciation-schedule", Map.of(), null, null);

        assertThat(fixture.queries()).isNotEmpty();
        for (CapturedQuery captured : fixture.queries()) {
            verify(captured.query(), never()).setParameter(eq(OWNERS_PARAM), any());
        }
        verify(fixture.access(), times(10)).scope();
    }

    private static Fixture restrictedFixture(Set<UUID> visibleOwners) {
        EntityManager em = mock(EntityManager.class);
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        List<CapturedQuery> queries = captureQueries(em);
        OwnerScope ownerScope = new OwnerScope(false, visibleOwners);
        when(access.scope()).thenReturn(ownerScope);
        when(access.nativeReadScope(anyString(), eq(OWNERS_PARAM), eq(ownerScope))).thenAnswer(invocation -> {
            String ownerColumn = invocation.getArgument(0);
            return new NativeReadScope(
                    "(" + ownerColumn + " IS NULL OR " + ownerColumn + " IN (:" + OWNERS_PARAM + "))",
                    OWNERS_PARAM,
                    visibleOwners);
        });
        return fixture(em, access, queries);
    }

    private static Fixture viewAllFixture() {
        EntityManager em = mock(EntityManager.class);
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        List<CapturedQuery> queries = captureQueries(em);
        OwnerScope ownerScope = new OwnerScope(true, Set.of());
        when(access.scope()).thenReturn(ownerScope);
        when(access.nativeReadScope(anyString(), eq(OWNERS_PARAM), eq(ownerScope)))
                .thenReturn(new NativeReadScope("1=1", null, Set.of()));
        return fixture(em, access, queries);
    }

    private static Fixture fixture(EntityManager em, FinanceDocumentAccessPolicy access,
                                   List<CapturedQuery> queries) {
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readInt(anyString(), anyInt())).thenAnswer(invocation -> invocation.getArgument(1));
        FinanceStatementService statementService = mock(FinanceStatementService.class);
        FinanceCostService costService = mock(FinanceCostService.class);
        GlReportService glReportService = mock(GlReportService.class);
        FixedAssetService fixedAssetService = mock(FixedAssetService.class);
        ReportTableResponse empty = new ReportTableResponse(
                List.of(), List.of(), Map.of(), 1, 500, 0, 0);
        when(statementService.supplierStatement(null, null, null, 1, 500)).thenReturn(empty);
        when(costService.productCost(null, null, null, 1, 500)).thenReturn(empty);
        when(glReportService.trialBalance(null, null, 1, 500)).thenReturn(empty);
        when(fixedAssetService.depreciationSchedule()).thenReturn(empty);
        return new Fixture(
                new FinanceReportService(
                        em,
                        access,
                        settings,
                        statementService,
                        costService,
                        glReportService,
                        fixedAssetService),
                access,
                queries);
    }

    private static List<CapturedQuery> captureQueries(EntityManager em) {
        List<CapturedQuery> queries = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of());
            when(query.getSingleResult()).thenReturn(0L);
            queries.add(new CapturedQuery(invocation.getArgument(0), query));
            return query;
        });
        return queries;
    }

    private static boolean directlyReadsFinanceDocument(String sql) {
        return sql.contains("FROM finance_receipts ")
                || sql.contains("FROM finance_payments ")
                || sql.contains("JOIN finance_expenses ")
                || sql.contains("JOIN finance_other_incomes ");
    }

    private static String ownerAlias(String sql) {
        if (sql.contains("FROM finance_receipts receipt")) {
            return "receipt";
        }
        if (sql.contains("FROM finance_payments payment")) {
            return "payment";
        }
        return "t";
    }

    private record CapturedQuery(String sql, Query query) {
    }

    private record Fixture(FinanceReportService service,
                           FinanceDocumentAccessPolicy access,
                           List<CapturedQuery> queries) {
    }
}
