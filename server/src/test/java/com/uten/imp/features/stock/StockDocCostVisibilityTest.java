package com.uten.imp.features.stock;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class StockDocCostVisibilityTest {

    private final StockDocumentRepository documents = mock(StockDocumentRepository.class);
    private final StockBalanceAdjustmentCommandRepository balanceAdjustmentCommands =
            mock(StockBalanceAdjustmentCommandRepository.class);
    private final StockDocumentItemRepository items = mock(StockDocumentItemRepository.class);
    private final StockDocAccessPolicy access = mock(StockDocAccessPolicy.class);
    private final Query nativeQuery = mock(Query.class);
    private final EntityManager entityManager = stubbedEntityManager(nativeQuery);

    @Test
    void viewerWithoutCostPermissionGetsMaskedListAndDetail() {
        StockDocument document = document();
        StockDocumentItem item = item(document.getId());
        stubDocumentReads(document, item);

        StockDocService service = service(false);
        var listRow = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();
        var detail = service.detail(document.getId());

        assertNull(listRow.getTotalLocal());
        assertTrue(listRow.isCostMasked());
        assertNull(detail.getTotalOriginal());
        assertNull(detail.getTotalLocal());
        assertTrue(detail.isCostMasked());
        assertNull(detail.getItems().getFirst().getPrice());
        assertNull(detail.getItems().getFirst().getAmountOriginal());
        assertNull(detail.getItems().getFirst().getAmountLocal());
        assertTrue(detail.getItems().getFirst().isCostMasked());
        assertEquals(item.getQty(), detail.getItems().getFirst().getQty());
        assertEquals(item.getWeight(), detail.getItems().getFirst().getWeight());
    }

    @Test
    void viewerWithCostPermissionKeepsListAndDetailAmounts() {
        StockDocument document = document();
        StockDocumentItem item = item(document.getId());
        stubDocumentReads(document, item);

        StockDocService service = service(true);
        var listRow = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();
        var detail = service.detail(document.getId());

        assertEquals(document.getTotalLocal(), listRow.getTotalLocal());
        assertFalse(listRow.isCostMasked());
        assertEquals(document.getTotalOriginal(), detail.getTotalOriginal());
        assertEquals(document.getTotalLocal(), detail.getTotalLocal());
        assertFalse(detail.isCostMasked());
        assertEquals(item.getPrice(), detail.getItems().getFirst().getPrice());
        assertEquals(item.getAmountOriginal(), detail.getItems().getFirst().getAmountOriginal());
        assertEquals(item.getAmountLocal(), detail.getItems().getFirst().getAmountLocal());
        assertFalse(detail.getItems().getFirst().isCostMasked());
    }

    @Test
    void viewerWithoutCostPermissionCannotSortDocumentsByTotal() {
        ApiException error = assertThrows(
                ApiException.class,
                () -> service(false).list(emptyFilter(), 1, 20, "total", "desc"));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
    }

    @ParameterizedTest
    @ValueSource(strings = {"price", "amountOriginal", "amountLocal"})
    void viewerWithoutCostPermissionCannotBlindWriteMoneyFields(String field) {
        StockDocItemLine line = quantityLine();
        switch (field) {
            case "price" -> line.setPrice(new BigDecimal("10.00"));
            case "amountOriginal" -> line.setAmountOriginal(new BigDecimal("100.00"));
            case "amountLocal" -> line.setAmountLocal(new BigDecimal("123.45"));
            default -> throw new IllegalArgumentException(field);
        }

        ApiException error = assertThrows(
                ApiException.class,
                () -> service(false).create(request(line)));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
    }

    @Test
    void viewerWithoutCostPermissionCanStillCreatePureQuantityDocument() {
        StockDocItemLine line = quantityLine();
        UUID baseUnitId = UUID.randomUUID();
        Query unitBasis = mock(Query.class);
        when(unitBasis.setParameter(org.mockito.ArgumentMatchers.anyString(), any())).thenReturn(unitBasis);
        when(unitBasis.getResultList()).thenReturn(List.<Object[]>of(new Object[]{false, baseUnitId, false}));
        when(entityManager.createNativeQuery(org.mockito.ArgumentMatchers.contains("SELECT g.is_deleted, u.id")))
                .thenReturn(unitBasis);
        Query goodsSnapshot = mock(Query.class);
        when(goodsSnapshot.setParameter(org.mockito.ArgumentMatchers.anyString(), any())).thenReturn(goodsSnapshot);
        when(goodsSnapshot.getResultList()).thenReturn(
                List.<Object[]>of(new Object[]{line.getGoodsId(), "G-001", "纯数量货品"}));
        when(entityManager.createNativeQuery(org.mockito.ArgumentMatchers.contains("SELECT goods.id, goods.code, goods.name")))
                .thenReturn(goodsSnapshot);

        var detail = assertDoesNotThrow(() -> service(false).create(request(line)));

        assertTrue(detail.isCostMasked());
        assertEquals(line.getQty(), detail.getItems().getFirst().getQty());
        assertNull(detail.getItems().getFirst().getPrice());
        assertNull(detail.getItems().getFirst().getAmountOriginal());
        assertNull(detail.getItems().getFirst().getAmountLocal());
    }

    @Test
    void viewerWithoutCostPermissionCannotBlindWriteMoneyOnUpdate() {
        StockDocument document = document();
        when(documents.findById(document.getId())).thenReturn(Optional.of(document));
        when(entityManager.find(
                StockDocument.class,
                document.getId(),
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        StockDocItemLine line = quantityLine();
        line.setAmountLocal(new BigDecimal("123.45"));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service(false).update(document.getId(), request(line)));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
    }

    @Test
    void viewerWithoutCostPermissionCannotClearStoredCostsByMaskedUpdate() {
        StockDocument document = document();
        StockDocumentItem storedItem = item(document.getId());
        when(entityManager.find(
                StockDocument.class,
                document.getId(),
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(items.findByDocIdOrderByLineNoAsc(any(UUID.class)))
                .thenReturn(List.of(storedItem));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service(false).update(
                        document.getId(), request(quantityLine())));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode(), error.getMessage());
        verify(items, never()).deleteByDocId(document.getId());
    }

    private void stubDocumentReads(StockDocument document, StockDocumentItem item) {
        when(documents.findAll(
                org.mockito.ArgumentMatchers.<Specification<StockDocument>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(document)));
        when(documents.findById(document.getId())).thenReturn(Optional.of(document));
        when(items.findByDocIdOrderByLineNoAsc(document.getId())).thenReturn(List.of(item));
        when(balanceAdjustmentCommands.existsByStockDocumentId(document.getId())).thenReturn(false);
    }

    private StockDocService service(boolean canViewCost) {
        when(access.hasAuthority(StockCostMasker.PERMISSION)).thenReturn(canViewCost);
        return new StockDocService(
                documents,
                balanceAdjustmentCommands,
                items,
                mock(StockBalanceRepository.class),
                mock(StockService.class),
                mock(StockReservationService.class),
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                entityManager,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService.class),
                mock(com.uten.imp.application.port.ProductionCompletionReversePort.class),
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                access,
                mock(ProductionStockTaskAccessPolicy.class),
                mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class),
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
    }

    private static EntityManager stubbedEntityManager(Query query) {
        EntityManager entityManager = mock(EntityManager.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(false);
        when(query.getResultList()).thenReturn(List.of());
        return entityManager;
    }

    private static StockDocSaveRequest request(StockDocItemLine line) {
        StockDocSaveRequest request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(LocalDate.of(2026, 8, 27));
        request.setWarehouseId(UUID.randomUUID());
        request.setItems(List.of(line));
        return request;
    }

    private static StockDocItemLine quantityLine() {
        StockDocItemLine line = new StockDocItemLine();
        line.setLineNo(1);
        line.setGoodsId(UUID.randomUUID());
        line.setQty(new BigDecimal("10"));
        return line;
    }

    private static StockDocument document() {
        StockDocument document = new StockDocument();
        document.setId(UUID.randomUUID());
        document.setDocType("OTHER_IN");
        document.setBillNo("OI-001");
        document.setBillDate(LocalDate.of(2026, 8, 27));
        document.setWarehouseId(UUID.randomUUID());
        document.setTotalOriginal(new BigDecimal("100.00"));
        document.setTotalLocal(new BigDecimal("123.45"));
        document.setStatus((short) 0);
        return document;
    }

    private static StockDocumentItem item(UUID documentId) {
        StockDocumentItem item = new StockDocumentItem();
        item.setId(UUID.randomUUID());
        item.setDocId(documentId);
        item.setLineNo(1);
        item.setGoodsId(UUID.randomUUID());
        item.setQty(new BigDecimal("10"));
        item.setBaseQty(new BigDecimal("10"));
        item.setPrice(new BigDecimal("10.00"));
        item.setAmountOriginal(new BigDecimal("100.00"));
        item.setAmountLocal(new BigDecimal("123.45"));
        item.setWeight(new BigDecimal("2.5"));
        return item;
    }

    private static StockDocQueryFilter emptyFilter() {
        return new StockDocQueryFilter(
                null, null, null, null, null, null, null, null);
    }
}
