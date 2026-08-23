package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractLossPreMutationContractTest {

    @Test
    void sourceCostValidationPrecedesPeriodLockSupplierQuantityAndClaimWrites() throws Exception {
        String waste = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/subcontract/waste/SubcontractWasteService.java"));
        String claim = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/payables/SubcontractLossClaimService.java"));

        int validate = waste.indexOf("lossClaimPort.validateApprovedWaste(approvedWaste)");
        int periodLock = waste.indexOf("glPostingService.lockAutoProjectionPeriod(r.getBillDate())");
        int supplierMutation = waste.indexOf("SET wasted_qty = COALESCE(wasted_qty,0) + :q");
        int claimMutation = waste.indexOf("lossClaimPort.openForApprovedWaste(approvedWaste)");
        assertThat(validate).isGreaterThanOrEqualTo(0);
        assertThat(validate).isLessThan(periodLock);
        assertThat(periodLock).isLessThan(supplierMutation);
        assertThat(supplierMutation).isLessThan(claimMutation);

        String preflight = between(claim,
                "public void validateApprovedWaste", "public void openForApprovedWaste");
        assertThat(preflight)
                .contains("sourceCost(input.materialIssueItemId())")
                .contains("requireValuedExcess(excess, source.unitBookValueLocal())")
                .doesNotContain("INSERT INTO", "UPDATE ", "DELETE FROM");
    }

    private static String between(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).isGreaterThanOrEqualTo(0);
        assertThat(to).isGreaterThan(from);
        return source.substring(from, to);
    }
}
