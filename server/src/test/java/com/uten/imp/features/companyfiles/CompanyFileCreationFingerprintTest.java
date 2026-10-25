package com.uten.imp.features.companyfiles;

import com.uten.imp.config.props.CryptoProperties;
import org.junit.jupiter.api.Test;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class CompanyFileCreationFingerprintTest {
    private CompanyFileCreationFingerprint signer(String key) {
        var properties=new CryptoProperties();properties.setHmacKey(key);
        return new CompanyFileCreationFingerprint(properties);
    }
    @Test void evidenceIsStableButBoundToSecretActorAndCompletePayload() {
        UUID actor=UUID.randomUUID();String payload="initial password=not-for-storage";
        String first=signer("server-secret-one").sign(actor,payload);
        assertThat(first).matches("v2:[0-9a-f]{64}").doesNotContain(payload,"not-for-storage");
        assertThat(signer("server-secret-one").sign(actor,payload)).isEqualTo(first);
        assertThat(signer("server-secret-two").sign(actor,payload)).isNotEqualTo(first);
        assertThat(signer("server-secret-one").sign(UUID.randomUUID(),payload)).isNotEqualTo(first);
        assertThat(signer("server-secret-one").sign(actor,payload+"changed")).isNotEqualTo(first);
    }
    @Test void absentSecretFailsClosedWithoutEchoingSensitivePayload() {
        assertThatThrownBy(()->signer(null)).isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(()->signer(" ")).isInstanceOf(IllegalStateException.class);
    }
}
