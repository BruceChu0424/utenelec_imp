package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.shipment.dto.BatchShipRequest;
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
    void batchNeverMergesSameClientAcrossOwnersAndEachDraftInheritsItsSourceOwner() {
        UUID client = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID ownerA = UUID.randomUUID();
        UUID ownerB = UUID.randomUUID();
        UUID itemA = UUID.randomUUID();
        UUID itemB = UUID.randomUUID();
        UUID goodsA = UUID.randomUUID();
        UUID goodsB = UUID.randomUUID();

        Query batchQuery = queryReturning(List.of(
                batchRow(itemA, goodsA, client, currency, ownerA, "SO-A"),
                batchRow(itemB, goodsB, client, currency, ownerB, "SO-B")));
        Query sourceAQuery = queryReturning(Collections.singletonList(
                sourceRow(itemA, goodsA, client, ownerA, "SO-A")));
        Query sourceBQuery = queryReturning(Collections.singletonList(
                sourceRow(itemB, goodsB, client, ownerB, "SO-B")));
        when(em.createNativeQuery(anyString()))
                .thenReturn(batchQuery, sourceAQuery, sourceBQuery);
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
    }

    private Query queryReturning(List<Object[]> rows) {
        Query query = org.mockito.Mockito.mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(new ArrayList<>(rows));
        return query;
    }

    private Object[] batchRow(UUID itemId, UUID goodsId, UUID clientId,
                              UUID currencyId, UUID ownerId, String billNo) {
        return new Object[]{
                itemId, goodsId, null, null, BigDecimal.ONE, BigDecimal.TEN,
                BigDecimal.TEN, clientId, currencyId, billNo, ownerId,
                (short) 1, false, false
        };
    }

    private Object[] sourceRow(UUID itemId, UUID goodsId, UUID clientId,
                               UUID ownerId, String billNo) {
        return new Object[]{
                itemId, goodsId, clientId, ownerId, (short) 1,
                false, false, billNo
        };
    }

    private BatchShipRequest.Line batchLine(UUID itemId) {
        BatchShipRequest.Line line = new BatchShipRequest.Line();
        line.setOrderItemId(itemId);
        line.setQty(BigDecimal.ONE);
        return line;
    }
}
