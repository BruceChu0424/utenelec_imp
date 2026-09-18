package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.master.client.ClientShipAddressService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesMutationFootprintService;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.features.stock.StockService;
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

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 销售出货「币种」表头筛选（2026-09-16）：ShipmentQueryFilter 增 currencyId，
 * 按 sales_shipments.currency_id 等值（客户零星发货段共用 /shipments 端点同享该参数）。
 */
class SalesShipmentCurrencyFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void currencyIdFiltersByEqualOnCurrencyColumn() {
        SalesShipmentRepository shipmentRepo = mock(SalesShipmentRepository.class);
        when(shipmentRepo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        SalesDocumentAccessPolicy access = mock(SalesDocumentAccessPolicy.class);
        // scope()/readablePredicate() 返回 null 也不影响：空页不触发逐单映射，
        // cb 为深桩对 null 入参同样给出桩值。
        lenient().when(access.scope(anyString())).thenReturn(null);
        CustomerShipmentPolicy policy = mock(CustomerShipmentPolicy.class);
        lenient().when(policy.has(anyString())).thenReturn(false);
        lenient().when(policy.can(anyString(), anyString())).thenReturn(false);

        UUID currencyId = UUID.randomUUID();
        PageResponse<ShipmentListItem> page = service(shipmentRepo, access, policy).list(
                new ShipmentQueryFilter(null, null, null, null, null, null, null,
                        null, LocalDate.of(2026, 9, 1), LocalDate.of(2026, 9, 30),
                        null, currencyId),
                1, 20, null, null);
        assertThat(page.getItems()).isEmpty();

        ArgumentCaptor<Specification<SalesShipment>> captor =
                ArgumentCaptor.forClass(Specification.class);
        verify(shipmentRepo).findAll(captor.capture(), any(Pageable.class));
        Root<SalesShipment> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(cb).equal(any(), eq(currencyId));
        verify(root).get("currencyId");
    }

    private static SalesShipmentService service(
            SalesShipmentRepository shipmentRepo,
            SalesDocumentAccessPolicy access,
            CustomerShipmentPolicy policy) {
        return new SalesShipmentService(
                shipmentRepo,
                mock(SalesShipmentItemRepository.class),
                mock(StockService.class),
                mock(StockReservationService.class),
                mock(ArApLedgerService.class),
                mock(TxSessionVars.class),
                mock(EntityManager.class),
                mock(DocNumberService.class),
                access,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(ClientShipAddressService.class),
                mock(SalesMutationFootprintService.class),
                policy,
                mock(DirectCustomerShipmentCommercialService.class),
                mock(SalesShipmentReviewSnapshotService.class),
                mock(com.uten.imp.application.port.CustomerShipmentInventoryPort.class),
                mock(TaskClaimService.class));
    }
}
