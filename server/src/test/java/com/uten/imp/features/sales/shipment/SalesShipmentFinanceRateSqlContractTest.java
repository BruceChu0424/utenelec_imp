package com.uten.imp.features.sales.shipment;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesShipmentFinanceRateSqlContractTest {

    private static final Path SOURCE = Path.of(
            "src/main/java/com/uten/imp/features/sales/shipment/SalesShipmentService.java");

    @Test
    void shippedPostingLocksAnActiveFinanceCurrencyRateBeforeStockMutation() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();

        assertThat(source).contains("from currencies currency");
        assertThat(source).contains("currency.status = '使用'");
        assertThat(source).contains("currency.exchange_rate");
        assertThat(source).contains("for share");
        int approvalStart = source.indexOf("private shipmentdetail approvelocked");
        String approvalPath = source.substring(approvalStart,
                source.indexOf("public shipmentdetail reject", approvalStart));
        assertThat(approvalPath.indexOf("applyfinancepostingrate(s, items)"))
                .isLessThan(approvalPath.indexOf("stockservice.lockinventory"));
        assertThat(source).contains("item.setamountlocal(local)");
        assertThat(source).contains("shipment.setexchangerate(financerate)");
    }

    @Test
    void draftPersistenceIgnoresClientAuthoredLocalAmounts() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();

        assertThat(source).contains("it.setamountlocal(null)");
        assertThat(source).contains("s.settotallocal(null)");
    }

    @Test
    void arSettlementMetadataLocksActiveClientTermsAndNeverUsesLastOperationDate() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();

        assertThat(source).contains(
                "select client.price_style, client.tday",
                "client.status = '使用'",
                "client.is_deleted, false",
                "for share");
        int approvalStart = source.indexOf("private shipmentdetail approvelocked");
        String approvalPath = source.substring(approvalStart,
                source.indexOf("public shipmentdetail reject", approvalStart));
        assertThat(approvalPath).contains(
                "clientsettlementsnapshot settlement = lockclientsettlementsnapshot(s)",
                "settlement.duedate()",
                "settlement.settlementstylelegacy()");
        assertThat(approvalPath).doesNotContain("s.getlastdate().tolocaldate()");
    }
}
