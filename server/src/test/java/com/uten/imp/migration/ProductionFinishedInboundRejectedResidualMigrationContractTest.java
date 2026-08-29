package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFinishedInboundRejectedResidualMigrationContractTest {

    @Test
    void rejectedConfirmationMayKeepOneValidatedSameSourceResidual() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("drop constraint production_finished_in_confirmation_shape_chk")
                .contains("decision = 'rejected'")
                .contains("confirmation.residual_stock_document_id is not null")
                .contains("residual_item.doc_id is distinct from confirmation.residual_stock_document_id")
                .contains("residual_item.source_daily_report_item_id is distinct from source_item.source_daily_report_item_id")
                .contains("residual_plan_id is distinct from source_plan_id")
                .contains("rejected confirmation must preserve all quantity for redelivery");
    }

    @Test
    void historicalUnlinkedRejectedFactsRemainValidWithoutLedgerMutation() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("historical unlinked rejected facts remain valid")
                .contains("confirmation.residual_stock_document_id is null and item.residual_stock_document_item_id is not null")
                .doesNotContain("update production_finished_in_confirmations")
                .doesNotContain("delete from production_finished_in_confirmations");
    }

    private static String compact() throws Exception {
        Path direct = Path.of("src/main/resources/db/migration/"
                + "V418__production_finished_in_rejected_residual.sql");
        Path path = Files.exists(direct)
                ? direct : Path.of("server").resolve(direct);
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
