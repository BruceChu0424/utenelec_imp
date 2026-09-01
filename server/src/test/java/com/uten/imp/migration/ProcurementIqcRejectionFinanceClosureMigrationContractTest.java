package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementIqcRejectionFinanceClosureMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V440__procurement_iqc_rejection_finance_closure.sql");

    @Test
    void permissionSurfaceUsesStableUuidAndRejectsIdentityDrift()
            throws Exception {
        String sql = compact();
        int surfaceStart = sql.indexOf("insert into permission_surfaces");
        int mappingStart = sql.indexOf(
                "insert into permission_surface_permissions", surfaceStart);

        assertThat(surfaceStart).isGreaterThanOrEqualTo(0);
        assertThat(mappingStart).isGreaterThan(surfaceStart);
        String surfaceInsert = sql.substring(surfaceStart, mappingStart);
        assertThat(sql).contains("identity conflicts with the stable uuid");
        assertThat(surfaceInsert)
                .contains("insert into permission_surfaces"
                        + "(id,surface_key,name,sort_order,enabled)")
                .contains("'44000000-0000-4000-8000-000000000001'")
                .contains("'procurement.iqc-rejection'")
                .contains("on conflict(surface_key) do update")
                .doesNotContain("gen_random_uuid")
                .doesNotContain("nextval(");
    }

    @Test
    void exactSevenPermissionLinksRemainIdempotent() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("where surface.surface_key='procurement.iqc-rejection'")
                .contains("on conflict(surface_id,permission_id) do nothing")
                .contains("if v_links<>7 then")
                .contains("v440 iqc rejection permission surface is incomplete");
        assertThat(occurrences(sql, "'procurement_iqc_rejection:"))
                .isGreaterThanOrEqualTo(21);
    }

    @Test
    void actionTaxonomyHistoryGuardAndLedgerMetadataStayCompatible()
            throws Exception {
        String sql=compact();
        assertThat(sql)
                .contains("'procurement_iqc_rejection:view_all'")
                .contains("266,'view'")
                .contains("'procurement_iqc_rejection:reverse'")
                .contains("271,'execute'")
                .contains("inspection.status in('partial','resolved')")
                .contains("procurement_iqc_failure_detection_guard")
                .contains("'purchase_receipt','purchase_return','purchase_iqc_credit'")
                .contains("'subcontract_loss_offset','subcontract_iqc_credit'");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\r\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }

    private static int occurrences(String value, String needle) {
        int count = 0;
        int from = 0;
        while ((from = value.indexOf(needle, from)) >= 0) {
            count++;
            from += needle.length();
        }
        return count;
    }
}
