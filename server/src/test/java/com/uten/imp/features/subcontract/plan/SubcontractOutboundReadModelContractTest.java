package com.uten.imp.features.subcontract.plan;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.MaterialPlanLine;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundPlanLine;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskListItem;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractOutboundReadModelContractTest {

    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    @Test
    void warehouseTaskExposesPreparationCountsAndExecutableQuantity() {
        OutboundTaskListItem task = new OutboundTaskListItem(
                UUID.randomUUID(), UUID.randomUUID(), "WW-001", "委外商",
                LocalDate.of(2026, 8, 30), 4,
                new BigDecimal("40"), new BigDecimal("5"),
                new BigDecimal("35"), UUID.randomUUID(), "EC-001",
                new BigDecimal("12"), 2, 1, 1);

        JsonNode json = mapper.valueToTree(task);

        assertThat(json.get("readyOutboundQty").decimalValue())
                .isEqualByComparingTo("12");
        assertThat(json.get("readyLineCount").intValue()).isEqualTo(2);
        assertThat(json.get("waitingPreparationCount").intValue()).isEqualTo(1);
        assertThat(json.get("blockedLineCount").intValue()).isEqualTo(1);
    }

    @Test
    void warehouseLineUsesExplicitServerSnapshotsAndDraftReservedWireName() {
        List<String> mutableActions = new ArrayList<>(List.of("HANDLE_OUTBOUND"));
        OutboundPlanLine line = new OutboundPlanLine(
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), null,
                "PARENT", "父件", UUID.randomUUID(), "TARGET", "目标件", "A-01",
                null, null, UUID.randomUUID(), "件",
                BigDecimal.ONE, BigDecimal.ONE,
                new BigDecimal("20"), new BigDecimal("4"), new BigDecimal("3"),
                "MAKE_THEN_OUTBOUND", "READY_OUTBOUND", new BigDecimal("20"),
                new BigDecimal("13"), new BigDecimal("16"),
                UUID.randomUUID(), UUID.randomUUID(), null, mutableActions);
        mutableActions.clear();

        JsonNode json = mapper.valueToTree(line);

        assertThat(json.has("draftReservedQty")).isTrue();
        assertThat(json.has("draftQty")).isFalse();
        assertThat(json.get("draftReservedQty").decimalValue())
                .isEqualByComparingTo("3");
        assertThat(json.get("readyOutboundQty").decimalValue())
                .isEqualByComparingTo("13");
        assertThat(json.get("remainingQty").decimalValue())
                .isEqualByComparingTo("16");
        assertThat(line.allowedActions()).containsExactly("HANDLE_OUTBOUND");
    }

    @Test
    void orderProgressLineUsesTheSameQuantityAndActionContract() {
        MaterialPlanLine line = new MaterialPlanLine(
                UUID.randomUUID(), "PARENT", "父件", "TARGET", "目标件",
                null, "件", BigDecimal.ONE,
                new BigDecimal("20"), new BigDecimal("4"), new BigDecimal("3"),
                "MAKE_THEN_OUTBOUND", "WAITING_FQC", new BigDecimal("12"),
                BigDecimal.ZERO, new BigDecimal("16"),
                UUID.randomUUID(), UUID.randomUUID(), "等待品质检验",
                List.of("OPEN_ANALYSIS"));

        JsonNode json = mapper.valueToTree(line);

        assertThat(json.has("draftReservedQty")).isTrue();
        assertThat(json.has("draftQty")).isFalse();
        assertThat(json.get("readyOutboundQty").decimalValue())
                .isEqualByComparingTo("0");
        assertThat(json.get("remainingQty").decimalValue())
                .isEqualByComparingTo("16");
        assertThat(json.get("allowedActions").get(0).textValue())
                .isEqualTo("OPEN_ANALYSIS");
        assertThat(Arrays.stream(MaterialPlanLine.class.getRecordComponents())
                .map(component -> component.getName()))
                .containsSubsequence(
                        "preparedQty", "readyOutboundQty", "remainingQty",
                        "preparationAnalysisId", "preparationAnalysisItemId",
                        "blocker", "allowedActions");
    }
}
