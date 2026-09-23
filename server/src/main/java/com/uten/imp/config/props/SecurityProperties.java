package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * 安全部署配置 (uten.security.*): CORS 白名单 + HTTPS/swagger 开关。登录/导出限流、账号锁定、
 * 密码历史等运行时策略只登记在系统设置 (SystemSettingKey)。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.security")
public class SecurityProperties {

    /** CORS 允许来源（逗号分隔）。默认值与 application.yml 保持一致。 */
    private String corsAllowedOrigins = "http://localhost:53764,http://localhost:8080";

    /** 生产是否强制 HTTPS（建议由反向代理终结 TLS）。 */
    private boolean requireHttps = false;

    /** swagger-ui / v3/api-docs 是否放行（默认关闭，dev profile 显式开启）。 */
    private boolean swaggerEnabled = false;
}
