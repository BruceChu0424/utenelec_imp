package com.uten.imp.features.profilechange;

import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Base64;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProfileChangeSnapshotCodecTest {

    @Mock
    private TxSessionVars tx;

    private ProfileChangeSnapshotCodec codec;

    @BeforeEach
    void setUp() {
        codec = new ProfileChangeSnapshotCodec(tx);
    }

    @Test
    void sensitiveSnapshotsUseDomainMarkedCiphertextIncludingBlankValues() {
        String payload = ProfileChangeSnapshotCodec.PAYLOAD_PREFIX;
        when(tx.encrypt(payload)).thenReturn("2:blank-cipher");

        assertEquals(
                ProfileChangeSnapshotCodec.ENCODING_PGCRYPTO_V1,
                codec.encodingFor(ProfileFieldPolicy.Field.HUJI_ADDRESS));
        assertEquals(
                "2:blank-cipher",
                codec.encode(ProfileFieldPolicy.Field.HUJI_ADDRESS, ""));
        verify(tx).encrypt(payload);
    }

    @Test
    void emergencyContactSnapshotsAreProtectedButOrdinaryNameIsPlain() {
        when(tx.encrypt(ProfileChangeSnapshotCodec.PAYLOAD_PREFIX + "张三"))
                .thenReturn("2:contact-cipher");

        assertEquals(
                "2:contact-cipher",
                codec.encode("emergencyContact.0.name", "张三"));
        assertEquals(
                ProfileChangeSnapshotCodec.ENCODING_PLAIN,
                codec.encodingFor(ProfileFieldPolicy.Field.FULL_NAME));
        assertEquals(
                "普通姓名",
                codec.encode(ProfileFieldPolicy.Field.FULL_NAME, "普通姓名"));
    }

    @Test
    void decodeRequiresMatchingEncodingAndInnerDomainMarker() {
        when(tx.decrypt("2:phone-cipher"))
                .thenReturn(ProfileChangeSnapshotCodec.PAYLOAD_PREFIX + "13800138000");

        assertEquals(
                "13800138000",
                codec.decode(
                        ProfileFieldPolicy.Field.PHONE,
                        ProfileChangeSnapshotCodec.ENCODING_PGCRYPTO_V1,
                        "2:phone-cipher"));
        assertThrows(
                IllegalStateException.class,
                () -> codec.decode(
                        ProfileFieldPolicy.Field.PHONE,
                        ProfileChangeSnapshotCodec.ENCODING_LEGACY_UNKNOWN,
                        "13800138000"));
        when(tx.decrypt("2:wrong-domain")).thenReturn("another-domain:value");
        assertThrows(
                IllegalStateException.class,
                () -> codec.decode(
                        ProfileFieldPolicy.Field.PHONE,
                        ProfileChangeSnapshotCodec.ENCODING_PGCRYPTO_V1,
                        "2:wrong-domain"));
    }

    @Test
    void legacyPlaintextIsEncryptedAndExistingCipherIsVerifiedThenCanonicalized() {
        UUID rowId = UUID.randomUUID();
        String canonicalPayload = ProfileChangeSnapshotCodec.PAYLOAD_PREFIX + "旧地址";
        when(tx.encrypt(canonicalPayload)).thenReturn("2:new-cipher");

        assertEquals(
                "2:new-cipher",
                codec.canonicalizeLegacySensitive(
                        rowId, ProfileFieldPolicy.Field.HUJI_ADDRESS, "new", "旧地址"));

        when(tx.decrypt("1:legacy-cipher")).thenReturn("旧地址");
        assertEquals(
                "2:new-cipher",
                codec.canonicalizeLegacySensitive(
                        rowId,
                        ProfileFieldPolicy.Field.HUJI_ADDRESS,
                        "new",
                        "1:legacy-cipher"));
    }

    @Test
    void alreadyCanonicalLegacyCipherIsKeptWithoutReencrypting() {
        UUID rowId = UUID.randomUUID();
        when(tx.decrypt("2:canonical"))
                .thenReturn(ProfileChangeSnapshotCodec.PAYLOAD_PREFIX + "13800138000");

        assertEquals(
                "2:canonical",
                codec.canonicalizeLegacySensitive(
                        rowId, ProfileFieldPolicy.Field.PHONE, "new", "2:canonical"));
        verify(tx, never()).encrypt(anyString());
    }

    @Test
    void cipherLookingButUnreadableLegacyValueFailsClosed() {
        UUID rowId = UUID.randomUUID();
        when(tx.decrypt("v7:not-readable")).thenThrow(new IllegalStateException("missing key"));

        assertThrows(
                IllegalStateException.class,
                () -> codec.canonicalizeLegacySensitive(
                        rowId,
                        ProfileFieldPolicy.Field.HUJI_ADDRESS,
                        "old",
                        "v7:not-readable"));
        verify(tx, never()).encrypt(anyString());
    }

    @Test
    void unversionedPgcryptoPacketUsesCurrentKeyCompatibilityInsteadOfDoubleEncryption() {
        UUID rowId = UUID.randomUUID();
        byte[] pgpPacket = new byte[] {(byte) 0xc3, 0x01, 0x04, 0x00, 0x01, 0x02};
        String rawBase64 = Base64.getEncoder().encodeToString(pgpPacket);
        when(tx.decrypt(rawBase64)).thenReturn("旧手机号");
        when(tx.encrypt(ProfileChangeSnapshotCodec.PAYLOAD_PREFIX + "旧手机号"))
                .thenReturn("2:canonical");

        assertEquals(
                "2:canonical",
                codec.canonicalizeLegacySensitive(
                        rowId, ProfileFieldPolicy.Field.PHONE, "old", rawBase64));
    }
}
