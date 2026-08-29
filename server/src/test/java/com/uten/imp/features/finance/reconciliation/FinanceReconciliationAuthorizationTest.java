package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationListItem;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationQueryFilter;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;

import static org.assertj.core.api.Assertions.assertThat;

class FinanceReconciliationAuthorizationTest {

    private static final String REQUIRED =
            "hasAuthority('account:view') and hasAuthority('account:balance:view') "
                    + "and hasAuthority('account:flow:view')";

    @Test
    void legacyEndpointAndServiceRequireAllSensitiveAccountAuthorities() throws Exception {
        Method controller = onlyListMethod(FinanceReconciliationController.class);
        Method service = FinanceReconciliationService.class.getDeclaredMethod(
                "list", FinanceReconciliationQueryFilter.class, int.class, int.class,
                String.class, String.class);

        assertThat(controller.getAnnotation(PreAuthorize.class).value()).isEqualTo(REQUIRED);
        assertThat(service.getAnnotation(PreAuthorize.class).value()).isEqualTo(REQUIRED);
        assertThat(controller.getAnnotation(PreAuthorize.class).value())
                .doesNotContain("finance_reconciliation:view", "finance_report:view");
    }

    @Test
    void listContractCarriesAppendOnlyEntryKindAndReversalLineage() throws Exception {
        assertThat(FinanceReconciliationListItem.class.getDeclaredField("entryKind").getType())
                .isEqualTo(String.class);
        assertThat(FinanceReconciliationListItem.class.getDeclaredField("reversalOfId").getType())
                .isEqualTo(java.util.UUID.class);
        assertThat(FinanceReconciliation.class.getDeclaredField("entryKind").getType())
                .isEqualTo(String.class);
        assertThat(FinanceReconciliation.class.getDeclaredField("reversalOfId").getType())
                .isEqualTo(java.util.UUID.class);
    }

    private static Method onlyListMethod(Class<?> type) {
        return java.util.Arrays.stream(type.getDeclaredMethods())
                .filter(method -> method.getName().equals("list"))
                .findFirst()
                .orElseThrow();
    }
}
