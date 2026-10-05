package com.uten.imp.features.admin.systemtest;

import com.uten.imp.application.port.BusinessTestResetFilesPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import javax.sql.DataSource;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** The drain-timeout refusal now needs a real database (super-admin check); see BusinessDataResetRefusalsPostgresTest. */
class PermanentRecordResetPolicyTest {
    @Test void disabledEnvironmentCannotUseTheExplicitTestResetException() {
        var source=mock(DataSource.class);var transactions=mock(PlatformTransactionManager.class);
        var drain=mock(BusinessDataResetDrainGate.class);var files=mock(BusinessTestResetFilesPort.class);
        var audit=mock(AuditService.class);var service=new BusinessDataResetService(source,transactions,
                new BusinessDataResetFeatureGate(false),drain,audit,files);
        UUID actor=UUID.randomUUID(),attempt=UUID.randomUUID();
        assertThatThrownBy(()->service.reset(actor,"policy-test",attempt)).isInstanceOf(ApiException.class)
            .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        assertThatThrownBy(()->service.preview(actor,"policy-test")).isInstanceOf(ApiException.class)
            .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(source,transactions,drain,files,audit);
    }
}
