package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementInspectionOptionalPassReasonMigrationContractTest {

    private static final Path V335 = Path.of(
            "src/main/resources/db/migration",
            "V335__allow_optional_iqc_pass_reason.sql");

    @Test
    void v335AllowsPassWithoutAReasonButKeepsFailClosed() throws Exception {
        String sql = Files.readString(V335, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();

        assertThat(sql)
                .contains("drop constraint procurement_inspection_events_reason_chk")
                .doesNotContain("drop constraint if exists")
                .contains("add constraint procurement_inspection_events_reason_chk check")
                .contains("action in ('received', 'pass', 'production_woken', 'receipt_reversed')")
                .contains("or nullif(btrim(reason), '') is not null")
                .contains("not valid")
                .contains("validate constraint procurement_inspection_events_reason_chk")
                .doesNotContain("'fail', 'pass'");
    }
}
