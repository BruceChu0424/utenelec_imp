package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.shipment.dto.BatchShipRequest;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemLine;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SalesShipmentOwnerBoundaryTest {

    @Mock private SalesShipmentRepository shipmentRepo;
    @Mock private SalesShipmentItemRepository itemRepo;
    @Mock private StockService stockService;
    @Mock private StockReservationService reservationService;
    @Mock private ArApLedgerService arApService;
    @Mock private TxSessionVars tx;
    @Mock private EntityManager em;
    @Mock private DocNumberService docNumberService;
    @Mock private SalesDocumentAccessPolicy accessPolicy;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    @Mock private com.uten.imp.features.notice.ChainNoticeService chainNotice;

    @Test
    void newSalesShipmentCannotBypassOrderPolicyWithUnlinkedLine() {
        SalesShipmentService service = new SalesShipmentService(
                shipmentRepo,
                itemRepo,
                stockService,
                reservationService,
                arApService,
                tx,
                em,
                docNumberService,
                accessPolicy,
                currentUser,
                nameResolver,
                chainNotice);
        ShipmentItemLine line = new ShipmentItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setUnitId(UUID.randomUUID());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        ShipmentSaveRequest request = new ShipmentSaveRequest();
        request.setItems(List.of(line));

        assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> service.create(request));
    }

    @Test
    void batchNeverMergesSameClientAcrossOwnersAndEachDraftInheritsItsSourceOwner() {
        UUID client = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID ownerA = UUID.randomUUID();
        UUID ownerB = UUID.randomUUID();
        UUID orderA = UUID.randomUUID();
        UUID orderB = UUID.randomUUID();
        UUID itemA = UUID.randomUUID();
        UUID itemB = UUID.randomUUID();
        UUID goodsA = UUID.randomUUID();
        UUID goodsB = UUID.randomUUID();

        Query batchQuery = queryReturning(List.of(
                batchRow(itemA, goodsA, client, currency, ownerA, "SO-A"),
                batchRow(itemB, goodsB, client, currency, ownerB, "SO-B")));
        Query sourceAQuery = queryReturning(Collections.singletonList(
                sourceRow(itemA, goodsA, client, currency, ownerA, "SO-A")));
        Query sourceBQuery = queryReturning(Collections.singletonList(
                sourceRow(itemB, goodsB, client, currency, ownerB, "SO-B")));
        Query orderAQuery = queryReturningRaw(List.of(orderA));
        Query orderBQuery = queryReturningRaw(List.of(orderB));
        Query lockedAQuery = queryReturningRaw(List.of(itemA));
        Query lockedBQuery = queryReturningRaw(List.of(itemB));
        Query allocationAQuery = queryReturning(Collections.singletonList(
                allocationRow(itemA)));
        Query allocationBQuery = queryReturning(Collections.singletonList(
                allocationRow(itemB)));
        Query policyAQuery = queryReturning(Collections.singletonList(
                policyRow(itemA, orderA, "SO-A")));
        Query policyBQuery = queryReturning(Collections.singletonList(
                policyRow(itemB, orderB, "SO-B")));
        Query eventAQuery = commandQuery();
        Query eventBQuery = commandQuery();
        when(em.createNativeQuery(anyString()))
                .thenReturn(
                        batchQuery,
                        orderAQuery, lockedAQuery, allocationAQuery,
                        sourceAQuery, policyAQuery, eventAQuery,
                        orderBQuery, lockedBQuery, allocationBQuery,
                        sourceBQuery, policyBQuery, eventBQuery);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        when(docNumberService.nextNumber(any()))
                .thenReturn("OUT-A", "OUT-B");
        when(accessPolicy.ownerForNewDocument(any()))
                .thenAnswer(invocation -> invocation.getArgument(0));

        SalesShipmentService service = new SalesShipmentService(
                shipmentRepo,
                itemRepo,
                stockService,
                reservationService,
                arApService,
                tx,
                em,
                docNumberService,
                accessPolicy,
                currentUser,
                nameResolver,
                chainNotice);

        BatchShipRequest request = new BatchShipRequest();
        request.setBillDate(LocalDate.now());
        request.setLines(List.of(batchLine(itemA), batchLine(itemB)));

        assertEquals(2, service.batchCreate(request).size());

        ArgumentCaptor<SalesShipment> saved = ArgumentCaptor.forClass(SalesShipment.class);
        org.mockito.Mockito.verify(shipmentRepo, org.mockito.Mockito.atLeast(2)).save(saved.capture());
        Set<SalesShipment> distinct =
                Collections.newSetFromMap(new IdentityHashMap<>());
        distinct.addAll(saved.getAllValues());
        assertEquals(2, distinct.size());
        assertEquals(Set.of(ownerA, ownerB),
                distinct.stream().map(SalesShipment::getOwnerEmployeeId)
                        .collect(java.util.stream.Collectors.toSet()));

        ArgumentCaptor<SalesShipmentItem> savedItems =
                ArgumentCaptor.forClass(SalesShipmentItem.class);
        org.mockito.Mockito.verify(itemRepo,
                org.mockito.Mockito.times(2)).save(savedItems.capture());
        assertEquals(
                Set.of(new BigDecimal("10")),
                savedItems.getAllValues().stream()
                        .map(SalesShipmentItem::getPrice)
                        .collect(java.util.stream.Collectors.toSet()));
        assertEquals(
                Set.of(new BigDecimal("10.0000")),
                savedItems.getAllValues().stream()
                        .map(SalesShipmentItem::getAmountLocal)
                        .collect(java.util.stream.Collectors.toSet()));
    }

    private Query queryReturning(List<Object[]> rows) {
        return queryReturningRaw(rows);
    }

    private Query queryReturningRaw(List<?> rows) {
        Query query = org.mockito.Mockito.mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(new ArrayList<>(rows));
        return query;
    }

    private Query commandQuery() {
        Query query = org.mockito.Mockito.mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }

    private Object[] allocationRow(UUID itemId) {
        return new Object[]{
                itemId, BigDecimal.TEN, 1, BigDecimal.ZERO
        };
    }

    private Object[] policyRow(UUID itemId, UUID orderId, String billNo) {
        return new Object[]{
                itemId, orderId, billNo, "LEGACY_UNSPECIFIED", null, BigDecimal.ONE
        };
    }

    private Object[] batchRow(UUID itemId, UUID goodsId, UUID clientId,
                              UUID currencyId, UUID ownerId, String billNo) {
        return new Object[]{
                itemId, goodsId, null, goodsId, BigDecimal.ONE,
                new BigDecimal("999"),
                BigDecimal.TEN, clientId, currencyId, billNo, ownerId,
                (short) 1, false, false,
                BigDecimal.ONE, BigDecimal.ZERO, 1, ownerId
        };
    }

    private Object[] sourceRow(UUID itemId, UUID goodsId, UUID clientId,
                               UUID currencyId, UUID ownerId, String billNo) {
        return new Object[]{
                itemId, goodsId, null, goodsId, BigDecimal.ONE,
                clientId, ownerId, (short) 1, false, false, billNo,
                currencyId, BigDecimal.ONE, BigDecimal.ZERO,
                1, ownerId,
                BigDecimal.TEN, BigDecimal.TEN, BigDecimal.TEN,
                BigDecimal.ONE, BigDecimal.ZERO, BigDecimal.ZERO,
                "CLIENT", "MODEL", null
        };
    }

    private BatchShipRequest.Line batchLine(UUID itemId) {
        BatchShipRequest.Line line = new BatchShipRequest.Line();
        line.setOrderItemId(itemId);
        line.setQty(BigDecimal.ONE);
        return line;
    }
}
