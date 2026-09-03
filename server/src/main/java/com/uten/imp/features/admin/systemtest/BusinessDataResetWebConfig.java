package com.uten.imp.features.admin.systemtest;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * 排水过滤器的容器级注册：顺序 -200，先于 Spring Security（-100）执行，
 * 保证清空期间的 503 拦截与在途计数覆盖鉴权查询。
 * 只挂 /api/* —— actuator 健康检查等运维端点不受排水影响。
 */
@Configuration
public class BusinessDataResetWebConfig {

    @Bean
    public FilterRegistrationBean<BusinessDataResetDrainFilter> businessDataResetDrainFilterRegistration(
            BusinessDataResetDrainGate gate, ObjectMapper objectMapper) {
        FilterRegistrationBean<BusinessDataResetDrainFilter> registration =
                new FilterRegistrationBean<>(
                        new BusinessDataResetDrainFilter(gate, objectMapper));
        registration.setOrder(-200);
        registration.addUrlPatterns("/api/*");
        registration.setName("businessDataResetDrainFilter");
        return registration;
    }
}
