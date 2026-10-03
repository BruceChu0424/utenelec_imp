package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationListItem;
import com.uten.imp.features.stock.insight.dto.HealthRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.ProductUsageRow;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class PlatformDisplayExactAmountsTest {
    private static final BigDecimal EXACT = new BigDecimal("9007199254740993.123456789012345678901234567890");
    private final ObjectMapper mapper = new ObjectMapper();

    @Test void reconciliationRetainsExactAmountsBesideTheCompatibleNumericFields() throws Exception {
        var row = new FinanceReconciliationListItem(null, null, null, null, null, null, null,
                EXACT, null, null, null, null, null, null, null);
        var json = mapper.readTree(mapper.writeValueAsString(row));
        assertThat(json.get("inAmount").isNumber()).isTrue();
        assertThat(json.get("inAmountExact").isTextual()).isTrue();
        assertThat(json.get("inAmountExact").asText()).isEqualTo(EXACT.toPlainString());
        assertThat(json.get("outAmountExact").isNull()).isTrue();
    }

    @Test void authorizedWorkshopCostsHaveExactStringsAndMaskedCostsStayNull() throws Exception {
        var row = new ProductUsageRow(null, 0, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, EXACT, EXACT, false, null, null, null, null, null);
        var json = mapper.readTree(mapper.writeValueAsString(row));
        assertThat(json.get("currentValue").isNumber()).isTrue();
        assertThat(json.get("currentValueExact").asText()).isEqualTo(EXACT.toPlainString());
        assertThat(json.get("unitMaterialCostExact").asText()).isEqualTo(EXACT.toPlainString());
        var masked = new ProductUsageRow(null, 0, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, false, null, null, null, null, null);
        var maskedJson = mapper.readTree(mapper.writeValueAsString(masked));
        assertThat(maskedJson.get("currentValueExact").isNull()).isTrue();
        assertThat(maskedJson.get("unitMaterialCostExact").isNull()).isTrue();
    }

    @Test void inventoryHealthRetainsExactCostAndNeverExposesAMaskedCompanion() throws Exception {
        var row = mapper.convertValue(Map.of("amountLocal", EXACT, "costMasked", false), HealthRow.class);
        var json = mapper.readTree(mapper.writeValueAsString(row));
        assertThat(json.get("amountLocal").isNumber()).isTrue();
        assertThat(json.get("amountLocalExact").isTextual()).isTrue();
        assertThat(json.get("amountLocalExact").asText()).isEqualTo(EXACT.toPlainString());
        var masked = mapper.convertValue(Map.of("amountLocal", EXACT, "costMasked", true), HealthRow.class);
        assertThat(mapper.readTree(mapper.writeValueAsString(masked)).get("amountLocalExact").isNull()).isTrue();
        var unknown = mapper.convertValue(Map.of("costMasked", false), HealthRow.class);
        assertThat(mapper.readTree(mapper.writeValueAsString(unknown)).get("amountLocalExact").isNull()).isTrue();
    }
}
