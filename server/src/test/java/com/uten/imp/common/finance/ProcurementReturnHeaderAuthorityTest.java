package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementReturnHeaderAuthorityTest {

    @Test
    void derivesCompleteHeaderWithoutAnyClientCommercialFields() {
        UUID supplier = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        Fixture fixture = fixture(List.of(
                new Object[]{first, supplier, currency, new BigDecimal("7.1"),
                        new BigDecimal("13"), settlement, 6},
                new Object[]{second, supplier, currency, new BigDecimal("7.10"),
                        new BigDecimal("13.0"), settlement, 6}));

        var header = ProcurementReturnHeaderAuthority.derive(
                fixture.em(), "PURCHASE", List.of(first, second));

        assertThat(header.supplierId()).isEqualTo(supplier);
        assertThat(header.exchangeRate()).isEqualByComparingTo("7.1");
        assertThat(header.taxRate()).isEqualByComparingTo("13");
        assertThat(header.settlementMethodId()).isEqualTo(settlement);
        assertThat(fixture.sql().get()).contains("FOR SHARE OF receipt_item,receipt");
    }

    @Test
    void mixedCurrencyTaxOrSettlementFailsClosed() {
        UUID supplier = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        Fixture fixture = fixture(List.of(
                new Object[]{first, supplier, UUID.randomUUID(), BigDecimal.ONE,
                        new BigDecimal("13"), UUID.randomUUID(), null},
                new Object[]{second, supplier, UUID.randomUUID(), BigDecimal.ONE,
                        new BigDecimal("9"), UUID.randomUUID(), null}));

        assertThatThrownBy(() -> ProcurementReturnHeaderAuthority.derive(
                fixture.em(), "SUBCONTRACT", List.of(first, second)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("相同供应商、币种、汇率、税率和结算方式");
    }

    @Test
    void missingOrDuplicateReceiptItemIdentityFailsBeforeDraftCreation() {
        UUID id = UUID.randomUUID();
        assertThatThrownBy(() -> ProcurementReturnHeaderAuthority.derive(
                mock(EntityManager.class), "PURCHASE", List.of(id, id)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("唯一关联来源收货明细");
    }

    private static Fixture fixture(List<Object[]> rows) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        AtomicReference<String> sql = new AtomicReference<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sql.set(invocation.getArgument(0));
            return query;
        });
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return new Fixture(em, sql);
    }

    private record Fixture(EntityManager em, AtomicReference<String> sql) {
    }
}
