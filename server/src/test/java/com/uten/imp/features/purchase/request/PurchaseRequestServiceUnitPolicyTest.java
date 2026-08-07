package com.uten.imp.features.purchase.request;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PurchaseRequestServiceUnitPolicyTest {

    @Test
    void createPersistsTheUnitResolvedByTheSharedPolicy() {
        Fixture fixture = new Fixture();
        UUID goodsId = UUID.randomUUID();
        UUID baseUnitId = UUID.randomUUID();
        RequestItemLine line = new RequestItemLine();
        line.setGoodsId(goodsId);
        line.setQty(new BigDecimal("12"));
        RequestSaveRequest request = new RequestSaveRequest();
        request.setBillDate(LocalDate.of(2026, 7, 31));
        request.setItems(List.of(line));
        when(fixture.docNumberService.nextNumber(DocNumberPrefix.PURCHASE_REQUEST))
                .thenReturn("SQ260731001");
        when(fixture.currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        when(fixture.lineUnitPolicy.normalizeAndValidate(goodsId, null, null, 1))
                .thenReturn(new PurchaseLineUnitPolicy.ResolvedUnit(
                        baseUnitId, BigDecimal.ONE));

        fixture.service.create(request);

        ArgumentCaptor<PurchaseRequestItem> itemCaptor =
                ArgumentCaptor.forClass(PurchaseRequestItem.class);
        verify(fixture.itemRepo).save(itemCaptor.capture());
        assertEquals(baseUnitId, itemCaptor.getValue().getUnitId());
        assertEquals(
                0,
                BigDecimal.ONE.compareTo(itemCaptor.getValue().getUnitRate()));
    }

    @Test
    void approveNormalizesPersistedDraftItemsBeforeChangingStatus() {
        Fixture fixture = new Fixture();
        UUID requestId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID baseUnitId = UUID.randomUUID();
        PurchaseRequest request = new PurchaseRequest();
        request.setId(requestId);
        request.setStatus((short) 0);
        PurchaseRequestItem item = new PurchaseRequestItem();
        item.setRequestId(requestId);
        item.setLineNo(1);
        item.setGoodsId(goodsId);
        item.setQty(BigDecimal.ONE);
        when(fixture.em.find(
                PurchaseRequest.class,
                requestId,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(request);
        when(fixture.requestRepo.findById(requestId))
                .thenReturn(java.util.Optional.of(request));
        when(fixture.itemRepo.findByRequestIdOrderByLineNoAsc(requestId))
                .thenReturn(List.of(item));
        when(fixture.lineUnitPolicy.normalizeAndValidate(goodsId, null, null, 1))
                .thenReturn(new PurchaseLineUnitPolicy.ResolvedUnit(
                        baseUnitId, BigDecimal.ONE));
        when(fixture.currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());

        fixture.service.approve(requestId);

        assertEquals(baseUnitId, item.getUnitId());
        assertEquals(0, BigDecimal.ONE.compareTo(item.getUnitRate()));
        assertEquals((short) 1, request.getStatus());
        verify(fixture.itemRepo).saveAll(List.of(item));
        verify(fixture.requestRepo).save(request);
    }

    private static final class Fixture {
        private final PurchaseRequestRepository requestRepo =
                mock(PurchaseRequestRepository.class);
        private final PurchaseRequestItemRepository itemRepo =
                mock(PurchaseRequestItemRepository.class);
        private final TxSessionVars tx = mock(TxSessionVars.class);
        private final SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        private final EmployeeNameResolver nameResolver =
                mock(EmployeeNameResolver.class);
        private final DocNumberService docNumberService =
                mock(DocNumberService.class);
        private final EntityManager em = mock(EntityManager.class);
        private final ProductionSupplySourceGuard sourceGuard =
                mock(ProductionSupplySourceGuard.class);
        private final PurchaseLineUnitPolicy lineUnitPolicy =
                mock(PurchaseLineUnitPolicy.class);
        private final PurchaseRequestService service = new PurchaseRequestService(
                requestRepo,
                itemRepo,
                tx,
                currentUser,
                nameResolver,
                docNumberService,
                em,
                sourceGuard,
                lineUnitPolicy,
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class));
    }
}
