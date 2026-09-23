package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * JWT 部署配置 (uten.jwt.*): HS256 签名密钥与签发者。令牌有效期属于运行时策略,
 * 只登记在系统设置 (SystemSettingKey.JWT_ACCESS_TTL_MINUTES / JWT_REFRESH_TTL_DAYS)。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.jwt")
public class JwtProperties {

    /** HS256 签名密钥（≥32 字节）。生产走环境变量 UTEN_JWT_SECRET。 */
    private String secret = "";

    private String issuer = "uten-imp";
}
