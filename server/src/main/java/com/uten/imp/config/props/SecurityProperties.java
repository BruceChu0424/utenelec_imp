package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.security")
public class SecurityProperties {

    /** CORS 允许来源（逗号分隔）。默认值与 application.yml 保持一致。 */
    private String corsAllowedOrigins = "http://localhost:53764,http://localhost:8080";

    /** 登录限流：每分钟每 IP 次数。 */
    private int loginRateLimitPerMinute = 5;

    /** 连续失败几次锁定。 */
    private int lockoutThreshold = 5;

    /** 锁定时长（分钟）。 */
    private int lockoutMinutes = 15;

    /** 改密时禁止重用的最近密码数。 */
    private int passwordHistorySize = 5;

    /** 生产是否强制 HTTPS（建议由反向代理终结 TLS）。 */
    private boolean requireHttps = false;

    /** swagger-ui / v3/api-docs 是否放行（dev true、prod false；false 时这些路径回落到认证保护）。 */
    private boolean swaggerEnabled = true;
}
