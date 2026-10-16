package com.uten.imp.features.visitor.sms.settings;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.visitor.sms.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.env.MockEnvironment;
import org.springframework.transaction.support.TransactionTemplate;
import static com.uten.imp.features.visitor.sms.SmsRuntimeTestSupport.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real V867 + PostgreSQL locks/CAS/audit. Gateway factory is always mocked: zero SMS/network calls. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SmsSettingsPostgresTest {
    private MigratedSchemaBaseline.ScopedDatabase database;
    private JdbcTemplate jdbc;
    private TransactionTemplate tx;
    private SmsSettingsService service;
    private SmsGatewaySettingsStore store;
    private final UUID actorId=UUID.randomUUID();
    private AuditService audit;
    @BeforeEach void setup() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("sms_runtime");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        jdbc=new JdbcTemplate(source);tx=new TransactionTemplate(new DataSourceTransactionManager(source));
        UUID employee=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'SMS fixture administrator','其他',id,CURRENT_DATE,'active','regular'
                FROM departments WHERE code='DEPT_FIN'
                """,employee,"SMS-"+employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES(?,?,?,'fixture-only',false,'active',true)",
                actorId,employee,"sms-fixture-"+actorId);
        store=new SmsGatewaySettingsStore(jdbc);
        var principal=new AuthUser(actorId,employee,"sms-fixture",Set.of("authorization:manage"),false,true,true);
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(principal));
        var factory=mock(SmsGatewayFactory.class);when(factory.create(any())).thenReturn(new DisabledSmsGateway());
        var cipher=cipher("1");audit=mock(AuditService.class);
        var profiles=new MockEnvironment();profiles.setActiveProfiles("test");
        service=new SmsSettingsService(store,new SmsGatewayRuntime(store,environment(),cipher,profiles),factory,cipher,current,jdbc,audit);
    }
    @AfterEach void close() throws Exception { if(database!=null)database.close(); }
    private SmsSettingsDto.Save request(String revision) {
        return new SmsSettingsDto.Save(revision,"ALIYUN","dysmsapi.aliyuncs.com","测试签名","SMS_FIXTURE",ID,SECRET,false,false);
    }
    @Test void migrationPreservesDeploymentSourceAndProtectsVersionAndConfigurationFromPhysicalReset() {
        assertThat(service.current().source()).isEqualTo("ENV");assertThat(service.current().version()).isZero();
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure)",String.class))
                .contains("('sms_gateway_settings', 'PRESERVE')");
        assertThatThrownBy(()->jdbc.update("DELETE FROM sms_gateway_settings")).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.update("UPDATE sms_gateway_settings SET version=0")).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(service.current().version()).isZero();
    }
    @Test void twoConcurrentSuperAdminsCannotOverwriteTheSameRevision() throws Exception {
        var command=request(service.current().revision());var barrier=new CyclicBarrier(2);
        try(var executor=Executors.newVirtualThreadPerTaskExecutor()) {
            java.util.concurrent.Callable<String> save=()->{barrier.await(5,TimeUnit.SECONDS);try {
                tx.execute(status->service.save(command));return "SAVED";
            }catch(ApiException conflict){return conflict.getCode().name();}};
            var first=executor.submit(save);var second=executor.submit(save);
            assertThat(List.of(first.get(15,TimeUnit.SECONDS),second.get(15,TimeUnit.SECONDS))).containsExactlyInAnyOrder("SAVED","CONFLICT");
        }
        assertThat(service.current().version()).isEqualTo(1);
    }
    @Test void encryptedCredentialPairAndMaskedHintNeverEnterDatabaseAuditPayload() {
        tx.execute(status->service.save(request(service.current().revision())));
        var row=store.current().orElseThrow();
        assertThat(row.accessKeyIdCipher()).startsWith("g1:").doesNotContain(ID);
        assertThat(row.accessKeySecretCipher()).startsWith("g1:").doesNotContain(SECRET);
        var payloads=jdbc.queryForList("SELECT COALESCE(\"before\"::text,'')||COALESCE(\"after\"::text,'') FROM audit_log WHERE target_type='sms_gateway_settings'",String.class);
        assertThat(payloads).isNotEmpty();
        payloads.forEach(payload->assertThat(payload).doesNotContain(ID,SECRET,row.accessKeyIdCipher(),row.accessKeySecretCipher(),
                "access_key_id_cipher","access_key_secret_cipher","access_key_id_hint"));
    }
    @Test void revokingRealSuperAdminAuthorityStopsAStaleJwtBeforeAnyConfigWrite() {
        String revision=service.current().revision();
        jdbc.update("UPDATE users SET is_super_admin=false WHERE id=?",actorId);
        assertThatThrownBy(()->tx.execute(status->service.save(request(revision)))).isInstanceOf(ApiException.class);
        assertThat(store.current().orElseThrow().version()).isZero();
    }
    @Test void failedAuditRollsBackCredentialsAndRowAuditTogether() {
        doThrow(new IllegalStateException("fixture audit unavailable")).when(audit).logCommitted(any(),any(),any(),any(),any(),any());
        String revision=service.current().revision();
        assertThatThrownBy(()->tx.execute(status->service.save(request(revision)))).isInstanceOf(IllegalStateException.class);
        var row=store.current().orElseThrow();assertThat(row.version()).isZero();assertThat(row.accessKeySecretCipher()).isNull();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='sms_gateway_settings'",Long.class)).isZero();
    }
    @Test void actualSchemaAcceptsOfficialSmsHostsButRejectsCustomerBucketDestinationsAndIncompleteAliyun() {
        for(String endpoint:SmsEndpointPolicy.ALLOWED) {
            var saved=tx.execute(status->service.save(new SmsSettingsDto.Save(service.current().revision(),"ALIYUN",endpoint,
                    "测试签名","SMS_FIXTURE",ID,SECRET,false,false)));
            assertThat(saved.endpoint()).isEqualTo(endpoint);assertThat(saved.status()).isEqualTo("READY");
        }
        assertThat(store.current().orElseThrow().version()).isEqualTo(7);
        assertThatThrownBy(()->jdbc.update("UPDATE sms_gateway_settings SET version=version+1,endpoint='dysmsapi.oss-cn-hangzhou.aliyuncs.com'"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.update("UPDATE sms_gateway_settings SET version=version+1,endpoint=NULL"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(store.current().orElseThrow().version()).isEqualTo(7);
        var disabled=tx.execute(status->service.save(new SmsSettingsDto.Save(service.current().revision(),"DISABLED",null,
                null,null,null,null,true,false)));
        assertThat(disabled.endpoint()).isNull();assertThat(disabled.status()).isEqualTo("DISABLED");
        assertThat(store.current().orElseThrow().version()).isEqualTo(8);
    }
}
