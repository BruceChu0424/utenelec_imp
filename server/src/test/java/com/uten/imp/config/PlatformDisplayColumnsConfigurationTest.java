package com.uten.imp.config;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class PlatformDisplayColumnsConfigurationTest {
    private PlatformDisplayColumnsConfiguration config(String... rights) {
        var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"staff",Set.of(rights),false,true,false)));
        return new PlatformDisplayColumnsConfiguration(current);
    }
    @Test void financeReviewerCanUseSamePurchaseAndSubcontractDisplayFieldsWithoutBusinessEditRights() {
        var configuration=config("finance_order_approval:view");
        for(var adapter:List.of(configuration.purchaseDisplayColumns(),configuration.subcontractDisplayColumns())) {
            assertThatCode(()->adapter.requireDefinitionAccess(true)).doesNotThrowAnyException();
            assertThat(adapter.canViewPrice()).isTrue();
            assertThat(adapter.canWrite()).isFalse();
            assertThat(adapter.supportsValues()).isFalse();
            assertThatThrownBy(()->adapter.authorize(Set.of(UUID.randomUUID()),false)).isInstanceOf(ApiException.class);
        }
    }
    @Test void narrowHistoryAndWorkshopReadersGetPersonalColumnsWithoutCostOrRecordWrites() {
        for(String permission:List.of("warehouse_purchase_receipt_history:view","warehouse_subcontract_waste_history:view","workshop_material:view")) {
            var adapter=config(permission).warehouseDisplayColumns();
            assertThatCode(()->adapter.requireDefinitionAccess(true)).doesNotThrowAnyException();
            assertThat(adapter.canViewPrice()).isFalse();
            assertThat(adapter.canWrite()).isFalse();
        }
    }
    @Test void buyerCanConfigureOwnWorkbenchButUnrelatedScopeRemainsForbidden() {
        var configuration=config("purchase_request:view");
        assertThatCode(()->configuration.operationsDisplayColumns().requireDefinitionAccess(true)).doesNotThrowAnyException();
        assertThatThrownBy(()->configuration.payrollDisplayColumns().requireDefinitionAccess(false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->configuration.adminDisplayColumns().requireDefinitionAccess(false)).isInstanceOf(ApiException.class);
    }
    @Test void lossClaimAmountCalculationsFollowTheExistingFinanceAmountAuthority() {
        var ordinary=config("subcontract_loss_claim:view").financeDisplayColumns();
        assertThatCode(()->ordinary.requireDefinitionAccess(false)).doesNotThrowAnyException();
        assertThat(ordinary.canViewPrice()).isFalse();
        assertThat(config("subcontract_loss_claim:view","finance:view:all").financeDisplayColumns().canViewPrice()).isTrue();
    }
}
