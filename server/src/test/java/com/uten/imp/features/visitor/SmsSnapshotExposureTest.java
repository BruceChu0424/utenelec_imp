package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.visitor.sms.*;
import com.uten.imp.security.*;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.env.MockEnvironment;
import static com.uten.imp.features.visitor.sms.SmsRuntimeTestSupport.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SmsSnapshotExposureTest {
    @Test void realAliyunSenderNeverExposesOtpEvenWhenOldDevelopmentEnvironmentSaysLogAndExpose() {
        var store=mock(SmsGatewaySettingsStore.class);var cipher=cipher("1");
        when(store.current()).thenReturn(Optional.of(row(cipher,1,"ALIYUN")));
        var env=environment();env.setProvider("log");env.setExposeCode(true);
        var profiles=new MockEnvironment();profiles.setActiveProfiles("dev");
        var factory=mock(SmsGatewayFactory.class);var actual=mock(SmsGateway.class);
        when(factory.create(any())).thenReturn(actual);when(actual.sendCode(any(),any())).thenReturn(SmsSendResult.UNCERTAIN);
        var router=new DynamicSmsGateway(new SmsGatewayRuntime(store,env,cipher,profiles),factory);
        var settings=mock(SystemSettingsService.class);when(settings.readInt(SystemSettingKey.SMS_CODE_TTL_MINUTES)).thenReturn(5);
        var issuance=mock(VisitorSmsIssuanceTransaction.class);UUID issuanceId=UUID.randomUUID();
        when(issuance.prepare(any(),any(),any())).thenReturn(new VisitorSmsIssuanceTransaction.Issuance(issuanceId));
        var sms=new VisitorSmsService(mock(VisitorOtpVerifier.class),router,settings,issuance);
        var audit=mock(AuditService.class);
        var auth=new VisitorAuthService(mock(VisitorAccountRepository.class),sms,mock(VisitorRefreshTokenService.class),
                mock(VisitorRefreshTokenRepository.class),mock(VisitorRefreshTransaction.class),mock(VisitorRefreshCompromiseService.class),
                mock(EmployeeSensitiveRepository.class),mock(JwtService.class),mock(SecurityContextCurrentUser.class),mock(TxSessionVars.class),
                audit,mock(LoginRateLimiter.class),mock(MasterCodeService.class),mock(VisitorAccountCreationLock.class),
                mock(com.uten.imp.features.auth.AuthSessionService.class));
        var result=auth.sendCode("13800138000","127.0.0.1");
        assertThat(result.devCode()).isNull();assertThat(result.expiresInSeconds()).isEqualTo(300);
        var code=ArgumentCaptor.forClass(String.class);verify(actual,times(1)).sendCode(eq("13800138000"),code.capture());
        assertThat(code.getValue()).matches("[0-9]{6}");
        verify(issuance).complete(issuanceId,SmsSendResult.UNCERTAIN);verify(issuance,never()).reject(any());
        mockingDetails(audit).getInvocations().forEach(call->assertThat(java.util.Arrays.toString(call.getArguments()))
                .doesNotContain(code.getValue(),ID,SECRET,"13800138000"));
    }
}
