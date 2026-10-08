package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
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

    @ParameterizedTest
    @CsvSource({"MAKE,CREATED", "MAKE,IN_PROGRESS", "MAKE,DONE", "BUY,OPEN", "BUY,DONE", "SUBCONTRACT,CREATED"})
    void issuedSharedSourceKeepsAppendContextWithoutInventingPrivateDemand(String route,String status) {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        when(source.sourceConfirmed()).thenReturn(route);
        SupplyActionView action=issued(source,route,status,"AGGREGATE_SUPPLY","300","100");
        var result=project(source,List.of(),List.of(),List.of(action));
        assertThat(result.actionable()).isTrue();
        assertThat(result.planningUncoveredQty()).isZero();
        assertThat(result.netShortageQty()).isZero();
        assertThat(result.totalOrderedQty()).isEqualByComparingTo("400");
        assertThat(AggregateMaterialSourceEligibility.hasResponsibility(source,Map.of())).isFalse();
    }

    @Test void purePublicIntentKeepsZeroAllocationSourceNavigable() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        SupplyActionView action=issued(source,"MAKE","CREATED","AGGREGATE_SUPPLY","0","100");
        var result=project(source,List.of(),List.of(),List.of(action));
        assertThat(result.actionable()).isTrue();
        assertThat(result.allocatedOrderedQty()).isZero();
        assertThat(result.totalOrderedQty()).isEqualByComparingTo("100");
        assertThat(source.downstreamReferences()).singleElement().satisfies(ref->assertThat(ref.allocatedQty()).isZero());
    }

    @Test void safetyOnlyPurchaseKeepsZeroAllocationOrderIdentityAndDoesNotBecomePrivateDemand() {
        MaterialView source=source("INACTIVE_PARENT_COVERED");
        when(source.sourceConfirmed()).thenReturn("BUY");
        SupplyActionView action=issued(source,"BUY","OPEN","AGGREGATE_SUPPLY","0","0");
        when(action.safetyReplenishmentQty()).thenReturn(new BigDecimal("6"));
        var result=project(source,List.of(),List.of(),List.of(action));
        assertThat(result.actionable()).isTrue();
        assertThat(result.allocatedOrderedQty()).isZero();
        assertThat(result.totalOrderedQty()).isEqualByComparingTo("6");
        assertThat(result.planningUncoveredQty()).isZero();
    }

    @Test void canonicalIssuedTargetKeepsOriginalAppendableAndPreservesOnlyExactTargets() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        MaterialView target=source("DELEGATED_TO_MAKE_CHILD");
        MaterialView retired=source("INACTIVE_PARENT_COVERED");
        SupplyActionView action=issued(target,"MAKE","CREATED","AGGREGATE_SUPPLY","300","100");
        var result=project(source,List.of(),List.of(target,retired),List.of(action));
        assertThat(result.actionable()).isTrue();
        assertThat(result.targetMaterialLineIds()).containsExactlyInAnyOrder(target.materialLineId(),retired.materialLineId());
        assertThat(result.totalOrderedQty()).isEqualByComparingTo("400");
        assertThat(result.planningUncoveredQty()).isZero();
        assertThat(source.downstreamReferences()).isEmpty();
    }

    @Test void originalIssuedSupplyRemainsAnAppendContextWhenItsAliasesHaveRetired() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        MaterialView retired=source("INACTIVE_PARENT_COVERED");
        SupplyActionView action=issued(source,"MAKE","CREATED","AGGREGATE_SUPPLY","300","100");
        var result=project(source,List.of(),List.of(retired),List.of(action));
        assertThat(result.actionable()).isTrue();
        assertThat(result.totalOrderedQty()).isEqualByComparingTo("400");
    }

    @ParameterizedTest
    @CsvSource({"CANCELLED,AGGREGATE_SUPPLY", "CREATED,FUTURE_TRANSFER", "CREATED,SHARED_FUTURE_CLAIM",
            "DONE,ROOT_OUTPUT", "CREATED,AGGREGATE_CONTINUATION"})
    void cancelledOrAdoptedSupplyDoesNotCreateIndependentOrderAuthority(String status,String operation) {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        SupplyActionView action=issued(source,"MAKE",status,operation,"300","100");
        assertThat(project(source,List.of(),List.of(),List.of(action)).actionable()).isFalse();
    }

    @Test void cancelledReferenceWrongRouteMissingProofAndZeroOrdersCannotReviveSource() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        SupplyActionView action=issued(source,"BUY","CREATED","AGGREGATE_SUPPLY","300","100");
        assertThat(AggregateMaterialSourceEligibility.hasOrderingContext(source,Map.of(),Map.of(action.actionId(),action))).isFalse();
        when(source.sourceConfirmed()).thenReturn("BUY");
        assertThat(AggregateMaterialSourceEligibility.hasOrderingContext(source,Map.of(),Map.of())).isFalse();
        when(action.requestedQty()).thenReturn(BigDecimal.ZERO);
        when(action.publicSurplusQty()).thenReturn(BigDecimal.ZERO);
        assertThat(AggregateMaterialSourceEligibility.hasOrderingContext(source,Map.of(),Map.of(action.actionId(),action))).isFalse();
        when(action.requestedQty()).thenReturn(BigDecimal.TEN);
        doReturn(List.of(new DownstreamReference(action.actionId(),"BUY","CANCELLED",null,null,null,BigDecimal.TEN))).when(source).downstreamReferences();
        assertThat(AggregateMaterialSourceEligibility.hasOrderingContext(source,Map.of(),Map.of(action.actionId(),action))).isFalse();
    }

    @Test void ordinaryIssuedMakeAnchorCanAppendWhileUnissuedSharedAnchorCannotImpersonateAnOrder() {
        MaterialView source=source("DELEGATED_TO_MAKE_CHILD");
        ProductView anchor=mock(ProductView.class);
        UUID anchorId=UUID.randomUUID();
        when(anchor.analysisLineId()).thenReturn(anchorId);
        when(anchor.sourceType()).thenReturn("MAKE_COMPONENT");
        when(anchor.issuedPlanQty()).thenReturn(BigDecimal.TEN);
        when(source.planAnchorAnalysisLineId()).thenReturn(anchorId);
        assertThat(AggregateMaterialSourceEligibility.hasOrderingContext(source,Map.of(anchorId,anchor),Map.of())).isTrue();
        when(anchor.sourceType()).thenReturn("AGGREGATE_MAKE");
        assertThat(AggregateMaterialSourceEligibility.hasOrderingContext(source,Map.of(anchorId,anchor),Map.of())).isFalse();
    }

    private SupplyActionView issued(MaterialView source,String route,String status,String operation,String privateQty,String publicQty) {
        SupplyActionView action=mock(SupplyActionView.class);
        when(action.actionId()).thenReturn(UUID.randomUUID());
        when(action.route()).thenReturn(route);
        when(action.status()).thenReturn(status);
        when(action.operationType()).thenReturn(operation);
        when(action.requestedQty()).thenReturn(new BigDecimal(privateQty));
        when(action.publicSurplusQty()).thenReturn(new BigDecimal(publicQty));
        doReturn(List.of(new DownstreamReference(action.actionId(),route,status,
                "PRODUCTION_PLAN",UUID.randomUUID(),"PLAN-1",new BigDecimal(privateQty)))).when(source).downstreamReferences();
        return action;
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
        return project(source,products,targets,List.of());
    }

    private AggregatePreparationView project(MaterialView source,List<ProductView> products,List<MaterialView> targets,List<SupplyActionView> actions) {
        var materials=new java.util.ArrayList<>(List.of(source));materials.addAll(targets);
        var shares=new java.util.LinkedHashMap<UUID,BigDecimal>();
        targets.forEach(target->shares.put(target.materialLineId(),BigDecimal.TEN));
        AggregateMaterialPreparationProjection.apply(materials,products,actions,
                Map.of(source.materialLineId(),new AggregateDelegationProjection.Delegation(BigDecimal.TEN,shares,targets.isEmpty())),
                Map.of(),new AggregateAdoptionIntentReader.Coverage(Map.of(),Map.of()),Map.of(),Map.of());
        var result=ArgumentCaptor.forClass(AggregatePreparationView.class);
        verify(source).withAggregatePreparation(result.capture());
        return result.getValue();
    }
}
