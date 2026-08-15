package com.uten.imp.features.profilechange;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.annotation.Order;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.UUID;

/**
 * V284 forward backfill for historically mislabelled profile-change snapshots.
 *
 * <p>The {@code value_encoding} column is both a durable progress ledger and a
 * read/write gate.  Rows are locked and committed individually in bounded
 * batches.  A cipher-looking value that cannot be decrypted with the configured
 * current/legacy keyring aborts startup and remains LEGACY_UNKNOWN.</p>
 */
@Component
@Order(59)
public class ProfileChangeSnapshotBackfillRunner implements ApplicationRunner {

    private static final Logger log =
            LoggerFactory.getLogger(ProfileChangeSnapshotBackfillRunner.class);
    private static final int BATCH_SIZE = 200;

    private final JdbcTemplate jdbc;
    private final ProfileChangeSnapshotCodec codec;
    private final TransactionTemplate transactionTemplate;

    public ProfileChangeSnapshotBackfillRunner(
            JdbcTemplate jdbc,
            ProfileChangeSnapshotCodec codec,
            PlatformTransactionManager transactionManager) {
        this.jdbc = jdbc;
        this.codec = codec;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
    }

    @Override
    public void run(ApplicationArguments args) {
        long migrated = 0;
        while (true) {
            List<UUID> ids = nextBatch();
            if (ids.isEmpty()) {
                break;
            }
            for (UUID id : ids) {
                Boolean changed = transactionTemplate.execute(status -> migrateOne(id));
                if (Boolean.TRUE.equals(changed)) {
                    migrated++;
                }
            }
        }

        Long remaining = jdbc.queryForObject(
                "SELECT count(*) FROM profile_change_requests "
                        + "WHERE value_encoding = 'LEGACY_UNKNOWN'",
                Long.class);
        if (remaining == null || remaining != 0) {
            throw new IllegalStateException(
                    "profile-change snapshot backfill did not reach a protected terminal state; "
                            + "remaining=" + remaining);
        }
        if (migrated > 0) {
            log.info("Profile-change V284 snapshot backfill completed for {} rows", migrated);
        }
    }

    private List<UUID> nextBatch() {
        return jdbc.query(
                """
                SELECT id
                FROM profile_change_requests
                WHERE value_encoding = 'LEGACY_UNKNOWN'
                ORDER BY id
                LIMIT ?
                """,
                statement -> statement.setInt(1, BATCH_SIZE),
                (result, rowNumber) -> result.getObject("id", UUID.class));
    }

    private boolean migrateOne(UUID id) {
        codec.bindWriteCapability();
        List<LegacyRow> rows = jdbc.query(
                """
                SELECT id, field_code, old_value_enc, new_value_enc, value_encoding
                FROM profile_change_requests
                WHERE id = ?
                FOR UPDATE
                """,
                statement -> statement.setObject(1, id),
                (result, rowNumber) -> new LegacyRow(
                        result.getObject("id", UUID.class),
                        result.getString("field_code"),
                        result.getString("old_value_enc"),
                        result.getString("new_value_enc"),
                        result.getString("value_encoding")));
        if (rows.isEmpty()) {
            return false;
        }
        LegacyRow row = rows.get(0);
        if (!ProfileChangeSnapshotCodec.ENCODING_LEGACY_UNKNOWN.equals(row.valueEncoding())) {
            return false;
        }
        if (!ProfileFieldPolicy.requiresEncryptedSnapshot(row.fieldCode())) {
            throw new IllegalStateException(
                    "LEGACY_UNKNOWN profile-change row is not a protected field: " + row.id());
        }
        if (row.newValue() == null) {
            throw new IllegalStateException(
                    "legacy sensitive profile-change row has no new snapshot: " + row.id());
        }

        String oldCipher = codec.canonicalizeLegacySensitive(
                row.id(), row.fieldCode(), "old", row.oldValue());
        String newCipher = codec.canonicalizeLegacySensitive(
                row.id(), row.fieldCode(), "new", row.newValue());
        int updated = jdbc.update(
                """
                UPDATE profile_change_requests
                SET old_value_enc = ?,
                    new_value_enc = ?,
                    value_encoding = 'PGCRYPTO_V1'
                WHERE id = ?
                  AND value_encoding = 'LEGACY_UNKNOWN'
                """,
                oldCipher, newCipher, row.id());
        if (updated != 1) {
            throw new IllegalStateException(
                    "profile-change snapshot backfill lost row ownership: " + row.id());
        }
        return true;
    }

    private record LegacyRow(
            UUID id,
            String fieldCode,
            String oldValue,
            String newValue,
            String valueEncoding) {
    }
}
