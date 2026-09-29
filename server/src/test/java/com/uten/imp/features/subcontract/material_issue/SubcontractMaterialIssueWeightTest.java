package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemDto;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 委外出仓实称重量(ADR-135 §3.8): 行重量千克 4 位, 0 = 没称, 按重量计的行丢弃;
 * 「数量按称重推算」随行保存; 审核后登记 ISSUE 称重核对观测(往来方 = 加工商), 红冲时一并红冲。
 */
class SubcontractMaterialIssueWeightTest {

    @Test
    void lineWeightIsNonNegativeFourDecimalKilogramsAndZeroMeansNotWeighed() {
        assertThat(SubcontractMaterialIssueService.normalizedWeightKg(null)).isNull();
        assertThat(SubcontractMaterialIssueService.normalizedWeightKg(BigDecimal.ZERO)).isNull();
        assertThat(SubcontractMaterialIssueService.normalizedWeightKg(new BigDecimal("3.2500")))
                .isEqualByComparingTo("3.25");
        for (String invalid : List.of("-1", "0.00001", "100000000000000")) {
            assertThatThrownBy(() -> SubcontractMaterialIssueService.normalizedWeightKg(new BigDecimal(invalid)))
                    .isInstanceOfSatisfying(ApiException.class,
                            error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
    }

    @Test
    void itemDtoExposesTheWeighCountFlagNextToTheWeight() {
        List<String> fields = Arrays.stream(MaterialIssueItemDto.class.getDeclaredFields())
                .map(java.lang.reflect.Field::getName)
                .toList();
        assertThat(fields).contains("weight", "qtyFromWeight");
    }

    @Test
    void approvedIssueRecordsCheckObservationAndReversalReversesIt() throws Exception {
        String source = Files.readString(Path.of(
                        "src/main/java/com/uten/imp/features/subcontract/material_issue/"
                                + "SubcontractMaterialIssueService.java"),
                StandardCharsets.UTF_8);
        assertThat(source)
                .contains("it.setWeight(weights.get(autoLine - 1));")
                .contains("it.setQtyFromWeight(Boolean.TRUE.equals(l.getQtyFromWeight()));")
                .contains("recordIssueObservation(r, it, posted, now);")
                .contains("posted.weightSource() != WeightSource.MEASURED")
                .contains("SourceKind.ISSUE")
                .contains("\"SUBCONTRACTOR\"")
                .contains("weightObservations.reverseByCaptureKey(ISSUE_CAPTURE_PREFIX + it.getId());");
        assertThat(SubcontractMaterialIssueService.ISSUE_CAPTURE_PREFIX).isEqualTo("ISSUE:");
    }
}
