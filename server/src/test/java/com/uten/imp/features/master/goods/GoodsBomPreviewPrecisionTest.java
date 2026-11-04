package com.uten.imp.features.master.goods;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import java.math.BigDecimal;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class GoodsBomPreviewPrecisionTest {
    private static final String PURPOSE="goods.bom.periodic-per-piece";
    @Test void confirmationWithoutANewHeaderUsesTheActualReviewedChoice()throws Exception {
        Map<String,BusinessPrecisionContext.Choice> frozen;
        try(var preview=BusinessPrecisionContext.use(Map.of(PURPOSE,new BusinessPrecisionContext.Choice(24,"DOWN")))) {
            assertThat(GoodsPeriodicMaterialRules.asPerPiece(BigDecimal.ONE,new BigDecimal("3")))
                    .isEqualByComparingTo("0.333333333333333333333333");
            frozen=GoodsBomPreviewPrecision.snapshot();
        }
        try(var nextRequest=BusinessPrecisionContext.use(Map.of())) {
            assertThat(GoodsBomPreviewPrecision.confirm(frozen,()->GoodsPeriodicMaterialRules.asPerPiece(BigDecimal.ONE,new BigDecimal("3"))))
                    .isEqualByComparingTo("0.333333333333333333333333");
            assertThat(BusinessPrecisionContext.choices()).isEmpty();
        }
    }
    @Test void aDifferentNewChoiceCannotSilentlyChangeAReviewedWrite()throws Exception {
        var wrote=new AtomicBoolean();
        var frozen=Map.of(PURPOSE,new BusinessPrecisionContext.Choice(24,"DOWN"));
        try(var changed=BusinessPrecisionContext.use(Map.of(PURPOSE,new BusinessPrecisionContext.Choice(2,"HALF_UP")))) {
            assertThatThrownBy(()->GoodsBomPreviewPrecision.confirm(frozen,()->{wrote.set(true);return BigDecimal.ZERO;}))
                    .hasMessageContaining("重新预览");
        }
        assertThat(wrote).isFalse();
    }
}
