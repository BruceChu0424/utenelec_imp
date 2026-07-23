package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.jwt")
public class JwtProperties {

    /** HS256 签名密钥（≥32 字节）。生产走环境变量 UTEN_JWT_SECRET。 */
    private String secret = "";

    /** access token 有效期（分钟）。 */
    private long accessTtlMinutes = 15;

    /** refresh token 有效期（天）。 */
    private long refreshTtlDays = 7;

    private String issuer = "uten-imp";
}
