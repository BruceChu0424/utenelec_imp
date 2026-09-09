package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementReceiptArrivalAllowanceContractTest {

    @Test
    void authorityRunsAfterExceptionDecisionButBeforeInventoryIqcAndAp() throws Exception {
        assertOrder("purchase/receipt/PurchaseReceiptService.java", "PURCHASE");
        assertOrder("subcontract/receipt/SubcontractReceiptService.java", "SUBCONTRACT");
    }

    @Test
    void onlyReceiptAdjustedApprovedExcessExtendsTheOrderAmountAuthority() throws Exception {
        String purchase = source("purchase/receipt/PurchaseReceiptAmountAuthority.java");
        String subcontract = source("subcontract/receipt/SubcontractReceiptAmountAuthority.java");
        for (String authority : new String[]{purchase, subcontract}) {
            assertThat(authority)
                    .contains("arrival_overage_posted_qty")
                    .contains("status='RECEIPT_ADJUSTED'")
                    .contains("decision IN('APPROVE_ALL','APPROVE_CUSTOM')")
                    .contains("approved_excess_qty>0")
                    .contains("ORDER BY id FOR UPDATE")
                    .contains("postedOverageQty.add(currentApprovedOverageQty)");
        }
    }

    private static void assertOrder(String path, String type) throws Exception {
        String service = source(path);
        int arrival = service.indexOf(
                "arrivalControl.validateBeforeApproval(\n"
                        + "                ProcurementArrivalControlPort." + type);
        int authority = service.indexOf("receiptAmountAuthority.apply(r, items)");
        int iqc = service.indexOf("inspectionService.receive");
        int ap = service.indexOf("arApService.postArAp");
        assertThat(arrival).isGreaterThanOrEqualTo(0);
        assertThat(arrival).isLessThan(authority);
        assertThat(authority).isLessThan(iqc);
        assertThat(authority).isLessThan(ap);
    }

    private static String source(String relative) throws Exception {
        return Files.readString(Path.of("src/main/java/com/uten/imp/features", relative))
                .replace("\r\n", "\n");
    }
}
