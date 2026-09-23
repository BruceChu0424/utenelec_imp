package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.CancelRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 取消原因选填的契约(2026-09-22 用户口径「取消分析的原因不用必填」)：
 * 空白放行并落「未填写原因」；填了就至少 2 字(库级 CHECK 同口径)、上限 1000。
 */
class MaterialAnalysisCancelRequestTest {

    private static final String FINGERPRINT = "a".repeat(64);
    private static final Validator VALIDATOR =
            Validation.buildDefaultValidatorFactory().getValidator();

    private static CancelRequest request(String reason) {
        return new CancelRequest(3L, FINGERPRINT, "idem-key-12345678", reason);
    }

    @Test
    void blankReasonIsAcceptedAndFallsBackToDefault() {
        assertThat(VALIDATOR.validate(request(null))).isEmpty();
        assertThat(VALIDATOR.validate(request(""))).isEmpty();
        assertThat(VALIDATOR.validate(request("   \n "))).isEmpty();
        assertThat(request(null).effectiveReason()).isEqualTo(CancelRequest.DEFAULT_REASON);
        assertThat(request("").effectiveReason()).isEqualTo(CancelRequest.DEFAULT_REASON);
        assertThat(request("  ").effectiveReason()).isEqualTo(CancelRequest.DEFAULT_REASON);
    }

    @Test
    void typedReasonNeedsAtLeastTwoCharactersAndIsTrimmed() {
        assertThat(VALIDATOR.validate(request("改"))).isNotEmpty();
        assertThat(VALIDATOR.validate(request(" 改 "))).isNotEmpty();
        assertThat(VALIDATOR.validate(request("改期"))).isEmpty();
        assertThat(VALIDATOR.validate(request("  重新安排需求  "))).isEmpty();
        assertThat(VALIDATOR.validate(request("第一行\n第二行"))).isEmpty();
        assertThat(request("  重新安排需求  ").effectiveReason()).isEqualTo("重新安排需求");
        assertThat(VALIDATOR.validate(request("x".repeat(1001)))).isNotEmpty();
    }
}
