package com.uten.imp.features.finance.asset.api;

import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class AssetWorkbenchRequestValidationTest {

    private static Validator validator;

    @BeforeAll
    static void configureValidator() {
        validator = Validation.buildDefaultValidatorFactory().getValidator();
    }

    @Test
    void previewRejectsInvalidCalendarMonthShapeAndUnknownRunType() {
        var request = new AssetWorkbenchRequests.PostingPreviewCommand("DELETE_ALL", "CORPORATE", "2026-13");
        assertThat(validator.validate(request)).hasSize(2);
    }

    @Test
    void clientAssetCodeIsOptionalBecauseServerOwnsNumbering() {
        var request = new AssetWorkbenchRequests.FixedAssetDraft(
                null, "Machine", null, null, null, null, null, null, null,
                new BigDecimal("100.00"), BigDecimal.ZERO, 12, "2026-08",
                null, null, null, null, null, null, null, null, null, null);
        assertThat(validator.validate(request)).isEmpty();
    }

    @Test
    void reversalRequiresVersionAndNormalizesBlankReasonToDefault() {
        var request = new AssetWorkbenchRequests.PostingReasonCommand(null, " ");
        // reason 选填：空白在构造期归一为 DEFAULT_REASON（落库列有非空 CHECK），
        // 仅 expectedVersion 违反 @NotNull。
        assertThat(validator.validate(request)).hasSize(1);
        assertThat(request.reason()).isEqualTo(AssetWorkbenchRequests.DEFAULT_REASON);
    }

    @Test
    void immediateAssetChangesRequireAnEffectiveDate() {
        var transfer = new AssetWorkbenchRequests.TransferCommand(
                0L, java.util.UUID.randomUUID(), null, null, "move", null);
        var status = new AssetWorkbenchRequests.OperatingStatusCommand(
                0L, "IN_USE", "resume", null);

        assertThat(validator.validate(transfer)).isNotEmpty();
        assertThat(validator.validate(status)).isNotEmpty();
    }
}
