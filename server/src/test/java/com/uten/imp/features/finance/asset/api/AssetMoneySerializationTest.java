package com.uten.imp.features.finance.asset.api;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class AssetMoneySerializationTest {

    private final ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();

    @Test
    void workbenchAmountsSerializeAsExactJsonStrings() throws Exception {
        var response = new AssetWorkbenchResponses.Overview(
                new BigDecimal("99999999999999.9999"),
                new BigDecimal("12345678901234.5678"),
                new BigDecimal("0.0001"),
                0, 0, 0, "2026-08", true, List.of(), false,
                List.of("Posted workflows are disabled"));

        var json = objectMapper.readTree(objectMapper.writeValueAsString(response));

        assertThat(json.get("originalValue").isTextual()).isTrue();
        assertThat(json.get("originalValue").textValue()).isEqualTo("99999999999999.9999");
        assertThat(json.get("netBookValue").textValue()).isEqualTo("12345678901234.5678");
        assertThat(json.get("deferredBalance").textValue()).isEqualTo("0.0001");
    }

    @Test
    void categoryRatesSerializeAsExactJsonStrings() throws Exception {
        var response = new AssetCategoryContracts.Category(
                null, "FIXED_ASSET", "MACHINE", "Machine", 1, "ACTIVE",
                LocalDate.of(2026, 8, 1), "STRAIGHT_LINE", 60,
                new BigDecimal("0.123456"), null, null, null, null,
                List.of(), true, List.of(), 0);

        var json = objectMapper.readTree(objectMapper.writeValueAsString(response));

        assertThat(json.get("defaultResidualRate").isTextual()).isTrue();
        assertThat(json.get("defaultResidualRate").textValue()).isEqualTo("0.123456");
    }
}
