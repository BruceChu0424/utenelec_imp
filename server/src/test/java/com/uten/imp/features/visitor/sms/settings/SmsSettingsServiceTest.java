package com.uten.imp.features.visitor.sms.settings;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.visitor.sms.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.mock.env.MockEnvironment;
import static com.uten.imp.features.visitor.sms.SmsRuntimeTestSupport.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SmsSettingsServiceTest {
    private final SmsGatewaySettingsStore store=mock(SmsGatewaySettingsStore.class);
    private final SmsGatewayFactory factory=mock(SmsGatewayFactory.class);
    private final JdbcTemplate jdbc=mock(JdbcTemplate.class);
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private final AuditService audit=mock(AuditService.class);
    private final AtomicReference<Optional<SmsGatewaySettingsStore.Row>> rows=new AtomicReference<>(Optional.empty());
    private final AuthUser actor=new AuthUser(UUID.randomUUID(),null,"fixture-admin",Set.of("authorization:manage"),false,true,true);
    private final com.uten.imp.security.SecretCipher cipher=cipher("1");
    private SmsGatewayRuntime runtime;
    private SmsSettingsService service;
    @BeforeEach void setup() {
        var profiles=new MockEnvironment();profiles.setActiveProfiles("prod");
        runtime=new SmsGatewayRuntime(store,environment(),cipher,profiles);
        when(store.current()).thenAnswer(call->rows.get());when(store.lockCurrent()).thenAnswer(call->rows.get());
        when(store.save(any(),anyLong(),anyBoolean())).thenAnswer(call->{rows.set(Optional.of(call.getArgument(0)));return true;});
        when(current.get()).thenReturn(Optional.of(actor));
        when(jdbc.query(anyString(),org.mockito.ArgumentMatchers.<RowMapper<UUID>>any(),eq(actor.getId())))
                .thenReturn(List.of(actor.getId()));
        when(factory.create(any())).thenReturn(new DisabledSmsGateway());
        service=new SmsSettingsService(store,runtime,factory,cipher,current,jdbc,audit);
    }
    private SmsSettingsDto.Save request(String revision,String provider,String id,String secret,boolean clear) {
        return new SmsSettingsDto.Save(revision,provider,"dysmsapi.aliyuncs.com","测试签名","SMS_FIXTURE",id,secret,clear,false);
    }
    @Test void explicitFirstSavePreservesEnvCredentialsEncryptedWithoutAnyReadResponseOrAuditSecret() throws Exception {
        String revision=service.current().revision();
        var result=service.save(request(revision,"ALIYUN","","",false));
        var stored=rows.get().orElseThrow();
        assertThat(result.source()).isEqualTo("DATABASE");assertThat(result.version()).isEqualTo(1);
        assertThat(cipher.decrypt(stored.accessKeyIdCipher(),SmsGatewaySettingsStore.idAad())).isEqualTo(ID);
        assertThat(cipher.decrypt(stored.accessKeySecretCipher(),SmsGatewaySettingsStore.secretAad())).isEqualTo(SECRET);
        String json=new ObjectMapper().findAndRegisterModules().writeValueAsString(result);
        assertThat(json).doesNotContain(ID,SECRET,stored.accessKeyIdCipher(),stored.accessKeySecretCipher());
        assertThat(stored.toString()).doesNotContain(ID,SECRET,stored.accessKeyIdCipher());
        verify(audit).logCommitted(actor.getId(),actor.getLoginAccount(),"sms_settings.update","sms_gateway_settings",SmsGatewaySettingsStore.ID.toString(),"success");
        verify(factory,times(1)).create(any()); // construction only; no sender invocation
    }
    @Test void blankKeepsCiphertextsAndExplicitDisabledClearRemovesBothTogether() {
        rows.set(Optional.of(row(cipher,4,"ALIYUN")));
        var previous=rows.get().orElseThrow();
        service.save(request(service.current().revision(),"ALIYUN",null,null,false));
        assertThat(rows.get().orElseThrow().accessKeyIdCipher()).isEqualTo(previous.accessKeyIdCipher());
        assertThat(rows.get().orElseThrow().accessKeySecretCipher()).isEqualTo(previous.accessKeySecretCipher());
        var cleared=service.save(request(service.current().revision(),"DISABLED",null,null,true));
        assertThat(cleared.accessKeyConfigured()).isFalse();
        assertThat(rows.get().orElseThrow().accessKeyIdCipher()).isNull();assertThat(rows.get().orElseThrow().accessKeySecretCipher()).isNull();
    }
    @Test void resettingToEnvPreservesMonotonicVersionAndRejectsStaleFormReplay() {
        var initial=service.current();
        var changed=service.save(request(initial.revision(),"DISABLED",null,null,true));
        var reset=service.save(new SmsSettingsDto.Save(changed.revision(),null,null,null,null,null,null,false,true));
        assertThat(reset.version()).isEqualTo(2);assertThat(reset.source()).isEqualTo("ENV");
        assertThat(reset.revision()).isNotEqualTo(initial.revision());
        assertThatThrownBy(()->service.save(request(initial.revision(),"DISABLED",null,null,true))).isInstanceOf(ApiException.class);
        assertThat(rows.get().orElseThrow().version()).isEqualTo(2);
    }
    @Test void partialCredentialsClearConflictAndEndpointChangeNeverReuseOldKey() {
        String revision=service.current().revision();
        assertThatThrownBy(()->service.save(request(revision,"ALIYUN","replacement",null,false))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.save(request(revision,"DISABLED","replacement","replacement",true))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.save(new SmsSettingsDto.Save(revision,"ALIYUN","dysmsapi.ap-southeast-1.aliyuncs.com",
                "测试签名","SMS_FIXTURE",null,null,false,false))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.save(new SmsSettingsDto.Save(revision,"ALIYUN","http://127.0.0.1:8888/",
                "测试签名","SMS_FIXTURE","id","secret",false,false))).isInstanceOf(ApiException.class);
        verify(store,never()).save(any(),anyLong(),anyBoolean());
    }
    @Test void staleOrDemotedPrincipalCannotWriteEvenIfJwtStillSaysSuperAdmin() {
        when(jdbc.query(anyString(),org.mockito.ArgumentMatchers.<RowMapper<UUID>>any(),eq(actor.getId())))
                .thenReturn(List.of());
        assertThatThrownBy(()->service.save(request("stale","ALIYUN",ID,SECRET,false))).isInstanceOf(ApiException.class);
        verify(store,never()).lockCurrent();
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),null,"manager",Set.of("authorization:manage"),false,true,false)));
        assertThatThrownBy(service::current).isInstanceOf(ApiException.class);
    }
    @Test void prodCannotPersistLogAndSecretsAreWriteOnlyInRequestSerialization() throws Exception {
        var request=request(service.current().revision(),"LOG",ID,SECRET,false);
        assertThatThrownBy(()->service.save(request)).isInstanceOf(ApiException.class);
        assertThat(new ObjectMapper().writeValueAsString(request)).doesNotContain(ID,SECRET);
        assertThat(request.toString()).doesNotContain(ID,SECRET);
        verify(store,never()).save(any(),anyLong(),anyBoolean());
    }
    @Test void onlyPublishedSmsHostsCanReceiveCredentialsAndEveryOfficialServiceIsSelectable() {
        assertThat(service.current().allowedEndpoints()).containsExactlyElementsOf(SmsEndpointPolicy.ALLOWED);
        for(String endpoint:new String[]{"dysmsapi.oss-cn-hangzhou.aliyuncs.com","dysmsapi.customer.aliyuncs.com",
                "https://dysmsapi.aliyuncs.com","dysmsapi.aliyuncs.com:443","127.0.0.1"}) {
            String revision=service.current().revision();
            assertThatThrownBy(()->service.save(new SmsSettingsDto.Save(revision,"ALIYUN",endpoint,
                    "测试签名","SMS_FIXTURE",ID,SECRET,false,false))).isInstanceOf(ApiException.class);
        }
        verify(store,never()).save(any(),anyLong(),anyBoolean());
        for(String endpoint:SmsEndpointPolicy.ALLOWED) {
            var saved=service.save(new SmsSettingsDto.Save(service.current().revision(),"ALIYUN",endpoint.toUpperCase(java.util.Locale.ROOT),
                    "测试签名","SMS_FIXTURE",ID,SECRET,false,false));
            assertThat(saved.endpoint()).isEqualTo(endpoint);assertThat(saved.status()).isEqualTo("READY");
        }
        assertThat(rows.get().orElseThrow().version()).isEqualTo(7);
    }
    @Test void unusedEndpointCanBeBlankWhenExplicitlyClearingAndDisablingSms() {
        var result=service.save(new SmsSettingsDto.Save(service.current().revision(),"DISABLED",null,
                null,null,null,null,true,false));
        assertThat(result.endpoint()).isNull();assertThat(result.status()).isEqualTo("DISABLED");
        assertThat(result.accessKeyConfigured()).isFalse();assertThat(result.allowedEndpoints()).hasSize(7);
    }
}
