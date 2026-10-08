package com.uten.imp.security;

import com.uten.imp.config.props.CryptoProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** PGP maintenance never returns decrypted values to Java or includes values in errors. */
@Component
@RequiredArgsConstructor
public class PiiCipherRewrapper {
    private final JdbcTemplate db;
    private final CryptoProperties crypto;

    public record Result(String cipher, boolean changed) {
        @Override public String toString() { return "PgpRewrapResult[changed=" + changed + "]"; }
    }

    public String currentVersion() {
        if (!PgpCipherEnvelope.validVersion(crypto.getPgpKeyVersion())
                || !PgpCipherEnvelope.validVersion(crypto.getPgpUnversionedKeyVersion())
                || crypto.getPgpMasterKey() == null || crypto.getPgpMasterKey().isBlank()) {
            throw new IllegalStateException("PGP 密钥轮换配置不完整，原值未改变");
        }
        return crypto.getPgpKeyVersion();
    }

    public Result rewrap(String stored, String requiredPayloadPrefix) {
        if (stored == null) return new Result(null, false);
        if (stored.isBlank()) throw unreadable();
        try {
            String target = currentVersion();
            PgpCipherEnvelope source = PgpCipherEnvelope.parse(stored, crypto.getPgpUnversionedKeyVersion());
            String oldKey = source.version().equals(target) ? crypto.getPgpMasterKey()
                    : crypto.getPgpLegacyKeys().get(source.version());
            if (oldKey == null || oldKey.isBlank()) throw unreadable();
            boolean changed = !source.versioned() || !source.version().equals(target);
            // Validate even current-version ciphertext: a changed key under the
            // same version, damaged value or wrong snapshot domain must stop the batch.
            if (!changed) {
                Boolean valid = db.queryForObject("""
                        SELECT starts_with(pgp_sym_decrypt(decode(?, 'base64'), ?), ?)
                        """, Boolean.class, source.body(), oldKey, requiredPayloadPrefix);
                if (!Boolean.TRUE.equals(valid)) throw unreadable();
                return new Result(stored, false);
            }
            return db.queryForObject("""
                    WITH decoded AS MATERIALIZED (
                        SELECT pgp_sym_decrypt(decode(?, 'base64'), ?) AS plain
                    ), encoded AS MATERIALIZED (
                        SELECT encode(pgp_sym_encrypt(plain, ?), 'base64') AS body FROM decoded
                    )
                    SELECT encoded.body,
                           convert_to(pgp_sym_decrypt(decode(encoded.body,'base64'), ?),'UTF8')
                               = convert_to(decoded.plain,'UTF8')
                           AND starts_with(decoded.plain, ?) AS verified
                    FROM decoded CROSS JOIN encoded
                    """, (row, index) -> {
                if (!row.getBoolean("verified")) throw unreadable();
                return new Result(target + ":" + row.getString("body"), true);
            }, source.body(), oldKey, crypto.getPgpMasterKey(), crypto.getPgpMasterKey(), requiredPayloadPrefix);
        } catch (RuntimeException failure) {
            // JDBC exception details can contain bound crypto data. Do not attach
            // the cause to the public exception or log it. The transaction rolls back.
            throw unreadable();
        }
    }

    private static IllegalStateException unreadable() {
        return new IllegalStateException("密文无法通过历史密钥、完整性或快照格式核验，本批未修改；请核对密钥配置后重试");
    }
}
