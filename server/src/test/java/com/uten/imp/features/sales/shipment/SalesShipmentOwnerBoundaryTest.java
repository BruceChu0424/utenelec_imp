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
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
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
    @Mock private com.uten.imp.features.master.client.ClientShipAddressService clientShipAddressService;

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
                chainNotice, clientShipAddressService);
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
    void linkedDraftIgnoresForgedClientLocalAmount() {
        UUID client = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        Query orderQuery = queryReturningRaw(List.of(orderId));
        Query lockedQuery = queryReturningRaw(List.of(itemId));
        Query allocationQuery = queryReturning(Collections.singletonList(
                allocationRow(itemId)));
        Query sourceQuery = queryReturning(Collections.singletonList(
                sourceRow(itemId, goodsId, client, currency, owner, orderId, "SO-FORGED")));
        Query policyQuery = queryReturning(Collections.singletonList(
                policyRow(itemId, orderId, "SO-FORGED")));
        Query snapshotQuery = queryReturning(Collections.singletonList(
                snapshotRow(itemId, "G-FORGED", "Forged snapshot goods")));
        Query eventQuery = commandQuery();
        when(em.createNativeQuery(anyString())).thenReturn(
                orderQuery, lockedQuery, allocationQuery,
                sourceQuery, policyQuery, snapshotQuery, eventQuery);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        when(docNumberService.nextNumber(any())).thenReturn("OUT-FORGED");
        when(accessPolicy.ownerForNewDocument(owner)).thenReturn(owner);

        ShipmentItemLine line = new ShipmentItemLine();
        line.setOrderItemId(itemId);
        line.setGoodsId(goodsId);
        line.setUnitId(goodsId);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        line.setPrice(new BigDecimal("999"));
        line.setAmountOriginal(new BigDecimal("999"));
        line.setAmountLocal(new BigDecimal("888888"));
        ShipmentSaveRequest request = new ShipmentSaveRequest();
        request.setBillDate(LocalDate.now());
        request.setClientId(client);
        request.setWarehouseId(UUID.randomUUID());
        request.setItems(List.of(line));

        SalesShipmentService service = new SalesShipmentService(
                shipmentRepo, itemRepo, stockService, reservationService,
                arApService, tx, em, docNumberService, accessPolicy,
                currentUser, nameResolver, chainNotice, clientShipAddressService);

        service.create(request);

        ArgumentCaptor<SalesShipment> savedShipment =
                ArgumentCaptor.forClass(SalesShipment.class);
        org.mockito.Mockito.verify(shipmentRepo, org.mockito.Mockito.atLeastOnce())
                .save(savedShipment.capture());
        SalesShipment persisted = savedShipment.getAllValues().getLast();
        assertEquals(new BigDecimal("10.0000"), persisted.getTotalOriginal());
        assertNull(persisted.getTotalLocal());
        assertNull(persisted.getExchangeRate());
        assertEquals(orderId, persisted.getSourceOrderId());
        assertEquals("SO-FORGED", persisted.getSourceDocNo());
        ArgumentCaptor<SalesShipmentItem> savedItem =
                ArgumentCaptor.forClass(SalesShipmentItem.class);
        org.mockito.Mockito.verify(itemRepo).save(savedItem.capture());
        assertEquals(new BigDecimal("10.0000"), savedItem.getValue().getAmountOriginal());
        assertNull(savedItem.getValue().getAmountLocal());
    }

    @Test
    void noRateOrdersCanOpenDraftsWithoutMergingAcrossOwners() {
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
                batchRow(itemA, goodsA, client, currency, ownerA, orderA, "SO-A"),
                batchRow(itemB, goodsB, client, currency, ownerB, orderB, "SO-B")));
        Query sourceAQuery = queryReturning(Collections.singletonList(
                sourceRow(itemA, goodsA, client, currency, ownerA, orderA, "SO-A")));
        Query sourceBQuery = queryReturning(Collections.singletonList(
                sourceRow(itemB, goodsB, client, currency, ownerB, orderB, "SO-B")));
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
        Query snapshotAQuery = queryReturning(Collections.singletonList(
                snapshotRow(itemA, "G-A", "Goods A")));
        Query snapshotBQuery = queryReturning(Collections.singletonList(
                snapshotRow(itemB, "G-B", "Goods B")));
        Query eventAQuery = commandQuery();
        Query eventBQuery = commandQuery();
        when(em.createNativeQuery(anyString()))
                .thenReturn(
                        batchQuery,
                        orderAQuery, lockedAQuery, allocationAQuery,
                        sourceAQuery, policyAQuery, snapshotAQuery, eventAQuery,
                        orderBQuery, lockedBQuery, allocationBQuery,
                        sourceBQuery, policyBQuery, snapshotBQuery, eventBQuery);
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
                chainNotice, clientShipAddressService);

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
        assertEquals(Set.of(orderA, orderB),
                distinct.stream().map(SalesShipment::getSourceOrderId)
                        .collect(java.util.stream.Collectors.toSet()));
        assertTrue(distinct.stream().allMatch(s -> s.getExchangeRate() == null));
        assertTrue(distinct.stream().allMatch(s -> s.getTotalLocal() == null));

        ArgumentCaptor<SalesShipmentItem> savedItems =
                ArgumentCaptor.forClass(SalesShipmentItem.class);
        org.mockito.Mockito.verify(itemRepo,
                org.mockito.Mockito.times(2)).save(savedItems.capture());
        assertEquals(
                Set.of(new BigDecimal("10")),
                savedItems.getAllValues().stream()
                        .map(SalesShipmentItem::getPrice)
                        .collect(java.util.stream.Collectors.toSet()));
        assertTrue(savedItems.getAllValues().stream()
                .allMatch(item -> item.getAmountLocal() == null));
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
                              UUID currencyId, UUID ownerId, UUID orderId,
                              String billNo) {
        return new Object[]{
                itemId, goodsId, null, goodsId, BigDecimal.ONE,
                new BigDecimal("999"),
                BigDecimal.TEN, clientId, currencyId, billNo, ownerId,
                (short) 1, false, false,
                BigDecimal.ZERO, null, ownerId, orderId, null
        };
    }

    private Object[] sourceRow(UUID itemId, UUID goodsId, UUID clientId,
                               UUID currencyId, UUID ownerId, UUID orderId,
                               String billNo) {
        return new Object[]{
                itemId, goodsId, null, goodsId, BigDecimal.ONE,
                clientId, ownerId, (short) 1, false, false, billNo,
                currencyId, BigDecimal.ZERO, null, ownerId,
                BigDecimal.TEN, BigDecimal.TEN, BigDecimal.ONE,
                BigDecimal.ZERO, BigDecimal.ZERO,
                "CLIENT", "MODEL", null, orderId, null
        };
    }

    private Object[] snapshotRow(UUID itemId, String code, String name) {
        return new Object[]{itemId, code, name};
    }

    private BatchShipRequest.Line batchLine(UUID itemId) {
        BatchShipRequest.Line line = new BatchShipRequest.Line();
        line.setOrderItemId(itemId);
        line.setQty(BigDecimal.ONE);
        return line;
    }
}
