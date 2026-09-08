package com.uten.imp.features.stock.valuation;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementCostSourceEvidenceTest {
    @Test
    void paidReceiptRetainsTheCompleteBookProductAndImmutableAuthority() {
        Map<String, Object> row = approvedPart();
        row.put("payable_local", new BigDecimal("0.000000000000000000000007000001"));
        var evidence = ProcurementCostSourceEvidenceService.evidence(row).orElseThrow();
        assertThat(evidence.knownValueLocal()).isEqualByComparingTo("0.000000000000000000000007000001");
        assertThat(evidence.carriedQtyBase()).isZero();
        assertThat(evidence.complete()).isTrue();
        assertThat(evidence.authorityId()).isEqualTo(row.get("id"));
        assertThat(evidence.evidenceHash()).matches("[0-9a-f]{64}");
        assertThat(ProcurementCostSourceEvidenceService.evidence(new HashMap<>(row))
                .orElseThrow().evidenceHash()).isEqualTo(evidence.evidenceHash());
    }

    @Test
    void freeReplacementHasZeroNewChargeAndRequiresAllPhysicalCostToBeCarried() {
        Map<String, Object> row = approvedPart();
        row.put("billing_mode", "NO_CHARGE");
        row.put("payable_local", BigDecimal.ZERO);
        row.put("funding_slice_id", UUID.randomUUID());
        row.remove("ap_id");
        var evidence = ProcurementCostSourceEvidenceService.evidence(row).orElseThrow();
        assertThat(evidence.knownValueLocal()).isZero();
        assertThat(evidence.carriedQtyBase()).isEqualByComparingTo("8");
        row.remove("funding_slice_id");
        assertThat(ProcurementCostSourceEvidenceService.evidence(row)).isEmpty();
    }

    @Test
    void missingPayableOrUnknownAmountCannotBecomeAnApprovedFreeAcquisition() {
        Map<String, Object> row = approvedPart();
        row.remove("ap_id");
        assertThat(ProcurementCostSourceEvidenceService.evidence(row)).isEmpty();
        row.put("payable_local", null);
        assertThat(ProcurementCostSourceEvidenceService.evidence(row)).isEmpty();
        row.put("payable_local", BigDecimal.ZERO);
        assertThat(ProcurementCostSourceEvidenceService.evidence(row)).isPresent();
    }

    private static Map<String, Object> approvedPart() {
        Map<String, Object> row = new HashMap<>();
        for (String field : new String[]{"id", "receipt_id", "receipt_item_id", "warehouse_id", "goods_id", "ap_id"}) {
            row.put(field, UUID.randomUUID());
        }
        row.put("receipt_type", "PURCHASE");
        row.put("billing_mode", "STANDARD");
        row.put("base_qty", new BigDecimal("8"));
        row.put("payable_local", new BigDecimal("400"));
        return row;
    }
}
