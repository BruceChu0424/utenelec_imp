package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class ProfileChangeSnapshotProtectionMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V284__profile_change_sensitive_snapshot_protection.sql");

    @Test
    void v284AddsDurableEncodingStateAndFailClosedWriteGuard() throws IOException {
        String sql = compact(Files.readString(MIGRATION));

        assertThat(sql)
                .contains("add column if not exists value_encoding varchar(24)")
                .contains("'plain', 'pgcrypto_v1', 'legacy_unknown'")
                .contains("field_code in ('phone', 'hujiaddress')")
                .contains("field_code like 'emergencycontact.%'")
                .contains("profile_change_requests_legacy_encoding_idx")
                .contains("fn_profile_change_snapshot_requires_encryption")
                .contains("fn_is_versioned_pgcrypto_text")
                .contains("fn_guard_profile_change_snapshot_protection")
                .contains("before insert or update on profile_change_requests")
                .contains("current_setting('app.profile_change_snapshot_codec', true) is distinct from 'v1'")
                .contains("sensitive profile-change write requires snapshot codec capability v1")
                .contains("sensitive profile-change snapshot must use pgcrypto_v1")
                .doesNotContain("uten_pgp_master_key")
                .doesNotContain("pgp_sym_encrypt(");
    }

    @Test
    void v284VerifiesEffectiveAuditRedactionAndCleansHistoricalCopies()
            throws IOException {
        String sql = compact(Files.readString(MIGRATION));

        assertThat(sql)
                .contains("function_row.proname = 'fn_audit'")
                .contains("fn_audit_redact_row( 'profile_change_requests'")
                .contains("'v284-redaction-sentinel-old'")
                .contains("'old_value_enc'")
                .contains("'new_value_enc'")
                .contains("update audit_log")
                .contains("target_type in ('profile_change_requests', 'profilechangerequest')")
                .contains("before - array[ 'old_value_enc', 'new_value_enc', 'review_comment' ]::text[]")
                .contains("\"after\" - array[ 'old_value_enc', 'new_value_enc', 'review_comment' ]::text[]");
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
