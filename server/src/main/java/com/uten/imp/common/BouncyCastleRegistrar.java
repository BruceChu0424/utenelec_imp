package com.uten.imp.common;

import jakarta.annotation.PostConstruct;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.springframework.stereotype.Component;

import java.security.Security;

/**
 * 启动时把 BouncyCastle 注册为 JCE provider（POI OOXML Agile 加密依赖）。
 *
 * <p>幂等：已注册则跳过。Argon2 密码哈希走 Spring Security Codec，此前未注册 provider，
 * 故此处首次注册（仅加密导出需要）。
 */
@Component
public class BouncyCastleRegistrar {

    @PostConstruct
    public void register() {
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.addProvider(new BouncyCastleProvider());
        }
    }
}
