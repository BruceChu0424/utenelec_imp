package com.uten.imp.support;

import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.security.LocalNetworkAccessPolicy;
import com.uten.imp.security.RemoteAccessPolicy;
import com.uten.imp.security.RemoteRequestBudgetFilter;
import com.uten.imp.security.TrustedRequestOriginPolicy;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;

import java.time.Clock;

/** HTTP slices retain real ingress/budget filters. */
@TestConfiguration(proxyBeanMethods = false)
@Import({DeploymentProperties.class, LocalNetworkAccessPolicy.class, TrustedRequestOriginPolicy.class,
        RemoteAccessPolicy.class, RemoteRequestBudgetFilter.class})
public class RemoteIngressSecurityTestConfiguration {
    @Bean @ConditionalOnMissingBean(Clock.class)
    Clock remoteIngressTestClock() { return Clock.systemUTC(); }

    @Bean @ConditionalOnMissingBean(MeterRegistry.class)
    MeterRegistry remoteIngressTestMetrics() { return new SimpleMeterRegistry(); }

    /** Boot 4 的切片不再提供 databind-2 ObjectMapper（自动配置只给 Jackson 3），
     *  而被 @Import 进来的安全过滤器（ImpersonationWriteGuardFilter 等）构造器要它。 */
    @Bean @ConditionalOnMissingBean(com.fasterxml.jackson.databind.ObjectMapper.class)
    com.fasterxml.jackson.databind.json.JsonMapper remoteIngressTestJackson2() {
        return com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
    }
}
