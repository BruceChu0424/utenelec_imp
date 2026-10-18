package com.uten.imp.features.notice;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class BusinessTaskNoticeAuthorityTest {
    @Test
    void ordinaryActionsDoNotCreatePopupCategoriesOrDemandOptionalNavigationViews() {
        for (String event : BusinessNoticeActionCatalog.events()) {
            assertThat(ReviewNoticeCatalog.isReviewEvent(event)).as(event).isFalse();
        }
        assertThat(BusinessNoticeActionCatalog.eligible("PREPLAN_SUPPLY_DOCUMENT_CREATED",
                Set.of("notice:read", "purchase_request:view", "purchase_order:create", "purchase_order:decompose"))).isTrue();
        assertThat(BusinessNoticeActionCatalog.eligible("SALES_QUOTE_FINANCE_CONFIRMED",
                Set.of("notice:read", "sales_quote:view", "sales_quote:convert", "sales_order:create"))).isTrue();
        assertThat(BusinessNoticeActionCatalog.eligible("SALES_QUOTE_FINANCE_CONFIRMED",
                Set.of("notice:read", "sales_quote:view", "sales_quote:convert"))).isFalse();
    }

    @Test
    void everyAdministratorKeepsItsOwnTaskGrantsRegardlessOfCandidateOrder() {
        var users = mock(UserAccountRepository.class);
        var permissions = mock(PermissionResolver.class);
        var first = admin();
        var second = admin();
        when(permissions.grantedPermsOf(first)).thenReturn(Set.of("notice:read"));
        when(permissions.grantedPermsOf(second)).thenReturn(Set.of("notice:read", "workshop_material:view", "workshop_material:issue"));
        var service = new WorkshopMaterialNoticeService(mock(NoticeService.class), users, permissions, null,
                mock(WarehouseNoticeRouter.class), mock(JdbcTemplate.class));
        for (List<UserAccount> order : List.of(List.of(first, second), List.of(second, first))) {
            when(users.findAll()).thenReturn(order);
            Set<UUID> audience = ReflectionTestUtils.invokeMethod(service, "usersWithNoticeAnd", Set.of("workshop_material:issue"));
            assertThat(audience).containsExactly(second.getId());
        }
    }

    @Test
    void workshopActionWithoutItsPageViewDoesNotReceiveTasks() {
        var users = mock(UserAccountRepository.class);
        var permissions = mock(PermissionResolver.class);
        var user = admin();
        when(users.findAll()).thenReturn(List.of(user));
        when(permissions.grantedPermsOf(user)).thenReturn(Set.of("notice:read", "workshop_material:issue"));
        var service = new WorkshopMaterialNoticeService(mock(NoticeService.class), users, permissions, null,
                mock(WarehouseNoticeRouter.class), mock(JdbcTemplate.class));
        Set<UUID> audience = ReflectionTestUtils.invokeMethod(service, "usersWithNoticeAnd", Set.of("workshop_material:issue"));
        assertThat(audience).isEmpty();
    }

    @Test
    void iqcRecipientsNeedTheNextActionForTheCurrentPhysicalAndFinancialState() {
        String view = "procurement_iqc_rejection:view";
        String record = "procurement_iqc_rejection:record_return";
        String credit = "procurement_iqc_rejection:confirm_credit";
        String amount = "procurement_iqc_rejection:amount:view";
        String close = "procurement_iqc_rejection:close_no_credit";
        var waiting = Map.<String,Object>of("status", "PENDING_RETURN", "inspection_status", "PARTIAL");
        assertThat(ChainNoticeService.canActIqcRejection("PROCUREMENT_IQC_REJECTION_OPENED", waiting,
                Set.of("notice:read", view, record))).isFalse();
        var ready = Map.<String,Object>of("status", "PENDING_RETURN", "inspection_status", "RESOLVED");
        assertThat(ChainNoticeService.canActIqcRejection("PROCUREMENT_IQC_REJECTION_OPENED", ready,
                Set.of("notice:read", view, record))).isTrue();
        assertThat(ChainNoticeService.canActIqcRejection("PROCUREMENT_IQC_REJECTION_OPENED", ready,
                Set.of("notice:read", view, "procurement_iqc_rejection:view:all"))).isFalse();
        var money = Map.<String,Object>of("status", "RETURN_RECORDED", "failed_amount_original", BigDecimal.ONE,
                "failed_amount_local", BigDecimal.TEN);
        assertThat(ChainNoticeService.canActIqcRejection("PROCUREMENT_IQC_REJECTION_RETURNED", money,
                Set.of("notice:read", view, credit))).isFalse();
        assertThat(ChainNoticeService.canActIqcRejection("PROCUREMENT_IQC_REJECTION_RETURNED", money,
                Set.of("notice:read", view, credit, amount))).isTrue();
        assertThat(ChainNoticeService.canActIqcRejection("PROCUREMENT_IQC_REJECTION_RETURNED", money,
                Set.of("notice:read", view, close))).isFalse();
        var zero = Map.<String,Object>of("status", "RETURN_RECORDED", "failed_amount_original", BigDecimal.ZERO,
                "failed_amount_local", BigDecimal.ZERO);
        assertThat(ChainNoticeService.canActIqcRejection("PROCUREMENT_IQC_REJECTION_RETURNED", zero,
                Set.of("notice:read", view, close))).isTrue();
    }

    private static UserAccount admin() {
        var user = new UserAccount();
        user.setId(UUID.randomUUID()); user.setEmployeeId(UUID.randomUUID());
        user.setStatus("active"); user.setSuperAdmin(true);
        return user;
    }
}
