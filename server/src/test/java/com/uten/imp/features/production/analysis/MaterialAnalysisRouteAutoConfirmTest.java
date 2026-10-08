package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.DownstreamReference;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.SupplyActionView;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** 「按货品档案自动确认供应方式」唯一判据 (ADR-102) 的逐条口径. */
class MaterialAnalysisRouteAutoConfirmTest {
    private static final UUID ITEM = UUID.randomUUID();
    private static final MaterialAnalysisRouteAutoConfirm.Facts NO_FACTS =
            new MaterialAnalysisRouteAutoConfirm.Facts(Set.of(), Set.of(), Map.of(), Set.of(), Set.of());

    @Test
    void decisiveSuggestionsAreConfirmedPerActionGroupAndReviewIsLeftForHumans() {
        var buy = row(1, "a", "10", "BUY", null);
        var make = row(1, "b", "10", "MAKE", null);
        var subcontract = row(2, "c", "5", "SUBCONTRACT", null);
        var review = row(1, "d", "10", "REVIEW", null);
        var root = row(0, "ROOT_SUPPLY", "0", "MAKE", null);

        var plan = MaterialAnalysisRouteAutoConfirm.plan(List.of(buy, make, subcontract, review, root), Map.of(), NO_FACTS);

        assertThat(plan.groupCount()).isEqualTo(4);
        assertThat(plan.changes()).extracting(MaterialAnalysisRouteBatchWriter.Change::materialId)
                .containsExactlyInAnyOrder(buy.id(), make.id(), subcontract.id(), root.id());
        assertThat(plan.changes()).allSatisfy(change -> assertThat(change.reason()).isNull());
        assertThat(plan.changes()).filteredOn(change -> change.materialId().equals(subcontract.id()))
                .extracting(MaterialAnalysisRouteBatchWriter.Change::route).containsExactly("SUBCONTRACT");
    }

    @Test
    void confirmedCoveredBlockedAndDownstreamRowsAreNeverTouched() {
        var confirmed = row(1, "a", "10", "BUY", "MAKE");
        var covered = row(1, "b", "0", "BUY", null);
        var blocked = row(1, "c", "10", "BUY", null, UUID.randomUUID());
        var withTask = row(1, "d", "10", "BUY", null);
        var liveGroup = row(1, "e", "10", "BUY", null);
        var issued = row(1, "f", "10", "MAKE", null);
        UUID anchor = UUID.randomUUID();
        var facts = new MaterialAnalysisRouteAutoConfirm.Facts(Set.of(), Set.of(anchor), Map.of(issued.id(), anchor),
                Set.of(withTask.id()), Set.of(liveGroup.actionGroupKey()));

        var plan = MaterialAnalysisRouteAutoConfirm.plan(List.of(confirmed, covered, blocked, withTask, liveGroup, issued),
                Map.of(blocked.analysisItemId(), "销售订单已停止"), facts);

        assertThat(plan.changes()).isEmpty();
        assertThat(plan.groupCount()).isZero();
    }

    @Test
    void historicalRootPlanProvesMakeAndIssuedRootIsLeftAlone() {
        var root = row(0, "ROOT_SUPPLY", "0", "BUY", null);
        var withPlan = new MaterialAnalysisRouteAutoConfirm.Facts(Set.of(ITEM), Set.of(), Map.of(), Set.of(), Set.of());
        assertThat(MaterialAnalysisRouteAutoConfirm.plan(List.of(root), Map.of(), withPlan).changes())
                .extracting(MaterialAnalysisRouteBatchWriter.Change::route).containsExactly("MAKE");

        var issued = new MaterialAnalysisRouteAutoConfirm.Facts(Set.of(ITEM), Set.of(ITEM), Map.of(), Set.of(), Set.of());
        assertThat(MaterialAnalysisRouteAutoConfirm.plan(List.of(root), Map.of(), issued).changes()).isEmpty();
    }

