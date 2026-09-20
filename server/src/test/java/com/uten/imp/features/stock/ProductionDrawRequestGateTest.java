package com.uten.imp.features.stock;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Optional;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProductionDrawRequestGateTest {
    @Mock EntityManager em;
    @Mock StockDocumentRepository docRepo;
    @Mock StockDocumentItemRepository itemRepo;
    @Mock ProductionMaterialStockLedgerService productionMaterialLedger;
    @Mock FulfillmentMutationLocks mutationLocks;
    @Mock ProductionMutationFootprintPort mutationFootprints;
    @Mock TxSessionVars tx;
    @Mock StockDocAccessPolicy access;
    @Mock SecurityContextCurrentUser currentUser;
    @Mock ProductionStockTaskAccessPolicy productionStockTaskAccess;
    @InjectMocks StockDocService service;

    @Test
    void internalDrawCannotBeOpenedThroughWarehouseDetail() {
        StockDocument draw = unrequestedDraw();
        when(docRepo.findById(draw.getId())).thenReturn(Optional.of(draw));

        assertThatThrownBy(() -> service.detail(draw.getId()))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND));

        verifyNoInteractions(itemRepo, productionMaterialLedger);
    }

    @Test
    void directApproveAndIssueRejectsBeforeAnyApprovalOrMaterialPosting() {
        emptyExecutionGraph();
        StockDocument draw = unrequestedDraw();
        when(mutationLocks.acquire(any())).thenReturn(mock(FulfillmentMutationLocks.Guard.class));
        when(em.find(StockDocument.class, draw.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(draw);

        assertThatThrownBy(() -> service.approveAndIssue(draw.getId(), new StockDocIssueRequest()))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("车间尚未提交领料申请");
                });

        assertThat(draw.getStatus()).isZero();
        verify(docRepo, never()).save(any());
        verifyNoInteractions(itemRepo, productionMaterialLedger);
    }

    @Test
    void directIssueOfPreviouslyApprovedButUnrequestedDrawStillRejects() {
        emptyExecutionGraph();
        StockDocument draw = unrequestedDraw();
        draw.setStatus((short) 1);
        when(mutationLocks.acquire(any())).thenReturn(mock(FulfillmentMutationLocks.Guard.class));
        when(em.find(StockDocument.class, draw.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(draw);
        Query provenance = mock(Query.class);
        doReturn(provenance).when(em).createNativeQuery(contains("fn_is_production_linked_stock_document"));
        when(provenance.setParameter("id", draw.getId())).thenReturn(provenance);
        when(provenance.getSingleResult()).thenReturn(true);
        when(access.hasAuthority("stock_doc:issue")).thenReturn(true);
        Query warehouse=mock(Query.class);
        doReturn(warehouse).when(em).createNativeQuery(contains("FROM warehouses WHERE id=:id AND is_line_side"));
        when(warehouse.setParameter("id",draw.getWarehouseId())).thenReturn(warehouse);
        when(warehouse.getSingleResult()).thenReturn(false);

        assertThatThrownBy(() -> service.issue(draw.getId(), new StockDocIssueRequest()))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("车间尚未提交领料申请");
                });

        verify(docRepo, never()).save(any());
        verifyNoInteractions(itemRepo, productionMaterialLedger);
    }

    @Test
    void batchIssueRejectsUnrequestedDocumentBeforeReadingItsMaterialRows() {
        emptyExecutionGraph();
        StockDocument draw = unrequestedDraw();
        draw.setBillNo("LL-REQUEST-GATE");
        when(mutationLocks.acquire(any())).thenReturn(mock(FulfillmentMutationLocks.Guard.class));
        when(em.find(StockDocument.class, draw.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(draw);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(access.hasAuthority("stock_doc:approve")).thenReturn(true);
        Query header = mock(Query.class);
        doReturn(header).when(em).createNativeQuery(contains("SELECT bill_no, doc_type, status"));
        when(header.setParameter("id", draw.getId())).thenReturn(header);
        when(header.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{draw.getBillNo(), "DRAW", (short) 0}));
        StockDocIssueBatchRequest request = new StockDocIssueBatchRequest();
        request.setIdempotencyKey("unrequested-batch-001");
        request.setDocIds(List.of(draw.getId()));

        assertThatThrownBy(() -> service.issueFullBatch(request))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("LL-REQUEST-GATE", "车间尚未提交领料申请");
                });

        assertThat(draw.getStatus()).isZero();
        verify(docRepo, never()).save(any());
        verifyNoInteractions(itemRepo, productionMaterialLedger);
    }

    private void emptyExecutionGraph() {
        Query empty = mock(Query.class);
        when(empty.setParameter(anyString(), any())).thenReturn(empty);
        when(empty.getResultList()).thenReturn(List.of());
        doReturn(empty).when(em).createNativeQuery(anyString(), eq(UUID.class));
    }

    private StockDocument unrequestedDraw() {
        StockDocument draw = new StockDocument();
        draw.setId(UUID.randomUUID());
        draw.setDocType("DRAW");
        draw.setWarehouseId(UUID.randomUUID());
        draw.setStatus((short) 0);
        Query gate = mock(Query.class);
        doReturn(gate).when(em).createNativeQuery(contains("fn_production_draw_requested"));
        when(gate.setParameter("documentId", draw.getId())).thenReturn(gate);
        when(gate.getSingleResult()).thenReturn(false);
        return draw;
    }
}
