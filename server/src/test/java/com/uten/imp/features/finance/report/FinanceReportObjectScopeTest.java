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
import org.springframework.security.access.prepost.PreAuthorize;

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
    void arApPartyLocationEndpointRequiresFinanceReportView() throws Exception {
        var method = FinanceReportController.class.getDeclaredMethod(
                "arApPartyLocations", String.class, int.class, int.class);

        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('finance_report:view')");
    }

    @Test
    void financeWidePartyLocationsDoNotUseClientOwnerVisibility() {
        // 该 fixture 只表达 finance:view:all，没有 client:view:all；定位必须仍与公司级报表同范围。
        Fixture fixture = viewAllFixture();

        var response = fixture.service().arApPartyLocations("  C-002  ", 2, 25);

        assertThat(response.getPage()).isEqualTo(2);
        assertThat(response.getSize()).isEqualTo(25);
        assertThat(fixture.queries()).hasSize(2);
        CapturedQuery data = fixture.queries().get(0);
        CapturedQuery count = fixture.queries().get(1);
        assertThat(data.sql())
                .contains("FROM clients c")
                .contains("FROM suppliers s")
                .contains("LOWER(COALESCE(c.name,'')) LIKE :locationKw")
                .contains("LOWER(COALESCE(c.code,'')) LIKE :locationKw")
                .contains("LOWER(COALESCE(s.name,'')) LIKE :locationKw")
                .contains("LOWER(COALESCE(s.code,'')) LIKE :locationKw")
                .contains("UNION")
                .contains("ORDER BY party_type ASC, category_id ASC NULLS LAST")
                .doesNotContain("owner_employee_id")
                .doesNotContain("clientOwners");
        assertThat(count.sql())
                .startsWith("SELECT COUNT(*) FROM (")
                .contains("UNION")
                .doesNotContain("owner_employee_id");
        verify(data.query()).setParameter("locationKw", "%c-002%");
        verify(data.query()).setParameter("locationLimit", 25);
        verify(data.query()).setParameter("locationOffset", 25L);
        verify(count.query()).setParameter("locationKw", "%c-002%");
        verify(fixture.access(), times(1)).scope();
    }

    @Test
    void partyLocationsAreDeduplicatedStableAndMappedAcrossPages() {
        UUID clientCategory = UUID.randomUUID();
        UUID supplierCategory = UUID.randomUUID();
        // createNativeQuery is invoked lazily by the service, so prepare deterministic rows
        // through a fresh fixture whose first query mock returns both party types.
        EntityManager em = mock(EntityManager.class);
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(new OwnerScope(true, Set.of()));
        List<CapturedQuery> queries = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            if (queries.isEmpty()) {
                List<Object[]> locationRows = new ArrayList<>();
                locationRows.add(new Object[]{"CLIENT", clientCategory});
                locationRows.add(new Object[]{"SUPPLIER", supplierCategory});
                locationRows.add(new Object[]{"SUPPLIER", null});
                when(query.getResultList()).thenReturn(locationRows);
            } else {
                when(query.getSingleResult()).thenReturn(203L);
            }
            queries.add(new CapturedQuery(invocation.getArgument(0), query));
            return query;
        });
        FinanceReportService service = fixture(em, access, queries).service();

        var response = service.arApPartyLocations("party", 2, 100);

        assertThat(response.getItems())
                .containsExactly(
                        new ArApPartyLocation("CLIENT", clientCategory),
                        new ArApPartyLocation("SUPPLIER", supplierCategory),
                        new ArApPartyLocation("SUPPLIER", null));
        assertThat(response.getTotal()).isEqualTo(203);
        assertThat(response.getTotalPages()).isEqualTo(3);
        assertThat(queries.get(0).sql())
                .contains("UNION")
                .doesNotContain("UNION ALL")
                .contains("ORDER BY party_type ASC, category_id ASC NULLS LAST");
        verify(queries.get(0).query()).setParameter("locationOffset", 100L);
    }

    @Test
    void arApOverviewKeywordMatchesPartyNameAndCodeWithOneBoundParameter() {
        Fixture fixture = viewAllFixture();

        fixture.service().arApOverview(
                LocalDate.of(2026, 1, 1),
                LocalDate.of(2026, 12, 31),
                "ALL",
                "  ACME-001  ",
                null,
                null,
                1,
                50);

        // 列表 + 计数 + 服务端合计（ReportTotalsCalculator 把同一份 where 包一层 SUM）。
        // 合计查询也必须原样带上关键词谓词与同一个 :kw 绑定，否则表尾合计会比列表多算。
        assertThat(fixture.queries()).hasSize(3);
        for (CapturedQuery captured : fixture.queries()) {
            assertThat(captured.sql())
                    .contains("COALESCE(c.code,'') AS partyCode")
                    .contains("COALESCE(s.code,'') AS partyCode")
                    .contains("LOWER(COALESCE(partyName,'')) LIKE LOWER(:kw)")
                    .contains("LOWER(COALESCE(partyCode,'')) LIKE LOWER(:kw)");
            verify(captured.query()).setParameter("kw", "%acme-001%");
        }
    }

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
        // 列表 + 计数 + 两条服务端合计（按分组维度归并，一维一条）。
        // 合计查询是把列表 SQL 整个包进 FROM (...) t，所以同样直读凭证表——
        // 它必须和列表走同一份归属谓词，否则 view:all 之外的人能从表尾合计里反推总额。
        assertThat(sensitiveQueries).hasSize(4);
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
                () -> service.arApPartyLocations("customer", 1, 100),
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

        ApiException accountStatementError = assertThrows(
                ApiException.class,
                () -> service.accountStatement(null, null, null, null, 1, 50));
        assertThat(accountStatementError.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertThat(accountStatementError.getMessage()).contains("账户流水要求同时具备");

        assertThat(fixture.queries()).isEmpty();
        verify(fixture.access(), times(companyEntries.size())).scope();
    }

    @Test
    void dedicatedAccountAuthoritiesAllowStatementWithoutFinanceViewAllScope() {
        Fixture fixture = restrictedFixture(Set.of(UUID.randomUUID()));
        when(fixture.access().hasAuthority("account:view")).thenReturn(true);
        when(fixture.access().hasAuthority("account:balance:view")).thenReturn(true);
        when(fixture.access().hasAuthority("account:flow:view")).thenReturn(true);

        fixture.service().accountStatement(
                UUID.randomUUID(),
                null,
                LocalDate.of(2026, 12, 31),
                null,
                1,
                50);

        assertThat(fixture.queries()).hasSize(1);
        assertThat(fixture.queries().get(0).sql())
                .contains("FROM finance_reconciliations flow")
                .doesNotContain(OWNERS_PARAM);
        verify(fixture.access(), never()).scope();
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
        verify(fixture.access(), times(9)).scope();
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
