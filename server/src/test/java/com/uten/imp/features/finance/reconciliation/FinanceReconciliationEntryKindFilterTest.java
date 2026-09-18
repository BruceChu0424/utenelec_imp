package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationListItem;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationQueryFilter;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 账户流水「流水类型」表头筛选（2026-09-16）：entryKind 按
 * finance_reconciliations.entry_kind 等值（POSTING 入账 / REVERSAL 反向冲销 / ADJUSTMENT 余额调整）。
 */
class FinanceReconciliationEntryKindFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void entryKindFiltersByEqualOnEntryKindColumn() {
        FinanceReconciliationRepository repo = mock(FinanceReconciliationRepository.class);
        when(repo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));

        PageResponse<FinanceReconciliationListItem> page =
                new FinanceReconciliationService(repo).list(
                        new FinanceReconciliationQueryFilter(
                                null, null, null, null, null, null, null, "POSTING"),
                        1, 20, null, null);
        org.assertj.core.api.Assertions.assertThat(page.getItems()).isEmpty();

        ArgumentCaptor<Specification<FinanceReconciliation>> captor =
                ArgumentCaptor.forClass(Specification.class);
        verify(repo).findAll(captor.capture(), any(Pageable.class));
        Root<FinanceReconciliation> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(cb).equal(any(), eq("POSTING"));
        verify(root).get("entryKind");
    }
}
