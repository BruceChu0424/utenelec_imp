package com.uten.imp.config;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.WarehouseScopeReadSnapshotFilter;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** 只读请求的仓库数据范围快照(ADR-149 §2.1)的容器级注册。 */
@Configuration(proxyBeanMethods = false)
public class WarehouseScopeReadSnapshotConfig {
    @Bean
    public FilterRegistrationBean<WarehouseScopeReadSnapshotFilter> warehouseScopeReadSnapshot(
            WarehouseTaskScopePort scopes) {
        var registration = new FilterRegistrationBean<>(new WarehouseScopeReadSnapshotFilter(scopes));
        // 紧跟 Spring Security 过滤链(-100)之后: 主体已解析, 未认证/被拒的请求不开窗口。
        registration.setOrder(
                org.springframework.boot.autoconfigure.security.SecurityProperties.DEFAULT_FILTER_ORDER + 1);
        registration.addUrlPatterns("/api/*");
        registration.setName("warehouseScopeReadSnapshotFilter");
        return registration;
    }
}
