package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.platformcolumns.PlatformColumnLineInput;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MaterialIssueDraftRowsTest {

    @Test
    void planRowsKeepTheirIdentityAcrossReorderAndRepeatedQuantityWeightEdits() {
        UUID issue = UUID.randomUUID();
        SubcontractMaterialIssueItem first = existing(issue, UUID.randomUUID());
        SubcontractMaterialIssueItem second = existing(issue, UUID.randomUUID());
        Instant created = Instant.parse("2026-09-30T10:00:00Z");
        first.setCreatedAt(created);
        first.setWeight(new BigDecimal("20"));
        MaterialIssueItemLine firstInput = planLine(first.getPlanItemId());
        firstInput.setQty(new BigDecimal("500"));
        firstInput.setWeight(new BigDecimal("10"));
        MaterialIssueItemLine secondInput = planLine(second.getPlanItemId());

        var reordered = MaterialIssueDraftRows.reconcile(issue, List.of(first, second),
                List.of(secondInput, firstInput));
        var savedAgain = MaterialIssueDraftRows.reconcile(issue, reordered.targets(),
                List.of(firstInput, secondInput));

        assertThat(reordered.targets()).containsExactly(second, first);
        assertThat(savedAgain.targets()).containsExactly(first, second);
        assertThat(savedAgain.targets().getFirst()).isSameAs(first);
        assertThat(first.getCreatedAt()).isEqualTo(created);
        assertThat(reordered.removed()).isEmpty();
        assertThat(savedAgain.removed()).isEmpty();
    }

    @Test
    void onlyOmittedRowsAreRemovedAndExplicitManualIdsArePreserved() {
        UUID issue = UUID.randomUUID();
        SubcontractMaterialIssueItem retained = existing(issue, null);
        SubcontractMaterialIssueItem removed = existing(issue, null);
        MaterialIssueItemLine retainedInput = new MaterialIssueItemLine();
        retainedInput.setId(retained.getId());
        MaterialIssueItemLine newInput = new MaterialIssueItemLine();

        var result = MaterialIssueDraftRows.reconcile(issue, List.of(retained, removed),
                List.of(newInput, retainedInput));

        assertThat(result.targets().get(1)).isSameAs(retained);
        assertThat(result.targets().getFirst().getId()).isNotIn(retained.getId(), removed.getId());
        assertThat(result.removed()).containsExactly(removed);
    }

    @Test
    void existingPlatformSourceIdentityCanPreserveAManualRow() {
        UUID issue = UUID.randomUUID();
        SubcontractMaterialIssueItem item = existing(issue, null);
        MaterialIssueItemLine input = new MaterialIssueItemLine();
        input.setPlatformFields(new PlatformColumnLineInput.Fields(item.getId(), 1, List.of()));

        var result = MaterialIssueDraftRows.reconcile(issue, List.of(item), List.of(input));

        assertThat(result.targets()).containsExactly(item);
        assertThat(result.removed()).isEmpty();
    }

    @Test
    void rejectsForeignStaleDuplicateAndChangedSourceIdentities() {
        UUID issue = UUID.randomUUID();
        SubcontractMaterialIssueItem item = existing(issue, UUID.randomUUID());
        MaterialIssueItemLine stale = planLine(item.getPlanItemId());
        stale.setId(UUID.randomUUID());
        MaterialIssueItemLine changedPlan = planLine(UUID.randomUUID());
        changedPlan.setId(item.getId());
        MaterialIssueItemLine removedPlan = new MaterialIssueItemLine();
        removedPlan.setId(item.getId());
        MaterialIssueItemLine changedExtension = planLine(item.getPlanItemId());
        changedExtension.setId(item.getId());
        changedExtension.setPlatformFields(new PlatformColumnLineInput.Fields(UUID.randomUUID(), 1, List.of()));
        for (MaterialIssueItemLine invalid : List.of(stale, changedPlan, removedPlan, changedExtension)) {
            assertConflict(issue, List.of(item), List.of(invalid));
        }
        MaterialIssueItemLine same = planLine(item.getPlanItemId());
        assertConflict(issue, List.of(item), List.of(same, same));
        assertConflict(UUID.randomUUID(), List.of(item), List.of(same));
    }

    private static void assertConflict(UUID issue, List<SubcontractMaterialIssueItem> existing,
                                       List<MaterialIssueItemLine> requested) {
        assertThatThrownBy(() -> MaterialIssueDraftRows.reconcile(issue, existing, requested))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
    }

    private static SubcontractMaterialIssueItem existing(UUID issue, UUID plan) {
        SubcontractMaterialIssueItem item = new SubcontractMaterialIssueItem();
        item.setIssueId(issue);
        item.setPlanItemId(plan);
        item.setQty(new BigDecimal("1000"));
        return item;
    }

    private static MaterialIssueItemLine planLine(UUID plan) {
        MaterialIssueItemLine line = new MaterialIssueItemLine();
        line.setPlanItemId(plan);
        line.setQty(new BigDecimal("1000"));
        return line;
    }
}
