package com.uten.imp.features.finance.gl;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractWasteLossGlAccountingTest {

    @Test
    void excessWasteUsesDedicatedExpenseAndInventoryProjectionWithoutApNetting() throws Exception {
        String projection = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/gl/SubcontractWasteLossGlProjection.java"));
        String posting = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/gl/GlPostingService.java"));

        assertThat(projection)
                .contains("line.excess_loss_qty>0")
                .contains("LEFT JOIN v_subcontract_loss_case_value actual ON actual.case_id=loss.id")
                .contains("actual.complete IS DISTINCT FROM TRUE")
                .contains("actual.loss_book_value_local IS NULL")
                .contains("system_posting_style_id('SUBCONTRACT_ABNORMAL_LOSS')")
                .contains("system_posting_style_id('INVENTORY_ASSET')")
                .contains("voucher.id,1,loss_style.id,1,actual.loss_book_value_local")
                .contains("voucher.id,2,inventory_style.id,-1,actual.loss_book_value_local")
                .doesNotContain("AP_CONTROL", "SUBCONTRACT_LOSS_RECOVERY", "loss.loss_book_value_local");
        assertThat(posting)
                .contains("SubcontractWasteLossGlProjection.assertConfiguration(em, period)")
                .contains("SubcontractWasteLossGlProjection.assertProjectionOwnership(em, period)")
                .contains("SubcontractWasteLossGlProjection.post(em, period)")
                .contains("removeSubcontractWasteLossDoc");
    }

    @Test
    void migrationPinsTheReviewedAbnormalLossRoleUuid() throws Exception {
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/V376__subcontract_abnormal_loss_gl.sql"));
        assertThat(migration)
                .contains("37600000-0000-4000-8100-000000000001")
                .contains("SUBCONTRACT_ABNORMAL_LOSS")
                .contains("required_category='EXPENSE'")
                .contains("unreviewed UUID");
    }
}
