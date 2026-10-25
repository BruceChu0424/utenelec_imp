package com.uten.imp.features.companyfiles;

import com.uten.imp.config.props.CryptoProperties;
import org.springframework.stereotype.Component;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.util.HexFormat;
import java.util.UUID;

/** Stable keyed idempotency evidence: a database/audit reader cannot guess an initial password. */
@Component
public class CompanyFileCreationFingerprint {
    private static final String DOMAIN = "uten-company-file-create-v2\n";
    private final byte[] key;

    public CompanyFileCreationFingerprint(CryptoProperties properties) {
        if (properties.getHmacKey() == null || properties.getHmacKey().isBlank()) {
            throw new IllegalStateException("缺少资料库创建请求的 HMAC 配置");
        }
        key = properties.getHmacKey().getBytes(StandardCharsets.UTF_8);
    }

    String sign(UUID actor, String payload) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return "v2:" + HexFormat.of().formatHex(
                    mac.doFinal((DOMAIN + actor + "\n" + payload).getBytes(StandardCharsets.UTF_8)));
        } catch (java.security.GeneralSecurityException impossible) {
            throw new IllegalStateException("无法核对资料库创建请求", impossible);
        }
    }
}
