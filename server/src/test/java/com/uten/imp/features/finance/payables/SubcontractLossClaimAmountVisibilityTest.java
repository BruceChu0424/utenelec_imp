package com.uten.imp.features.finance.payables;

import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;
import java.util.Map;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.mock;
import static org.mockito.ArgumentMatchers.*;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@ExtendWith(MockitoExtension.class)
class SubcontractLossClaimAmountVisibilityTest {

    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private CommercialPriceVisibility commercialPriceVisibility;
    @Mock private EntityManager em;
    @InjectMocks private SubcontractLossClaimService service;

    @Test
    void warehouseSummaryKeepsLossQuantitiesButMasksBookAndClaimAmounts() {
        when(commercialPriceVisibility.canViewFinance()).thenReturn(false);
        Object[] row = new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), "SW-1", UUID.randomUUID(),
                "S-1", "供应商", "AWAITING_FULFILLMENT",
                new BigDecimal("5"), new BigDecimal("1"), new BigDecimal("4"),
                new BigDecimal("40"), new BigDecimal("30"), 2L, OffsetDateTime.now(), "人民币", "CNY"
        };

        SubcontractLossClaimContracts.CaseSummary summary =
                ReflectionTestUtils.invokeMethod(service, "summary", (Object) row);

        assertTrue(summary.priceMasked());
        assertThat(new BigDecimal(summary.actualLossQty())).isEqualByComparingTo("5");
        assertThat(new BigDecimal(summary.allowedLossQty())).isEqualByComparingTo("1");
        assertThat(new BigDecimal(summary.excessLossQty())).isEqualByComparingTo("4");
        assertNull(summary.lossBookValueLocal());
        assertNull(summary.claimAmountLocal());
        assertNull(summary.currencyName());
        assertNull(summary.currencyCode());
    }

    @Test
    void financeSummaryKeepsExactBookAndClaimAmountsAndUnknownBookValue() {
        when(commercialPriceVisibility.canViewFinance()).thenReturn(true);
        Object[] row = new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), "SW-2", UUID.randomUUID(),
                "S-1", "供应商", "AWAITING_FULFILLMENT",
                new BigDecimal("5"), BigDecimal.ONE, new BigDecimal("4"),
                new BigDecimal("40.000000000000000000000000000001"),
                new BigDecimal("30.000000000000000000000001"), 2L, OffsetDateTime.now(), "人民币", "CNY"
        };
        SubcontractLossClaimContracts.CaseSummary summary =
                ReflectionTestUtils.invokeMethod(service, "summary", (Object) row);
        assertThat(summary.priceMasked()).isFalse();
        assertThat(summary.currencyName()).isEqualTo("人民币");
        assertThat(summary.currencyCode()).isEqualTo("CNY");
        assertThat(new BigDecimal(summary.lossBookValueLocal()))
                .isEqualByComparingTo("40.000000000000000000000000000001");
        assertThat(new BigDecimal(summary.claimAmountLocal()))
                .isEqualByComparingTo("30.000000000000000000000001");

        row[10] = null;
        summary = ReflectionTestUtils.invokeMethod(service, "summary", (Object) row);
        assertNull(summary.lossBookValueLocal());
        assertThat(new BigDecimal(summary.claimAmountLocal()))
                .isEqualByComparingTo("30.000000000000000000000001");
    }
    @Test void actualDetailUnitProjectionRequiresItsOwnChoiceAndNeverRepricesTheClaim()throws Exception {
        detailRows(BigDecimal.ONE,true);
        assertThatThrownBy(()->service.detail(UUID.randomUUID())).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,error->assertThat(error.details()).containsEntry("calculationKey","money.unit-value").containsEntry("maxScale",30));
        try(var selected=BusinessPrecisionContext.use(Map.of("money.unit-value",new BusinessPrecisionContext.Choice(24,"DOWN")))){
            var detail=service.detail(UUID.randomUUID());
            assertThat(detail.lines().getFirst().unitBookValueLocal()).isEqualTo("0.333333333333333333333333");
            assertThat(new BigDecimal(detail.lines().getFirst().lossBookValueLocal())).isEqualByComparingTo("0.4");
            assertThat(new BigDecimal(detail.summary().claimAmountLocal())).isEqualByComparingTo("27.000000000000000000000001");
            assertThat(BusinessPrecisionContext.usedChoices()).containsKey("money.unit-value");
        }
    }
    @Test void actualDetailKeepsFiniteTwentyFourPlaceUnitValueWithoutAChoice(){
        detailRows(new BigDecimal("3.000000000000000000000003"),true);
        assertThat(service.detail(UUID.randomUUID()).lines().getFirst().unitBookValueLocal()).isEqualTo("1.000000000000000000000001");
    }
    @Test void maskedDetailNeverEvaluatesOrPromptsForAHiddenNonTerminatingUnitValue(){
        detailRows(BigDecimal.ONE,false);
        var detail=service.detail(UUID.randomUUID());assertNull(detail.lines().getFirst().unitBookValueLocal());assertNull(detail.lines().getFirst().lossBookValueLocal());
    }
    private void detailRows(BigDecimal total,boolean visible){
        when(commercialPriceVisibility.canViewFinance()).thenReturn(visible);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);Query query=mock(Query.class);when(query.setParameter(anyString(),any())).thenReturn(query);
            Object[] summary={UUID.randomUUID(),UUID.randomUUID(),"SW-UNIT",UUID.randomUUID(),"S-UNIT","匿名加工商","AWAITING_FULFILLMENT",new BigDecimal("3"),new BigDecimal("2"),BigDecimal.ONE,new BigDecimal("0.4"),new BigDecimal("27.000000000000000000000001"),1L,OffsetDateTime.now(),"人民币","CNY"};
            Object[] line={UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),"G-UNIT","匿名材料",null,null,UUID.randomUUID(),new BigDecimal("3"),new BigDecimal("2"),BigDecimal.ONE,total,new BigDecimal("0.4"),"VALUED"};
            List<Object[]> rows=sql.contains("FROM subcontract_loss_case_lines line")?java.util.Collections.singletonList(line):sql.contains("FROM subcontract_loss_cases loss")?java.util.Collections.singletonList(summary):List.of();
            when(query.getResultList()).thenReturn(rows);return query;
        });
    }
}
