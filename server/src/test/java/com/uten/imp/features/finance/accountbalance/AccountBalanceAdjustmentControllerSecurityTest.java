package com.uten.imp.features.finance.accountbalance;

import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchRequest;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentItemRequest;
import com.uten.imp.common.time.BusinessTime;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.authorization.method.AuthorizationManagerBeforeMethodInterceptor;
import org.springframework.security.core.context.SecurityContextHolder;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

class AccountBalanceAdjustmentControllerSecurityTest {

    private static final String REQUIRED =
            "hasAuthority('account:view') and hasAuthority('account:balance:view') "
                    + "and hasAuthority('account:balance:adjust')";

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void controllerAndServiceRequireAllThreeAuthorities() throws Exception {
        Method controller = AccountBalanceAdjustmentController.class
                .getDeclaredMethod("adjust", AccountBalanceAdjustmentBatchRequest.class);
        Method service = AccountBalanceAdjustmentService.class
                .getDeclaredMethod("adjust", AccountBalanceAdjustmentBatchRequest.class);

        assertThat(controller.getAnnotation(PreAuthorize.class).value()).isEqualTo(REQUIRED);
        assertThat(service.getAnnotation(PreAuthorize.class).value()).isEqualTo(REQUIRED);
    }

    @Test
    void editingAccountDataCannotBypassAnyBalanceAuthorityAtControllerOrService() {
        var service = mock(AccountBalanceAdjustmentService.class);
        var controller = secured(new AccountBalanceAdjustmentController(service));
        var securedService = secured(service);
        var request = request();
        String[] required = {"account:view", "account:balance:view", "account:balance:adjust"};

        // Exercise every incomplete combination, even when ordinary account editing is granted.
        for (int mask = 0; mask < 7; mask++) {
            var authorities = new ArrayList<String>();
            authorities.add("account:edit");
            for (int bit = 0; bit < required.length; bit++) {
                if ((mask & (1 << bit)) != 0) authorities.add(required[bit]);
            }
            authenticate(authorities);
            assertThatThrownBy(() -> controller.adjust(request))
                    .isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(() -> securedService.adjust(request))
                    .isInstanceOf(AccessDeniedException.class);
        }
        verifyNoInteractions(service);
    }

    @Test
    void namedBalanceAdjusterDoesNotNeedOrdinaryAccountEditingPermission() {
        var service = mock(AccountBalanceAdjustmentService.class);
        var controller = secured(new AccountBalanceAdjustmentController(service));
        var request = request();
        authenticate(List.of("account:view", "account:balance:view", "account:balance:adjust"));

        controller.adjust(request);

        verify(service).adjust(request);
    }

    private static AccountBalanceAdjustmentBatchRequest request() {
        return new AccountBalanceAdjustmentBatchRequest(
                "SELECTED", BusinessTime.today(), "上线盘点真实余额", "balance-permission-test",
                List.of(new AccountBalanceAdjustmentItemRequest(
                        UUID.randomUUID(), BigDecimal.ZERO, new BigDecimal("25.1234"), null)));
    }

    private static void authenticate(List<String> authorities) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("operator", "unused", authorities.toArray(String[]::new)));
    }

    @SuppressWarnings("unchecked")
    private static <T> T secured(T target) {
        var factory = new ProxyFactory(target);
        factory.setProxyTargetClass(true);
        factory.addAdvisor(AuthorizationManagerBeforeMethodInterceptor.preAuthorize());
        return (T) factory.getProxy();
    }
}
