package com.uten.imp.features.visitor.sms;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;
import static com.uten.imp.features.visitor.sms.SmsRuntimeTestSupport.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SmsGatewayRuntimeTest {
    private final SmsGatewaySettingsStore store=mock(SmsGatewaySettingsStore.class);
    @Test void absentOverrideKeepsEnvironmentAndResetVersionNeverRecreatesOldRevision() {
        var environment=environment();var profiles=new MockEnvironment();profiles.setActiveProfiles("prod");
        var runtime=new SmsGatewayRuntime(store,environment,cipher("1"),profiles);
        var first=runtime.resolve(Optional.empty());
        assertThat(first.source()).isEqualTo("ENV");assertThat(first.effectiveProvider()).isEqualTo("ALIYUN");
        var reset=new SmsGatewaySettingsStore.Row(2,"ENV","DISABLED",null,null,null,null,null,null,null,null);
        var after=runtime.resolve(Optional.of(reset));
        assertThat(after.effectiveProvider()).isEqualTo("ALIYUN");assertThat(after.revision()).isNotEqualTo(first.revision());
    }
    @Test void databaseAliyunOverridesLogEnvironmentWithoutExposingARealOtp() {
        var env=environment();env.setProvider("log");env.setExposeCode(true);
        var profiles=new MockEnvironment();profiles.setActiveProfiles("dev");var cipher=cipher("1");
        var runtime=new SmsGatewayRuntime(store,env,cipher,profiles);
        assertThat(runtime.resolve(Optional.empty()).developmentCodeAllowed()).isTrue();
        var actual=runtime.resolve(Optional.of(row(cipher,1,"ALIYUN")));
        assertThat(actual.source()).isEqualTo("DATABASE");assertThat(actual.effectiveProvider()).isEqualTo("ALIYUN");
        assertThat(actual.developmentCodeAllowed()).isFalse();
    }
    @Test void prodAndCloudAlwaysOverrideDevLogAndCodeExposure() {
        var env=environment();env.setProvider("log");env.setExposeCode(true);
        for(String profile:new String[]{"prod","cloud"}) {
            var profiles=new MockEnvironment();profiles.setActiveProfiles("dev",profile);
            var snapshot=new SmsGatewayRuntime(store,env,cipher("1"),profiles).resolve(Optional.empty());
            assertThat(snapshot.effectiveProvider()).isEqualTo("DISABLED");
            assertThat(snapshot.status()).isEqualTo("BLOCKED");assertThat(snapshot.developmentCodeAllowed()).isFalse();
        }
    }
    @Test void existingDedicatedInternalTestPolicyCannotBeBypassedByRestoredDatabaseConfig() {
        var profiles=new MockEnvironment();profiles.setActiveProfiles("internal-test");var cipher=cipher("1");
        var runtime=new SmsGatewayRuntime(store,environment(),cipher,profiles);
        assertThat(runtime.resolve(Optional.of(row(cipher,1,"ALIYUN"))).effectiveProvider()).isEqualTo("DISABLED");
    }
    @Test void normalNonProductionEnvironmentMayUseAliyunAndNoKeyIsEverSerialized() throws Exception {
        var profiles=new MockEnvironment();profiles.setActiveProfiles("test");var cipher=cipher("1");
        var row=row(cipher,1,"ALIYUN");var runtime=new SmsGatewayRuntime(store,environment(),cipher,profiles);
        var snapshot=runtime.resolve(Optional.of(row));
        assertThat(snapshot.effectiveProvider()).isEqualTo("ALIYUN");
        String json=new ObjectMapper().findAndRegisterModules().writeValueAsString(snapshot);
        assertThat(json).doesNotContain(ID,SECRET,row.accessKeyIdCipher(),row.accessKeySecretCipher());
        assertThat(snapshot.toString()).doesNotContain(ID,SECRET);
    }
    @Test void unreadableDatabaseSecretNeverFallsBackToWorkingEnvironmentCredentials() {
        var old=row(cipher("1"),4,"ALIYUN");
        var tampered=new SmsGatewaySettingsStore.Row(old.version(),old.mode(),old.provider(),old.endpoint(),old.signName(),old.templateCode(),
                old.accessKeySecretCipher(),old.accessKeyIdCipher(),old.accessKeyIdHint(),old.updatedAt(),old.updatedBy());
        var runtime=new SmsGatewayRuntime(store,environment(),cipher("1"),new MockEnvironment());
        var snapshot=runtime.resolve(Optional.of(tampered));
        assertThat(snapshot.secretUnreadable()).isTrue();assertThat(snapshot.status()).isEqualTo("KEY_UNREADABLE");
        assertThat(snapshot.effectiveProvider()).isEqualTo("DISABLED");
    }
    @Test void sharedDatabaseCasRevisionDoesNotDependOnAnIneffectiveNodeLocalExposeFlag() {
        var cipher=cipher("1");var row=Optional.of(row(cipher,4,"ALIYUN"));
        var first=environment();var second=environment();second.setExposeCode(true);
        var prod=new MockEnvironment();prod.setActiveProfiles("prod");var cloud=new MockEnvironment();cloud.setActiveProfiles("cloud");
        var primary=new SmsGatewayRuntime(store,first,cipher,prod).resolve(row);
        var proxy=new SmsGatewayRuntime(store,second,cipher,cloud).resolve(row);
        assertThat(primary.developmentCodeAllowed()).isFalse();assertThat(proxy.developmentCodeAllowed()).isFalse();
        assertThat(primary.revision()).isEqualTo(proxy.revision());
    }
    @Test void unknownEnvironmentDestinationCannotSendEvenWithOtherwiseCompleteLegacyCredentials() {
        var env=environment();var profiles=new MockEnvironment();profiles.setActiveProfiles("prod");
        var runtime=new SmsGatewayRuntime(store,env,cipher("1"),profiles);
        for(String endpoint:new String[]{"dysmsapi.oss-cn-hangzhou.aliyuncs.com","dysmsapi.customer.aliyuncs.com",
                "https://dysmsapi.aliyuncs.com","dysmsapi.aliyuncs.com:443","127.0.0.1"}) {
            env.setEndpoint(endpoint);
            var value=runtime.resolve(Optional.empty());
            assertThat(value.endpoint()).isEqualTo(endpoint); // displayed, never silently rewritten in deployment config
            assertThat(value.status()).isEqualTo("INVALID");assertThat(value.effectiveProvider()).isEqualTo("DISABLED");
            assertThat(value.developmentCodeAllowed()).isFalse();
            assertThat(new SmsGatewayFactory(new ObjectMapper()).create(value))
                    .isInstanceOf(DisabledSmsGateway.class); // no SDK construction or network call
            assertThat(env.getEndpoint()).isEqualTo(endpoint);
        }
        env.setEndpoint(" DYsMsApi.ALIYUNCS.COM ");
        assertThat(runtime.resolve(Optional.empty()).effectiveProvider()).isEqualTo("ALIYUN");
        assertThat(env.getEndpoint()).isEqualTo(" DYsMsApi.ALIYUNCS.COM ");
    }
}
