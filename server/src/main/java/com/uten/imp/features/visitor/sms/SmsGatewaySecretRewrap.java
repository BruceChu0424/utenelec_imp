package com.uten.imp.features.visitor.sms;

import com.uten.imp.security.SecretCipher;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.annotation.Profile;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Same key-ring lifecycle as AI secrets; cloud replicas never rewrite credentials. */
@Slf4j
@Component
@Profile("!cloud")
public class SmsGatewaySecretRewrap {
    private final SmsGatewaySettingsStore store;
    private final SecretCipher cipher;
    private final TransactionTemplate tx;
    public SmsGatewaySecretRewrap(SmsGatewaySettingsStore store,SecretCipher cipher,PlatformTransactionManager manager) {
        this.store=store;this.cipher=cipher;this.tx=new TransactionTemplate(manager);this.tx.setTimeout(30);
    }
    @EventListener(ApplicationReadyEvent.class) public void onStartup() {
        if(!cipher.available())return;
        try { tx.executeWithoutResult(status->rewrap()); }
        catch(RuntimeException failure) { log.warn("SMS credential rewrap skipped ({})",failure.getClass().getSimpleName()); }
    }
    int rewrap() {
        var existing=store.lockCurrent();
        if(existing.isEmpty())return 0;
        var row=existing.get();
        if(row.accessKeyIdCipher()==null||row.accessKeySecretCipher()==null
                ||!cipher.needsRewrap(row.accessKeyIdCipher())&&!cipher.needsRewrap(row.accessKeySecretCipher()))return 0;
        try {
            String id=cipher.encrypt(cipher.decrypt(row.accessKeyIdCipher(),SmsGatewaySettingsStore.idAad()),SmsGatewaySettingsStore.idAad());
            String secret=cipher.encrypt(cipher.decrypt(row.accessKeySecretCipher(),SmsGatewaySettingsStore.secretAad()),SmsGatewaySettingsStore.secretAad());
            var changed=new SmsGatewaySettingsStore.Row(row.version()+1,row.mode(),row.provider(),row.endpoint(),row.signName(),row.templateCode(),
                    id,secret,row.accessKeyIdHint(),row.updatedAt(),row.updatedBy());
            return store.save(changed,row.version(),true)?1:0;
        } catch(SecretCipher.SecretUnreadableException unreadable) {
            log.warn("SMS credentials unreadable; existing encrypted values retained");return 0;
        }
    }
}
