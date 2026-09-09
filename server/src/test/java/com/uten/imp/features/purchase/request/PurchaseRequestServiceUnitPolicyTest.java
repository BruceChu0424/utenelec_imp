package com.uten.imp.features.purchase.request;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
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
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
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
        stubMasterSnapshot(fixture.em, goodsId);

        fixture.service.create(request);

        ArgumentCaptor<PurchaseRequestItem> itemCaptor =
                ArgumentCaptor.forClass(PurchaseRequestItem.class);
        verify(fixture.itemRepo).save(itemCaptor.capture());
        assertEquals(baseUnitId, itemCaptor.getValue().getUnitId());
        assertEquals(
                0,
                BigDecimal.ONE.compareTo(itemCaptor.getValue().getUnitRate()));
        assertEquals("G-TEST", itemCaptor.getValue().getGoodsCodeSnapshot());
        assertEquals("测试货品", itemCaptor.getValue().getGoodsNameSnapshot());
        assertEquals("MASTER_AT_SAVE", itemCaptor.getValue().getGoodsSnapshotSource());
        assertNull(itemCaptor.getValue().getGoodsSnapshotLockedAt());
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
        stubMasterSnapshot(fixture.em, goodsId);

        fixture.service.approve(requestId);

        assertEquals(baseUnitId, item.getUnitId());
        assertEquals(0, BigDecimal.ONE.compareTo(item.getUnitRate()));
        assertEquals("MASTER_AT_APPROVAL", item.getGoodsSnapshotSource());
        assertNotNull(item.getGoodsSnapshotLockedAt());
        assertEquals((short) 1, request.getStatus());
        verify(fixture.itemRepo).saveAll(List.of(item));
        verify(fixture.requestRepo).save(request);
    }

    // ---- V477 分解前数量修正：守卫契约 ----

    @Test
    void adjustItemQtyRejectsOrderedOrPendingOccupiedLines() {
        Fixture fixture = new Fixture();
        UUID requestId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        PurchaseRequest request = new PurchaseRequest();
        request.setId(requestId);
        request.setStatus((short) 1);
        PurchaseRequestItem item = new PurchaseRequestItem();
        item.setId(itemId);
        item.setRequestId(requestId);
        item.setQty(new BigDecimal("10"));
        item.setOrderedQty(new BigDecimal("4"));
        when(fixture.requestRepo.findById(requestId))
                .thenReturn(java.util.Optional.of(request));
        when(fixture.itemRepo.findById(itemId))
                .thenReturn(java.util.Optional.of(item));

        ApiException ordered = assertThrows(
                ApiException.class,
                () -> fixture.service.adjustItemQty(
                        requestId, itemId, new BigDecimal("6")));
        assertTrue(ordered.getMessage().contains("已生成订货单"));

        item.setOrderedQty(null);
        Query pendingQuery = mock(Query.class);
        when(pendingQuery.setParameter(anyString(), any())).thenReturn(pendingQuery);
        when(pendingQuery.getSingleResult()).thenReturn(new BigDecimal("2"));
        when(fixture.em.createNativeQuery(
                org.mockito.ArgumentMatchers.contains(
                        "procurement_order_approval_cases")))
                .thenReturn(pendingQuery);
        ApiException pending = assertThrows(
                ApiException.class,
                () -> fixture.service.adjustItemQty(
                        requestId, itemId, new BigDecimal("6")));
        assertTrue(pending.getMessage().contains("待财务审核"));
    }

    @Test
    void adjustItemQtyUpdatesCleanLineAndReturnsRefreshedDetail() {
        Fixture fixture = new Fixture();
        UUID requestId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        PurchaseRequest request = new PurchaseRequest();
        request.setId(requestId);
        request.setStatus((short) 1);
        PurchaseRequestItem item = new PurchaseRequestItem();
        item.setId(itemId);
        item.setRequestId(requestId);
        item.setQty(new BigDecimal("10"));
        when(fixture.requestRepo.findById(requestId))
                .thenReturn(java.util.Optional.of(request));
        when(fixture.itemRepo.findById(itemId))
                .thenReturn(java.util.Optional.of(item));
        Query pendingQuery = mock(Query.class);
        when(pendingQuery.setParameter(anyString(), any())).thenReturn(pendingQuery);
        when(pendingQuery.getSingleResult()).thenReturn(new BigDecimal("0"));
        when(fixture.em.createNativeQuery(
                org.mockito.ArgumentMatchers.contains(
                        "procurement_order_approval_cases")))
                .thenReturn(pendingQuery);
        when(fixture.itemRepo.findByRequestIdOrderByLineNoAsc(requestId))
                .thenReturn(List.of(item));

        var detail = fixture.service.adjustItemQty(
                requestId, itemId, new BigDecimal("12.5"));

        assertNotNull(detail);
        assertEquals(0, new BigDecimal("12.5").compareTo(item.getQty()));
        assertEquals(0, new BigDecimal("12.5").compareTo(
                detail.getItems().getFirst().getQty()));
    }

    private static void stubMasterSnapshot(EntityManager em, UUID goodsId) {
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, goodsId, "G-TEST", "测试货品"}));
        Query pending = mock(Query.class);
        when(em.createNativeQuery(contains("pending.pending_qty FROM purchase_request_items"))).thenReturn(pending);
        when(pending.setParameter(anyString(), any())).thenReturn(pending);
        when(pending.getResultList()).thenReturn(List.of());
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
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.application.port.OrganizationReferencePort.class));
    }
}
