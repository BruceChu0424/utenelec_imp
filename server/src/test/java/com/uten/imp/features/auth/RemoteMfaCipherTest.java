package com.uten.imp.features.auth;

import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.security.SecretCipher;
import com.uten.imp.security.SecretCipherProperties;
import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class RemoteMfaCipherTest {
    @Test void rotationReadsOnlyExplicitHistoricalKeysAndCannotMoveCiphertextBetweenUsersOrColumns() {
        String oldKey="old-mfa-test-key-material-at-least-32-bytes";
        String newKey="new-mfa-test-key-material-at-least-32-bytes";
        String context="staff_mfa|secret|"+UUID.randomUUID();
        String secret=Totp.newSecret();
        String encrypted=cipher(oldKey,"1",Map.of()).encrypt(secret,context);
        var rotated=cipher(newKey,"2",Map.of("1",oldKey));
        assertThat(rotated.decrypt(encrypted,context)).isEqualTo(secret);
        assertThat(rotated.needsRewrap(encrypted)).isTrue();
        assertThat(encrypted).startsWith("g1:"); // Merely reading does not silently mutate durable state.
        assertThatThrownBy(()->cipher(newKey,"2",Map.of()).decrypt(encrypted,context)).isInstanceOf(SecretCipher.SecretUnreadableException.class);
        assertThatThrownBy(()->rotated.decrypt(encrypted,"staff_mfa|secret|"+UUID.randomUUID())).isInstanceOf(SecretCipher.SecretUnreadableException.class);
        assertThatThrownBy(()->rotated.decrypt(encrypted,context.replace("|secret|","|pending_secret|"))).isInstanceOf(SecretCipher.SecretUnreadableException.class);
    }
    private SecretCipher cipher(String key,String version,Map<String,String> history){
        var p=new SecretCipherProperties();p.setSecretCipherKey(key);p.setSecretCipherKeyVersion(version);p.setSecretCipherLegacyKeys(history);
        var jwt=new JwtProperties();jwt.setIssuer("mfa-cipher-test");return new SecretCipher(p,new CryptoProperties(),jwt);
    }
}
