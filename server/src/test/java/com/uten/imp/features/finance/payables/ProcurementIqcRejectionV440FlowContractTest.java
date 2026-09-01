package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementIqcRejectionV440FlowContractTest {

    @Test
    void arrivalCapacityReopensOnlyPhysicallyReturnedFailureAndConsumesItExplicitly()
            throws IOException {
        String arrival = source(
                "com/uten/imp/features/warehouse/inbound/ProcurementArrivalControlService.java");
        String allocation = source(
                "com/uten/imp/common/finance/ProcurementIqcReplacementAllocationService.java");
        String purchaseReceipt = source(
                "com/uten/imp/features/purchase/receipt/PurchaseReceiptService.java");
        String purchaseAmount = source(
                "com/uten/imp/features/purchase/receipt/PurchaseReceiptAmountAuthority.java");
        String subcontractReceipt = source(
                "com/uten/imp/features/subcontract/receipt/SubcontractReceiptService.java");
        String subcontractAmount = source(
                "com/uten/imp/features/subcontract/receipt/SubcontractReceiptAmountAuthority.java");

        assertThat(arrival)
                .contains(".add(returnedIqcFailureQty(orderType,row.orderItemId()))")
                .contains(".subtract(zero(row.receivedQty()))")
                .contains("return_recorded_at IS NOT NULL")
                .contains("'RETURN_RECORDED','CREDIT_CONFIRMED',")
                .contains("'CLOSED_NO_CREDIT','FINANCE_EXCEPTION'");
        assertThat(allocation)
                .contains("FILTER(WHERE allocation.status='ACTIVE')")
                .contains("ORDER BY return_date,id FOR UPDATE")
                .contains("SET status='REVERSED',row_version=row_version+1")
                .contains("WHERE id=:id AND status='ACTIVE' AND row_version=:version");
        assertThat(purchaseAmount)
                .contains("replacementAllocation.allocateForReceiptItem(");
        assertThat(purchaseReceipt)
                .contains("iqcReplacementAllocation.reverseForReceipt(");
        assertThat(subcontractAmount)
                .contains("replacementAllocation.allocateForReceiptItem(");
        assertThat(subcontractReceipt)
                .contains("iqcReplacementAllocation.reverseForReceipt(");
    }

    @Test
    void commandReplayPrecedesMutationAndFinanceExceptionHasAnExplicitRecoveryLane()
            throws IOException {
        String service = source(
                "com/uten/imp/features/finance/payables/ProcurementIqcRejectionService.java");
        int retry = service.indexOf("public CaseDetail retryFinanceProjection(");
        int replay = service.indexOf("if(commandReplay(request.commandId(),id,", retry);
        int version = service.indexOf("requireVersion(row, request.expectedVersion())", retry);

        assertThat(retry).isGreaterThanOrEqualTo(0);
        assertThat(replay).isGreaterThan(retry);
        assertThat(version).isGreaterThan(replay);
        assertThat(service.substring(retry))
                .contains("if (!\"FINANCE_EXCEPTION\".equals(row.status()))")
                .contains("?(physicalReturned?\"RETURN_RECORDED\":\"PENDING_RETURN\")")
                .contains("publish(projection.exceptionCode()==null?EVENT_OPENED:EVENT_FINANCE_EXCEPTION");
    }

    @Test
    void amountMaskControlsBothPayloadAmountsAndTheExplicitMaskedFlag()
            throws IOException {
        String service = source(
                "com/uten/imp/features/finance/payables/ProcurementIqcRejectionService.java");

        assertThat(service)
                .contains("boolean canSeePrice = has(\"procurement_iqc_rejection:amount:view\")")
                .contains("canSeePrice ? money(row[14]) : null")
                .contains("canSeePrice ? money(row[15]) : null")
                .contains("List.copyOf(actions), !canSeePrice)");
    }

    @Test
    void migrationKeepsReplacementAllocationActiveCapAndReversalAuditFields()
            throws IOException {
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V440__procurement_iqc_rejection_finance_closure.sql"));

        assertThat(migration)
                .contains("allocated_qty               NUMERIC(18,4) NOT NULL")
                .contains("status                      TEXT NOT NULL DEFAULT 'ACTIVE'")
                .contains("CHECK (status IN ('ACTIVE','REVERSED'))")
                .contains("reversed_by                 UUID REFERENCES users(id)")
                .contains("reverse_reason              TEXT")
                .contains("CREATE INDEX idx_procurement_iqc_replacement_case");
    }

    private static String source(String relativePath) throws IOException {
        return Files.readString(Path.of("src/main/java", relativePath));
    }
}
