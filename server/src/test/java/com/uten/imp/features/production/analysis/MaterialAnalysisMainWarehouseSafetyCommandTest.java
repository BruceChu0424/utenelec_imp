package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.util.List;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialAnalysisMainWarehouseSafetyCommandTest {
    @Test void repeatedBomRowsUseTheMainBudgetOnceAndNeverReadTheDefaultLeaf() {
        MaterialView first=material("10","12","0","0"),second=material("10","12","0","0");
        var result=MaterialAnalysisCommandService.groupSafetySnapshot(List.of(first,second));
        assertThat(result.publicAvailableQty()).isEqualByComparingTo("12");
        assertThat(result.gapQty()).isZero();
        verify(first,never()).warehouseBreakdown();verify(second,never()).warehouseBreakdown();
    }

    @Test void maximumGoodsSafetyThresholdAndSharedPublicInflightProduceOneGap() {
        var result=MaterialAnalysisCommandService.groupSafetySnapshot(List.of(
                material("8","4","2","4"),material("10","4","2","4")));
        assertThat(result.safetyStockQty()).isEqualByComparingTo("10");
        assertThat(result.publicAvailableQty()).isEqualByComparingTo("4");
        assertThat(result.openSupplyQty()).isEqualByComparingTo("2");
        assertThat(result.gapQty()).isEqualByComparingTo("4");
    }

    @ParameterizedTest @ValueSource(strings={"public","open","gap"})
    void absentMainAuthorityCannotBeReconstructedFromAnArbitraryLeaf(String missing) {
        var material=material("10","4","2","4");
        switch(missing){
            case "public" -> when(material.mainWarehousePublicAvailableQty()).thenReturn(null);
            case "open" -> when(material.mainWarehouseOpenSafetySupplyQty()).thenReturn(null);
            case "gap" -> when(material.mainWarehouseSafetyReplenishmentGapQty()).thenReturn(null);
        }
        assertThatThrownBy(()->MaterialAnalysisCommandService.groupSafetySnapshot(List.of(material)))
                .isInstanceOf(ApiException.class).hasMessageContaining("主仓安全库存汇总缺失");
        verify(material,never()).warehouseBreakdown();
    }

    @ParameterizedTest @ValueSource(strings={"public","open","gap"})
    void negativeMainBudgetIsRejected(String invalid) {
        var material=material("10",invalid.equals("public")?"-1":"4",invalid.equals("open")?"-1":"2",invalid.equals("gap")?"-1":"4");
        assertThatThrownBy(()->MaterialAnalysisCommandService.groupSafetySnapshot(List.of(material)))
                .isInstanceOf(ApiException.class).hasMessageContaining("主仓安全库存汇总无效");
    }

    @Test void inconsistentPublicOrInflightSnapshotsCannotBeCombinedIntoAnInventedBudget() {
        assertThatThrownBy(()->MaterialAnalysisCommandService.groupSafetySnapshot(List.of(
                material("10","12","0","0"),material("10","4","8","0"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("快照不一致");
    }

    @Test void echoedGapMustMatchTheFrozenMainTotals() {
        assertThatThrownBy(()->MaterialAnalysisCommandService.groupSafetySnapshot(List.of(material("10","4","2","6"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("快照不一致");
    }

    private static MaterialView material(String safety,String available,String open,String gap){
        MaterialView value=mock(MaterialView.class);
        when(value.safetyStockQty()).thenReturn(new BigDecimal(safety));
        when(value.mainWarehousePublicAvailableQty()).thenReturn(new BigDecimal(available));
        when(value.mainWarehouseOpenSafetySupplyQty()).thenReturn(new BigDecimal(open));
        when(value.mainWarehouseSafetyReplenishmentGapQty()).thenReturn(new BigDecimal(gap));
        return value;
    }
}
