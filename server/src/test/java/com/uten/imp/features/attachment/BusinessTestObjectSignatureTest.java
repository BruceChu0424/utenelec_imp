package com.uten.imp.features.attachment;
import com.uten.imp.config.props.CryptoProperties;
import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
class BusinessTestObjectSignatureTest {
    private final CryptoProperties properties=new CryptoProperties();
    @Test void generationAttemptSourceAndEveryExactObjectAttributeAreSigned() {
        properties.setHmacKey("isolated-test-key");var signer=new BusinessTestObjectSignature(properties);
        var ticket=sample(0,"FINAL","same-key",10,"a".repeat(64));String signature=signer.sign(ticket.canonical());
        assertThat(signer.matches(ticket.canonical(),signature)).isTrue();
        assertThat(signer.matches(sample(1,"FINAL","same-key",10,"a".repeat(64)).canonical(),signature)).isFalse();
        assertThat(signer.matches(sample(0,"STAGING","same-key",10,"a".repeat(64)).canonical(),signature)).isFalse();
        assertThat(signer.matches(sample(0,"FINAL","other-key",10,"a".repeat(64)).canonical(),signature)).isFalse();
        assertThat(signer.matches(sample(0,"FINAL","same-key",11,"a".repeat(64)).canonical(),signature)).isFalse();
        assertThat(signer.matches(sample(0,"FINAL","same-key",10,"b".repeat(64)).canonical(),signature)).isFalse();
    }
    @Test void signatureDoesNotExposeKeyAndMissingFacilitiesFailClosed() {
        properties.setHmacKey("isolated-test-key");var signer=new BusinessTestObjectSignature(properties);
        assertThat(signer.sign(sample(0,"FINAL","key",1,"a".repeat(64)).canonical())).matches("[0-9a-f]{64}").doesNotContain(properties.getHmacKey());
        properties.setHmacKey(null);assertThatThrownBy(()->signer.sign("test")).hasMessageContaining("签名设施");
    }
    private BusinessTestObjectCleanup.Intent sample(long gen,String location,String key,long size,String sha) {
        UUID fixed=UUID.fromString("11111111-1111-1111-1111-111111111111");
        return new BusinessTestObjectCleanup.Intent(fixed,"CLEAR_TEST_BUSINESS_WITH_HISTORY",fixed,gen,fixed,"operator","db","ATTACHMENT","source","0".repeat(64),location,"local",key,null,true,size,sha,null,Instant.parse("2026-10-01T12:00:00.123456Z"),0);
    }
}
