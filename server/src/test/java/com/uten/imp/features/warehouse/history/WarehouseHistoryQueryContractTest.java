package com.uten.imp.features.warehouse.history;

import org.junit.jupiter.api.Test;

import java.util.Locale;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseHistoryQueryContractTest {

    private static final Set<String> PROHIBITED_COLUMNS = Set.of(
            "price",
            "amount_original",
            "amount_local",
            "total_original",
            "total_local",
            "currency_id",
            "exchange_rate",
            "tax_rate",
            "settlement_method_id",
            "settlement_style_legacy",
            "ap_posted",
            "deduct_amount",
            "deduct_posted");

    @Test
    void everyQueryUsesOnlyItsWhitelistedTablesAndNoCommercialColumn() {
        Map<WarehouseHistoryType, String> expectedItems = Map.of(
                WarehouseHistoryType.PURCHASE_RECEIPT, "purchase_receipt_items",
                WarehouseHistoryType.SUBCONTRACT_RECEIPT, "subcontract_receipt_items",
                WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE, "subcontract_material_issue_items",
                WarehouseHistoryType.SUBCONTRACT_RETURN, "subcontract_return_items",
                WarehouseHistoryType.SUBCONTRACT_MATERIAL_RETURN, "subcontract_material_return_items",
                WarehouseHistoryType.SUBCONTRACT_WASTE, "subcontract_waste_items");

        expectedItems.forEach((type, itemTable) -> {
            String list = WarehouseHistoryQueries.listSql(type);
            String count = WarehouseHistoryQueries.countSql(type);
            String header = WarehouseHistoryQueries.detailHeaderSql(type);
            String lines = WarehouseHistoryQueries.detailLinesSql(type);
            for (String sql : Set.of(list, count, header, lines)) {
                String normalized = sql.toLowerCase(Locale.ROOT);
                assertThat(normalized).contains(type.headerTable(), itemTable);
                assertThat(normalized).doesNotContain("%s", "${");
                assertThat(PROHIBITED_COLUMNS)
                        .as("commercial columns must never be selected for %s", type)
                        .noneMatch(normalized::contains);
            }
            assertThat(list).contains(":keyword", ":keyword_pattern", ":status", ":limit", ":offset");
            assertThat(count).contains(":keyword", ":keyword_pattern", ":status");
            assertThat(header).contains("h.id = :id");
            assertThat(lines).contains("i." + type.itemForeignKey() + " = :id");
        });
    }

    @Test
    void receiptQueriesUseAuthoritativeIqcSidecarAndOtherQueriesDoNot() {
        assertThat(WarehouseHistoryQueries.detailLinesSql(WarehouseHistoryType.PURCHASE_RECEIPT))
                .contains("procurement_inspection_items", "receipt_type = 'PURCHASE'");
        assertThat(WarehouseHistoryQueries.detailLinesSql(WarehouseHistoryType.SUBCONTRACT_RECEIPT))
                .contains("procurement_inspection_items", "receipt_type = 'SUBCONTRACT'");
        for (WarehouseHistoryType type : Set.of(
                WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE,
                WarehouseHistoryType.SUBCONTRACT_RETURN,
                WarehouseHistoryType.SUBCONTRACT_MATERIAL_RETURN,
                WarehouseHistoryType.SUBCONTRACT_WASTE)) {
            assertThat(WarehouseHistoryQueries.detailLinesSql(type))
                    .doesNotContain("procurement_inspection_items");
        }
    }
}
