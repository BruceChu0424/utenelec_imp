package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class AggregateMaterialSourceEligibilityTest {
    @Test void delegatedStartMemberIsNotActionableMerelyBecauseItsControlStageWasRetained() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        assertThat(project(source,List.of()).actionable()).isFalse();
    }

    @Test void activeZeroNeedSourceRetainsTheExplicitAppendEntry() {
        assertThat(project(source("ACTIVE"),List.of()).actionable()).isTrue();
        assertThat(project(source("TRANSFERRED_TO_PLAN"),List.of()).actionable()).isTrue();
    }

    @Test void outstandingOrdinaryPlanKeepsItsOwnResponsibilityButSharedAnchorDoesNotReviveOldMembers() {
        MaterialView ordinary=source("DELEGATED_TO_MAKE_CHILD");
        ProductView anchor=mock(ProductView.class);
        UUID anchorId=UUID.randomUUID();
        when(anchor.analysisLineId()).thenReturn(anchorId);
        when(anchor.sourceType()).thenReturn("MAKE_COMPONENT");
        when(anchor.remainingQty()).thenReturn(BigDecimal.TEN);
        when(ordinary.planAnchorAnalysisLineId()).thenReturn(anchorId);
        assertThat(project(ordinary,List.of(anchor)).actionable()).isTrue();

        MaterialView shared=source("DELEGATED_TO_MAKE_CHILD");
        when(shared.planAnchorAnalysisLineId()).thenReturn(anchorId);
        when(anchor.sourceType()).thenReturn("AGGREGATE_MAKE");
        assertThat(project(shared,List.of(anchor)).actionable()).isFalse();
    }

    @Test void prioritySupplementRetainsTheEntryWhenOrdinaryDemandIsZero() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        when(source.priorityMakeSupplementQty()).thenReturn(BigDecimal.TEN);
        assertThat(project(source,List.of()).actionable()).isTrue();
    }

    @Test void positiveOriginalRemainderStaysActionableWhenAllHistoricalTargetsAreRetired() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        MaterialView retired=source("INACTIVE_PARENT_COVERED");
        when(source.requiredQty()).thenReturn(BigDecimal.TEN);
        when(source.planningUncoveredQty()).thenReturn(BigDecimal.TEN);
        AggregatePreparationView projected=project(source,List.of(),List.of(retired));
        assertThat(projected.actionable()).isTrue();
        assertThat(projected.targetMaterialLineIds()).containsExactly(retired.materialLineId());
    }

    private MaterialView source(String state) {
        MaterialView source=mock(MaterialView.class,RETURNS_SELF);
        when(source.materialLineId()).thenReturn(UUID.randomUUID());
        when(source.analysisLineId()).thenReturn(UUID.randomUUID());
        when(source.nodeKey()).thenReturn("source");
        when(source.level()).thenReturn(1);
        when(source.routeConfirmed()).thenReturn(true);
        when(source.sourceConfirmed()).thenReturn("MAKE");
        when(source.controlStage()).thenReturn("START");
        when(source.requirementState()).thenReturn(state);
        when(source.downstreamReferences()).thenReturn(List.of());
        return source;
    }

    private AggregatePreparationView project(MaterialView source,List<ProductView> products) {
        return project(source,products,List.of());
    }

    private AggregatePreparationView project(MaterialView source,List<ProductView> products,List<MaterialView> targets) {
        var materials=new java.util.ArrayList<>(List.of(source));materials.addAll(targets);
        var shares=new java.util.LinkedHashMap<UUID,BigDecimal>();
        targets.forEach(target->shares.put(target.materialLineId(),BigDecimal.TEN));
        AggregateMaterialPreparationProjection.apply(materials,products,List.of(),
                Map.of(source.materialLineId(),new AggregateDelegationProjection.Delegation(BigDecimal.TEN,shares,targets.isEmpty())),
                Map.of(),new AggregateAdoptionIntentReader.Coverage(Map.of(),Map.of()),Map.of(),Map.of());
        var result=ArgumentCaptor.forClass(AggregatePreparationView.class);
        verify(source).withAggregatePreparation(result.capture());
        return result.getValue();
    }
}
