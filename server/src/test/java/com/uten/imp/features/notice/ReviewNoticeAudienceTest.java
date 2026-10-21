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
    void shipmentFinanceCardsRequireCurrentPageViewAndEitherDecisionPermission() {
        String event = "SALES_SHIPMENT_PENDING_FINANCE_AUDIT";
        for (String action : List.of("sales_shipment_finance:approve", "sales_shipment_finance:reject")) {
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read", action))).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read", "sales_shipment_finance:view", action))).isTrue();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read", "sales_shipment_finance:view"))).isFalse();
        }
    }

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

    /** Action eligibility needs no organization query; PostgreSQL routing tests cover the separate object responsibility. */
    @Test
    void warehouseEventEligibilityFollowsActionsWhileObjectsUseTheirSeparateResponsibilityGate() {
        var permissions = Set.of("notice:read", "warehouse_sales_outbound:view", "warehouse_sales_outbound:execute", "warehouse_iqc_stock_in:view",
                "warehouse_iqc_stock_in:confirm", "stock_doc:view", "stock_doc:approve", "stock_doc:issue",
                "warehouse_inbound:view", "warehouse_inbound:stock_in");
        var events = List.of("SALES_SHIPMENT_PENDING_PICK", "PROCUREMENT_IQC_STOCK_IN_PENDING", "PRODUCTION_DRAW_PENDING",
                "PRODUCTION_MATERIAL_DISCOVERY_PENDING", "PROCUREMENT_FINANCE_APPROVED");
        for (String event : events) {
            assertThat(ReviewNoticeAudience.eligible(event, permissions)).as(event).isTrue();
        }
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employee = UUID.randomUUID();
        UUID account = UUID.randomUUID();
        var keeper = new AuthUser(account, employee, "finance-keeper", permissions, false, true, false);
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(keeper)).containsAll(events);
        verifyNoInteractions(jdbc);
    }

    @Test
    void productionChangesRequireCurrentApprovalAndNoticePermissions() {
        var events=Set.of("PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED", "PRODUCTION_MATERIAL_INCREMENT_SUBMITTED");
        var permissions=Set.of("notice:read", "production_plan:approve");
        for(String event:events) {
            assertThat(ReviewNoticeCatalog.of(event)).isPresent();
            assertThat(ReviewNoticeAudience.eligible(event, permissions)).as(event).isTrue();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read", "production_plan:view"))).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("production_plan:approve"))).isFalse();
        }
        JdbcTemplate jdbc=mock(JdbcTemplate.class);
        UUID employee=UUID.randomUUID();
        var user=new AuthUser(UUID.randomUUID(),employee,"planner",permissions,false,true,false);
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(user)).containsAll(events);
        verifyNoInteractions(jdbc);
    }
    @Test
    void workshopMaterialEventsReachOnlyThePeopleWhoCanStillHandleThem() {
        // 领料 / 退料待办: 仓库发料人。
        for (String event : List.of("WORKSHOP_MATERIAL_REQUISITION_PENDING", "WORKSHOP_MATERIAL_RETURN_PENDING")) {
            assertThat(ReviewNoticeCatalog.of(event)).isPresent();
            assertThat(ReviewNoticeAudience.eligible(event,
                    Set.of("notice:read", "workshop_material:view", "workshop_material:issue"))).as(event).isTrue();
            assertThat(ReviewNoticeAudience.eligible(event,
                    Set.of("notice:read", "workshop_material:view", "workshop_material:request")))
                    .as(event).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event,
                    Set.of("workshop_material:view", "workshop_material:issue"))).as(event).isFalse();
        }
        // 未审报工拦住结算: 报工审核人, 或删掉 / 改好自己草稿的制单人。
        String report = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT";
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:view", "production_daily_report:approve"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:view", "production_daily_report:delete"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:create"))).isFalse();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "production_daily_report:view"))).isFalse();
        assertThat(ReviewNoticeAudience.eligible(report,
                Set.of("notice:read", "workshop_material:view", "workshop_material:issue"))).isFalse();
        // 缺单个重量: BOM 维护人。
        String weight = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_WEIGHT";
        assertThat(ReviewNoticeAudience.eligible(weight,
                Set.of("notice:read", "goods:view", "goods:bom:edit"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(weight,
                Set.of("notice:read", "goods:view", "goods:bom:view"))).isFalse();
        // 有理论没进过料: 仓库发料人或该车间的认料人；具体车间范围由发卡侧约束。
        String stock = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK";
        assertThat(ReviewNoticeAudience.eligible(stock,
                Set.of("notice:read", "workshop_material:view", "workshop_material:issue"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(stock,
                Set.of("notice:read", "workshop_material:view", "workshop_material:choose"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(stock,
                Set.of("notice:read", "workshop_material:view"))).isFalse();
        // 结算连续失败: 设置负责人。
        String failing = "WORKSHOP_MATERIAL_CLOSE_FAILING";
        assertThat(ReviewNoticeAudience.eligible(failing,
                Set.of("notice:read", "workshop_material:view", "workshop_material:setup"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(failing,
                Set.of("notice:read", "workshop_material:view", "workshop_material:count"))).isFalse();
    }

    @Test
    void everyRegisteredEventRejectsViewOnlyAndMissingActionRecipients() {
        Set<String> views = Set.of("notice:read", "sales_order_finance:view", "sales_quote_finance:view",
                "finance_order_approval:view", "procurement_inspection:view",
                "production_material_analysis:view", "production_execution:view",
                "warehouse_iqc_stock_in:view", "stock_doc:view", "warehouse_inbound:view",
                "sales_order:view", "procurement_iqc_rejection:view",
                "workshop_material:view", "production_daily_report:view", "goods:view");
        for (String event : ReviewNoticeCatalog.events()) {
            assertThat(ReviewNoticeAudience.eligible(event, views)).as(event).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read"))).as(event).isFalse();
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
    void financeRequiresCurrentViewAndExactGrantedActionWithoutOrganizationQueries() {
        Set<String> permissions = Set.of("notice:read", "sales_order_finance:view", "sales_order_finance:confirm");
        assertThat(ReviewNoticeAudience.eligible("SALES_ORDER_PENDING_FINANCE_CONFIRM",
                permissions)).isTrue();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employeeId = UUID.randomUUID();
        AuthUser user = new AuthUser(UUID.randomUUID(), employeeId, "test",
                permissions, false, true, true);
        var resolver = mock(com.uten.imp.features.auth.PermissionResolver.class);
        when(resolver.grantedPermsOf(user.getId())).thenReturn(permissions);
        var audience = new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), resolver);
        assertThat(audience.eligibleEvents(user)).containsExactly("SALES_ORDER_PENDING_FINANCE_CONFIRM");
        when(resolver.grantedPermsOf(user.getId())).thenReturn(Set.of("notice:read", "sales_order_finance:view"));
        assertThat(audience.eligibleEvents(user)).isEmpty();
        verifyNoInteractions(jdbc);
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
        assertThat(ReviewNoticeAudience.eligible(event, reviewer)).isTrue();
        assertThat(ReviewNoticeAudience.eligible(event,
                Set.of("notice:read", "sales_quote_finance:view", "sales_quote_finance:reject"))).isTrue();
        assertThat(ReviewNoticeAudience.eligible(event,
                Set.of("notice:read", "sales_quote_finance:view", "sales_quote_finance:reverse"))).isFalse();
        assertThat(ReviewNoticeAudience.eligible(event,
                Set.of("notice:read", "sales_quote_finance:view"))).isFalse();
        assertThat(ReviewNoticeAudience.eligible(event,
                Set.of("notice:read", "sales_order_finance:view", "sales_order_finance:confirm"))).isFalse();
    }

    @Test
    void functionAuthorityDoesNotRequireAnOrganizationLookup() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID employeeId = UUID.randomUUID();
        Set<String> permissions = Set.of("notice:read", "finance_order_approval:view", "finance_order_approval:reject");
        AuthUser user = new AuthUser(UUID.randomUUID(), employeeId, "test",
                permissions, false, true, false);
        when(jdbc.queryForList(anyString(), eq(String.class), eq(employeeId), eq(employeeId)))
                .thenReturn(List.of("DEPT_FIN"));
        assertThat(new ReviewNoticeAudience(jdbc, mock(com.uten.imp.security.OwnerVisibility.class), mock(com.uten.imp.features.auth.PermissionResolver.class)).eligibleEvents(user)).containsExactlyInAnyOrder(
                "PROCUREMENT_FINANCE_SUBMITTED", "PROCUREMENT_FINANCE_CHANGE_SUBMITTED");
        verifyNoInteractions(jdbc);
    }

    @Test
    void decompositionRequiresCreatingTheTargetOrderAndShortDeliveryHasAnExplicitActionContract() {
        var permissions = new java.util.HashSet<>(Set.of("notice:read", "subcontract_application:view",
                "subcontract_order:decompose"));
        assertThat(ReviewNoticeAudience.eligible("SUBCONTRACT_ORDER_KIT_READY", permissions)).isFalse();
        permissions.add("subcontract_order:create");
        assertThat(ReviewNoticeAudience.eligible("SUBCONTRACT_ORDER_KIT_READY", permissions)).isTrue();
        for (String event : List.of("SUBCONTRACT_SHORT_DELIVERY_DETECTED", "SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE")) {
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read", "subcontract_order:view"))).isFalse();
            assertThat(ReviewNoticeAudience.eligible(event, Set.of("notice:read", "subcontract_order:view",
                    "subcontract_short_delivery:decide"))).isTrue();
        }
    }

    @Test
    void unassignedSuperAdminCannotBuildAnOverLimitOrWorkshopReadScopeFromItsMirror() {
        var jdbc = mock(JdbcTemplate.class);
        var owners = mock(com.uten.imp.security.OwnerVisibility.class);
        var resolver = mock(com.uten.imp.features.auth.PermissionResolver.class);
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "admin", Set.of("notice:read",
                "production_plan:approve", "production_execution:view", "production_execution:start"), false, true, true);
        when(resolver.grantedPermsOf(user.getId())).thenReturn(Set.of("notice:read"));
        var scope = new ReviewNoticeAudience(jdbc, owners, resolver).readScope(user);
        assertThat(scope.overLimitAllowed()).isFalse();
        assertThat(scope.workshop().allowed()).isFalse();
        assertThat(scope.actionEvents()).isEmpty();
        verifyNoInteractions(owners, jdbc);
    }
}
