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
    void overLimitReadScopeUsesTheCanonicalCurrentOwnerScopeOnlyForApprovers() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        var owners = mock(com.uten.imp.security.OwnerVisibility.class);
        UUID owner = UUID.randomUUID();
        when(owners.evaluate("production_plan", "production_plan:view:all"))
                .thenReturn(new com.uten.imp.security.OwnerVisibility.OwnerScope(false, Set.of(owner)));
        var audience = new ReviewNoticeAudience(jdbc, owners, mock(com.uten.imp.features.auth.PermissionResolver.class));
        AuthUser planner = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "planner",
                Set.of("notice:read", "production_plan:approve"), false, true, false);
        var scope = audience.readScope(planner);
        assertThat(scope.overLimitAllowed()).isTrue();
        assertThat(scope.overLimitSeeAll()).isFalse();
        assertThat(scope.overLimitOwners()).isEqualTo(owner.toString());
        assertThat(scope.workshop().allowed()).isFalse();
        verify(owners).evaluate("production_plan", "production_plan:view:all");
        AuthUser reader = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader",
                Set.of("notice:read", "production_plan:view"), false, true, false);
        assertThat(audience.readScope(reader).overLimitAllowed()).isFalse();
        verifyNoMoreInteractions(owners);
    }

    /**
     * ADR-149: 仓库类通知池按仓纳入了部门外登记的仓库负责人(如财务部的人负责五金仓库), 弹卡资格同口径,
     * 否则发给他的待办只躺在通知列表里不弹卡。没登记负责人的部门外的人仍然不弹。
     */
    @Test
    void outOfDepartmentWarehouseKeepersGetTheWarehouseActionCards() {
        var permissions = Set.of("notice:read", "warehouse_sales_outbound:execute", "warehouse_iqc_stock_in:view",
                "warehouse_iqc_stock_in:confirm", "stock_doc:view", "stock_doc:approve", "stock_doc:issue",
                "warehouse_inbound:view", "warehouse_inbound:stock_in");
        var events = List.of("SALES_SHIPMENT_PENDING_PICK", "PROCUREMENT_IQC_STOCK_IN_PENDING", "PRODUCTION_DRAW_PENDING",
                "PRODUCTION_MATERIAL_DISCOVERY_PENDING", "PROCUREMENT_FINANCE_APPROVED");
        for (String event : events) {
            assertThat(ReviewNoticeAudience.eligible(event, permissions, Set.of("DEPT_FIN"), true)).as(event).isTrue();
            assertThat(ReviewNoticeAudience.eligible(event, permissions, Set.of("DEPT_FIN"), false)).as(event).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, permissions, Set.of("SUB_WH"), false)).as(event).isTrue();
        }
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employee = UUID.randomUUID();
        UUID account = UUID.randomUUID();
        var keeper = new AuthUser(account, employee, "finance-keeper", permissions, false, true, false);
        when(jdbc.queryForList(anyString(), eq(String.class), eq(employee), eq(employee))).thenReturn(List.of("DEPT_FIN"));
        when(jdbc.queryForObject(contains("fn_warehouse_responsible_user_ids"), eq(Boolean.class), eq(account)))
                .thenReturn(true);
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(keeper)).containsAll(events);
        when(jdbc.queryForObject(contains("fn_warehouse_responsible_user_ids"), eq(Boolean.class), eq(account)))
                .thenReturn(false);
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(keeper)).doesNotContainAnyElementsOf(events);
    }

    @Test
    void productionChangesReachTheCurrentPlanningReviewPoolAndStopAfterPermissionOrMembershipRemoval() {
        var events=Set.of("PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED", "PRODUCTION_MATERIAL_INCREMENT_SUBMITTED");
        var permissions=Set.of("notice:read", "production_plan:approve");
        for(String event:events) {
            assertThat(ReviewNoticeCatalog.of(event)).isPresent();
            assertThat(ReviewNoticeAudience.eligible(event, permissions, Set.of("SUB_PLAN"))).as(event).isTrue();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read", "production_plan:view"), Set.of("SUB_PLAN"))).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, permissions, Set.of("SUB_WH"))).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("production_plan:approve"), Set.of("SUB_PLAN"))).isFalse();
        }
        JdbcTemplate jdbc=mock(JdbcTemplate.class);
        UUID employee=UUID.randomUUID();
        var user=new AuthUser(UUID.randomUUID(),employee,"planner",permissions,false,true,false);
        when(jdbc.queryForList(anyString(),eq(String.class),eq(employee),eq(employee))).thenReturn(List.of("SUB_PLAN"));
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(user)).containsAll(events);
    }
    @Test
    void workshopMaterialEventsReachOnlyThePeopleWhoCanStillHandleThem() {
        Set<String> none = Set.of();
        // 领料 / 退料待办: 仓库发料人。
        for (String event : List.of("WORKSHOP_MATERIAL_REQUISITION_PENDING", "WORKSHOP_MATERIAL_RETURN_PENDING")) {
            assertThat(ReviewNoticeCatalog.of(event)).isPresent();
            assertThat(ReviewNoticeAudience.eligible(event,
                    Set.of("notice:read", "workshop_material:view", "workshop_material:issue"), none)).as(event).isTrue();
            assertThat(ReviewNoticeAudience.eligible(event,
                    Set.of("notice:read", "workshop_material:view", "workshop_material:request"), Set.of("DEPT_PROD")))
                    .as(event).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event,
                    Set.of("workshop_material:view", "workshop_material:issue"), none)).as(event).isFalse();
        }
        // 未审报工拦住结算: 报工审核人, 或删掉 / 改好自己草稿的制单人。
        String report = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT";
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:view", "production_daily_report:approve"), none)).isTrue();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:view", "production_daily_report:delete"), none)).isTrue();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:create"), none)).isTrue();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:view"), none)).isFalse();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "workshop_material:view", "workshop_material:issue"), none)).isFalse();
        // 缺单个重量: BOM 维护人。
        String weight = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_WEIGHT";
        assertThat(ReviewNoticeAudience.eligible(weight,
                Set.of("notice:read", "goods:bom:edit"), none)).isTrue();
        assertThat(ReviewNoticeAudience.eligible(weight,
                Set.of("notice:read", "goods:view", "goods:bom:view"), none)).isFalse();
        // 有理论没进过料: 仓库发料人, 或仍在生产部子树的车间认料人。
        String stock = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK";
        assertThat(ReviewNoticeAudience.eligible(stock,
                Set.of("notice:read", "workshop_material:view", "workshop_material:issue"), Set.of("SUB_WH"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(stock,
                Set.of("notice:read", "workshop_material:view", "workshop_material:choose"), Set.of("DEPT_PROD"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(stock,
                Set.of("notice:read", "workshop_material:view", "workshop_material:choose"), Set.of("SUB_WH"))).isFalse();
        assertThat(ReviewNoticeAudience.eligible(stock,
                Set.of("notice:read", "workshop_material:view"), Set.of("SUB_WH", "DEPT_PROD"))).isFalse();
        // 结算连续失败: 设置负责人。
        String failing = "WORKSHOP_MATERIAL_CLOSE_FAILING";
        assertThat(ReviewNoticeAudience.eligible(failing,
                Set.of("notice:read", "workshop_material:setup"), none)).isTrue();
        assertThat(ReviewNoticeAudience.eligible(failing,
                Set.of("notice:read", "workshop_material:view", "workshop_material:count"), none)).isFalse();
    }

    @Test
    void everyRegisteredEventRejectsViewOnlyAndDepartmentOnlyRecipients() {
        Set<String> views = Set.of("notice:read", "sales_order_finance:view", "sales_quote_finance:view",
                "finance_order_approval:view", "procurement_inspection:view",
                "production_material_analysis:view", "production_execution:view",
                "warehouse_iqc_stock_in:view", "stock_doc:view", "warehouse_inbound:view",
                "sales_order:view", "procurement_iqc_rejection:view",
                "workshop_material:view", "production_daily_report:view", "goods:view");
        Set<String> departments = Set.of("DEPT_FIN", "SUB_PLAN", "DEPT_PROD",
                "SUB_WH", "DEPT_QA", "SUB_PURCHASE", "DEPT_SALES", "DEPT_RAIL");
        for (String event : ReviewNoticeCatalog.events()) {
            assertThat(ReviewNoticeAudience.eligible(event, views, departments)).as(event).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read"), departments)).as(event).isFalse();
        }
    }

    @Test
    void superAdminEligibilityUsesReallyGrantedAuthoritiesNotTheMirror() {
        // 2026-10-09(ADR-063 追加修订)：超管的全量目录码是操作授权面，不是任务归属——
        // 弹卡资格(含「通知设置」列表)按真实授出权限判定，否则超管被放大成全事件。
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employeeId = UUID.randomUUID();
        UUID accountId = UUID.randomUUID();
        // 会话里的镜像权限看起来什么都有（含盘点审核/人事/仓库）。
        AuthUser admin = new AuthUser(accountId, employeeId, "admin", Set.of(
                "notice:read", "stock:count:finance_review", "stock:count:warehouse_review",
                "expense:approve", "warehouse_inbound:stock_in", "subcontract_order:draw"),
                false, true, true);
        when(jdbc.queryForList(anyString(), eq(String.class), eq(employeeId), eq(employeeId)))
                .thenReturn(List.of("DEPT_FIN"));
        var resolver = mock(com.uten.imp.features.auth.PermissionResolver.class);
        var audience = new ReviewNoticeAudience(jdbc,
                mock(com.uten.imp.security.OwnerVisibility.class), resolver);

        // 真实只有全员基础包 → 资格面为空（纯权限事件一个都不弹、也不进设置列表）。
        when(resolver.grantedPermsOf(accountId)).thenReturn(Set.of("notice:read"));
        assertThat(audience.eligibleEvents(admin)).isEmpty();

        // 真实加授销售财务确认两码 → 恰好只有财务确认事件。
        when(resolver.grantedPermsOf(accountId)).thenReturn(Set.of(
                "notice:read", "sales_order_finance:view", "sales_order_finance:confirm"));
        assertThat(audience.eligibleEvents(admin))
                .containsExactly("SALES_ORDER_PENDING_FINANCE_CONFIRM");
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
        AuthUser user = new AuthUser(UUID.randomUUID(), employeeId, "test",
                permissions, false, true, true);
        when(jdbc.queryForList(anyString(), eq(String.class), eq(employeeId), eq(employeeId)))
                .thenReturn(List.of("GM"));
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(user)).isEmpty();
    }

    @Test
    void quoteFinanceReviewCardIsAnActionCardForFinanceReviewersOnly() {
        String event = "SALES_QUOTE_PENDING_FINANCE_REVIEW";
        assertThat(ReviewNoticeCatalog.of(event)).hasValueSatisfying(entry -> {
            assertThat(entry.aggregateKind()).isEqualTo("SALES_QUOTE");
            assertThat(entry.claimTargetType()).isEqualTo("SALES_QUOTE_FINANCE_REVIEW");
        });
        // 退回/确认/撤销确认是发给负责销售的普通通知: 不能登记, 否则按报价撤卡时会被一起撤掉。
        assertThat(ReviewNoticeCatalog.isReviewEvent("SALES_QUOTE_FINANCE_RETURNED")).isFalse();
        assertThat(ReviewNoticeCatalog.isReviewEvent("SALES_QUOTE_FINANCE_CONFIRMED")).isFalse();
        assertThat(ReviewNoticeCatalog.isReviewEvent("SALES_QUOTE_FINANCE_REOPENED")).isFalse();
        Set<String> reviewer = Set.of("notice:read", "sales_quote_finance:view", "sales_quote_finance:confirm");
        assertThat(ReviewNoticeAudience.eligible(event, reviewer, Set.of("DEPT_FIN"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(event, reviewer, Set.of("DEPT_SALES"))).isFalse();
        assertThat(ReviewNoticeAudience.eligible(event,
                Set.of("notice:read", "sales_quote_finance:view"), Set.of("DEPT_FIN"))).isFalse();
        assertThat(ReviewNoticeAudience.eligible(event,
                Set.of("notice:read", "sales_order_finance:view", "sales_order_finance:confirm"),
                Set.of("DEPT_FIN"))).isFalse();
    }

    @Test
    void currentPrimaryAndSecondaryMembershipIsQueriedOnceForTheWholeEventCatalog() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employeeId = UUID.randomUUID();
        Set<String> permissions = Set.of("notice:read", "finance_order_approval:view", "finance_order_approval:reject");
        AuthUser user = new AuthUser(UUID.randomUUID(), employeeId, "test",
                permissions, false, true, false);
        when(jdbc.queryForList(anyString(), eq(String.class), eq(employeeId), eq(employeeId)))
                .thenReturn(List.of("DEPT_FIN"));
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(user)).containsExactlyInAnyOrder(
                "PROCUREMENT_FINANCE_SUBMITTED", "PROCUREMENT_FINANCE_CHANGE_SUBMITTED");
        verify(jdbc, times(1)).queryForList(argThat(sql -> sql.contains("employee_secondary_departments")
                && sql.contains("employee.is_deleted = FALSE") && sql.contains("ancestry")),
                eq(String.class), eq(employeeId), eq(employeeId));
    }
}
