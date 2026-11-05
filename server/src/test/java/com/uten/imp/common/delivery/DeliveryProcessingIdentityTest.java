package com.uten.imp.common.delivery;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class DeliveryProcessingIdentityTest {
    @Test void aWholeProductCannotHideInvalidIdentityOnTheActualLaserTargetButUnrelatedReferencesStayHarmless() {
        var laser=node("laser",List.of(DeliveryPlan.Operation.LASER),List.of("UNIT_MISSING"));
        var unrelated=node("reference",List.of(),List.of("ROW_COLOR_LEGACY"));
        var root=root(List.of(laser,unrelated));
        assertThatThrownBy(()->DeliveryProcessingTargets.resolve(root,List.of(),BigDecimal.TEN,DeliveryPlan.assembled()))
                .isInstanceOf(ApiException.class).hasMessageContaining("身份未核对");
        var valid=node("laser",List.of(DeliveryPlan.Operation.LASER),List.of());
        var result=DeliveryProcessingTargets.resolve(root(List.of(valid,unrelated)),List.of(),BigDecimal.TEN,DeliveryPlan.assembled());
        assertThat(result).singleElement().satisfies(target->{assertThat(target.name()).isEqualTo("laser");assertThat(target.quantityExact()).isEqualTo("20");});
    }
    private static DeliveryBom.Node node(String label,List<DeliveryPlan.Operation> operations,List<String> problems){
        UUID edge=UUID.nameUUIDFromBytes(label.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        return new DeliveryBom.Node(List.of(edge),edge,UUID.randomUUID(),label,label,problems.contains("UNIT_MISSING")?null:UUID.randomUUID(),"个",null,null,"","自制", "2","PER_UNIT","1",true,
                DeliveryBom.ChildrenState.NONE,false,DeliveryBom.MaterialRole.PART,operations,List.of(),problems);
    }
    private static DeliveryBom.Node root(List<DeliveryBom.Node> children){
        return new DeliveryBom.Node(List.of(),null,UUID.randomUUID(),"FG","Whole product",UUID.randomUUID(),"个",null,null,"","自制","1","PER_UNIT","1",true,
                DeliveryBom.ChildrenState.LOADED,false,DeliveryBom.MaterialRole.PART,List.of(),children);
    }
}
