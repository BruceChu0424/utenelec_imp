package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierPayablesIntegrityMigrationContractTest {

    private static final Path MIGRATIONS = Path.of("src/main/resources/db/migration");

    @Test
    void paymentLineBackfillDoesNotReferenceTheUpdateTargetInsideAFromJoin()
            throws IOException {
        String sql = Files.readString(MIGRATIONS.resolve(
                "V330__supplier_payables_and_subcontract_loss_claims.sql"));
        String normalized = sql.replaceAll("\\s+", " ").toLowerCase();

        assertThat(normalized)
                .contains("select ledger.exchange_rate from ar_ap_ledger ledger"
                        + " where ledger.id = line.applied_ledger_id")
                .doesNotContain("join ar_ap_ledger ledger on ledger.id ="
                        + " line.applied_ledger_id");
    }

    @Test
    void derivedOpenItemMetadataCannotBeChangedWithoutReDerivation() throws IOException {
        String sql = Files.readString(MIGRATIONS.resolve(
                "V334__derive_ar_ap_open_item_metadata.sql"))
                + Files.readString(MIGRATIONS.resolve(
                "V341__harden_ar_ap_open_item_derivation.sql"));
        String normalized = sql.replaceAll("\\s+", " ").toUpperCase();

        boolean derivesOnEveryUpdate = normalized.contains(
                "BEFORE INSERT OR UPDATE ON AR_AP_LEDGER");
        boolean explicitlyWatchesDerivedColumns = Pattern.compile(
                        "UPDATE OF[^;]*(BUSINESS_TYPE[^;]*OPEN_ITEM_KIND|OPEN_ITEM_KIND[^;]*BUSINESS_TYPE)[^;]*ON AR_AP_LEDGER")
                .matcher(normalized).find();

        assertThat(derivesOnEveryUpdate || explicitlyWatchesDerivedColumns)
                .as("native SQL must not bypass canonical business_type/open_item_kind derivation")
                .isTrue();
    }

    @Test
    void offsetSnapshotsEnforceCreditAndPayableSidesAtTheDatabaseBoundary() throws IOException {
        String sql = Files.readString(MIGRATIONS.resolve(
                "V332__supplier_open_item_offsets.sql"))
                + Files.readString(MIGRATIONS.resolve(
                "V365__supplier_offset_snapshot_shape_guard.sql"));

        assertThat(sql)
                .containsPattern("(?s)source_balance_before_original\\s*<=\\s*0")
                .containsPattern("(?s)source_balance_after_original\\s*<=\\s*0")
                .containsPattern("(?s)target_balance_before_original\\s*>=\\s*0")
                .containsPattern("(?s)target_balance_after_original\\s*>=\\s*0");
    }
}
