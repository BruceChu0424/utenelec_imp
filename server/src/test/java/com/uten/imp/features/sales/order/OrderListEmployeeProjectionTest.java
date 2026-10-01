package com.uten.imp.features.sales.order;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrder;
import com.uten.imp.features.subcontract.order.SubcontractOrderRepository;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Page mapping contract, complemented by actual Hibernate/PostgreSQL query budgets in EmployeeNameResolverBatchPostgresTest. */
@ExtendWith(MockitoExtension.class)
@SuppressWarnings({"unchecked", "rawtypes"})
class OrderListEmployeeProjectionTest {
    @Mock private SalesOrderRepository salesRepository;
    @Mock private PurchaseOrderRepository purchaseRepository;
    @Mock private SubcontractOrderRepository subcontractRepository;
    @Mock private SalesDocumentAccessPolicy salesAccess;
    @Mock private PurchaseDocumentAccessPolicy purchaseAccess;
    @Mock private SubcontractDocumentAccessPolicy subcontractAccess;
    @Mock private EmployeeNameResolver names;
    @Mock private ProcurementApprovalProjectionQuery approvals;
    @Mock private SalesPriceMasker salesPrices;
    @Mock private CommercialPriceVisibility commercialPrices;
    @InjectMocks private SalesOrderService sales;
    @InjectMocks private PurchaseOrderService purchase;
    @InjectMocks private SubcontractOrderService subcontract;

    @BeforeEach void scopes() {
        var scope = new OwnerVisibility.OwnerScope(false, Set.of(UUID.randomUUID()));
        lenient().when(salesAccess.scope()).thenReturn(scope);
        lenient().when(purchaseAccess.scope()).thenReturn(scope);
        lenient().when(subcontractAccess.scope()).thenReturn(scope);
        ReflectionTestUtils.setField(purchase, "commercialPriceVisibility", commercialPrices);
        ReflectionTestUtils.setField(subcontract, "commercialPriceVisibility", commercialPrices);
    }

    @Test void salesResolvesOnlyTheReturnedPageAndKeepsItsOrderNullIdsAndMasking() {
        UUID seller = UUID.randomUUID(), unknown = UUID.randomUUID();
        List<SalesOrder> rows = List.of(sale(seller), sale(null), sale(seller), sale(unknown));
        when(salesRepository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(rows, PageRequest.of(1, 4), 200));
        // The null-id row must not call get(null) even when an implementation returns Map.of.
        when(names.namesOf(anyCollection())).thenReturn(Map.of(seller, "本页业务员"));
        var result = sales.list(new OrderQueryFilter(null, null, null, null, null, null, null, null),
                2, 4, "billDate", "asc");
        ArgumentCaptor<Collection<UUID>> requested = ArgumentCaptor.forClass(Collection.class);
        verify(names).namesOf(requested.capture());
        assertThat(requested.getValue()).containsExactly(seller, null, seller, unknown);
        verify(names, never()).nameOf(any());
        verify(names, never()).resolveForWrite(any(), any(), any(), any());
        assertThat(result.getItems()).extracting(row -> row.getId())
                .containsExactlyElementsOf(rows.stream().map(SalesOrder::getId).toList());
        assertThat(result.getItems()).extracting(row -> row.getSellerName())
                .containsExactly("本页业务员", null, "本页业务员", null);
        assertThat(result.getItems()).allSatisfy(row -> {
            assertThat(row.isPriceMasked()).isTrue();
            assertThat(row.getTotalOriginal()).isNull();
        });
        assertThat(result.getPage()).isEqualTo(2);
        assertThat(result.getSize()).isEqualTo(4);
        assertThat(result.getTotal()).isEqualTo(200);
    }

    @Test void emptySalesPageDoesNotAttemptScalarOrWriteResolution() {
        when(salesRepository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(), PageRequest.of(0, 20), 0));
        var result = sales.list(new OrderQueryFilter(null, null, null, null, null, null, null, null),
                1, 20, null, null);
        assertThat(result.getItems()).isEmpty();
        verifyNoInteractions(names);
    }

    @Test void purchaseListPassesThroughApprovalSnapshotsWithoutLookingUpEmployees() {
        PurchaseOrder first = new PurchaseOrder(); first.setId(UUID.randomUUID()); first.setStatus((short) 0);
        PurchaseOrder second = new PurchaseOrder(); second.setId(UUID.randomUUID()); second.setStatus((short) 0);
        Map<UUID, FinanceApproval> snapshots = Map.of(first.getId(), approval("审批时姓名"), second.getId(), approval(null));
        when(purchaseRepository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(first, second), PageRequest.of(0, 20), 2));
        when(approvals.latestForOrders(eq("PURCHASE"), anyMap())).thenReturn(snapshots);
        var result = purchase.list(new com.uten.imp.features.purchase.order.dto.OrderQueryFilter(
                null, null, null, null, null, null, null), 1, 20, null, null);
        assertThat(result.getItems().get(0).getFinanceApproval()).isSameAs(snapshots.get(first.getId()));
        assertThat(result.getItems().get(1).getFinanceApproval().assigneeName()).isNull();
        verify(approvals).latestForOrders("PURCHASE", Map.of(first.getId(), (short) 0, second.getId(), (short) 0));
        verifyNoInteractions(names);
    }

    @Test void subcontractListPassesThroughApprovalSnapshotsWithoutLookingUpEmployees() {
        SubcontractOrder first = new SubcontractOrder(); first.setId(UUID.randomUUID()); first.setStatus((short) 0);
        SubcontractOrder second = new SubcontractOrder(); second.setId(UUID.randomUUID()); second.setStatus((short) 0);
        Map<UUID, FinanceApproval> snapshots = Map.of(first.getId(), approval("审批时姓名"), second.getId(), approval(null));
        when(subcontractRepository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(first, second), PageRequest.of(0, 20), 2));
        when(approvals.latestForOrders(eq("SUBCONTRACT"), anyMap())).thenReturn(snapshots);
        var result = subcontract.list(new com.uten.imp.features.subcontract.order.dto.OrderQueryFilter(
                null, null, null, null, null, null, null, null), 1, 20, null, null);
        assertThat(result.getItems().get(0).getFinanceApproval()).isSameAs(snapshots.get(first.getId()));
        assertThat(result.getItems().get(1).getFinanceApproval().assigneeName()).isNull();
        verify(approvals).latestForOrders("SUBCONTRACT", Map.of(first.getId(), (short) 0, second.getId(), (short) 0));
        verifyNoInteractions(names);
    }

    private static SalesOrder sale(UUID seller) {
        SalesOrder order = new SalesOrder();
        order.setId(UUID.randomUUID());
        order.setSellerId(seller);
        order.setStatus((short) 0);
        order.setTotalOriginal(new BigDecimal("123.45"));
        return order;
    }

    private static FinanceApproval approval(String name) {
        return new FinanceApproval(UUID.randomUUID(), "PENDING", 2, 4,
                UUID.randomUUID(), UUID.randomUUID(), name, null, null, List.of());
    }
}
