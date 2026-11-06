package com.uten.imp.features.purchase.receipt;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ReceiptCommercialMaskContractTest {

    @Test
    void purchaseReceiptRoundTripsRawIntentClassificationsAcrossPriceMasking() throws Exception {
        var json = new com.fasterxml.jackson.databind.ObjectMapper();
        var mask = PurchaseReceiptService.class.getDeclaredMethod("maskItemPrices",
                com.uten.imp.features.purchase.receipt.dto.ReceiptItemDto.class);
        mask.setAccessible(true);
        for (String intent : java.util.Arrays.asList(null, "NORMAL", "RETURN_REPLACEMENT")) {
            for (String giftIntent : java.util.Arrays.asList(null, "NORMAL", "RETURN_REPLACEMENT")) {
                var original = new com.uten.imp.features.purchase.receipt.dto.ReceiptItemDto(
                        java.util.UUID.randomUUID(), 1, java.util.UUID.randomUUID(), "CODE", "NAME", "SOURCE", null,
                        null, java.util.UUID.randomUUID(), java.math.BigDecimal.ONE, new java.math.BigDecimal("2"),
                        new java.math.BigDecimal("7"), new java.math.BigDecimal("14"), new java.math.BigDecimal("14"),
                        java.math.BigDecimal.ZERO, java.math.BigDecimal.ONE, null,
                        java.util.UUID.randomUUID(), java.util.UUID.randomUUID(), "ORDER", "SOURCE", "note");
                original.setReplacementIntent(intent);
                original.setGiftReplacementIntent(giftIntent);
                var before = json.<com.fasterxml.jackson.databind.JsonNode>valueToTree(original);
                var masked = (com.uten.imp.features.purchase.receipt.dto.ReceiptItemDto) mask.invoke(null, original);
                var after = json.<com.fasterxml.jackson.databind.JsonNode>valueToTree(masked);
                for (var projected : java.util.List.of(before, after)) {
                    assertThat(projected.has("replacementIntent")).isTrue();
                    assertThat(projected.has("giftReplacementIntent")).isTrue();
                    assertThat(projected.get("replacementIntent").isNull() ? null : projected.get("replacementIntent").asText()).isEqualTo(intent);
                    assertThat(projected.get("giftReplacementIntent").isNull() ? null : projected.get("giftReplacementIntent").asText()).isEqualTo(giftIntent);
                }
                assertThat(masked.getPrice()).isNull();
                assertThat(masked.getAmountOriginal()).isNull();
                assertThat(masked.getAmountLocal()).isNull();
                for (String field : java.util.List.of("price", "priceExact", "amountOriginal", "amountOriginalExact", "amountLocal", "amountLocalExact")) {
                    assertThat(after.hasNonNull(field)).as(field).isFalse();
                }
                assertThat(json.<com.fasterxml.jackson.databind.JsonNode>valueToTree(original)).isEqualTo(before);
            }
        }
    }

    @Test
    void purchaseReceiptMasksCommercialHeaderAndAmountSortSideChannel() throws Exception {
        // V607+ 重写后源码为 CRLF 行尾：统一行尾，多行锚点不受行尾差异影响。
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/purchase/receipt/PurchaseReceiptService.java"))
                .replace("\r\n", "\n");

        // 2026-09-25 单号列统一：价格遮蔽分支仍不放开金额排序（total 不进白名单），
        // billNo 排序不泄露商业信息故保留在两分支。
        assertThat(source)
                .contains("boolean priceMasked = priceMasker==null||!priceMasker.canViewPurchaseReceipt()")
                .contains("f.headerFilters().requireAmountVisible(!priceMasked)")
                .contains("HeaderColumnFilter.requireAmountSortVisible(sort,!priceMasked)")
                .contains("priceMasked\n                                ? Map.of(\"billDate\", \"billDate\", \"billNo\", \"billNo\")")
                .contains("mask ? null : r.getCurrencyId()")
                .contains("mask ? null : r.getExchangeRate()")
                .contains("mask ? null : r.getTaxRate()")
                .contains("mask ? null : r.getSettlementMethodId()");
    }

    @Test
    void subcontractReceiptMasksCommercialHeaderAndAmountSortSideChannel() throws Exception {
        // 与采购侧同款：统一行尾，多行锚点不受 CRLF/LF 差异影响。
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/subcontract/receipt/SubcontractReceiptService.java"))
                .replace("\r\n", "\n");

        assertThat(source)
                .contains("boolean priceMasked = priceMasker==null||!priceMasker.canViewSubcontractReceipt()")
                .contains("f.headerFilters().requireAmountVisible(!priceMasked)")
                .contains("HeaderColumnFilter.requireAmountSortVisible(sort,!priceMasked)")
                .contains("priceMasked\n                                ? Map.of(\"billDate\", \"billDate\", \"billNo\", \"billNo\")\n                                : ALLOWED_SORT")
                .contains("mask ? null : r.getCurrencyId()")
                .contains("mask ? null : r.getExchangeRate()")
                .contains("mask ? null : r.getTaxRate()")
                .contains("mask ? null : r.getSettlementMethodId()");
    }
}
