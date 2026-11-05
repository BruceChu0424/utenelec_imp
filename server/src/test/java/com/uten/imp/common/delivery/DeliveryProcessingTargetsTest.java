package com.uten.imp.common.delivery;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class DeliveryProcessingTargetsTest {
    private final UUID a=UUID.randomUUID(),b=UUID.randomUUID();
    private DeliveryBom.Node node(List<UUID> path,String name,String qty,String basis,String output,
            List<DeliveryPlan.Operation> ops,List<DeliveryBom.Node> children){
        return new DeliveryBom.Node(path,path.isEmpty()?null:path.getLast(),UUID.randomUUID(),name,name,UUID.randomUUID(),"个",null,null,null,
            "自制",qty,basis,output,true,children.isEmpty()?DeliveryBom.ChildrenState.NONE:DeliveryBom.ChildrenState.LOADED,
            false,DeliveryBom.MaterialRole.PART,ops,children);
    }
    @Test void aWholeDeliveredAssemblyKeepsTheActualNestedLaserSubjectAndQuantity(){
        var plate=node(List.of(a,b),"底板","3","PER_UNIT","1",List.of(DeliveryPlan.Operation.LASER),List.of());
        var module=node(List.of(a),"模块","2","PER_UNIT","1",List.of(),List.of(plate));
        var root=node(List.of(),"成品","1","PER_UNIT","1",List.of(),List.of(module));
        var targets=DeliveryProcessingTargets.resolve(root,List.of(),new BigDecimal("5"),DeliveryPlan.assembled());
        assertThat(targets).hasSize(1);
        assertThat(targets.getFirst().path()).containsExactly(a,b);
        assertThat(targets.getFirst().name()).isEqualTo("底板");
        assertThat(targets.getFirst().quantityExact()).isEqualTo("30");
        assertThat(targets.getFirst().operations()).containsExactly("LASER");
        assertThat(DeliveryProcessingTargets.resolve(root,List.of(a),new BigDecimal("10"),DeliveryPlan.assembled())
            .getFirst().quantityExact()).isEqualTo("30");
    }
    @Test void fractionalPackagingRequirementRemainsAnExactFractionRatherThanSilentRounding(){
        var plate=node(List.of(a),"标签","1","PER_PACKAGE","3",List.of(DeliveryPlan.Operation.LASER),List.of());
        var root=node(List.of(),"成品","1","PER_UNIT","1",List.of(),List.of(plate));
        var target=DeliveryProcessingTargets.resolve(root,List.of(),new BigDecimal("5"),DeliveryPlan.assembled()).getFirst();
        assertThat(target.quantityExact()).isNull();
        assertThat(target.getQuantityDisplay()).isEqualTo("5/3");
        assertThat(target.quantityNumerator()).isEqualTo("5");
        assertThat(target.quantityDenominator()).isEqualTo("3");
    }
    @Test void unrelatedInvalidCoveredUsageDoesNotInventAnActiveProcessingRequirement(){
        var unused=node(List.of(a),"未启用子件",null,"PER_UNIT","1",List.of(),List.of());
        var root=node(List.of(),"成品","1","PER_UNIT","1",List.of(DeliveryPlan.Operation.LASER),List.of(unused));
        assertThat(DeliveryProcessingTargets.resolve(root,List.of(),BigDecimal.ONE,DeliveryPlan.assembled())).hasSize(1);
    }
}
