package com.uten.imp.features.stock;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService;
import com.uten.imp.application.port.ProductionCompletionReversePort;
import com.uten.imp.features.stock.dto.StockDocListItem;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
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

import java.util.List;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 仓库单据「调入仓」表头筛选（2026-09-16）：toWarehouseId 按转仓类单据
 * stock_documents.to_warehouse_id 等值（仅 TRANSFER 段前端开放该列）。
 */
class StockDocToWarehouseFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void toWarehouseIdFiltersByEqualOnToWarehouseColumn() {
        StockDocumentRepository docRepo = mock(StockDocumentRepository.class);
        when(docRepo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        StockDocAccessPolicy access = mock(StockDocAccessPolicy.class);
        lenient().when(access.scope()).thenReturn(mock(
                com.uten.imp.security.OwnerVisibility.OwnerScope.class,
                Answers.RETURNS_DEEP_STUBS));
        lenient().when(access.hasAuthority(anyString())).thenReturn(false);
        ProductionStockTaskAccessPolicy taskAccess =
                mock(ProductionStockTaskAccessPolicy.class);
        lenient().when(taskAccess.canAccessWarehouseTasks()).thenReturn(false);

        UUID toWarehouseId = UUID.randomUUID();
        PageResponse<StockDocListItem> page = service(docRepo, access, taskAccess).list(
                new StockDocQueryFilter("TRANSFER", null, null, null, null, null,
                        null, null, null, toWarehouseId),
                1, 20, null, null);
        org.assertj.core.api.Assertions.assertThat(page.getItems()).isEmpty();

        ArgumentCaptor<Specification<StockDocument>> captor =
                ArgumentCaptor.forClass(Specification.class);
        verify(docRepo).findAll(captor.capture(), any(Pageable.class));
        Root<StockDocument> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(cb).equal(any(), eq(toWarehouseId));
        verify(root).get("toWarehouseId");
    }

    private static StockDocService service(
            StockDocumentRepository docRepo,
            StockDocAccessPolicy access,
            ProductionStockTaskAccessPolicy taskAccess) {
        return new StockDocService(
                docRepo,
                mock(StockBalanceAdjustmentCommandRepository.class),
                mock(StockDocumentItemRepository.class),
                mock(StockBalanceRepository.class),
                mock(StockService.class),
                mock(StockReservationService.class),
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                mock(EntityManager.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(ProductionMaterialStockLedgerService.class),
                mock(ProductionCompletionReversePort.class),
                mock(TaskClaimService.class),
                access,
                taskAccess,
                mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class),
                mock(FulfillmentMutationLocks.class),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
    }
}
