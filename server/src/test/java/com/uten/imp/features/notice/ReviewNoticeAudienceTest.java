package com.uten.imp.features.notice;

import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ReviewNoticeAudienceTest {
    @Test
    void everyRegisteredEventRejectsViewOnlyAndDepartmentOnlyRecipients() {
        Set<String> views = Set.of("notice:read", "sales_order_finance:view",
                "finance_order_approval:view", "procurement_inspection:view",
                "production_material_analysis:view", "production_execution:view",
                "warehouse_iqc_stock_in:view", "stock_doc:view", "warehouse_inbound:view",
                "sales_order:view", "procurement_iqc_rejection:view");
        Set<String> departments = Set.of("DEPT_FIN", "SUB_PLAN", "DEPT_PROD",
                "SUB_WH", "DEPT_QA", "SUB_PURCHASE", "DEPT_SALES", "DEPT_RAIL");
        for (String event : ReviewNoticeCatalog.events()) {
            assertThat(ReviewNoticeAudience.eligible(event, views, departments)).as(event).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read"), departments)).as(event).isFalse();
        }
    }

    @Test
    void financeRequiresDepartmentAndViewAndExactActionEvenForSuperAdmin() {
        Set<String> permissions = Set.of("notice:read", "sales_order_finance:view", "sales_order_finance:confirm");
        assertThat(ReviewNoticeAudience.eligible("SALES_ORDER_PENDING_FINANCE_CONFIRM",
                permissions, Set.of("DEPT_FIN"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible("SALES_ORDER_PENDING_FINANCE_CONFIRM",
                permissions, Set.of("GM"))).isFalse();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employeeId = UUID.randomUUID();
        AuthUser user = new AuthUser(UUID.randomUUID(), employeeId, "test", Set.of(),
                permissions, false, true, true);
        when(jdbc.queryForList(anyString(), eq(String.class), eq(employeeId), eq(employeeId)))
                .thenReturn(List.of("GM"));
        assertThat(new ReviewNoticeAudience(jdbc).eligibleEvents(user)).isEmpty();
    }

    @Test
    void currentPrimaryAndSecondaryMembershipIsQueriedOnceForTheWholeEventCatalog() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employeeId = UUID.randomUUID();
        Set<String> permissions = Set.of("notice:read", "finance_order_approval:view", "finance_order_approval:reject");
        AuthUser user = new AuthUser(UUID.randomUUID(), employeeId, "test", Set.of(),
                permissions, false, true, false);
        when(jdbc.queryForList(anyString(), eq(String.class), eq(employeeId), eq(employeeId)))
                .thenReturn(List.of("DEPT_FIN"));
        assertThat(new ReviewNoticeAudience(jdbc).eligibleEvents(user)).containsExactlyInAnyOrder(
                "PROCUREMENT_FINANCE_SUBMITTED", "PROCUREMENT_FINANCE_CHANGE_SUBMITTED");
        verify(jdbc, times(1)).queryForList(argThat(sql -> sql.contains("employee_secondary_departments")
                && sql.contains("employee.is_deleted = FALSE") && sql.contains("ancestry")),
                eq(String.class), eq(employeeId), eq(employeeId));
    }
}
