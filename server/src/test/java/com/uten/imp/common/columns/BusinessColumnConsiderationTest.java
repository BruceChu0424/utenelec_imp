package com.uten.imp.common.columns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class BusinessColumnConsiderationTest {
    @Test void totalModeKeepsTheExactConsiderationWhenTheFeeChangesOrIsCleared() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        UUID columnId = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                columnId, "purchase_order", "运费", "AMOUNT", "ADD", 0L}));
        BusinessColumnService columns = new BusinessColumnService(
                em, mock(SecurityContextCurrentUser.class), new ObjectMapper());
        BigDecimal qty = new BigDecimal("3");
        BigDecimal total = new BigDecimal("10");
        BigDecimal referencePrice = MoneyPolicy.referenceUnitPrice(total, qty);
        assertThat(referencePrice).isEqualByComparingTo("3.3333333333");
        BigDecimal base = MoneyPolicy.orderBaseAmount(qty, referencePrice, total);
        List<ExtraColumnSnapshot> stored = List.of();
        for (String value : List.of("0.000000000000000000000000000001", "2", "")) {
            stored = columns.resolve("purchase_order", List.of(new ExtraColumnInput(columnId, value)), stored, false);
            BigDecimal amount = ExtraColumnCalculator.apply(base, stored);
            assertThat(amount).isEqualByComparingTo(total.add(value.isEmpty() ? BigDecimal.ZERO : new BigDecimal(value)));
        }
        assertThat(stored.getFirst().value()).isNull();
        assertThat(base).isEqualByComparingTo(total);
    }

    @Test void splitReceiptsAllocateTheAgreedFeeOnceAndReconcileToTheExactSourceTotal() {
        BigDecimal base = MoneyPolicy.orderBaseAmount(new BigDecimal("3"), new BigDecimal("3.3333333333"), new BigDecimal("10"));
        BigDecimal original = ExtraColumnCalculator.apply(base, List.of(new ExtraColumnSnapshot(
                UUID.randomUUID(), "运费", "AMOUNT", "ADD", "2")));
        BigDecimal local = MoneyPolicy.local(original, new BigDecimal("7.123456"));
        BigDecimal receivedOriginal = BigDecimal.ZERO;
        BigDecimal receivedLocal = BigDecimal.ZERO;
        for (int index = 0; index < 3; index++) {
            MoneyPolicy.LineAmounts batch = MoneyPolicy.prorateBatch(BigDecimal.ONE, BigDecimal.valueOf(index),
                    new BigDecimal("3"), original, local, receivedOriginal, receivedLocal);
            receivedOriginal = receivedOriginal.add(batch.original());
            receivedLocal = receivedLocal.add(batch.local());
        }
        assertThat(receivedOriginal).isEqualByComparingTo("12");
        assertThat(receivedLocal).isEqualByComparingTo(local);
    }
}
