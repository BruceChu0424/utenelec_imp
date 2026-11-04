package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.util.Map;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class ProcurementOrderRetainedQuantityTest {
    @Test void actualFiniteRetainedQuantityDoesNotBecomeTheConservativeFourPlaceMinimum(){
        var bound=new ProcurementOrderQuantityBounds.ReceiptBound(new BigDecimal("0.999999999999999999999999"),BigDecimal.ZERO,null);
        assertThat(bound.retainedOrderedQty(BigDecimal.ONE)).isEqualByComparingTo("0.999999999999999999999999");
        assertThat(BigDecimal.ONE.subtract(bound.retainedOrderedQty(BigDecimal.ONE))).isEqualByComparingTo("1e-24");
        assertThat(bound.minimumOrderedQty(BigDecimal.ONE)).isEqualByComparingTo("1");
    }
    @Test void aNonTerminatingRetainedSourceNeedsAChoiceThatActuallyCoversIt()throws Exception {
        var bound=new ProcurementOrderQuantityBounds.ReceiptBound(new BigDecimal("2"),BigDecimal.ZERO,null);
        assertThatThrownBy(()->bound.retainedOrderedQty(new BigDecimal("3"))).isInstanceOf(BusinessPrecisionRequiredException.class);
        try(var choice=BusinessPrecisionContext.use(Map.of("procurement.order.retained-quantity",new BusinessPrecisionContext.Choice(0,"DOWN")))){
            assertThatThrownBy(()->bound.retainedOrderedQty(new BigDecimal("3"))).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,error->assertThat(error.details()).containsEntry("selectionRejected",true).containsEntry("notWritten",true));
        }
        try(var choice=BusinessPrecisionContext.use(Map.of("procurement.order.retained-quantity",new BusinessPrecisionContext.Choice(2,"HALF_UP")))){
            assertThat(bound.retainedOrderedQty(new BigDecimal("3"))).isEqualByComparingTo("0.67");
        }
    }
}
