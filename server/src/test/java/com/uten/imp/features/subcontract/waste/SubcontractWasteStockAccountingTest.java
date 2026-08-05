package com.uten.imp.features.subcontract.waste;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SubcontractWasteStockAccountingTest {

    private SubcontractWasteRepository wasteRepo;
    private SubcontractWasteItemRepository itemRepo;
    private StockService stockService;
    private LinkedDocumentIntegrityService sourceIntegrity;
    private TxSessionVars tx;
    private EntityManager em;
    private SecurityContextCurrentUser currentUser;
    private EmployeeNameResolver nameResolver;
    private SubcontractWasteService service;
    private Query query;

    @BeforeEach
    void setUp() {
        wasteRepo = mock(SubcontractWasteRepository.class);
        itemRepo = mock(SubcontractWasteItemRepository.class);
        stockService = mock(StockService.class);
        sourceIntegrity = mock(LinkedDocumentIntegrityService.class);
        tx = mock(TxSessionVars.class);
        em = mock(EntityManager.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        nameResolver = mock(EmployeeNameResolver.class);
        query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(1); // CAS 守卫要求 UPDATE 命中 1 行（发料子件有余量）
        service = new SubcontractWasteService(
                wasteRepo,
                itemRepo,
                stockService,
                sourceIntegrity,
                tx,
                em,
                currentUser,
                nameResolver,
                mock(DocNumberService.class));
    }

    @Test
    void approvingSupplierWasteDoesNotDeductCompanyWarehouseTwice() {
        UUID documentId = UUID.randomUUID();
        SubcontractWaste document = document(documentId, (short) 0);
        SubcontractWasteItem item = item(documentId);
        when(em.find(SubcontractWaste.class, documentId,
                jakarta.persistence.LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(document);
        when(itemRepo.findByWasteIdOrderByLineNoAsc(documentId))
                .thenReturn(List.of(item));
        when(wasteRepo.findById(documentId)).thenReturn(Optional.of(document));
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());

        service.approve(documentId);

        verify(stockService, never()).lockInventory(any());
        verify(stockService, never()).recordMovement(any());
        verify(sourceIntegrity).validateSubcontractWaste(any(), any());
    }

    @Test
    void reversingHistoricalWasteRestoresOnlyItsRecordedWarehouseOutflow() {
        UUID documentId = UUID.randomUUID();
        SubcontractWaste document = document(documentId, (short) 1);
        SubcontractWasteItem item = item(documentId);
        when(em.find(SubcontractWaste.class, documentId,
                jakarta.persistence.LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(document);
        when(itemRepo.findByWasteIdOrderByLineNoAsc(documentId))
                .thenReturn(List.of(item));
        when(wasteRepo.findById(documentId)).thenReturn(Optional.of(document));
        when(query.getResultList()).thenReturn(List.of(item.getId()));

        service.reverse(documentId);

        verify(stockService).lockInventory(any());
        verify(stockService).recordMovement(any());
    }

    private static SubcontractWaste document(UUID id, short status) {
        SubcontractWaste document = new SubcontractWaste();
        document.setId(id);
        document.setBillNo("EW202608010001");
        document.setBillDate(LocalDate.of(2026, 8, 1));
        document.setSupplierId(UUID.randomUUID());
        document.setWarehouseId(UUID.randomUUID());
        document.setStatus(status);
        document.setTotalLocal(BigDecimal.ZERO);
        document.setTotalOriginal(BigDecimal.ZERO);
        return document;
    }

    private static SubcontractWasteItem item(UUID documentId) {
        SubcontractWasteItem item = new SubcontractWasteItem();
        item.setWasteId(documentId);
        item.setGoodsId(UUID.randomUUID());
        item.setUnitId(UUID.randomUUID());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.ONE);
        item.setMaterialIssueItemId(UUID.randomUUID());
        return item;
    }
}
