package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.order.dto.PlanProgressLine.SupplySource;
import java.math.BigDecimal;
import java.nio.file.Path;
import java.util.ArrayList;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class SalesOrderPreparationProgressTest {
    @Test void sharedPhysicalPreparationCasesPreserveQuantitiesAndSources() throws Exception {
        var fixture = new ObjectMapper().readTree(Path.of("../contracts/sales-preparation-progress/v1.json").toFile());
        for (var row : fixture.path("cases")) {
            var sources = new ArrayList<SupplySource>();
            for (var source : row.path("sources")) {
                sources.add(new SupplySource(source.path("kind").asText(), source.path("qty").decimalValue()));
            }
            var value = SalesOrderPreparationProgress.of(
                    new BigDecimal(row.path("qty").asText()), new BigDecimal(row.path("flagged").asText()),
                    new BigDecimal(row.path("shipped").asText()), new BigDecimal(row.path("returned").asText()),
                    new BigDecimal(row.path("stock").asText()), sources);
            assertThat(value.targetQty()).as(row.path("name").asText()).isEqualByComparingTo(row.path("target").asText());
            assertThat(value.preparedQty()).as(row.path("name").asText()).isEqualByComparingTo(row.path("prepared").asText());
            assertThat(value.stockQty()).isEqualByComparingTo(row.path("stock").asText());
            assertThat(value.sources()).containsExactlyElementsOf(sources);
        }
    }
}
