package com.uten.imp.features.sales.order;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.master.client.ClientDefaultTermsSyncService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesMasterReferenceValidator;
import com.uten.imp.features.sales.SalesMutationFootprintService;
import com.uten.imp.features.sales.order.dto.OrderListItem;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.sales.quote.SalesQuoteItemRepository;
import com.uten.imp.features.sales.quote.SalesQuoteRepository;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 销售订货「币种」表头筛选（2026-09-16）：currencyId 按订单表 currency_id 等值。
 * 订单表无仓库列（V51 起 sales_orders 只有 currency_id），故本参数族只有币种一列。
 */
class SalesOrderCurrencyFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void currencyIdFiltersByEqualOnCurrencyColumn() {
        SalesOrderRepository orderRepo = mock(SalesOrderRepository.class);
        when(orderRepo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        SalesDocumentAccessPolicy access = mock(SalesDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(mock(
                com.uten.imp.security.OwnerVisibility.OwnerScope.class,
                Answers.RETURNS_DEEP_STUBS));
        when(access.hasAuthority(any(String.class))).thenReturn(false);

        UUID currencyId = UUID.randomUUID();
        PageResponse<OrderListItem> page = service(orderRepo, access).list(
                new OrderQueryFilter(null, null, null, null,
                        LocalDate.of(2026, 9, 1), LocalDate.of(2026, 9, 30),
                        null, null, null, currencyId),
                1, 20, null, null);
        org.assertj.core.api.Assertions.assertThat(page.getItems()).isEmpty();

        ArgumentCaptor<Specification<SalesOrder>> captor =
                ArgumentCaptor.forClass(Specification.class);
        verify(orderRepo).findAll(captor.capture(), any(Pageable.class));
        Root<SalesOrder> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(cb).equal(any(), eq(currencyId));
        verify(root).get("currencyId");
    }

    private static SalesOrderService service(
            SalesOrderRepository orderRepo, SalesDocumentAccessPolicy access) {
        return new SalesOrderService(
                orderRepo,
                mock(SalesOrderItemRepository.class),
                mock(SalesOrderCostItemRepository.class),
                mock(StockReservationService.class),
                mock(PlanOrderItemLinkRepository.class),
                mock(SalesQuoteRepository.class),
                mock(SalesQuoteItemRepository.class),
                mock(SalesPriceMasker.class),
                access,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                mock(EntityManager.class),
                mock(SalesOrderPlanProgressQuery.class),
                mock(ChainNoticeService.class),
                mock(AuditService.class),
                mock(SalesMasterReferenceValidator.class),
                mock(TaskClaimService.class),
                mock(SalesOrderRevisionService.class),
                mock(SalesMutationFootprintService.class),
                mock(ClientDefaultTermsSyncService.class));
    }
}
