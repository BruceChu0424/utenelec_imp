package com.uten.imp.features.subcontract.order;

import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.dto.OrderQueryFilter;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Path;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 主类进行中必须先聚合再分页, 且始终保留可读范围及单据生命周期约束。 */
@ExtendWith(MockitoExtension.class)
@SuppressWarnings({"unchecked", "rawtypes"})
class SubcontractOrderInProgressFilterTest {
    @Mock private SubcontractOrderRepository repository;
    @Mock private ProcurementApprovalProjectionQuery approvals;
    @Mock private SubcontractDocumentAccessPolicy access;
    @InjectMocks private SubcontractOrderService service;

    @Test
    void includesPendingAndRejectedDraftsOrUnclosedApprovedOrdersBeforePagination() {
        verifyInProgress(Set.of(UUID.randomUUID()), Set.of(UUID.randomUUID()));
    }

    @Test
    void noFinanceCasesStillIncludesExecutingOrdersWithoutAnEmptyInClause() {
        verifyInProgress(Set.of(), Set.of());
    }

    private void verifyInProgress(Set<UUID> pending, Set<UUID> rejected) {
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        when(approvals.pendingOrderIds("SUBCONTRACT")).thenReturn(pending);
        when(approvals.rejectedOrderIds("SUBCONTRACT")).thenReturn(rejected);
        when(approvals.latestForOrders(eq("SUBCONTRACT"), any())).thenReturn(Map.of());
        var scope = new OwnerVisibility.OwnerScope(false, Set.of(UUID.randomUUID()));
        when(access.scope()).thenReturn(scope);

        service.list(new OrderQueryFilter(null, null, null, null, null, null, null,
                " in_progress "), 2, 20, "billDate", "asc");
        ArgumentCaptor<Specification<SubcontractOrder>> specification = ArgumentCaptor.forClass(Specification.class);
        ArgumentCaptor<Pageable> pageable = ArgumentCaptor.forClass(Pageable.class);
        verify(repository).findAll(specification.capture(), pageable.capture());
        assertThat(pageable.getValue().getPageNumber()).isEqualTo(1);
        assertThat(pageable.getValue().getPageSize()).isEqualTo(20);
        assertThat(pageable.getValue().getSort().getOrderFor("billDate").isAscending()).isTrue();

        Root<SubcontractOrder> root = mock(Root.class);
        CriteriaBuilder cb = mock(CriteriaBuilder.class);
        Path<Object> status = mock(Path.class);
        Path<Object> id = mock(Path.class);
        Path<Boolean> deleted = mock(Path.class);
        Path<Boolean> closed = mock(Path.class);
        when(root.get("status")).thenReturn(status);
        when(root.<Boolean>get("deleted")).thenReturn(deleted);
        when(root.<Boolean>get("closed")).thenReturn(closed);
        Predicate active = mock(Predicate.class);
        Predicate readable = mock(Predicate.class);
        Predicate approved = mock(Predicate.class);
        Predicate unclosed = mock(Predicate.class);
        Predicate executing = mock(Predicate.class);
        Predicate finance = mock(Predicate.class);
        Predicate progress = mock(Predicate.class);
        when(cb.isFalse(deleted)).thenReturn(active);
        when(access.readablePredicate(root, cb, "makerId", scope)).thenReturn(readable);
        when(cb.equal(status, (short) 1)).thenReturn(approved);
        when(cb.isFalse(closed)).thenReturn(unclosed);
        when(cb.and(approved, unclosed)).thenReturn(executing);
        Set<UUID> financeIds = new java.util.HashSet<>(pending);
        financeIds.addAll(rejected);
        if (financeIds.isEmpty()) {
            when(cb.disjunction()).thenReturn(finance);
        } else {
            Predicate draft = mock(Predicate.class);
            Predicate belongsToFinance = mock(Predicate.class);
            when(root.get("id")).thenReturn(id);
            when(cb.equal(status, (short) 0)).thenReturn(draft);
            when(id.in(financeIds)).thenReturn(belongsToFinance);
            when(cb.and(draft, belongsToFinance)).thenReturn(finance);
        }
        when(cb.or(finance, executing)).thenReturn(progress);

        specification.getValue().toPredicate(root, null, cb);
        verify(cb).or(finance, executing);
        verify(cb).and(new Predicate[]{active, readable, progress});
        if (financeIds.isEmpty()) verify(root, never()).get("id");
    }
}
