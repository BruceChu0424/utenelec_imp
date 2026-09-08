package com.uten.imp.features.sales;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesHeaderSourceUuidContractTest {

    @Test
    void v270AddsUuidForeignKeysWithoutGuessingHistoricalFreeText() throws IOException {
        String sql = canonical(source(
                "src/main/resources/db/migration/"
                        + "V270__sales_header_source_uuid_relations.sql"));

        assertThat(sql)
                .contains("ALTER TABLE sales_shipments ADD COLUMN IF NOT EXISTS source_order_id UUID")
                .contains("ALTER TABLE sales_other_shipments ADD COLUMN IF NOT EXISTS source_order_id UUID")
                .contains("ALTER TABLE sales_returns ADD COLUMN IF NOT EXISTS source_shipment_id UUID")
                .contains("FOREIGN KEY (source_order_id) REFERENCES sales_orders(id)")
                .contains("FOREIGN KEY (source_shipment_id) REFERENCES sales_shipments(id)")
                .contains("VALIDATE CONSTRAINT fk_sales_shipments_source_order")
                .contains("VALIDATE CONSTRAINT fk_sales_other_shipments_source_order")
                .contains("VALIDATE CONSTRAINT fk_sales_returns_source_shipment")
                .doesNotContain("UPDATE sales_shipments")
                .doesNotContain("UPDATE sales_other_shipments")
                .doesNotContain("UPDATE sales_returns");
    }

    @Test
    void onlineWritesDeriveOneHeaderUuidFromLineUuids() throws IOException {
        String shipment = source(
                "src/main/java/com/uten/imp/features/sales/shipment/SalesShipmentService.java");
        String other = source(
                "src/main/java/com/uten/imp/features/sales/other_shipment/SalesOtherShipmentService.java");
        String salesReturn = source(
                "src/main/java/com/uten/imp/features/sales/ret/SalesReturnService.java");

        assertThat(shipment)
                .contains("i.source_doc_no, o.id")
                .contains("applySource(s, source);")
                .contains("一张销售出货单只能关联同一张销售订单")
                .contains("UUID sourceOrderId")
                .contains("UUID sourceOrderId) {}")
                .contains("sourceReadable ? s.getSourceOrderId() : null");
        assertThat(other)
                .contains("throw retiredWrite();")
                .contains("sourceReadable ? s.getSourceOrderId() : null");
        assertThat(salesReturn)
                .contains("o.status, o.id, o.bill_no")
                .contains("applySource(r, source);")
                .contains("一张销售退货单只能关联同一张销售出货单")
                .contains("sourceReadable ? r.getSourceShipmentId() : null");
    }

    @Test
    void sourceAuthorizationUsesUuidAndNeverBillNumberLookup() throws IOException {
        String shipment = source(
                "src/main/java/com/uten/imp/features/sales/shipment/SalesShipmentService.java");
        String other = source(
                "src/main/java/com/uten/imp/features/sales/other_shipment/SalesOtherShipmentService.java");
        String salesReturn = source(
                "src/main/java/com/uten/imp/features/sales/ret/SalesReturnService.java");

        assertThat(shipment)
                .contains("WHERE id = :sourceOrderId")
                .doesNotContain("isOrderSourceDocReadable")
                .doesNotContain("setParameter(\"billNo\", sourceDocNo)");
        assertThat(other)
                .contains("WHERE id = :sourceOrderId")
                .doesNotContain("isOrderSourceDocReadable")
                .doesNotContain("setParameter(\"billNo\", sourceDocNo)");
        assertThat(salesReturn)
                .contains("WHERE id = :sourceShipmentId")
                .doesNotContain("isSourceDocReadable")
                .doesNotContain("setParameter(\"billNo\", sourceDocNo)");
    }

    @Test
    void apiFlutterAndLegacyImportCarryExplicitSourceIdentity() throws IOException {
        String shipmentDetail = source(
                "src/main/java/com/uten/imp/features/sales/shipment/dto/ShipmentDetail.java");
        String otherDetail = source(
                "src/main/java/com/uten/imp/features/sales/other_shipment/dto/OtherShipmentDetail.java");
        String returnDetail = source(
                "src/main/java/com/uten/imp/features/sales/ret/dto/ReturnDetail.java");
        String flutter = source("../lib/features/sales/models/sales_doc.dart");
        String legacy = source("legacy_migration/migrate_sales.sql");

        assertThat(shipmentDetail).contains("private UUID sourceOrderId;");
        assertThat(otherDetail).contains("private UUID sourceOrderId;");
        assertThat(returnDetail).contains("private UUID sourceShipmentId;");
        assertThat(flutter)
                .contains("final String? sourceOrderId;")
                .contains("final String? sourceShipmentId;")
                .contains("sourceOrderId: json['sourceOrderId'] as String?")
                .contains("sourceShipmentId: json['sourceShipmentId'] as String?");
        assertThat(legacy)
                .contains("source_order_id")
                .contains("source_shipment_id")
                .contains("历史自由文本不猜绑 source_order_id")
                .contains("历史自由文本不猜绑 source_shipment_id");
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path.normalize(), StandardCharsets.UTF_8);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
