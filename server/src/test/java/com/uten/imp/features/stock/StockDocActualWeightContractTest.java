package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-135: 仓库单据的行重量是整行实称(千克), 从不乘数量换算率; 只在正向过账时作为重量证据带进库存账,
 * 红冲一律不带(库存账按原流水镜像); 领料分批出库按累计切片, 分几次都分毫不差。
 */
class StockDocActualWeightContractTest {

    @Test
    void stockDocumentsPassLineWeightAsEvidenceOnlyOnForwardPostings() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source, StandardCharsets.UTF_8);

        assertThat(java)
                .contains("CapturedWeight.measured(it.getWeight())")
                .contains("CapturedWeight.slice(it.getWeight())")
                .contains("sign > 0 ? weight : null")
                .contains(".quantitySlice(it.getWeight(), it.getQty(), issuedBefore, issueQty)")
                .doesNotContain("it.getWeight().multiply(")
                .doesNotContain("private BigDecimal actualWeight(StockDocumentItem it)");
    }
}
