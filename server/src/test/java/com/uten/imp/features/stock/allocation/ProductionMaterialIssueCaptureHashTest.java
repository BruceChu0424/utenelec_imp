package com.uten.imp.features.stock.allocation;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

/**
 * ADR-135: 领料出库的台账请求哈希带上称重部分(逐行实称千克与「按称重推算」标记)。没有称重信息时哈希与原口径
 * 完全一致(已落库的幂等键照常重放); 同一幂等键换了重量重试会被判成不同请求。
 */
class ProductionMaterialIssueCaptureHashTest {

    private static final List<ProductionMaterialStockLedgerService.MaterialLine> LINES = List.of(
            new ProductionMaterialStockLedgerService.MaterialLine(
                    new UUID(0, 1), new UUID(0, 2), new UUID(0, 3), null, new UUID(0, 4), null,
                    new BigDecimal("12.5")));

    @Test
    void weightlessIssueKeepsTheExistingHash() throws Exception {
        String canonical = new UUID(0, 2) + "|" + new UUID(0, 3) + "|null|" + new UUID(0, 4) + "|null|12.5\n";
        String expected = java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
                .digest(canonical.getBytes(java.nio.charset.StandardCharsets.UTF_8)));

        assertEquals(expected, ProductionMaterialStockLedgerService.issueHash(LINES, null));
        assertEquals(expected, ProductionMaterialStockLedgerService.issueHash(LINES, ""));
    }

    @Test
    void captureFingerprintChangesTheIssueHash() {
        String legacy = ProductionMaterialStockLedgerService.issueHash(LINES, null);
        String weighed = ProductionMaterialStockLedgerService.issueHash(LINES, "ISSUE-CAPTURE-V1\nitem|1.5|false");
        String reweighed = ProductionMaterialStockLedgerService.issueHash(LINES, "ISSUE-CAPTURE-V1\nitem|1.6|false");

        assertNotEquals(legacy, weighed);
        assertNotEquals(weighed, reweighed);
        assertEquals(weighed,
                ProductionMaterialStockLedgerService.issueHash(LINES, "ISSUE-CAPTURE-V1\nitem|1.5|false"));
    }
}
