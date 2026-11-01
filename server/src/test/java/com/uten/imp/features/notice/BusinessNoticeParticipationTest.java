package com.uten.imp.features.notice;

import org.junit.jupiter.api.Test;
import java.util.HashSet;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class BusinessNoticeParticipationTest {
    @Test void readOnlyObserversAreSilentForEveryRegisteredActionAndOrdinaryReceipt() {
        Set<String> readers=new HashSet<>(Set.of("notice:read","sales:view:all","expense:view:all",
                "profile_change:view","visitor_approval:view","stock:count:finance_view"));
        BusinessNoticeParticipation.RULES.forEach(rule->rule.alternatives().forEach(alternative->alternative.stream()
                .filter(code->code.endsWith(":view") || code.endsWith(":read")).forEach(readers::add)));
        ReviewNoticeCatalog.events().forEach(event->assertThat(BusinessNoticeParticipation.allowed(null,event,readers)).as(event).isFalse());
        BusinessNoticeActionCatalog.events().forEach(event->assertThat(BusinessNoticeParticipation.allowed(null,event,readers)).as(event).isFalse());
        for(String route:Set.of("/sales/orders/123","/production/plans/123","/purchase/orders/123","/subcontract/orders/123",
                "/hr/profile-changes/123","/visitor-approval/123","/expense/approval/123","/finance/stock-count-review")) {
            assertThat(BusinessNoticeParticipation.allowed(route,null,readers)).as(route).isFalse();
        }
    }

    @Test void grantingAndRevokingTheCorrespondingActionChangesSubscriptionWithoutDepartmentChecks() {
        var permissions=new HashSet<>(Set.of("notice:read","sales_order:view","sales:view:all"));
        String route="/sales/orders/123";
        assertThat(BusinessNoticeParticipation.allowed(route,"SALES_ORDER_FINANCE_REJECTED",permissions)).isFalse();
        permissions.add("purchase_order:edit");
        assertThat(BusinessNoticeParticipation.allowed(route,null,permissions)).isFalse();
        permissions.add("sales_order:edit");
        assertThat(BusinessNoticeParticipation.allowed(route,"SALES_ORDER_FINANCE_REJECTED",permissions)).isTrue();
        assertThat(BusinessNoticeParticipation.allowed(route,"SALES_ORDER_CANCELED",permissions)).isTrue();
        permissions.remove("sales_order:edit");
        assertThat(BusinessNoticeParticipation.allowed(route,"SALES_ORDER_CANCELED",permissions)).isFalse();
    }

    @Test void preciseActionEventsCannotBeEnabledByAnUnrelatedActionOnTheSamePage() {
        Set<String> editor=Set.of("notice:read","sales_order:view","sales_order:edit");
        assertThat(BusinessNoticeParticipation.allowed("/sales/orders/123","SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP",editor)).isFalse();
        assertThat(BusinessNoticeParticipation.allowed("/sales/orders/123","SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP",
                Set.of("notice:read","sales_order:view","sales_shipment:view","sales_shipment:create"))).isTrue();
    }

    @Test void profileResultReceiptsRequireTheSubmittersLiveActionGrantEvenWithoutARoute() {
        for (String event : Set.of("PROFILE_CHANGE_APPROVED", "PROFILE_CHANGE_REJECTED")) {
            assertThat(BusinessNoticeParticipation.requiresPermission(null, event)).isTrue();
            assertThat(BusinessNoticeParticipation.allowed("/profile/edit", event,
                    Set.of("notice:read", "profile_change:view", "profile:review"))).isFalse();
            assertThat(BusinessNoticeParticipation.allowed(null, event,
                    Set.of("notice:read", "profile:edit:self"))).isTrue();
            assertThat(BusinessNoticeParticipation.allowed(null, event, Set.of("notice:read"))).isFalse();
        }
    }

    @Test void legacyProfileResultClassificationLeavesAnnouncementsAndDifferentBodiesAlone() {
        for (var example : LegacyProfileResultNoticeFixture.examples(java.util.UUID.randomUUID())) {
            assertThat(BusinessNoticeParticipation.legacyProfileResult(example.notice())).isEqualTo(example.legacyResult());
            assertThat(BusinessNoticeParticipation.allowed(example.notice(),Set.of("notice:read","profile_change:view")))
                    .isEqualTo(!example.legacyResult());
            assertThat(BusinessNoticeParticipation.allowed(example.notice(),Set.of("notice:read","profile:edit:self"))).isTrue();
            assertThat(example.notice().getAggregateId()).isNull();
        }
    }

    @Test void businessFutureRoutesFailClosedWhileAnnouncementsAndAccountSecurityKeepTheirAudience() {
        assertThat(BusinessNoticeParticipation.allowed("/sales/new-workflow",null,Set.of("notice:read"))).isFalse();
        assertThat(BusinessNoticeParticipation.allowed(null,"PRODUCTION_NEW_ACTION",Set.of("notice:read"))).isFalse();
        assertThat(BusinessNoticeParticipation.allowed(null,null,Set.of())).isTrue();
        assertThat(BusinessNoticeParticipation.allowed("/settings/security","ACCOUNT_SECURITY_CHANGED",Set.of())).isTrue();
        assertThat(BusinessNoticeParticipation.allowed("/admin/server-status",null,Set.of("server_status:view","notice:read"))).isFalse();
        assertThat(BusinessNoticeParticipation.allowed("/admin/server-status",null,Set.of("server_status:alert:receive","notice:read"))).isTrue();
    }
}
