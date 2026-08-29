package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class StockBalanceWeightQueryTest {

    @Test
    void balanceRowsExposeWeightAndAcceptWeightSorting() {
        StockBalanceRepository balances = mock(StockBalanceRepository.class);
        StockMovementRepository movements = mock(StockMovementRepository.class);
        StockBalance balance = new StockBalance();
        balance.setQty(new BigDecimal("12.5000"));
        balance.setWeight(new BigDecimal("7.2500"));
        when(balances.findAll(
                any(Specification.class),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(balance)));
        StockCostMasker costMasker = mock(StockCostMasker.class);
        when(costMasker.canView()).thenReturn(true);

        StockQueryService service = new StockQueryService(
                balances, movements, mock(EntityManager.class), costMasker);

        var result = service.balances(
                null, null, 1, 20, "weight", "desc");

        assertThat(result.getItems()).hasSize(1);
        assertThat(result.getItems().getFirst().getQty())
                .isEqualByComparingTo("12.5000");
        assertThat(result.getItems().getFirst().getWeight())
                .isEqualByComparingTo("7.2500");

        var pageable = org.mockito.ArgumentCaptor.forClass(Pageable.class);
        verify(balances).findAll(
                any(Specification.class),
                pageable.capture());
        var weightOrder = pageable.getValue().getSort().getOrderFor("weight");
        assertThat(weightOrder).isNotNull();
        assertThat(weightOrder.getDirection())
                .isEqualTo(org.springframework.data.domain.Sort.Direction.DESC);
    }
}
