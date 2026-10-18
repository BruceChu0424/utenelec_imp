package com.uten.imp.support;

import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.admin.remoteaccess.RemoteAccessSettingsService;
import com.uten.imp.security.LocalNetworkAccessPolicy;
import com.uten.imp.security.RemoteAccessPolicy;
import com.uten.imp.security.RemoteMfaGuardFilter;
import com.uten.imp.security.RemoteRequestBudgetFilter;
import com.uten.imp.security.TrustedRequestOriginPolicy;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;

import java.time.Clock;
import static org.mockito.Mockito.mock;

/** HTTP slices retain real ingress/MFA/budget filters; only the unrelated policy persistence is mocked. */
@TestConfiguration(proxyBeanMethods = false)
@Import({DeploymentProperties.class, LocalNetworkAccessPolicy.class, TrustedRequestOriginPolicy.class,
        RemoteAccessPolicy.class, RemoteMfaGuardFilter.class, RemoteRequestBudgetFilter.class})
public class RemoteIngressSecurityTestConfiguration {
    @Bean @ConditionalOnMissingBean(Clock.class)
    Clock remoteIngressTestClock() { return Clock.systemUTC(); }

    @Bean @ConditionalOnMissingBean(MeterRegistry.class)
    MeterRegistry remoteIngressTestMetrics() { return new SimpleMeterRegistry(); }

    @Bean @ConditionalOnMissingBean(RemoteAccessSettingsService.class)
    RemoteAccessSettingsService remoteIngressTestSettings() { return mock(RemoteAccessSettingsService.class); }
}
