package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class AggregatePlanAnchorProjectionTest {
    @Test void originalComponentUsesItsCanonicalComponentsOwnPlanInsteadOfTheParentPlan(){
        UUID origin=UUID.randomUUID(),target=UUID.randomUUID(),parent=UUID.randomUUID();
        UUID childPlan=UUID.randomUUID(),parentPlan=UUID.randomUUID();
        var result=AggregateDelegationProjection.planAnchors(Map.of(target,childPlan,parent,parentPlan),
                Map.of(origin,new AggregateDelegationProjection.Delegation(BigDecimal.TEN,Map.of(target,BigDecimal.TEN),false)));
        assertThat(result.get(origin)).isEqualTo(childPlan);
        assertThat(result.get(parent)).isEqualTo(parentPlan);
    }
    @Test void zeroQuantityAliasStillRetainsTheIssuedTaskIdentityForPublicAppend(){
        UUID origin=UUID.randomUUID(),target=UUID.randomUUID(),child=UUID.randomUUID();
        var result=AggregateDelegationProjection.planAnchors(Map.of(target,child),
                Map.of(origin,new AggregateDelegationProjection.Delegation(BigDecimal.ZERO,Map.of(target,BigDecimal.ZERO),false)));
        assertThat(result.get(origin)).isEqualTo(child);
    }
    @Test void severalCanonicalTargetsCannotBeResolvedByPickingAnArbitraryTask(){
        UUID origin=UUID.randomUUID(),a=UUID.randomUUID(),b=UUID.randomUUID();
        var result=AggregateDelegationProjection.planAnchors(Map.of(a,UUID.randomUUID(),b,UUID.randomUUID()),
                Map.of(origin,new AggregateDelegationProjection.Delegation(BigDecimal.TEN,Map.of(a,BigDecimal.ONE,b,BigDecimal.ONE),false)));
        assertThat(result).doesNotContainKey(origin);
    }
    @Test void anOriginalOwnTaskIsPreservedAndUnorderedTargetsDoNotInheritTheParentTask(){
        UUID origin=UUID.randomUUID(),target=UUID.randomUUID(),own=UUID.randomUUID();
        var relation=Map.of(origin,new AggregateDelegationProjection.Delegation(BigDecimal.ONE,Map.of(target,BigDecimal.ONE),false));
        assertThat(AggregateDelegationProjection.planAnchors(Map.of(origin,own,target,UUID.randomUUID()),relation).get(origin)).isEqualTo(own);
        assertThat(AggregateDelegationProjection.planAnchors(Map.of(),relation)).isEmpty();
    }
}
