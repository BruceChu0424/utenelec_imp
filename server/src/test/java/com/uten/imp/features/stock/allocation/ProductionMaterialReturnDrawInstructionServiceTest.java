package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class ProductionMaterialReturnDrawInstructionServiceTest {
    @Test void rejectsAnUnrepresentableRemainderInsteadOfSilentlyKeepingAPickingInstruction() {
        var item=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("2"),new BigDecimal("3"));
        assertThatThrownBy(()->ProductionMaterialReturnDrawInstructionService.exactReductions(new BigDecimal("0.5"),List.of(item)))
                .isInstanceOf(ApiException.class).hasMessageContaining("精确撤减");
    }
    @Test void differentOriginalUnitsCanExactlyCarryTheRemainder() {
        var large=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),BigDecimal.ONE,new BigDecimal("3"));
        var precise=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("0.0003"),BigDecimal.ONE);
        var result=ProductionMaterialReturnDrawInstructionService.exactReductions(BigDecimal.ONE,List.of(large,precise));
        assertThat(result.get(large.itemId())).isEqualByComparingTo("0.3333");
        assertThat(result.get(precise.itemId())).isEqualByComparingTo("0.0001");
        assertThat(result.get(large.itemId()).multiply(large.rate()).add(result.get(precise.itemId()))).isEqualByComparingTo(BigDecimal.ONE);
    }
    @Test void freeStockDoesNotRequireAFalsePickingInstruction() {
        assertThat(ProductionMaterialReturnDrawInstructionService.exactReductions(new BigDecimal("4"),List.of())).isEmpty();
        var item=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("2"),BigDecimal.ONE);
        assertThat(ProductionMaterialReturnDrawInstructionService.exactReductions(new BigDecimal("4"),List.of(item)).get(item.itemId())).isEqualByComparingTo("2");
    }
    @Test void anExactLaterUnitMustNotBeDefeatedByTheFirstGreedyLine() {
        var three=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("0.0002"),new BigDecimal("3"));
        var two=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("0.0002"),new BigDecimal("2"));
        var result=ProductionMaterialReturnDrawInstructionService.exactReductions(new BigDecimal("0.0004"),List.of(three,two));
        assertThat(result).hasSize(1); assertThat(result.get(two.itemId())).isEqualByComparingTo("0.0002");
    }
    @Test void boundedAlternativeOrderCanExactlyCombineTwoDifferentUnits() {
        var three=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("0.0004"),new BigDecimal("3"));
        var five=new ProductionMaterialReturnDrawInstructionService.PendingDraw(UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("0.0002"),new BigDecimal("5"));
        var result=ProductionMaterialReturnDrawInstructionService.exactReductions(new BigDecimal("0.0013"),List.of(three,five));
        assertThat(result.get(three.itemId())).isEqualByComparingTo("0.0001");
        assertThat(result.get(five.itemId())).isEqualByComparingTo("0.0002");
    }
}
