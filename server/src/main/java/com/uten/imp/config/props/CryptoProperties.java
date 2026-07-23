package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.crypto")
public class CryptoProperties {

    /** 当前 pgcrypto 主密钥（PII 字段加密）。必须经 .env/环境变量注入；缺省 fail-fast（不设弱默认）。 */
    private String pgpMasterKey;

    /** 当前密钥版本（密文前缀 `<version>:`，便于轮换）。默认 1。 */
    private String pgpKeyVersion = "1";

    /** 旧版本 → 旧密钥。轮换后保留用于解密历史密文（新增数据始终用当前版本）。 */
    private Map<String, String> pgpLegacyKeys = new HashMap<>();

    /** HMAC 密钥（身份证号查重等确定性哈希）。必须经 .env/环境变量注入。 */
    private String hmacKey;
}
