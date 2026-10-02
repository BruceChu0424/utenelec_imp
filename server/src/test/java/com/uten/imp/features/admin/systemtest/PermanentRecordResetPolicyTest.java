package com.uten.imp.features.admin.systemtest;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import javax.sql.DataSource;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class PermanentRecordResetPolicyTest {
    @Test void disabledEnvironmentCannotUseTheExplicitTestResetException() {
        var source=mock(DataSource.class);var transactions=mock(PlatformTransactionManager.class);
        var drain=mock(BusinessDataResetDrainGate.class);var files=mock(BusinessAttachmentResetPreparationPort.class);
        var audit=mock(AuditService.class);var service=new BusinessDataResetService(source,transactions,
                new BusinessDataResetFeatureGate(false),drain,audit,files);
        UUID actor=UUID.randomUUID(),attempt=UUID.randomUUID();
        assertThatThrownBy(()->service.reset(actor,"policy-test",attempt)).isInstanceOf(ApiException.class)
            .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(source,transactions,drain,files,audit);
    }

    @Test void enabledTestingResetStillRequiresDrainAndKeepsDefinitiveFailureEvidence() throws Exception {
        var source=mock(DataSource.class);var transactions=mock(PlatformTransactionManager.class);
        var drain=mock(BusinessDataResetDrainGate.class);var files=mock(BusinessAttachmentResetPreparationPort.class);
        var audit=mock(AuditService.class);var service=new BusinessDataResetService(source,transactions,
                new BusinessDataResetFeatureGate(true),drain,audit,files);
        UUID actor=UUID.randomUUID(),attempt=UUID.randomUUID();
        when(files.unpurgeableTestResetBlockers(actor)).thenReturn(java.util.List.of());
        when(drain.beginDrain(anyLong())).thenReturn(false);
        assertThatThrownBy(()->service.reset(actor,"policy-test",attempt)).isInstanceOf(ApiException.class)
            .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.CONFLICT))
            .hasMessageContaining("当前仍有进行中的请求");
        verify(files).unpurgeableTestResetBlockers(actor);
        verify(drain).beginDrain(BusinessDataResetService.DRAIN_TIMEOUT_MILLIS);
        verifyNoInteractions(source,transactions);
        verify(files,never()).prepareTestReset(any(),any(),any(),any());
        verify(audit).logExplicit(eq(actor),eq("policy-test"),eq("business_data_reset_received"),eq("system_test"),eq(attempt.toString()),anyString());
        verify(audit).logExplicit(eq(actor),eq("policy-test"),eq("business_data_reset_failed"),eq("system_test"),eq(attempt.toString()),contains("当前仍有进行中的请求"));
    }
}
