package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SalesReturnAmountAuthorityTest {
    @Test
    void discountedOriginalAndLocalAmountsConserveEverySplitAndFinalRoundingRemainder() {
        BigDecimal priorOriginal = BigDecimal.ZERO;
        BigDecimal priorLocal = BigDecimal.ZERO;
        for (int i = 0; i < 3; i++) {
            var amount = SalesReturnAmountAuthority.amounts(BigDecimal.ONE, bd("3"), bd("1"), bd("7.1234"),
                    BigDecimal.valueOf(i), priorOriginal, priorLocal);
            priorOriginal = priorOriginal.add(amount.original());
            priorLocal = priorLocal.add(amount.local());
        }
        assertThat(priorOriginal).isEqualByComparingTo("1");
        assertThat(priorLocal).isEqualByComparingTo("7.1234");
    }

    @Test
    void excessQuantityAndUnprovablePriorCreditsAreRejected() {
        assertThrows(ApiException.class, () -> SalesReturnAmountAuthority.amounts(bd("3"), bd("3"),
                bd("1"), bd("7"), bd("1"), bd("0.3333"), bd("2.3333")));
        assertThrows(ApiException.class, () -> SalesReturnAmountAuthority.amounts(bd("1"), bd("3"),
                bd("1"), bd("7"), bd("1"), bd("0.5"), bd("2.3333")));
    }

    @Test
    void reversalKeepsTheSurvivingRoundingSliceAndOnlyAllowsBoundedRoundingDifferences() {
        var third = SalesReturnAmountAuthority.amounts(bd("1"), bd("3"), bd("1"), bd("7"),
                bd("1"), bd("0.3334"), bd("2.3334"), 2, 1);
        assertThat(third.original()).isEqualByComparingTo("0.3333");
        assertThat(third.local()).isEqualByComparingTo("2.3333");
        var finalSlice = SalesReturnAmountAuthority.amounts(bd("1"), bd("3"), bd("1"), bd("7"),
                bd("2"), bd("0.6667"), bd("4.6667"), 3, 1);
        assertThat(finalSlice.original().add(third.original()).add(bd("0.3334")))
                .isEqualByComparingTo("1");
        assertThat(finalSlice.local().add(third.local()).add(bd("2.3334")))
                .isEqualByComparingTo("7");
        assertThrows(ApiException.class, () -> SalesReturnAmountAuthority.amounts(bd("1"), bd("3"),
                bd("1"), bd("7"), bd("1"), bd("0.5"), bd("2.3334"), 2, 1));
        assertThrows(ApiException.class, () -> SalesReturnAmountAuthority.amounts(bd("1"), bd("3"),
                bd("1"), bd("7"), bd("1"), bd("0.3334"), bd("2.3334"), 2, 0));
    }

    @Test
    void clientPriceAndAmountDoNotAuthorTheCredit() {
        Fixture fixture = fixture();
        fixture.item().setPrice(bd("999"));
        fixture.item().setAmountOriginal(bd("999999"));
        fixture.item().setAmountLocal(bd("999999"));
        fixture.service().apply(fixture.document(), List.of(fixture.item()));
        assertThat(fixture.item().getPrice()).isEqualByComparingTo("0.5");
        assertThat(fixture.document().getTotalOriginal()).isEqualByComparingTo("0.3333");
        assertThat(fixture.document().getTotalLocal()).isEqualByComparingTo("2.3333");
    }

    @Test
    void mismatchedClientCurrencyRateTaxAndSettlementCannotCreateACredit() {
        for (int field = 0; field < 5; field++) {
            Fixture fixture = fixture();
            switch (field) {
                case 0 -> fixture.document().setClientId(UUID.randomUUID());
                case 1 -> fixture.document().setCurrencyId(UUID.randomUUID());
                case 2 -> fixture.document().setExchangeRate(bd("99"));
                case 3 -> fixture.document().setTaxRate(bd("99"));
                case 4 -> fixture.document().setSettlementMethodId(UUID.randomUUID());
            }
            assertThrows(ApiException.class,
                    () -> fixture.service().apply(fixture.document(), List.of(fixture.item())));
        }
    }

    @Test
    void unsourcedAndDuplicateShipmentLinesAreRejected() {
        Fixture fixture = fixture();
        assertThrows(ApiException.class, () -> fixture.service().apply(fixture.document(),
                List.of(fixture.item(), fixture.item())));
        fixture.item().setOutItemId(null);
        assertThrows(ApiException.class, () -> fixture.service().apply(fixture.document(), List.of(fixture.item())));
    }

    private Fixture fixture() {
        SalesReturn document = new SalesReturn();
        document.setClientId(UUID.randomUUID());
        UUID currencyId = UUID.randomUUID();
        SalesReturnItem item = new SalesReturnItem();
        item.setOutItemId(UUID.randomUUID());
        item.setQty(BigDecimal.ONE);
        Object[] source = {item.getOutItemId(), UUID.randomUUID(), document.getClientId(), currencyId,
                bd("7"), null, bd("13"), (short) 1, "SHIPPED", true, bd("1"), bd("7"),
                bd("3"), bd("0.5"), bd("0.6667"), bd("1"), bd("7"), bd("0"), bd("0"), null};
        EntityManager em = mock(EntityManager.class);
        Query sourceQuery = query();
        when(em.createNativeQuery(contains("JOIN sales_shipments shipment"))).thenReturn(sourceQuery);
        when(sourceQuery.getResultList()).thenReturn(java.util.Collections.singletonList(source));
        Query arQuery = query();
        when(em.createNativeQuery(contains("FROM ar_ap_ledger"))).thenReturn(arQuery);
        when(arQuery.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{document.getClientId(), currencyId, bd("7"), null, bd("1"), bd("7")}));
        Query priorQuery = query();
        when(em.createNativeQuery(contains("JOIN sales_returns document"))).thenReturn(priorQuery);
        when(priorQuery.getSingleResult()).thenReturn(new Object[]{bd("0"), bd("0"), bd("0"), true});
        return new Fixture(new SalesReturnAmountAuthority(em, mock(SalesReturnItemRepository.class)), document, item);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }
    private static BigDecimal bd(String value) { return new BigDecimal(value); }
    private record Fixture(SalesReturnAmountAuthority service, SalesReturn document, SalesReturnItem item) {}
}
