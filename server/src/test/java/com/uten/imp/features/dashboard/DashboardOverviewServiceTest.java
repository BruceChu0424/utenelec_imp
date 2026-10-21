package com.uten.imp.features.dashboard;

import com.uten.imp.application.port.SalesDocumentReadScopePort;
import com.uten.imp.application.port.WorkbenchBadgeReadPort;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Transactional;

import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class DashboardOverviewServiceTest {
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final AuthUser user = mock(AuthUser.class);
    private final NoticeService notices = mock(NoticeService.class);
    private final SalesDocumentReadScopePort salesAccess = mock(SalesDocumentReadScopePort.class);
    private final WorkbenchBadgeReadPort badges = mock(WorkbenchBadgeReadPort.class);
    private final UUID employee = UUID.randomUUID();
    private final Set<String> grantedEntries = new HashSet<>();
    private final Set<String> staleEntries = new HashSet<>();
    private final Map<String, Long> todo = new HashMap<>(Map.of(
            "productionSchedule", 4L, "warehouseOutboundCenter", 14L, "warehouseInboundCenter", 21L,
            "purchaseTaskCenter", 6L, "subcontractTaskCenter", 7L, "visitorApproval", 2L,
            "hrProfileReview", 1L, "expenseFinance", 5L));
    private final Map<String, Long> facts = Map.of(
            "productionSchedule.overdue", 1L, "productionSchedule.urgent", 2L,
            "productionDraw.count", 4L, "productionReturn.count", 1L,
            "expense.pendingApprovalCount", 3L, "expense.pendingPaymentCount", 2L);
    private DashboardOverviewService service;

    @BeforeEach void before() {
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(user.getEmployeeId()).thenReturn(employee);
        when(user.getPermissions()).thenReturn(Set.of());
        department("DEPT_PROD");
        when(salesAccess.nativeReadScope(anyString(), anyString()))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope("1=1", null, Set.of()));
        when(badges.entries(any())).thenAnswer(invocation -> {
            Set<String> requested = invocation.getArgument(0);
            Map<String, Long> visible = new HashMap<>();
            requested.stream().filter(grantedEntries::contains).filter(todo::containsKey)
                    .forEach(entry -> visible.put(entry, todo.get(entry)));
            return new WorkbenchBadgeReadPort.Entries(visible, facts, Set.copyOf(staleEntries));
        });
        service = new DashboardOverviewService(currentUser, jdbc, notices, salesAccess, badges);
    }

    @Test void overviewDoesNotWrapPartitionsInSharedTransaction() throws Exception {
        assertThat(DashboardOverviewService.class.isAnnotationPresent(Transactional.class)).isFalse();
        assertThat(DashboardOverviewService.class.getDeclaredMethod("overview")
                .isAnnotationPresent(Transactional.class)).isFalse();
    }

    @Test void financeAmountsRemainAbsentEvenWithSensitiveReadPermissions() {
        when(user.getPermissions()).thenReturn(Set.of("account:view", "ar_ap_ledger:view"));
        assertThat(service.overview().metrics()).extracting(DashboardOverviewDto.MetricCard::id)
                .doesNotContain("cash-balance", "ar-balance", "ap-balance");
        verify(jdbc, never()).queryForObject(contains("FROM accounts"),
                org.mockito.ArgumentMatchers.<Class<?>>any());
        verifyNoInteractions(salesAccess);
    }

    @Test void overviewNoLongerCarriesOrQueriesPolicyIntelligence() {
        service.overview();
        com.fasterxml.jackson.databind.JsonNode wire = new com.fasterxml.jackson.databind.ObjectMapper()
                .findAndRegisterModules().valueToTree(service.overview());
        var fields = new java.util.ArrayList<String>();
        wire.fieldNames().forEachRemaining(fields::add);
        assertThat(fields)
                .containsExactly("departmentCode", "departmentName", "generatedAt", "metrics", "todos");
        assertThat(mockingDetails(jdbc).getInvocations())
                .flatExtracting(invocation -> java.util.Arrays.asList(invocation.getArguments()))
                .noneSatisfy(argument -> assertThat(String.valueOf(argument)).containsIgnoringCase("official_policy_briefs"));
    }

    @ParameterizedTest
    @CsvSource({
            "DEPT_PROD,visitorApproval,visitor-approval", "DEPT_FIN,visitorApproval,visitor-approval",
            "DEPT_PROD,hrProfileReview,profile-review", "DEPT_HR,expenseFinance,expense-approval",
            "GM,purchaseTaskCenter,fulfillment-purchase", "DEPT_FIN,subcontractTaskCenter,fulfillment-subcontract",
            "DEPT_SALES,warehouseOutboundCenter,fulfillment-warehouse-draw"
    })
    void authorizedBadgeEntryAppearsRegardlessOfTheEmployeesDepartment(String department, String entry, String id) {
        department(department);
        grantedEntries.add(entry);
        assertThat(service.overview().todos()).extracting(DashboardOverviewDto.TodoCard::id).contains(id);
    }

    @Test void membershipAloneNeverCreatesATodoWhenTheBadgePortDoesNotAuthorizeIt() {
        department("DEPT_FIN");
        assertThat(service.overview().todos()).isEmpty();
        department("DEPT_HR");
        assertThat(service.overview().todos()).isEmpty();
    }

    @Test void overviewRequestsRegisteredEntriesAndLetsTheirExistingPoliciesApply() {
        department("GM");
        service.overview();
        verify(badges).entries(Set.of("productionSchedule", "warehouseOutboundCenter", "warehouseInboundCenter",
                "purchaseTaskCenter", "subcontractTaskCenter", "visitorApproval", "hrProfileReview", "expenseFinance"));
    }

    @Test void salesMetricRetainsTheDocumentOwnerScopeAcrossDepartments() {
        department("DEPT_FIN");
        when(user.getPermissions()).thenReturn(Set.of("sales_order:view"));
        when(salesAccess.nativeReadScope("o.owner_employee_id", "dashboardOwners"))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope(
                        "o.owner_employee_id IN (:dashboardOwners)", "dashboardOwners", Set.of(employee)));
        when(jdbc.queryForObject(contains("o.owner_employee_id IN (?)"), eq(Long.class), eq(employee))).thenReturn(2L);
        assertThat(service.overview().metrics()).singleElement().satisfies(metric -> {
            assertThat(metric.id()).isEqualTo("sales-active");
            assertThat(metric.value()).isEqualTo("2");
        });
        verify(jdbc).queryForObject(contains("o.owner_employee_id IN (?)"), eq(Long.class), eq(employee));
    }

    @Test void financeTodosReuseBadgeFactsWithoutRecountingDocuments() {
        grantedEntries.add("expenseFinance");
        DashboardOverviewDto result = service.overview();
        assertThat(result.todos()).extracting(DashboardOverviewDto.TodoCard::id, DashboardOverviewDto.TodoCard::count)
                .containsExactly(org.assertj.core.groups.Tuple.tuple("expense-approval", 3L),
                        org.assertj.core.groups.Tuple.tuple("expense-payment", 2L));
        assertThat(result.todos()).extracting(DashboardOverviewDto.TodoCard::route)
                .containsExactly("/expense/approval?queue=pending", "/expense/approval?queue=payable");
        verify(jdbc, never()).queryForObject(contains("expense_claims"), eq(Long.class), any(Object[].class));
    }

    @Test void warehouseDirectionsUseTheirLeafFactsWithoutCountingTheLegacyAlias() {
        grantedEntries.addAll(Set.of("warehouseOutboundCenter", "warehouseInboundCenter", "warehouseDrawCenter"));
        todo.put("warehouseDrawCenter", 5L);
        DashboardOverviewDto result = service.overview();
        assertThat(result.todos()).extracting(DashboardOverviewDto.TodoCard::id)
                .containsExactly("fulfillment-warehouse-draw", "fulfillment-warehouse-return");
        assertThat(result.todos()).extracting(DashboardOverviewDto.TodoCard::count).containsExactly(4L, 1L);
        assertThat(result.todos()).extracting(DashboardOverviewDto.TodoCard::route)
                .containsExactly("/warehouse/tasks/outbound?section=DRAW", "/warehouse/tasks/inbound?section=RETURN");
    }

    @Test void legacyAliasDoesNotAuthorizeEitherWarehouseDirection() {
        grantedEntries.add("warehouseDrawCenter");
        todo.put("warehouseDrawCenter", 5L);
        assertThat(service.overview().todos()).isEmpty();
    }

    @Test void productionMetricAndTodoUseAuthorizedScheduleFactsOutsideProduction() {
        department("DEPT_HR");
        grantedEntries.add("productionSchedule");
        DashboardOverviewDto result = service.overview();
        assertThat(result.metrics()).singleElement().satisfies(metric -> {
            assertThat(metric.id()).isEqualTo("production-pending");
            assertThat(metric.value()).isEqualTo("4");
            assertThat(metric.subtitle()).isEqualTo("1 个已逾期");
        });
        assertThat(result.todos()).singleElement().satisfies(value -> {
            assertThat(value.count()).isEqualTo(4);
            assertThat(value.urgentCount()).isEqualTo(2);
        });
    }

    @Test void missingAndStaleSourcesStayHiddenWithoutHidingOtherGrantedEntries() {
        grantedEntries.addAll(Set.of("visitorApproval", "hrProfileReview", "expenseFinance"));
        staleEntries.add("visitorApproval");
        todo.remove("hrProfileReview");
        assertThat(service.overview().todos()).extracting(DashboardOverviewDto.TodoCard::id)
                .containsExactly("expense-approval", "expense-payment");
    }

    @Test void superAdminUsesAuthorizedBadgeEntriesWithoutAnEmployeeDepartmentRequirement() {
        when(user.isSuperAdmin()).thenReturn(true);
        when(user.getEmployeeId()).thenReturn(null);
        grantedEntries.addAll(Set.of("expenseFinance", "visitorApproval", "productionSchedule"));
        DashboardOverviewDto result = service.overview();
        assertThat(result.todos()).extracting(DashboardOverviewDto.TodoCard::id)
                .contains("expense-approval", "visitor-approval", "production-pending");
        assertThat(result.departmentCode()).isEqualTo("UNKNOWN");
    }

    @Test void departmentIsDisplayInformationAndDoesNotChangeTheGrantedTodoSet() {
        grantedEntries.add("expenseFinance");
        department("DEPT_PROD");
        DashboardOverviewDto before = service.overview();
        department("DEPT_HR");
        DashboardOverviewDto after = service.overview();
        assertThat(after.todos()).isEqualTo(before.todos());
        assertThat(before.departmentName()).isEqualTo("DEPT_PROD");
        assertThat(after.departmentName()).isEqualTo("DEPT_HR");
    }

    private void department(String code) {
        when(jdbc.queryForList(anyString(), eq(employee)))
                .thenReturn(List.of(Map.of("code", code, "name", code)));
    }
}
