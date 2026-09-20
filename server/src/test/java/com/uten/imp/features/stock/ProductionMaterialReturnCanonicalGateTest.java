package com.uten.imp.features.stock;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** The generic warehouse CRUD API cannot form a second material-return protocol. */
@ExtendWith(MockitoExtension.class)
class ProductionMaterialReturnCanonicalGateTest {
    @Mock EntityManager em;
    @Mock StockDocumentRepository documents;
    @Mock StockDocumentItemRepository items;
    @Mock StockBalanceAdjustmentCommandRepository adjustments;
    @Mock StockDocAccessPolicy access;
    @Mock TxSessionVars tx;
    @Mock TaskClaimService claims;
    @Mock FulfillmentMutationLocks locks;
    @Mock ProductionMutationFootprintPort footprints;
    @Mock ProductionMaterialStockLedgerService ledger;
    @InjectMocks StockDocService service;

    @Test
    void genericCreateRejectsMaterialReturnBeforeWritingAnything() {
        var request=new StockDocSaveRequest();request.setDocType("WDRAW");
        ApiException error=assertThrows(ApiException.class,()->service.create(request));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
        assertTrue(error.getMessage().contains("车间任务"));
        verifyNoInteractions(tx,documents,items,em,ledger);
    }

    @ParameterizedTest
    @CsvSource({"WDRAW,WDRAW","WDRAW,OTHER_IN","OTHER_IN,WDRAW"})
    void genericEditCannotChangeOrDisguiseMaterialReturn(String originalType,String requestedType) {
        StockDocument document=document(originalType);
        when(em.find(StockDocument.class,document.getId(),LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        var request=new StockDocSaveRequest();request.setDocType(requestedType);
        ApiException error=assertThrows(ApiException.class,()->service.update(document.getId(),request));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
        assertEquals(originalType,document.getDocType());
        verifyNoInteractions(documents,items,ledger);
    }

    @Test
    void genericApprovalRejectsUnrequestedMaterialReturnBeforeStockOrLedgerChanges() {
        Query empty=mock(Query.class);
        when(empty.setParameter(anyString(),any())).thenReturn(empty);
        when(empty.getResultList()).thenReturn(java.util.List.of());
        doReturn(empty).when(em).createNativeQuery(anyString(),eq(UUID.class));
        when(locks.acquire(any())).thenReturn(mock(FulfillmentMutationLocks.Guard.class));
        StockDocument document=document("WDRAW");
        when(em.find(StockDocument.class,document.getId(),LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        Query absent=mock(Query.class);
        when(absent.setParameter("id",document.getId())).thenReturn(absent);
        when(absent.getSingleResult()).thenReturn(false);
        doReturn(absent).when(em).createNativeQuery(contains("fn_is_production_linked_stock_document"));
        doReturn(absent).when(em).createNativeQuery(contains("fn_is_production_material_return_request"));
        ApiException error=assertThrows(ApiException.class,()->service.approve(document.getId()));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
        assertTrue(error.getMessage().contains("没有正式材料来源申请"));
        assertEquals((short)0,document.getStatus());
        verifyNoInteractions(documents,items,ledger);
    }

    private static StockDocument document(String type) {
        StockDocument document=new StockDocument();document.setId(UUID.randomUUID());
        document.setDocType(type);document.setStatus((short)0);return document;
    }
}
