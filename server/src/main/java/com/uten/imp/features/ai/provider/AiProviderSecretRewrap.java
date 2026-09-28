package com.uten.imp.features.ai.provider;

import com.uten.imp.security.SecretCipher;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.annotation.Profile;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 启动时把用旧密钥版本加密的服务商密钥改用当前版本重新加密(ADR-133; 表只有几行)。
 * 独立事务, 失败只记日志(解不开的密钥保持原样, 设置页会提示「密钥无法解密, 请重新填写」)。
 * 只在本地实例执行, 云端实例不写。
 */
@Slf4j
@Component
@Profile("!cloud")
public class AiProviderSecretRewrap {

    private final AiProviderRepository repository;
    private final SecretCipher cipher;
    private final TransactionTemplate tx;

    public AiProviderSecretRewrap(AiProviderRepository repository, SecretCipher cipher,
                                  PlatformTransactionManager transactionManager) {
        this.repository = repository;
        this.cipher = cipher;
        this.tx = new TransactionTemplate(transactionManager);
        this.tx.setTimeout(30);
    }

    @EventListener(ApplicationReadyEvent.class)
    public void rewrapOnStartup() {
        if (!cipher.available()) {
            return;
        }
        try {
            Integer rewrapped = tx.execute(status -> rewrap());
            if (rewrapped != null && rewrapped > 0) {
                log.info("Re-encrypted {} AI provider key(s) with the current secret-cipher key version", rewrapped);
            }
        } catch (RuntimeException e) {
            log.warn("AI provider key re-encryption skipped: {}", e.getClass().getSimpleName());
        }
    }

    int rewrap() {
        int count = 0;
        for (AiProvider provider : repository.lockAll()) {
            String stored = provider.getSecret();
            if (stored == null || !cipher.needsRewrap(stored)) {
                continue;
            }
            String aad = AiProvider.secretAad(provider.getId());
            try {
                provider.setSecret(cipher.encrypt(cipher.decrypt(stored, aad), aad));
                count++;
            } catch (SecretCipher.SecretUnreadableException e) {
                log.warn("AI provider {} key cannot be decrypted with any configured key version", provider.getId());
            }
        }
        repository.flush();
        return count;
    }
}
