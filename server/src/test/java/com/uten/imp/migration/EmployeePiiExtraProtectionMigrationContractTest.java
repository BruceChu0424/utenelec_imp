package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class EmployeePiiExtraProtectionMigrationContractTest {

    private static final Path ROOT = Path.of("src/main");

    @Test
    void v282GuardsEveryLegacyPlaintextColumnBehindDedicatedCapabilities()
            throws IOException {
        String sql = compact(Files.readString(ROOT.resolve(
                "resources/db/migration/V282__employee_pii_extra_encrypt.sql")));

        assertThat(sql)
                .contains("fn_guard_employee_pii_extra_plaintext")
                .contains("app.employee_pii_extra_backfill")
                .contains("app.employee_pii_extra_legacy_import")
                .contains("before insert on employees")
                .contains("before update of huji_address, residence_address, email, birth_date, marital_status, political_status, office_phone on employees")
                .contains("legacy pii plaintext write requires v282 migration capability")
                .doesNotContain("pgp_sym_encrypt(");
    }

    @Test
    void runnerIsSerializedRowLockedConditionalAndFailClosed() throws IOException {
        String runner = compact(Files.readString(ROOT.resolve(
                "java/com/uten/imp/features/org/employee/EmployeePiiExtraBackfillRunner.java")));

        assertThat(runner)
                .contains("private static final int batch_size = 100")
                .contains("select pg_advisory_lock(?, ?)")
                .contains("readinessstate.refusing_traffic")
                .contains("order by id limit ?")
                .contains("for update")
                .contains("bindemployeepiiextrabackfillv1()")
                .contains("on conflict (employee_id) do nothing")
                .contains("sensitiverows = loadsensitiveforupdate(id)")
                .contains("and \" + encryptedcolumn + \" is null")
                .contains("remaining != 0")
                .contains("could not create or lock")
                .contains("found conflicting existing");
    }

    @Test
    void v286AllowsExtensionOnlyRowsWithoutWeakeningEnrollmentValidation()
            throws IOException {
        String sql = compact(Files.readString(ROOT.resolve(
                "resources/db/migration/V286__employee_sensitive_optional_primary_identity.sql")));
        String entity = compact(Files.readString(ROOT.resolve(
                "java/com/uten/imp/features/org/employee/EmployeeSensitive.java")));
        String crypto = compact(Files.readString(ROOT.resolve(
                "java/com/uten/imp/security/TxSessionVars.java")));
        String onboarding = compact(Files.readString(ROOT.resolve(
                "java/com/uten/imp/features/org/employee/EmployeeOnboardingService.java")));
        String writer = compact(Files.readString(ROOT.resolve(
                "java/com/uten/imp/features/org/employee/EmployeePiiWriter.java")));

        assertThat(sql)
                .contains("alter column id_card_enc drop not null")
                .contains("alter column phone_enc drop not null")
                .doesNotContain("update employee_sensitive")
                .doesNotContain("pgp_sym_encrypt");
        assertThat(entity)
                .contains("@column(name = \"id_card_enc\")")
                .contains("@column(name = \"phone_enc\")")
                .doesNotContain("@column(name = \"id_card_enc\", nullable = false)")
                .doesNotContain("@column(name = \"phone_enc\", nullable = false)");
        assertThat(crypto)
                .contains("if (cipher == null || cipher.isblank()) { return null;");
        assertThat(onboarding)
                .contains("if (isblank(loginaccount))")
                .contains("if (isblank(temporarypassword))");
        assertThat(writer)
                .contains("if (idnumber == null || idnumber.isblank())")
                .contains("chinamobilenumber.normalize(phone)")
                .contains("existsbyidcardhashandemployeeidnot(hash, employeeid)");
    }

    @Test
    void v287RequiresOptionalIdentityDerivationsToHaveAuthoritativeCiphertext()
            throws IOException {
        String sql = compact(Files.readString(ROOT.resolve(
                "resources/db/migration/"
                        + "V287__employee_sensitive_optional_identity_invariants.sql")));

        assertThat(sql)
                .contains("employee_sensitive_id_card_derivation_ck")
                .contains("id_card_enc is not null or "
                        + "(id_card_last4 is null and id_card_hash is null)")
                .contains("employee_sensitive_phone_derivation_ck")
                .contains("phone_enc is not null or phone_hash is null")
                .contains("not valid")
                .contains("validate constraint employee_sensitive_id_card_derivation_ck")
                .contains("validate constraint employee_sensitive_phone_derivation_ck")
                .doesNotContain("update employee_sensitive")
                .doesNotContain("pgp_sym_encrypt");
    }

    @Test
    void reviewedLegacyHrImportsShareTheLockAndUseOnlyImportCapability()
            throws IOException {
        for (String file : new String[] {
                "migrate_hr_workers.sql", "migrate_hr_roster.sql"}) {
            String sql = compact(Files.readString(Path.of(
                    "legacy_migration", file)));
            String phoneColumn = file.contains("workers") ? "mobile" : "phone";

            assertNullableVersionedCipher(sql, "id_card");
            assertNullableVersionedCipher(sql, phoneColumn);
            assertThat(sql)
                    .contains("pg_advisory_xact_lock(1431586126, 282)")
                    .contains("set_config('app.employee_pii_extra_legacy_import', 'v1', true)")
                    .contains("case when nullif(btrim(s.id_card), '') is not null "
                            + "then right(btrim(s.id_card), 4) end")
                    .contains("case when s.rn = 1 "
                            + "and nullif(btrim(s.id_card), '') is not null "
                            + "then encode(hmac(btrim(s.id_card), :'hmac_key', "
                            + "'sha256'), 'hex') end")
                    .contains("case when nullif(btrim(s." + phoneColumn
                            + "), '') is not null then encode(hmac(btrim(s."
                            + phoneColumn + "), :'hmac_key', 'sha256'), 'hex') end")
                    .doesNotContain("session_replication_role = replica")
                    .doesNotContain("pgp_sym_encrypt(coalesce(nullif")
                    .doesNotContain("app.employee_pii_extra_backfill");
        }
    }

    private static void assertNullableVersionedCipher(
            String sql,
            String sourceColumn) {
        String source = "s." + sourceColumn;
        assertThat(sql).contains(
                "case when nullif(btrim(" + source + "), '') is not null "
                        + "then :'pgp_ver' || ':' || encode(pgp_sym_encrypt(btrim("
                        + source + "), :'pgp_key'), 'base64') end");
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
