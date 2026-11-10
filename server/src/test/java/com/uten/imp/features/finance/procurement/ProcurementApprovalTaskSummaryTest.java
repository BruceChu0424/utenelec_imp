package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProcurementApprovalTaskSummaryTest {
    private final ObjectMapper mapper = new ObjectMapper();
    private static final UUID PIECE = UUID.fromString("00000000-0000-0000-0000-000000000001");
    private static final UUID KG = UUID.fromString("00000000-0000-0000-0000-000000000002");

    @Test
    void exactQuantitiesKeepUnitsAndAllSubmittedPricesWithoutInventingAnAverage() throws Exception {
        var summaries = ProcurementApprovalTaskSummary.fromSnapshotItems("""
                [{"unitId":"%1$s","unitName":"个","quantity":"9007199254740993.1234","price":"0.01234567"},
                 {"unitId":"%1$s","unitName":"个","quantity":"0.0006","price":"0.012345670"},
                 {"unitId":"%1$s","unitName":"个","quantity":"2","price":"0"},
                 {"unitId":"%2$s","unitName":"公斤","quantity":"3.14159","price":"12.000001"}]
                """.formatted(PIECE, KG), mapper);
        assertThat(summaries).hasSize(2);
        assertThat(summaries.getFirst().quantity()).isEqualByComparingTo("9007199254740995.124");
        assertThat(summaries.getFirst().unitPrices()).hasSize(2);
        assertThat(summaries.getFirst().unitPrices().getFirst()).isZero();
        assertThat(summaries.getFirst().unitPrices().getLast()).isEqualByComparingTo("0.01234567");
        assertThat(summaries.getLast().quantity()).isEqualByComparingTo("3.14159");
        var json = mapper.readTree(mapper.writeValueAsString(summaries));
        assertThat(json.get(0).get("quantity").asText()).isEqualTo("9007199254740995.124");
        assertThat(json.get(0).get("quantity").isTextual()).isTrue();
        assertThat(json.get(0).get("unitPrices").get(1).isTextual()).isTrue();
    }

    @Test
    void missingQuantitiesPricesAndUnknownUnitIdentitiesDoNotBecomeZeroOrPartialTotals() {
        var summaries = ProcurementApprovalTaskSummary.fromSnapshotItems("""
                [{"unitId":"%1$s","unitName":"个","quantity":"10","price":"1"},
                 {"unitId":"%1$s","unitName":"个","quantity":null,"price":null},
                 {"unitName":null,"quantity":"2","price":"3"},
                 {"unitName":null,"quantity":"4","price":"5"}]
                """.formatted(PIECE), mapper);
        assertThat(summaries).hasSize(3);
        assertThat(summaries.getFirst().quantity()).isNull();
        assertThat(summaries.getFirst().missingPrice()).isTrue();
        assertThat(summaries.get(1).quantity()).isEqualByComparingTo("2");
        assertThat(summaries.get(2).quantity()).isEqualByComparingTo("4");
        assertThat(ProcurementApprovalTaskSummary.fromSnapshotItems(null, mapper)).isEmpty();
        assertThat(ProcurementApprovalTaskSummary.fromSnapshotItems("null", mapper)).isEmpty();
    }

    @Test
    void malformedCommercialFactsFailInsteadOfPublishingACompleteLookingSummary() {
        assertThatThrownBy(() -> ProcurementApprovalTaskSummary.fromSnapshotItems(
                "[{\"quantity\":\"invalid\"}]", mapper)).isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> ProcurementApprovalTaskSummary.fromSnapshotItems(
                "{}", mapper)).isInstanceOf(IllegalStateException.class);
    }
}
