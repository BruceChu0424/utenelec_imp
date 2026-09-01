package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementCommercialSnapshotPolicyTest {

    @Test
    void completeActiveSnapshotIsAccepted() {
        EntityManager em = entityManagerReturning(1L);

        assertThatCode(() -> ProcurementCommercialSnapshotPolicy.requireComplete(
                em, UUID.randomUUID(), new BigDecimal("7.123456"),
                new BigDecimal("13"), "委外订货"))
                .doesNotThrowAnyException();
    }

    @Test
    void missingOrOutOfRangeMoneyIdentityFailsBeforeFinanceReview() {
        EntityManager em = mock(EntityManager.class);
        assertThatThrownBy(() -> ProcurementCommercialSnapshotPolicy.requireComplete(
                em, null, BigDecimal.ONE, BigDecimal.ZERO, "采购订货"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("必须选择币种");
        assertThatThrownBy(() -> ProcurementCommercialSnapshotPolicy.requireComplete(
                em, UUID.randomUUID(), null, BigDecimal.ZERO, "采购订货"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("汇率必须大于0");
        assertThatThrownBy(() -> ProcurementCommercialSnapshotPolicy.requireComplete(
                em, UUID.randomUUID(), BigDecimal.ONE, null, "采购订货"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("税率必须明确填写");
        assertThatThrownBy(() -> ProcurementCommercialSnapshotPolicy.requireComplete(
                em, UUID.randomUUID(), BigDecimal.ONE, new BigDecimal("100.0001"),
                "采购订货"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("0至100");
    }

    @Test
    void inactiveCurrencyFailsClosed() {
        EntityManager em = entityManagerReturning(0L);

        assertThatThrownBy(() -> ProcurementCommercialSnapshotPolicy.requireComplete(
                em, UUID.randomUUID(), BigDecimal.ONE, BigDecimal.ZERO, "委外订货"))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("币种不存在、已停用");
                });
    }

    private static EntityManager entityManagerReturning(long count) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getSingleResult()).thenReturn(count);
        return em;
    }
}
