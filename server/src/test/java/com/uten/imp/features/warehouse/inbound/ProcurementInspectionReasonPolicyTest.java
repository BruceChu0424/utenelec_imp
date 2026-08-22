package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProcurementInspectionReasonPolicyTest {

    @Test
    void passReasonIsOptionalAndBlankNormalizesToNull() {
        assertThat(ProcurementInspectionService.normalizeDispositionReason("PASS", null))
                .isNull();
        assertThat(ProcurementInspectionService.normalizeDispositionReason("PASS", "   "))
                .isNull();
        assertThat(ProcurementInspectionService.normalizeDispositionReason(
                "PASS", "  特采依据 QA-01  "))
                .isEqualTo("特采依据 QA-01");
    }

    @Test
    void failReasonRemainsRequired() {
        assertThatThrownBy(() -> ProcurementInspectionService
                .normalizeDispositionReason("FAIL", null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessage("不合格原因不能为空");
        assertThatThrownBy(() -> ProcurementInspectionService
                .normalizeDispositionReason("FAIL", "   "))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessage("不合格原因不能为空");
    }

    @Test
    void anyNonBlankReasonIsTrimmedAndLimitedToFiveHundredCharacters() {
        assertThat(ProcurementInspectionService.normalizeDispositionReason(
                "FAIL", "  尺寸超差  "))
                .isEqualTo("尺寸超差");
        assertThatThrownBy(() -> ProcurementInspectionService
                .normalizeDispositionReason("PASS", "x".repeat(501)))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessage("质检结论原因不能超过 500 个字符");
    }

    @Test
    void passMovementRemarkHasNoNullTextOrTrailingColon() {
        assertThat(ProcurementInspectionService.passMovementRemark(null))
                .isEqualTo("IQC 合格放行");
        assertThat(ProcurementInspectionService.passMovementRemark("特采依据 QA-01"))
                .isEqualTo("IQC 合格放行：特采依据 QA-01");
    }
}
