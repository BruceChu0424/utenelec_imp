package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementReturnPayableAuthorityTest {
    @Test
    void exactActiveSourceApSupportsReturnEvenWhenLaterPaymentFieldsExist() {
        UUID supplier = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        EntityManager em = em(List.<Object[]>of(new Object[]{
                UUID.randomUUID(), supplier, currency, new BigDecimal("7"), settlement,
                new BigDecimal("100"), new BigDecimal("700")}));

        assertThatCode(() -> ProcurementReturnPayableAuthority.lockAndValidate(
                em, "SUBCONTRACT", UUID.randomUUID(), supplier, currency,
                new BigDecimal("7.0"), settlement,
                new BigDecimal("100"), new BigDecimal("700"), true))
                .doesNotThrowAnyException();
    }

    @Test
    void missingDuplicateOrAmountMismatchFailsClosed() {
        UUID supplier = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        assertThatThrownBy(() -> ProcurementReturnPayableAuthority.lockAndValidate(
                em(List.of()), "PURCHASE", UUID.randomUUID(), supplier, currency,
                BigDecimal.ONE, settlement, BigDecimal.TEN, BigDecimal.TEN, true))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("缺失或重复");

        Object[] wrong = new Object[]{UUID.randomUUID(), supplier, currency,
                BigDecimal.ONE, settlement, BigDecimal.ONE, BigDecimal.ONE};
        assertThatThrownBy(() -> ProcurementReturnPayableAuthority.lockAndValidate(
                em(List.<Object[]>of(wrong)), "PURCHASE", UUID.randomUUID(), supplier, currency,
                BigDecimal.ONE, settlement, BigDecimal.TEN, BigDecimal.TEN, true))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("双币总额不一致");
    }

    @Test
    void subcontractReceiptMustCarryItsApPostedMarker() {
        assertThatThrownBy(() -> ProcurementReturnPayableAuthority.lockAndValidate(
                mock(EntityManager.class), "SUBCONTRACT", UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID(), BigDecimal.ONE,
                UUID.randomUUID(), BigDecimal.ONE, BigDecimal.ONE, false))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("尚未标记应付已立账");
    }

    private static EntityManager em(List<Object[]> rows) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return em;
    }
}
