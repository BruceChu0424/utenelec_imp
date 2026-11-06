package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractReceiptAllowanceTest {
    @Test
    void sharedContractSeparatesTheNormalFinishedCeilingFromActualReceipts() throws Exception {
        JsonNode vectors=new ObjectMapper().readTree(Files.readString(
                Path.of("../contracts/subcontract-actual-receipt/v1.json"))).path("vectors");
        for(JsonNode vector:vectors) {
            var target=new BigDecimal(vector.path("target").asText());
            var pct=new BigDecimal(vector.path("lossPct").asText());
            var actual=new BigDecimal(vector.path("actualReceipt").asText());
            var limit=SubcontractReceiptAllowance.normalLimit(target,pct);
            assertThat(limit).as(vector.path("id").asText()).isEqualByComparingTo(vector.path("normalMaximum").asText());
            if("EXCEPTION".equals(vector.path("outcome").asText()))assertThat(actual).isGreaterThan(limit);
            else assertThat(actual).isLessThanOrEqualTo(limit);
        }
    }

    @Test
    void normalExtraReceiptsDoNotRaiseTheMinimumTargetOrBorrowPurchaseRounding() {
        assertThat(SubcontractReceiptAllowance.minimumTarget(new BigDecimal("1100"),BigDecimal.TEN))
                .isEqualByComparingTo("1000");
        assertThat(SubcontractReceiptAllowance.minimumTarget(new BigDecimal("1100.0001"),BigDecimal.TEN))
                .isEqualByComparingTo("1000.0001");
        assertThat(SubcontractReceiptAllowance.normalLimit(new BigDecimal("0.0001"),new BigDecimal("50")))
                .isEqualByComparingTo("0.0001");
        var bound=new ProcurementOrderQuantityBounds.ReceiptBound(new BigDecimal("1100"),BigDecimal.ZERO,null);
        assertThat(bound.minimumSubcontractTargetQty(BigDecimal.ONE,BigDecimal.TEN)).isEqualByComparingTo("1000");
        assertThat(bound.minimumOrderedQty(BigDecimal.ONE)).isEqualByComparingTo("1100");
        assertThat(SubcontractReceiptAllowance.minimumTargetForRetainedAndHeld(
                new BigDecimal("0.6666666666666666"),BigDecimal.ONE,BigDecimal.ONE,
                new BigDecimal("3"),BigDecimal.ZERO)).isEqualByComparingTo("1.0000");
    }
}
