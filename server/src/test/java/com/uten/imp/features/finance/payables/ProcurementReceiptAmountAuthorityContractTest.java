package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementReceiptAmountAuthorityContractTest {

    @Test
    void purchaseAndSubcontractReceiptAuthorityPrecedeInventoryIqcAndAp() throws Exception {
        assertReceiptAuthority(
                "purchase/receipt/PurchaseReceiptService.java",
                "purchase/receipt/PurchaseReceiptAmountAuthority.java",
                "receiptAmountAuthority.apply(r, items)",
                "FROM purchase_order_items source_item");
        assertReceiptAuthority(
                "subcontract/receipt/SubcontractReceiptService.java",
                "subcontract/receipt/SubcontractReceiptAmountAuthority.java",
                "receiptAmountAuthority.apply(r, items)",
                "FROM subcontract_order_items source_item");
    }

    @Test
    void subcontractOrderSettlementMethodIsAReviewedFinanceSnapshot() throws Exception {
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/V378__subcontract_order_settlement_snapshot.sql"));
        String entity = source("subcontract/order/SubcontractOrder.java");
        String request = source("subcontract/order/dto/OrderSaveRequest.java");
        String detail = source("subcontract/order/dto/OrderDetail.java");
        String list = source("subcontract/order/dto/OrderListItem.java");
        String approvalPort = Files.readString(Path.of(
                "src/main/java/com/uten/imp/application/port/ProcurementOrderApprovalPort.java"));
        String approval = source("finance/procurement/ProcurementFinanceApprovalService.java");

        assertThat(migration)
                .contains("ADD COLUMN settlement_method_id UUID")
                .contains("subcontract_orders_approved_settlement_chk")
                .contains("historical NULL must be reconciled");
        assertThat(entity).contains("@Column(name = \"settlement_method_id\")");
        assertThat(request).contains("private UUID settlementMethodId;");
        assertThat(detail).contains("private UUID settlementMethodId;");
        assertThat(list).contains("private UUID settlementMethodId;");
        assertThat(approvalPort).contains("UUID settlementMethodId");
        assertThat(approval).contains("header.put(\"settlementMethodId\", snapshot.settlementMethodId())");
    }

    private static void assertReceiptAuthority(
            String servicePath, String authorityPath, String call, String sourceTable) throws Exception {
        String service = source(servicePath);
        String authority = source(authorityPath);
        int apply = service.indexOf(call);
        assertThat(apply).isGreaterThanOrEqualTo(0);
        assertThat(apply).isLessThan(service.indexOf("inspectionService.receive"));
        assertThat(apply).isLessThan(service.indexOf("arApService.postArAp"));
        assertThat(authority)
                .contains(sourceTable)
                .contains("FOR UPDATE OF source_item, source_order")
                .contains("source_order.settlement_method_id")
                .contains("COUNT(*) FILTER")
                .contains("receipt_doc.status=1")
                .contains("item.setAmountOriginal(amounts.original())")
                .contains("Comparator.comparing");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(Path.of("src/main/java/com/uten/imp/features", relative));
    }
}
