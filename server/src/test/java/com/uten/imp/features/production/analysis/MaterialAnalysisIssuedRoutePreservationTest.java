package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialAnalysisIssuedRoutePreservationTest {
    private static final UUID GOODS=UUID.randomUUID(),UNIT=UUID.randomUUID();
    private static MaterialAnalysisIssuedRoutePreservation.Identity row(){
        return new MaterialAnalysisIssuedRoutePreservation.Identity(UUID.randomUUID(),UUID.randomUUID(),"node",GOODS,null,UNIT,null);
    }
    @Test void exactIssuedTargetPinsEveryOriginalWithoutUsingNamesOrSiblingOrder(){
        var original=row();var canonical=row();var unrelated=row();
        var projected=MaterialAnalysisIssuedRoutePreservation.project(List.of(original,canonical,unrelated),
                Map.of(original.key(),original,canonical.key(),canonical,unrelated.key(),unrelated),
                proof(Map.of(canonical.id(),Set.of("BUY"))),Map.of(original.id(),new AggregateDelegationProjection.Delegation(BigDecimal.ZERO,Map.of(canonical.id(),BigDecimal.ZERO),false)));
        assertThat(projected).containsEntry(original.key(),"BUY").containsEntry(canonical.key(),"BUY").doesNotContainKey(unrelated.key());
    }
    @Test void unissuedAliasDoesNotFreezeTheMasterRoute(){
        var original=row();var canonical=row();
        assertThat(MaterialAnalysisIssuedRoutePreservation.project(List.of(original,canonical),Map.of(original.key(),original,canonical.key(),canonical),
                proof(Map.of()),Map.of(original.id(),new AggregateDelegationProjection.Delegation(BigDecimal.TEN,Map.of(canonical.id(),BigDecimal.TEN),false)))).isEmpty();
    }
    @Test void mixedIssuedRoutesRejectInsteadOfChoosingTheFirstTarget(){
        var original=row();var first=row();var second=row();
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.project(List.of(original,first,second),Map.of(original.key(),original,first.key(),first,second.key(),second),
                proof(Map.of(first.id(),Set.of("BUY"),second.id(),Set.of("MAKE"))),Map.of(original.id(),new AggregateDelegationProjection.Delegation(BigDecimal.TEN,
                        Map.of(first.id(),BigDecimal.ONE,second.id(),BigDecimal.ONE),false)))).isInstanceOf(ApiException.class).hasMessageContaining("不同供应方式");
    }
    @Test void changedOrMissingPhysicalIdentityCannotInheritTheOldOrderRoute(){
        var original=row();var changed=new MaterialAnalysisIssuedRoutePreservation.Identity(original.id(),original.analysisItemId(),original.nodeKey(),GOODS,UUID.randomUUID(),UNIT,null);
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.project(List.of(original),Map.of(original.key(),changed),proof(Map.of(original.id(),Set.of("BUY"))),Map.of()))
                .isInstanceOf(ApiException.class).hasMessageContaining("物料身份");
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.project(List.of(original),Map.of(),proof(Map.of(original.id(),Set.of("BUY"))),Map.of()))
                .isInstanceOf(ApiException.class).hasMessageContaining("物料身份");
    }
    @Test void canceledAndAdoptedSupplyNeverInventOrderRouteProof(){
        var material=row();
        for(String operation:List.of("FUTURE_TRANSFER","SHARED_FUTURE_CLAIM","AGGREGATE_CONTINUATION")){
            SupplyActionView action=action("BUY","CREATED",operation);
            assertThat(routes(material,action,BigDecimal.ONE)).isEmpty();
        }
        assertThat(routes(material,action("BUY","CANCELLED","AGGREGATE_SUPPLY"),BigDecimal.ONE)).isEmpty();
    }
    @Test void purePublicSafetyAndMinimumQuantityOrdersKeepTheirRealRoute(){
        var material=row();
        SupplyActionView ordinary=action("BUY","CREATED","SUPPLY");
        when(ordinary.requestedQty()).thenReturn(new BigDecimal("0.0001"));
        assertThat(routes(material,ordinary,new BigDecimal("0.0001"))).containsEntry(material.id(),Set.of("BUY"));
        SupplyActionView publicOrder=action("BUY","CREATED","AGGREGATE_SUPPLY");
        when(publicOrder.requestedQty()).thenReturn(BigDecimal.ZERO);when(publicOrder.publicSurplusQty()).thenReturn(BigDecimal.TEN);
        assertThat(routes(material,publicOrder,BigDecimal.ZERO)).containsEntry(material.id(),Set.of("BUY"));
        when(publicOrder.publicSurplusQty()).thenReturn(BigDecimal.ZERO);when(publicOrder.safetyReplenishmentQty()).thenReturn(BigDecimal.TEN);
        assertThat(routes(material,publicOrder,BigDecimal.ZERO)).containsEntry(material.id(),Set.of("BUY"));
    }
    @Test void adoptedBuySupplyPreservesRecipientMakeWithoutBecomingAnOrderProof(){
        var base=row();var material=new MaterialAnalysisIssuedRoutePreservation.Identity(base.id(),base.analysisItemId(),base.nodeKey(),GOODS,null,UNIT,"MAKE");
        for(String operation:List.of("FUTURE_TRANSFER","SHARED_FUTURE_CLAIM","AGGREGATE_CONTINUATION")){
            SupplyActionView action=action("BUY","CREATED",operation);
            var facts=MaterialAnalysisIssuedRoutePreservation.directRoutes(List.of(material),Map.of(material.id(),List.of(new DownstreamReference(action.actionId(),"MAKE","CREATED","PURCHASE_REQUEST",UUID.randomUUID(),"REQ",BigDecimal.ONE))),List.of(action),Map.of(),List.of());
            assertThat(facts.routes()).isEmpty();
            assertThat(facts.dependencyRoutes()).containsEntry(material.id(),"MAKE");
            assertThat(MaterialAnalysisIssuedRoutePreservation.project(List.of(material),Map.of(material.key(),material),facts,Map.of())).containsEntry(material.key(),"MAKE");
        }
    }
    @Test void unknownRecipientRouteDoesNotGuessTheDonorRouteAndActualOrderOverridesCorruptedDependencyState(){
        var material=row();
        var unknown=new MaterialAnalysisIssuedRoutePreservation.Proofs(Map.of(),Map.of(),Set.of(material.id()));
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.project(List.of(material),Map.of(material.key(),material),unknown,Map.of()))
                .isInstanceOf(ApiException.class).hasMessageContaining("原供应方式记录缺失");
        var actual=new MaterialAnalysisIssuedRoutePreservation.Proofs(Map.of(material.id(),Set.of("BUY")),Map.of(material.id(),"MAKE"),Set.of());
        assertThat(MaterialAnalysisIssuedRoutePreservation.project(List.of(material),Map.of(material.key(),material),actual,Map.of())).containsEntry(material.key(),"BUY");
        var target=row();
        var targetProof=new MaterialAnalysisIssuedRoutePreservation.Proofs(Map.of(target.id(),Set.of("BUY")),Map.of(material.id(),"MAKE"),Set.of());
        assertThat(MaterialAnalysisIssuedRoutePreservation.project(List.of(material,target),Map.of(material.key(),material,target.key(),target),targetProof,
                Map.of(material.id(),new AggregateDelegationProjection.Delegation(BigDecimal.ONE,Map.of(target.id(),BigDecimal.ONE),false))))
                .containsEntry(material.key(),"BUY").containsEntry(target.key(),"BUY");
    }
    @Test void knownDependencyCannotGuessAnUnknownSiblingRecipientRoute(){
        var original=row();var known=row();var missing=row();
        var facts=new MaterialAnalysisIssuedRoutePreservation.Proofs(Map.of(),Map.of(known.id(),"MAKE"),Set.of(missing.id()));
        var aliases=Map.of(original.id(),new AggregateDelegationProjection.Delegation(BigDecimal.TEN,Map.of(known.id(),BigDecimal.ONE,missing.id(),BigDecimal.ONE),false));
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.project(List.of(original,known,missing),Map.of(original.key(),original,known.key(),known,missing.key(),missing),facts,aliases))
                .isInstanceOf(ApiException.class).hasMessageContaining("原供应方式记录缺失");
    }
    @Test void positiveInheritedSupplyPropagatesAcrossMemberBarriersAndSeveralLevelsWithoutAllocatingAgain(){
        var original=row();var intermediate=row();var target=row();var split=row();
        var coverage=Map.of(intermediate.id(),Map.of(original.id(),new BigDecimal("0.0001")),
                target.id(),Map.of(intermediate.id(),new BigDecimal("0.0001")),split.id(),Map.of(original.id(),BigDecimal.ONE));
        var inherited=MaterialAnalysisIssuedRoutePreservation.inherit(proof(Map.of(original.id(),Set.of("MAKE"))),List.of(original,intermediate,target,split),coverage);
        assertThat(inherited.routes()).containsEntry(intermediate.id(),Set.of("MAKE")).containsEntry(target.id(),Set.of("MAKE")).containsEntry(split.id(),Set.of("MAKE"));
        var shown=MaterialAnalysisIssuedRoutePreservation.project(List.of(original,intermediate,target,split),Map.of(original.key(),original,intermediate.key(),intermediate,target.key(),target,split.key(),split),inherited,
                Map.of(original.id(),new AggregateDelegationProjection.Delegation(BigDecimal.ONE,Map.of(),true)));
        assertThat(shown).hasSize(4).containsEntry(target.key(),"MAKE");
        assertThat(coverage.get(target.id()).get(intermediate.id())).isEqualByComparingTo("0.0001");
    }
    @Test void zeroAliasOrCoverageWithoutIssuedSupplyDoesNotInventCanonicalRouteAuthority(){
        var original=row();var target=row();
        var empty=MaterialAnalysisIssuedRoutePreservation.inherit(proof(Map.of(original.id(),Set.of("BUY"))),List.of(original,target),Map.of(target.id(),Map.of(original.id(),BigDecimal.ZERO)));
        assertThat(empty.routes()).doesNotContainKey(target.id());
        var unproved=MaterialAnalysisIssuedRoutePreservation.inherit(proof(Map.of()),List.of(original,target),Map.of(target.id(),Map.of(original.id(),BigDecimal.TEN)));
        assertThat(unproved.routes()).isEmpty();assertThat(unproved.dependencyRoutes()).isEmpty();
    }
    @Test void conflictingInheritedOrdersAndCyclicOrMissingSupplyProofsFailClosed(){
        var buy=row();var make=row();var target=row();
        var inherited=MaterialAnalysisIssuedRoutePreservation.inherit(proof(Map.of(buy.id(),Set.of("BUY"),make.id(),Set.of("MAKE"))),List.of(buy,make,target),
                Map.of(target.id(),Map.of(buy.id(),BigDecimal.ONE,make.id(),BigDecimal.ONE)));
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.project(List.of(buy,make,target),Map.of(buy.key(),buy,make.key(),make,target.key(),target),inherited,Map.of()))
                .isInstanceOf(ApiException.class).hasMessageContaining("不同供应方式");
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.inherit(proof(Map.of()),List.of(buy,target),Map.of(target.id(),Map.of(buy.id(),BigDecimal.ONE),buy.id(),Map.of(target.id(),BigDecimal.ONE))))
                .isInstanceOf(ApiException.class).hasMessageContaining("循环");
        assertThatThrownBy(()->MaterialAnalysisIssuedRoutePreservation.inherit(proof(Map.of()),List.of(target),Map.of(target.id(),Map.of(UUID.randomUUID(),BigDecimal.ONE))))
                .isInstanceOf(ApiException.class).hasMessageContaining("物料身份");
    }
    @Test void inheritedAdoptionPreservesTheCanonicalRecipientDecisionInsteadOfDonorRoute(){
        var source=row();var raw=row();
        var target=new MaterialAnalysisIssuedRoutePreservation.Identity(raw.id(),raw.analysisItemId(),raw.nodeKey(),GOODS,null,UNIT,"SUBCONTRACT");
        var direct=new MaterialAnalysisIssuedRoutePreservation.Proofs(Map.of(),Map.of(source.id(),"MAKE"),Set.of());
        var inherited=MaterialAnalysisIssuedRoutePreservation.inherit(direct,List.of(source,target),Map.of(target.id(),Map.of(source.id(),BigDecimal.ONE)));
        assertThat(inherited.routes()).isEmpty();
        assertThat(inherited.dependencyRoutes()).containsEntry(target.id(),"SUBCONTRACT");
    }
    private static MaterialAnalysisIssuedRoutePreservation.Proofs proof(Map<UUID,Set<String>> routes){
        return new MaterialAnalysisIssuedRoutePreservation.Proofs(routes,Map.of(),Set.of());
    }
    private static Map<UUID,Set<String>> routes(MaterialAnalysisIssuedRoutePreservation.Identity material,SupplyActionView action,BigDecimal allocated){
        return MaterialAnalysisIssuedRoutePreservation.directRoutes(List.of(material),Map.of(material.id(),List.of(new DownstreamReference(action.actionId(),action.route(),action.status(),"PURCHASE_REQUEST",UUID.randomUUID(),"REQ",allocated))),
                List.of(action),Map.of(),List.of()).routes();
    }
    private static SupplyActionView action(String route,String status,String operation){
        SupplyActionView action=mock(SupplyActionView.class);when(action.actionId()).thenReturn(UUID.randomUUID());when(action.route()).thenReturn(route);
        when(action.status()).thenReturn(status);when(action.operationType()).thenReturn(operation);when(action.goodsId()).thenReturn(GOODS);when(action.unitId()).thenReturn(UNIT);
        when(action.requestedQty()).thenReturn(BigDecimal.ONE);return action;
    }
}
