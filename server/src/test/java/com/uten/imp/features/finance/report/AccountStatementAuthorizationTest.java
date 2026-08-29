package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class AccountStatementAuthorizationTest {

    private static final String REQUIRED =
            "hasAuthority('account:view') and hasAuthority('account:balance:view') "
                    + "and hasAuthority('account:flow:view')";

    @Test
    void endpointRequiresAllAccountAuthoritiesWithoutLegacyReportBypass()
            throws Exception {
        PreAuthorize annotation = FinanceReportController.class.getDeclaredMethod(
                        "accountStatement", UUID.class, LocalDate.class, LocalDate.class,
                        String.class, int.class, int.class)
                .getAnnotation(PreAuthorize.class);

        assertThat(annotation.value()).isEqualTo(REQUIRED);
        assertThat(annotation.value()).doesNotContain("finance_report:view", "finance:view:all");
    }

    @Test
    void queryAndExportFailBeforeDatabaseWhenAccountAuthoritiesAreMissing() {
        EntityManager em = mock(EntityManager.class);
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        FinanceReportService service = new FinanceReportService(
                em,
                access,
                mock(SystemSettingsService.class),
                mock(FinanceStatementService.class),
                mock(FinanceCostService.class),
                mock(GlReportService.class),
                mock(FixedAssetService.class));

        assertThatThrownBy(() -> service.accountStatement(
                UUID.randomUUID(), null, null, null, 1, 20))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("账户流水要求同时具备");
        assertThatThrownBy(() -> service.export(
                "account/statement", Map.of("accountId", UUID.randomUUID().toString()), null, null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("账户流水要求同时具备");
        verifyNoInteractions(em);
    }
}
