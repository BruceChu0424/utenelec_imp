package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.assertj.core.api.Assertions.*;

class SalesDeliveryFulfillmentServiceTest {
    @Test void cumulativeSourceSlicesDoNotDuplicateOrLoseTheSharedComponentQuota() {
        BigDecimal total=new BigDecimal("1"), root=new BigDecimal("3");
        var a=SalesDeliveryFulfillmentService.proportionalSlice(total,BigDecimal.ZERO,BigDecimal.ONE,root);
        var b=SalesDeliveryFulfillmentService.proportionalSlice(total,BigDecimal.ONE,new BigDecimal("2"),root);
        var c=SalesDeliveryFulfillmentService.proportionalSlice(total,new BigDecimal("2"),root,root);
        assertThat(a).isEqualByComparingTo("0.3333");
        assertThat(a.add(b).add(c)).isEqualByComparingTo(total);
        assertThat(c).isEqualByComparingTo("0.3334");
    }
    @Test void sourceCapacityNeverIncludesAnUnselectedOrderOrExceedsItsRootSlice() {
        assertThat(SalesDeliveryFulfillmentService.proportionalSlice(new BigDecimal("2100"),new BigDecimal("20"),new BigDecimal("50"),new BigDecimal("100")))
                .isEqualByComparingTo("630");
        assertThatThrownBy(()->SalesDeliveryFulfillmentService.proportionalSlice(BigDecimal.ONE,BigDecimal.ZERO,new BigDecimal("101"),new BigDecimal("100")))
                .hasMessageContaining("分配不正确");
    }
}
