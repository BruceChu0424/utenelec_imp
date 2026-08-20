package com.uten.imp.features.subcontract.material_return;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SubcontractMaterialReturnAuthorityTest {

    @Test
    void approvalUpdatesOnlyTheSourceIssueItemDispositionCounter() {
        SubcontractMaterialReturnRepository returnRepo =
                mock(SubcontractMaterialReturnRepository.class);
        SubcontractMaterialReturnItemRepository itemRepo =
                mock(SubcontractMaterialReturnItemRepository.class);
        StockService stockService = mock(StockService.class);
        LinkedDocumentIntegrityService sourceIntegrity =
                mock(LinkedDocumentIntegrityService.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        EntityManager em = mock(EntityManager.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(1);
        when(query.getResultList()).thenReturn(List.of());

        SubcontractMaterialReturnService service =
                new SubcontractMaterialReturnService(
                        returnRepo,
                        itemRepo,
                        stockService,
                        sourceIntegrity,
                        tx,
                        em,
                        currentUser,
                        mock(EmployeeNameResolver.class),
                        mock(DocNumberService.class),
                        mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class),
                        mock(com.uten.imp.features.subcontract.LinkedOrderReadGate.class));

        UUID id = UUID.randomUUID();
        SubcontractMaterialReturn document = document(id);
        SubcontractMaterialReturnItem item = item(id);
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                item.getMaterialIssueItemId(), item.getGoodsId(), "FIXTURE", "Fixture goods"}));
        when(em.find(
                SubcontractMaterialReturn.class,
                id,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(itemRepo.findByMaterialReturnIdOrderByLineNoAsc(id))
                .thenReturn(List.of(item));
        when(returnRepo.findById(id)).thenReturn(Optional.of(document));
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());

        service.approve(id);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        String update = sql.getAllValues().stream()
                .filter(value -> value.contains("UPDATE subcontract_material_issue_items"))
                .findFirst()
                .orElseThrow();
        assertTrue(update.contains("subcontract_material_issue_items"));
        assertTrue(update.contains("returned_qty"));
        assertFalse(update.contains("subcontract_order_items"));
        assertFalse(update.contains("material_returned_qty"));
        verify(sourceIntegrity).validateSubcontractMaterialReturn(any(), any());
        verify(stockService).recordMovement(any());
    }

    private static SubcontractMaterialReturn document(UUID id) {
        SubcontractMaterialReturn document = new SubcontractMaterialReturn();
        document.setId(id);
        document.setBillNo("ESW202608010001");
        document.setBillDate(LocalDate.of(2026, 8, 1));
        document.setSupplierId(UUID.randomUUID());
        document.setWarehouseId(UUID.randomUUID());
        document.setStatus((short) 0);
        document.setTotalLocal(BigDecimal.ZERO);
        document.setTotalOriginal(BigDecimal.ZERO);
        return document;
    }

    private static SubcontractMaterialReturnItem item(UUID documentId) {
        SubcontractMaterialReturnItem item =
                new SubcontractMaterialReturnItem();
        item.setMaterialReturnId(documentId);
        item.setGoodsId(UUID.randomUUID());
        item.setGoodsCodeSnapshot("FIXTURE");
        item.setGoodsNameSnapshot("Fixture goods");
        item.setGoodsSnapshotSource("MASTER_AT_SAVE");
        item.setUnitId(UUID.randomUUID());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.ONE);
        item.setMaterialIssueItemId(UUID.randomUUID());
        item.setOrderItemId(UUID.randomUUID());
        return item;
    }
}
