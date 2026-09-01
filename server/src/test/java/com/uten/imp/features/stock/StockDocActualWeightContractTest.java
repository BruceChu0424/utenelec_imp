package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class StockDocActualWeightContractTest {

    @Test
    void stockDocumentsTreatWeightAsActualLineTotalNotQuantityConversion() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source, StandardCharsets.UTF_8);

        assertThat(java)
                .contains("it.getWeight().multiply(ratio);")
                .doesNotContain("it.getWeight().multiply(ratio).multiply(rate)")
                .contains("private BigDecimal actualWeight(StockDocumentItem it)")
                .contains("return it.getWeight();")
                .doesNotContain("return it.getWeight().multiply(rate);");
    }
}
