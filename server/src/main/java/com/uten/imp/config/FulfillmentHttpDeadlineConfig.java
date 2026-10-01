package com.uten.imp.config;

import com.uten.imp.common.web.FulfillmentHttpDeadlineFilter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.convert.DurationStyle;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

import java.time.temporal.ChronoUnit;

@Configuration(proxyBeanMethods = false)
public class FulfillmentHttpDeadlineConfig {
    @Bean
    public FilterRegistrationBean<FulfillmentHttpDeadlineFilter> fulfillmentHttpDeadline(
            @Value("${spring.transaction.default-timeout:40s}") String timeout) {
        var registration = new FilterRegistrationBean<>(new FulfillmentHttpDeadlineFilter(
                DurationStyle.detectAndParse(timeout, ChronoUnit.SECONDS)));
        registration.setOrder(Ordered.HIGHEST_PRECEDENCE + 20);
        registration.addUrlPatterns("/api/*");
        return registration;
    }
}
