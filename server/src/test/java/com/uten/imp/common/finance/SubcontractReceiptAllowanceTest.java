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
        assertThat(new ObjectMapper().readTree(Files.readString(Path.of("../contracts/subcontract-actual-receipt/v1.json")))
                .path("quantityFractionDigits").asInt()).isEqualTo(SubcontractReceiptAllowance.SOURCE_QUANTITY_SCALE);
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
        var retained=new BigDecimal("1100.0001");
        var minimum=SubcontractReceiptAllowance.minimumTarget(retained,BigDecimal.TEN);
        assertThat(minimum).isLessThanOrEqualTo(new BigDecimal("1000.0001"));
        assertThat(SubcontractReceiptAllowance.normalLimit(minimum,BigDecimal.TEN)).isGreaterThanOrEqualTo(retained);
        assertThat(SubcontractReceiptAllowance.normalLimit(new BigDecimal("0.0001"),new BigDecimal("50")))
                .isEqualByComparingTo("0.00015");
        var bound=new ProcurementOrderQuantityBounds.ReceiptBound(new BigDecimal("1100"),BigDecimal.ZERO,null);
        assertThat(bound.minimumSubcontractTargetQty(BigDecimal.ONE,BigDecimal.TEN)).isEqualByComparingTo("1000");
        assertThat(bound.minimumOrderedQty(BigDecimal.ONE)).isEqualByComparingTo("1100");
        assertThat(SubcontractReceiptAllowance.minimumTargetForRetainedAndHeld(
                new BigDecimal("0.6666666666666666"),BigDecimal.ONE,BigDecimal.ONE,
                new BigDecimal("3"),BigDecimal.ZERO)).isEqualByComparingTo("0.999999999999999933333334");
    }

    @Test
    void combinedExactSourcesMustStillFitTheTruncatedNormalReceiptGrid() {
        var actual=new BigDecimal("0.24452");
        var target=SubcontractReceiptAllowance.minimumTargetForRetainedAndHeld(
                actual,BigDecimal.ONE,BigDecimal.ZERO,BigDecimal.ONE,BigDecimal.TEN);
        assertThat(target).isEqualByComparingTo("0.222290909090909090909091");
        assertThat(SubcontractReceiptAllowance.normalLimit(target,BigDecimal.TEN)).isGreaterThanOrEqualTo(actual);
        var bound=new ProcurementOrderQuantityBounds.ReceiptBound(new BigDecimal("0.73356"),BigDecimal.ZERO,null);
        assertThat(bound.minimumSubcontractTargetQty(new BigDecimal("3"),BigDecimal.TEN)).isEqualByComparingTo(target);
        assertThat(SubcontractReceiptAllowance.minimumTargetForRetainedAndHeld(
                new BigDecimal("0.73356"),new BigDecimal("3"),BigDecimal.ZERO,BigDecimal.ONE,BigDecimal.TEN))
                .isEqualByComparingTo(target);
    }
    @Test
    void recordedSourceGridAndInverseShareTheSameExactContract() throws Exception {
        var contract=new ObjectMapper().readTree(Files.readString(Path.of("../contracts/subcontract-actual-receipt/v1.json")));
        var step=BigDecimal.ONE.movePointLeft(SubcontractReceiptAllowance.SOURCE_QUANTITY_SCALE);
        for(JsonNode vector:contract.path("normalAllowanceVectors")) {
            var target=new BigDecimal(vector.path("target").asText());var pct=new BigDecimal(vector.path("lossPct").asText());
            var limit=SubcontractReceiptAllowance.normalLimit(target,pct);
            assertThat(limit).as(vector.path("id").asText()).isEqualByComparingTo(vector.path("normalMaximum").asText());
            assertThat(limit).isGreaterThanOrEqualTo(target);
            assertThat(limit).isLessThanOrEqualTo(target.multiply(BigDecimal.ONE.add(pct.movePointLeft(2))));
        }
        for(JsonNode vector:contract.path("inverseVectors")) {
            var retained=new BigDecimal(vector.path("retainedBase").asText());var rate=new BigDecimal(vector.path("orderUnitRate").asText());
            var held=new BigDecimal(vector.path("heldMaterialQty").asText());var base=new BigDecimal(vector.path("baseBomQty").asText());
            var pct=new BigDecimal(vector.path("lossPct").asText());
            var target=SubcontractReceiptAllowance.minimumTargetForRetainedAndHeld(retained,rate,held,base,pct);
            var numerator=retained.multiply(base).add(held.multiply(rate));var denominator=rate.multiply(base);
            assertThat(target).as(vector.path("id").asText()).isEqualByComparingTo(vector.path("minimumTarget").asText());
            assertThat(SubcontractReceiptAllowance.normalLimit(target,pct).multiply(denominator)).isGreaterThanOrEqualTo(numerator);
            assertThat(SubcontractReceiptAllowance.normalLimit(target.subtract(step),pct).multiply(denominator)).isLessThan(numerator);
        }
    }

}