    @Test
    void factsIgnoreCancelledActionsAndReversedRootHandOvers() {
        var row = row(1, "a", "10", "BUY", null);
        var cancelled = new DownstreamReference(UUID.randomUUID(), "BUY", "CANCELLED", "PURCHASE_REQUEST",
                UUID.randomUUID(), "QG-1", BigDecimal.TEN);
        var reversed = new DownstreamReference(UUID.randomUUID(), "MAKE", "REVERSED", "ROOT_OUTPUT_FULFILLMENT",
                UUID.randomUUID(), "ROOT-1", BigDecimal.TEN);
        var facts = MaterialAnalysisRouteAutoConfirm.facts(List.of(), Map.of(), Map.of(),
                Map.of(row.id(), List.of(cancelled, reversed)),
                List.of(action(row.actionGroupKey(), "CANCELLED")));

        assertThat(facts.materialsWithLiveDownstream()).isEmpty();
        assertThat(facts.groupKeysWithLiveAction()).isEmpty();
        assertThat(MaterialAnalysisRouteAutoConfirm.plan(List.of(row), Map.of(), facts).changes()).hasSize(1);

        var open = MaterialAnalysisRouteAutoConfirm.facts(List.of(), Map.of(), Map.of(),
                Map.of(row.id(), List.of(new DownstreamReference(UUID.randomUUID(), "BUY", "OPEN", "PURCHASE_REQUEST",
                        UUID.randomUUID(), "QG-2", BigDecimal.TEN))),
                List.of(action(row.actionGroupKey(), "OPEN")));
        assertThat(open.materialsWithLiveDownstream()).containsExactly(row.id());
        assertThat(open.groupKeysWithLiveAction()).containsExactly(row.actionGroupKey());
        assertThat(MaterialAnalysisRouteAutoConfirm.plan(List.of(row), Map.of(), open).changes()).isEmpty();
    }

    @Test
    void minimumValidIssuedQuantityStillLocksTheRoute() {
        assertThat(MaterialAnalysisRouteAutoConfirm.issued(new BigDecimal("0.0001"))).isTrue();
        assertThat(MaterialAnalysisRouteAutoConfirm.issued(new BigDecimal("0.0002"))).isTrue();
        assertThat(MaterialAnalysisRouteAutoConfirm.issued(BigDecimal.ZERO)).isFalse();
        assertThat(MaterialAnalysisRouteAutoConfirm.issued(new BigDecimal("-0.0001"))).isFalse();
        assertThat(MaterialAnalysisRouteAutoConfirm.issued(null)).isFalse();
    }

    private static MaterialAnalysisService.MaterialRow row(int depth, String nodeKey, String shortage,
            String suggestion, String confirmed) {
        return row(depth, nodeKey, shortage, suggestion, confirmed, ITEM);
    }

    private static MaterialAnalysisService.MaterialRow row(int depth, String nodeKey, String shortage,
            String suggestion, String confirmed, UUID item) {
        BigDecimal one = BigDecimal.ONE;
        return new MaterialAnalysisService.MaterialRow(
                UUID.randomUUID(), item, nodeKey, UUID.randomUUID(), "G-" + nodeKey, nodeKey, null,
                null, null, UUID.randomUUID(), "piece", depth, "[\"" + nodeKey + "\"]",
                depth == 0 ? null : "parent", null, "START", "PER_UNIT", one, true, true, one, one, one,
                MaterialAnalysisService.BomUsage.design(one),
                new BigDecimal("10"), BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, new BigDecimal(shortage), null, suggestion, confirmed, null, false,
                null, null, null, null, null, null);
    }

    private static SupplyActionView action(String groupKey, String status) {
        return new SupplyActionView(UUID.randomUUID(), groupKey, 1, null, "BUY", status, UUID.randomUUID(), null,
                UUID.randomUUID(), BigDecimal.TEN, BigDecimal.ZERO, BigDecimal.TEN, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, null, "PURCHASE_REQUEST", UUID.randomUUID(), "QG-3", BigDecimal.ZERO, null,
                "SUPPLY", null);
    }
}
