package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.context.properties.source.ConfigurationPropertySources;
import org.springframework.core.env.SystemEnvironmentPropertySource;

import java.security.SecureRandom;
import java.util.Base64;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SecretCipherTest {

    private static final String HMAC = "hmac-key-0123456789-0123456789-abcdef";
    private static final String PGP = "pgp-master-key-0123456789-0123456789-xyz";
    private static final String DEDICATED = "dedicated-secret-cipher-key-0123456789-abc";
    private static final String ISSUER = "uten-imp-test";

    private static SecretCipher derivedOnly() {
        return new SecretCipher(null, null, Map.of(), HMAC, ISSUER, new SecureRandom());
    }

    private static String aad(UUID id) {
        return "ai_providers|secret|" + id;
    }

    @Test
    void roundTripsWithTheHmacDerivedKeyAndTagsTheCiphertextWithVersionH1() {
        SecretCipher cipher = derivedOnly();
        UUID id = UUID.randomUUID();

        String stored = cipher.encrypt("sk-live-abcdefghijklmnopqrstuvwxyz", aad(id));

        assertThat(stored).startsWith("gh1:").doesNotContain("sk-live");
        assertThat(cipher.decrypt(stored, aad(id))).isEqualTo("sk-live-abcdefghijklmnopqrstuvwxyz");
        assertThat(cipher.currentVersion()).isEqualTo(SecretCipher.DERIVED_VERSION);
        assertThat(cipher.needsRewrap(stored)).isFalse();
    }

    @Test
    void tamperedCiphertextNeverDecrypts() {
        SecretCipher cipher = derivedOnly();
        UUID id = UUID.randomUUID();
        String stored = cipher.encrypt("secret-value", aad(id));
        byte[] payload = Base64.getUrlDecoder().decode(stored.substring(stored.indexOf(':') + 1));
        payload[payload.length - 1] ^= 0x01;
        String tampered = stored.substring(0, stored.indexOf(':') + 1)
                + Base64.getUrlEncoder().withoutPadding().encodeToString(payload);

        assertThatThrownBy(() -> cipher.decrypt(tampered, aad(id)))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class)
                .hasMessage("secret unreadable");
        assertThatThrownBy(() -> cipher.decrypt("not-a-ciphertext", aad(id)))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class);
        assertThatThrownBy(() -> cipher.decrypt("gh1:@@@", aad(id)))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class);
    }

    @Test
    void ciphertextIsBoundToRowEnvironmentAndVersion() {
        SecretCipher cipher = derivedOnly();
        UUID id = UUID.randomUUID();
        String stored = cipher.encrypt("secret-value", aad(id));

        // 搬到别的行
        assertThatThrownBy(() -> cipher.decrypt(stored, aad(UUID.randomUUID())))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class);
        // 别的环境(JWT 签发者不同)
        SecretCipher otherEnvironment = new SecretCipher(null, null, Map.of(), HMAC, "uten-imp-production",
                new SecureRandom());
        assertThatThrownBy(() -> otherEnvironment.decrypt(stored, aad(id)))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class);
        // 改版本号前缀
        SecretCipher withLegacy = new SecretCipher(DEDICATED, "7", Map.of(), HMAC, ISSUER, new SecureRandom());
        String relabelled = "g7" + stored.substring(stored.indexOf(':'));
        assertThatThrownBy(() -> withLegacy.decrypt(relabelled, aad(id)))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class);
    }

    @Test
    void dedicatedKeyBecomesCurrentAndOlderVersionsStillDecryptForRewrap() {
        UUID id = UUID.randomUUID();
        String derivedCiphertext = derivedOnly().encrypt("old-secret", aad(id));
        SecretCipher version1 = new SecretCipher(DEDICATED, "1", Map.of(), HMAC, ISSUER, new SecureRandom());
        String v1Ciphertext = version1.encrypt("v1-secret", aad(id));

        String rotatedKey = "rotated-secret-cipher-key-9876543210-zyx";
        SecretCipher version2 = new SecretCipher(rotatedKey, "2", Map.of("1", DEDICATED), HMAC, ISSUER,
                new SecureRandom());

        assertThat(version1.currentVersion()).isEqualTo("1");
        assertThat(v1Ciphertext).startsWith("g1:");
        assertThat(version1.decrypt(derivedCiphertext, aad(id))).isEqualTo("old-secret");
        assertThat(version1.needsRewrap(derivedCiphertext)).isTrue();
        assertThat(version2.decrypt(v1Ciphertext, aad(id))).isEqualTo("v1-secret");
        assertThat(version2.needsRewrap(v1Ciphertext)).isTrue();
        String rewrapped = version2.encrypt(version2.decrypt(v1Ciphertext, aad(id)), aad(id));
        assertThat(rewrapped).startsWith("g2:");
        assertThat(version2.needsRewrap(rewrapped)).isFalse();
    }

    @Test
    void everyEncryptionUsesAFreshIv() {
        SecretCipher cipher = derivedOnly();
        UUID id = UUID.randomUUID();
        Set<String> ivs = new HashSet<>();
        Set<String> ciphertexts = new HashSet<>();
        for (int i = 0; i < 500; i++) {
            String stored = cipher.encrypt("same-plaintext", aad(id));
            ciphertexts.add(stored);
            byte[] payload = Base64.getUrlDecoder().decode(stored.substring(stored.indexOf(':') + 1));
            ivs.add(HexFormat.of().formatHex(payload, 0, 12));
        }
        assertThat(ivs).hasSize(500);
        assertThat(ciphertexts).hasSize(500);
    }

    @Test
    void hmacFallbackIsDeterministicAcrossInstancesAndNeverThePgpDerivedKey() {
        UUID id = UUID.randomUUID();
        String stored = derivedOnly().encrypt("shared-secret", aad(id));

        assertThat(derivedOnly().decrypt(stored, aad(id))).isEqualTo("shared-secret");
        assertThat(SecretCipher.deriveKey(HMAC, SecretCipher.DERIVED_INFO).getEncoded())
                .isEqualTo(SecretCipher.deriveKey(HMAC, SecretCipher.DERIVED_INFO).getEncoded())
                .isNotEqualTo(SecretCipher.deriveKey(PGP, SecretCipher.DERIVED_INFO).getEncoded());
        // 用 PGP 主密钥当 HMAC 密钥构造出的密码器解不开: 两把钥匙互不通用。
        SecretCipher fromPgp = new SecretCipher(null, null, Map.of(), PGP, ISSUER, new SecureRandom());
        assertThatThrownBy(() -> fromPgp.decrypt(stored, aad(id)))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class);
        // 同一材料作专用密钥与作 HMAC 派生, 用途标签不同, 得到不同的钥匙。
        assertThat(SecretCipher.deriveKey(HMAC, SecretCipher.CONFIGURED_INFO).getEncoded())
                .isNotEqualTo(SecretCipher.deriveKey(HMAC, SecretCipher.DERIVED_INFO).getEncoded());
    }

    @Test
    void hkdfMatchesRfc5869TestCaseOne() {
        byte[] ikm = HexFormat.of().parseHex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
        byte[] salt = HexFormat.of().parseHex("000102030405060708090a0b0c");
        byte[] info = HexFormat.of().parseHex("f0f1f2f3f4f5f6f7f8f9");

        byte[] okm = SecretCipher.hkdfSha256(ikm, salt, info, 42);

        assertThat(HexFormat.of().formatHex(okm)).isEqualTo(
                "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
    }

    @Test
    void rejectsWeakDedicatedKeysReservedVersionsAndMissingKeyMaterial() {
        assertThatThrownBy(() -> new SecretCipher("too-short", "1", Map.of(), HMAC, ISSUER, new SecureRandom()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("at least 32 bytes");
        assertThatThrownBy(() -> new SecretCipher(DEDICATED, "h2", Map.of(), HMAC, ISSUER, new SecureRandom()))
                .isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> new SecretCipher(DEDICATED, "1:bad", Map.of(), HMAC, ISSUER, new SecureRandom()))
                .isInstanceOf(IllegalStateException.class);

        SecretCipher none = new SecretCipher(null, null, Map.of(), null, ISSUER, new SecureRandom());
        assertThat(none.available()).isFalse();
        assertThatThrownBy(() -> none.encrypt("x", "ctx")).isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> none.decrypt("gh1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "ctx"))
                .isInstanceOf(SecretCipher.SecretUnreadableException.class);
    }

    @Test
    void dedicatedKeyWithoutHmacKeyStillWorks() {
        SecretCipher cipher = new SecretCipher(DEDICATED, "3", Map.of(), null, ISSUER, new SecureRandom());
        UUID id = UUID.randomUUID();

        String stored = cipher.encrypt("value", aad(id));

        assertThat(stored).startsWith("g3:");
        assertThat(cipher.decrypt(stored, aad(id))).isEqualTo("value");
    }

    @Test
    void cipherKeysBindFromTheDocumentedEnvironmentVariableNames() {
        Map<String, Object> environment = Map.of(
                "UTEN_CRYPTO_SECRETCIPHERKEY", DEDICATED,
                "UTEN_CRYPTO_SECRETCIPHERKEYVERSION", "2",
                "UTEN_CRYPTO_SECRETCIPHERLEGACYKEYS_1", "legacy-secret-cipher-key-0123456789-abcdef");
        Binder binder = new Binder(ConfigurationPropertySources.from(
                new SystemEnvironmentPropertySource("systemEnvironment", environment)));

        SecretCipherProperties properties = binder.bind("uten.crypto", SecretCipherProperties.class).get();

        assertThat(properties.getSecretCipherKey()).isEqualTo(DEDICATED);
        assertThat(properties.getSecretCipherKeyVersion()).isEqualTo("2");
        assertThat(properties.getSecretCipherLegacyKeys())
                .containsExactly(Map.entry("1", "legacy-secret-cipher-key-0123456789-abcdef"));
    }
}
