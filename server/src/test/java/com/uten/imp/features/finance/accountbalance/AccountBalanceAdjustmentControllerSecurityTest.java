package com.uten.imp.features.finance.accountbalance;

import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;

import static org.assertj.core.api.Assertions.assertThat;

class AccountBalanceAdjustmentControllerSecurityTest {

    private static final String REQUIRED =
            "hasAuthority('account:view') and hasAuthority('account:balance:view') "
                    + "and hasAuthority('account:balance:adjust')";

    @Test
    void controllerAndServiceRequireAllThreeAuthorities() throws Exception {
        Method controller = AccountBalanceAdjustmentController.class
                .getDeclaredMethod("adjust", AccountBalanceAdjustmentBatchRequest.class);
        Method service = AccountBalanceAdjustmentService.class
                .getDeclaredMethod("adjust", AccountBalanceAdjustmentBatchRequest.class);

        assertThat(controller.getAnnotation(PreAuthorize.class).value()).isEqualTo(REQUIRED);
        assertThat(service.getAnnotation(PreAuthorize.class).value()).isEqualTo(REQUIRED);
    }
}
