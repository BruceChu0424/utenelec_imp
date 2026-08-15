package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;

/**
 * 指定高风险、非计算型 PII 的字段加密配置（uten.crypto.*）：pgcrypto 主密钥、版本/历史密钥轮换
 * 与身份证号等字段的 HMAC 确定性哈希。
 *
 * <p>这不是“整库加密”配置。金额、数量、汇率和余额必须保留为可精确计算及约束的 NUMERIC；
 * 数据盘、备份和传输加密分别由基础设施、备份工具和 TLS 配置负责。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.crypto")
public class CryptoProperties {

    /** 当前 pgcrypto 主密钥（仅指定高风险 PII/敏感快照）。必须经环境或外部密钥管理注入；缺省 fail-fast。 */
    private String pgpMasterKey;

    /** 当前密钥版本（密文前缀 `<version>:`，便于轮换）。默认 1。 */
    private String pgpKeyVersion = "1";

    /** 旧版本 → 旧密钥。轮换后保留用于解密历史密文（新增数据始终用当前版本）。 */
    private Map<String, String> pgpLegacyKeys = new HashMap<>();

    /** HMAC 密钥（身份证号查重等确定性哈希）。必须经 .env/环境变量注入。 */
    private String hmacKey;
}
