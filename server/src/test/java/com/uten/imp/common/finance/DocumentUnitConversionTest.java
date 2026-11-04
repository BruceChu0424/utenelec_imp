package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class DocumentUnitConversionTest {
    @Test void finiteTwentyFourPlaceProductAndOriginalOperandsRemainExact(){
        BigDecimal q=new BigDecimal("0.123456789012345678901234");
        var value=DocumentUnitConversion.project(q,UUID.randomUUID(),BigDecimal.ONE);
        assertThat(value.quantity()).isSameAs(q);assertThat(value.basicQuantity()).isEqualByComparingTo(q);
        assertThat(value.policy()).isEmpty();
        assertThatThrownBy(()->DocumentUnitConversion.project(BigDecimal.ONE,UUID.randomUUID(),null)).isInstanceOf(RuntimeException.class);
        assertThat(DocumentUnitConversion.project(BigDecimal.ONE,UUID.randomUUID(),new BigDecimal("1e-24")).rate()).isEqualByComparingTo("1e-24");
        assertThatThrownBy(()->DocumentUnitConversion.project(BigDecimal.ONE,UUID.randomUUID(),new BigDecimal("1e-25")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).isNotInstanceOf(BusinessPrecisionRequiredException.class);
    }
    @Test void longerFiniteProductRequiresItsActualStorageChoiceAndNeverSilentlyDropsPositiveQuantity()throws Exception {
        var q=new BigDecimal("0.000000000000000000000001");var rate=new BigDecimal("0.5");
        assertThatThrownBy(()->DocumentUnitConversion.project(q,UUID.randomUUID(),rate)).isInstanceOf(BusinessPrecisionRequiredException.class);
        try(var policy=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(24,"DOWN")))){
            assertThatThrownBy(()->DocumentUnitConversion.project(q,UUID.randomUUID(),rate)).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,e->assertThat(e.details()).containsEntry("selectionRejected",true));
        }
        try(var policy=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(24,"HALF_UP")))){
            var value=DocumentUnitConversion.project(q,UUID.randomUUID(),rate);
            assertThat(value.product()).isEqualByComparingTo("5e-25");assertThat(value.basicQuantity()).isEqualByComparingTo(q);
            assertThat(value.policy()).containsKey("quantity.to-base");
            assertThatThrownBy(()->DocumentUnitConversion.requireWithin(value,new BigDecimal("5e-25"))).isInstanceOf(BusinessPrecisionRequiredException.class);
        }
    }
    @Test void savedChargedAndGiftAdoptionSurvivesAnUnrelatedNewChoice()throws Exception {
        try(var unrelated=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(0,"DOWN")))){
            var value=ProcurementQuantities.frozen(ProcurementQuantities.EXTRA_GIFT,new BigDecimal("0.1"),new BigDecimal("0.2"),
                    new BigDecimal("0.123456789012345678901234"),new BigDecimal("0.012345678901234567890123"),new BigDecimal("0.024691357802469135780247"));
            assertThat(value.physicalBase()).isEqualByComparingTo("0.037037036703703703670370");assertThat(BusinessPrecisionContext.usedChoices()).isEmpty();
        }
    }
    @Test void chargedAndGiftShareOnePhysicalProjectionAndKeepEachPositiveTranche()throws Exception {
        try(var policy=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(24,"HALF_UP")))){
            var value=ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,new BigDecimal("0.1"),new BigDecimal("0.2"),new BigDecimal("0.123456789012345678901234"));
            assertThat(value.chargedBase().add(value.giftBase())).isEqualByComparingTo(value.physicalBase());
            assertThat(value.giftBase()).isPositive();
        }
        assertThatThrownBy(()->ProcurementQuantities.of(ProcurementQuantities.LEGACY,BigDecimal.ONE,null,null)).isInstanceOf(RuntimeException.class);
    }
}
