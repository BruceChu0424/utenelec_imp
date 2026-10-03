package com.uten.imp.features.attachment;

import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Component;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;

/** Domain-separated exact-object signatures using the existing server key. Never stored/logged with the key. */
@Component
final class BusinessTestObjectSignature {
    private final CryptoProperties crypto;
    BusinessTestObjectSignature(CryptoProperties crypto) { this.crypto=crypto; }
    String sign(String canonical) {
        String key=crypto.getHmacKey();
        if(key==null || key.isBlank()) throw new ApiException(ErrorCode.CONFLICT,"测试原件清理签名设施未配置");
        try {
            Mac mac=Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key.getBytes(StandardCharsets.UTF_8),"HmacSHA256"));
            return HexFormat.of().formatHex(mac.doFinal(canonical.getBytes(StandardCharsets.UTF_8)));
        } catch (java.security.GeneralSecurityException error) {
            throw new IllegalStateException("Unable to sign exact test cleanup identity",error);
        }
    }
    boolean matches(String canonical,String signature) {
        if(signature==null || !signature.matches("[0-9a-f]{64}")) return false;
        return MessageDigest.isEqual(sign(canonical).getBytes(StandardCharsets.US_ASCII),signature.getBytes(StandardCharsets.US_ASCII));
    }
}
