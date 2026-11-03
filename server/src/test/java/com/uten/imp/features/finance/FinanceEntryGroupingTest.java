package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.JsonNode;
import java.nio.file.Path;
import java.util.ArrayList;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class FinanceEntryGroupingTest {
    private final ObjectMapper json = new ObjectMapper();

    @Test
    void sharedClientServerContract() throws Exception {
        JsonNode contract = json.readTree(Path.of("../contracts/finance-entry-grouping-v1.json").toFile());
        for (JsonNode scenario : contract.path("cases")) {
            var entries = new ArrayList<JsonNode>();
            scenario.path("entries").forEach(entries::add);
            var groups = FinanceEntryGrouping.group(entries, "test-command");
            assertThat(groups).as(scenario.path("name").asText()).hasSize(scenario.path("groups").asInt());
            for (int i = 0; i < groups.size(); i++) {
                assertThat(groups.get(i).path("items").size()).isEqualTo(scenario.path("lineCounts").get(i).asInt());
                if (scenario.has("accountAmounts")) {
                    assertThat(groups.get(i).path("accountAmount").asText()).isEqualTo(scenario.path("accountAmounts").get(i).asText());
                }
            }
            assertThat((JsonNode) json.valueToTree(entries)).isEqualTo(scenario.path("entries"));
        }
    }

    @Test
    void fiveHundredRowsBecomeOneDocumentWithoutDroppingLines() throws Exception {
        var entries = new ArrayList<JsonNode>();
        for (int i = 0; i < 500; i++) entries.add(json.readTree("{\"accountId\":\"same\",\"items\":[{\"amountOriginal\":\"0.01\"}]}"));
        assertThat(FinanceEntryGrouping.group(entries, "pressure-command").getFirst().path("items")).hasSize(500);
    }
}
