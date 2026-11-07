package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class MaterialOrderQuantityCompatibilityTest {
    @Test void legacyZeroOrdersNoNewSupplyButKeepsTheIndependentExistingStockHandover() {
        var old=new MaterialAnalysisContracts.SupplyQuantityInput("root",null,BigDecimal.ZERO,BigDecimal.ZERO);
        var required=BigDecimal.TEN;
        assertThat(MaterialOrderQuantity.incremental(old.qty(),old.quantityMode(),required,required)).isZero();
        assertThat(MaterialOrderQuantity.existingRootStockCeiling(old.qty(),old.quantityMode(),required)).isEqualByComparingTo("10");
    }

    @Test void reviewedCoverageTotalZeroAndPartialAmountsStayExplicit() {
        for(var amount:java.util.List.of(BigDecimal.ZERO,new BigDecimal("5"))) {
            var reviewed=new MaterialAnalysisContracts.SupplyQuantityInput("root",null,amount,BigDecimal.ZERO,
                    "COVERAGE_TOTAL","AVAILABLE_THEN_ORDER");
            assertThat(MaterialOrderQuantity.existingRootStockCeiling(reviewed.qty(),reviewed.quantityMode(),BigDecimal.TEN))
                    .isEqualByComparingTo(amount);
        }
    }

    @Test void anUnknownQuantityModeCannotAcquireExistingStock() {
        assertThatThrownBy(()->MaterialOrderQuantity.existingRootStockCeiling(BigDecimal.ZERO,"UNREVIEWED",BigDecimal.TEN))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }
}
