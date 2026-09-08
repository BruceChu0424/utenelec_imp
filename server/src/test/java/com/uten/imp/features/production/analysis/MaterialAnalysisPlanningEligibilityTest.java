package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertTimeout;

class MaterialAnalysisPlanningEligibilityTest {
    @Test
    void pendingAmendmentBlocksNewArrangementsIncludingChildAnchorsOnlyOnItsOwnBranch() {
        UUID pending = UUID.randomUUID();
        UUID child = UUID.randomUUID();
        UUID grandchild = UUID.randomUUID();
        UUID otherOrder = UUID.randomUUID();
        var pendingSource = source(pending, null, "SALES_ORDER_ITEM", false, "12");
        Map<UUID, String> blocks = MaterialAnalysisService.planningBlockedReasons(List.of(
                source(grandchild, child, "MAKE_COMPONENT", false, "10"),
                source(child, pending, "SUBCONTRACT_MAKE", false, "10"),
                pendingSource, source(otherOrder, null, "SALES_ORDER_ITEM", true, "10")));

        assertThat(blocks).containsOnlyKeys(pending, child, grandchild);
        assertThat(blocks.get(pending)).contains("等待财务确认");
        assertThat(blocks.get(grandchild)).isEqualTo(blocks.get(pending));
        // The old admitted work still owns its original ten-piece requirement.
        assertThat(pendingSource.materialRequirementQty()).isEqualByComparingTo("10");
        var view = pendingSource.toView(BigDecimal.ZERO, true,
                MaterialAnalysisService.ProductPlanState.NONE, blocks.get(pending));
        assertThat(view.canSchedule()).isFalse();
        assertThat(view.scheduleBlockedReason()).isEqualTo(blocks.get(pending));
        assertThat(view.requestedQty()).isEqualByComparingTo("10");
    }

    @Test
    void financeApprovalReopensExistingCapacityButAQuantityReductionRequiresExplicitReanalysis() {
        UUID id = UUID.randomUUID();
        assertThat(MaterialAnalysisService.planningBlockedReasons(List.of(
                source(id, null, "SALES_ORDER_ITEM", true, "12")))).isEmpty();
        var reduced = source(id, null, "SALES_ORDER_ITEM", true, "6");
        assertThat(MaterialAnalysisService.planningBlockedReasons(List.of(reduced)).get(id))
                .contains("数量已减少");
        assertThat(reduced.materialRequirementQty()).isEqualByComparingTo("10");
    }

    @Test
    void aMissingOrCyclicParentCannotTurnAChildIntoAnIndependentApprovedSource() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        UUID missing = UUID.randomUUID();
        Map<UUID, String> blocks = MaterialAnalysisService.planningBlockedReasons(List.of(
                source(first, second, "MAKE_COMPONENT", false, "10"),
                source(second, first, "MAKE_COMPONENT", false, "10"),
                source(missing, UUID.randomUUID(), "MAKE_COMPONENT", false, "10")));
        assertThat(blocks).containsOnlyKeys(first, second, missing);
        assertThat(blocks.get(first)).contains("父子关系");
        assertThat(blocks.get(missing)).contains("上层产品");
    }

    @Test
    void deepSourceInheritanceIsBoundedAndDoesNotUseTheCallStack() {
        List<MaterialAnalysisService.SourceLine> sources = new ArrayList<>();
        UUID parent = UUID.randomUUID();
        sources.add(source(parent, null, "SALES_ORDER_ITEM", false, "10"));
        for (int i = 0; i < 10_000; i++) {
            UUID id = UUID.randomUUID();
            sources.add(source(id, parent, "MAKE_COMPONENT", false, "10"));
            parent = id;
        }
        java.util.Collections.reverse(sources);
        assertTimeout(Duration.ofSeconds(2), () -> assertThat(
                MaterialAnalysisService.planningBlockedReasons(sources)).hasSize(10_001));
    }

    private static MaterialAnalysisService.SourceLine source(
            UUID id, UUID parent, String type, boolean approved, String orderQty) {
        Object[] row = new Object[47];
        row[0] = id;
        row[1] = type;
        row[8] = UUID.randomUUID();
        row[14] = UUID.randomUUID();
        row[16] = BigDecimal.ONE;
        row[17] = new BigDecimal("10");
        row[20] = new BigDecimal(orderQty);
        row[28] = (short) 1;
        row[35] = 1;
        row[41] = parent;
        row[43] = approved;
        return MaterialAnalysisService.SourceLine.from(row);
    }
}
