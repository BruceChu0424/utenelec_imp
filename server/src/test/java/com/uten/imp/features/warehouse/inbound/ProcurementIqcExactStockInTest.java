package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.web.ApiException;
import jakarta.validation.Validation;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class ProcurementIqcExactStockInTest {
    @Test void explicitNewTargetSubtractsActualPriorAmountAndWeightInsteadOfRepricingIt()throws Exception {
        try(var selected=BusinessPrecisionContext.use(Map.of("money.cumulative-share",new BusinessPrecisionContext.Choice(2,"HALF_UP"),"quantity.slice",new BusinessPrecisionContext.Choice(2,"HALF_UP")))){
            assertThat(ProcurementIqcStockInService.amountAfterActual(BigDecimal.ONE,new BigDecimal("3"),new BigDecimal("2"),new BigDecimal(".3334"))).isEqualByComparingTo(".3366");
            assertThat(ProcurementIqcStockInService.weightAfterActual(BigDecimal.ONE,new BigDecimal("3"),new BigDecimal("2"),new BigDecimal(".3334"))).isEqualByComparingTo(".3366");
        }
    }
    @Test void finalSliceKeepsExactSourceRemainderUnderAnUnrelatedCurrentChoice()throws Exception {
        try(var selected=BusinessPrecisionContext.use(Map.of("money.cumulative-share",new BusinessPrecisionContext.Choice(0,"DOWN")))){
            assertThat(ProcurementIqcStockInService.amountAfterActual(new BigDecimal("1.0001"),new BigDecimal("3"),new BigDecimal("3"),new BigDecimal(".3334"))).isEqualByComparingTo(".6667");
        }
        assertThat(ProcurementIqcStockInService.amountAfterActual(new BigDecimal("1e-24"),BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ZERO)).isEqualByComparingTo("1e-24");
    }
    @Test void insufficientNewChoiceAndMissingActualEvidenceCannotBecomeAClampedZero()throws Exception {
        try(var selected=BusinessPrecisionContext.use(Map.of("money.cumulative-share",new BusinessPrecisionContext.Choice(0,"DOWN")))){
            assertThatThrownBy(()->ProcurementIqcStockInService.amountAfterActual(BigDecimal.ONE,new BigDecimal("3"),new BigDecimal("2"),new BigDecimal(".3333"))).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,error->assertThat(error.details()).containsEntry("selectionRejected",true));
        }
        assertThatThrownBy(()->ProcurementIqcStockInService.weightAfterActual(BigDecimal.ONE,new BigDecimal("3"),BigDecimal.ONE,null)).isInstanceOf(ApiException.class).hasMessageContaining("原实际入库份额");
    }
    @Test void releasedWarehouseDtoHasAdditiveExactQuantitiesAndActualWeightWithoutCommercialFields()throws Exception {
        BigDecimal exact=new BigDecimal("9007199254740993.000000000000000000000001"),beforeWeight=new BigDecimal("0.333333333333333333333333");
        var slice=new ProcurementIqcStockInContracts.ReleasedSlice(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),"匿名","匿名",null,UUID.randomUUID(),"KG",null,
                exact,exact,exact,exact,exact,exact,BigDecimal.ONE,null,null,null,null,List.of(),UUID.randomUUID(),"匿名仓","CHARGED",beforeWeight);
        var json=new ObjectMapper().valueToTree(slice);
        for(String key:List.of("receivedBaseQty","qualityPassedBaseQty","warehouseStockedBaseQty","releasedBaseQty","stockedForReleaseBaseQty","remainingBaseQty")){
            assertThat(json.get(key).isNumber()).isTrue();assertThat(json.get(key+"Exact").asText()).isEqualTo(exact.toPlainString());
        }
        assertThat(json.get("stockedForReleaseWeightExact").asText()).isEqualTo(beforeWeight.toPlainString());
        for(String forbidden:List.of("price","amount","amountLocal","releasedAmountLocal","currencyId","exchangeRate"))assertThat(json.has(forbidden)).isFalse();
    }
    @Test void httpContractAcceptsPositiveTwentyFourPlaceQuantityAndRejectsZero(){
        try(var factory=Validation.buildDefaultValidatorFactory()){
            var validator=factory.getValidator();UUID id=UUID.randomUUID();
            assertThat(validator.validate(new ProcurementIqcStockInContracts.ConfirmItem(id,new BigDecimal("1e-24"),new BigDecimal("1e-24"),"A",UUID.randomUUID()))).isEmpty();
            assertThat(validator.validate(new ProcurementIqcStockInContracts.ConfirmItem(id,BigDecimal.ZERO,BigDecimal.ONE,"A",UUID.randomUUID()))).isNotEmpty();
        }
    }
}
