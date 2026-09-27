package com.uten.imp.features.purchase.receipt;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ReceiptCommercialMaskContractTest {

    @Test
    void purchaseReceiptMasksCommercialHeaderAndAmountSortSideChannel() throws Exception {
        // V607+ 重写后源码为 CRLF 行尾：统一行尾，多行锚点不受行尾差异影响。
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/purchase/receipt/PurchaseReceiptService.java"))
                .replace("\r\n", "\n");

        // 2026-09-25 单号列统一：价格遮蔽分支仍不放开金额排序（total 不进白名单），
        // billNo 排序不泄露商业信息故保留在两分支。
        assertThat(source)
                .contains("boolean priceMasked = !priceMasker.canViewPurchaseReceipt()")
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
                .contains("boolean priceMasked = !priceMasker.canViewSubcontractReceipt()")
                .contains("priceMasked\n                                ? Map.of(\"billDate\", \"billDate\", \"billNo\", \"billNo\")\n                                : ALLOWED_SORT")
                .contains("mask ? null : r.getCurrencyId()")
                .contains("mask ? null : r.getExchangeRate()")
                .contains("mask ? null : r.getTaxRate()")
                .contains("mask ? null : r.getSettlementMethodId()");
    }
}
