package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PreplanAnalysisStockPegServiceTest {

    @Test
    void receiptReverseFailsAsBusinessConflictAfterPegWasTransferredToAPlan() {
        EntityManager em = mock(EntityManager.class);
        Query transferred = mock(Query.class);
        when(transferred.setParameter(anyString(), any())).thenReturn(transferred);
        when(transferred.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        when(em.createNativeQuery(anyString())).thenReturn(transferred);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForReceipt("SUBCONTRACT", UUID.randomUUID()));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage())
                .contains("一对一可逆转移链")
                .contains("受控异常处理");
        verify(transferred, never()).executeUpdate();
    }

    @Test
    void finishedInboundReverseFailsAsBusinessConflictAfterPegWasTransferredToAPlan() {
        EntityManager em = mock(EntityManager.class);
        Query transferred = mock(Query.class);
        when(transferred.setParameter(anyString(), any())).thenReturn(transferred);
        when(transferred.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        when(em.createNativeQuery(anyString())).thenReturn(transferred);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class));
        UUID stockDocumentId = UUID.randomUUID();

        ApiException error = assertThrows(ApiException.class, () ->
                service.requireFinishedInboundReversible(stockDocumentId));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage())
                .contains("成品入库")
                .contains("一对一可逆转移链")
                .contains("受控异常处理");
        verify(transferred).setParameter("sourceDocType", "PRODUCTION_INBOUND");
        verify(transferred).setParameter("sourceDocId", stockDocumentId);
        verify(transferred, never()).executeUpdate();
    }

    @Test
    void actionCancellationNeverOverwritesAnyTransferredToPlanMarker() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        when(rows.setParameter(anyString(), any())).thenReturn(rows);
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        when(rows.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{UUID.randomUUID(), BigDecimal.TEN, BigDecimal.ZERO,
                        BigDecimal.ZERO, goodsId, colorId, (short) 0, null},
                new Object[]{UUID.randomUUID(), BigDecimal.TEN, BigDecimal.ZERO,
                        BigDecimal.ONE, goodsId, colorId, (short) 0,
                        "TRANSFERRED_TO_PLAN"},
                new Object[]{UUID.randomUUID(), BigDecimal.TEN, BigDecimal.ZERO,
                        BigDecimal.TEN, goodsId, colorId, (short) 1,
                        "TRANSFERRED_TO_PLAN"}));
        when(em.createNativeQuery(anyString())).thenReturn(rows);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForSupplyItems(
                        UUID.randomUUID(), List.of(UUID.randomUUID()), null));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("部分或全部转入正式生产需求");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("r.status = :effective")
                .contains("r.release_reason = 'TRANSFERRED_TO_PLAN'")
                .contains("FOR UPDATE OF r");
        verify(rows, never()).executeUpdate();
    }

    @Test
    void inspectionPassLocksInventoryThenClaimantAnalysesThenActions() {
        EntityManager em = mock(EntityManager.class);
        Query anchor = mock(Query.class);
        Query analysisLock = mock(Query.class);
        Query claimants = mock(Query.class);
        for (Query query : List.of(anchor, analysisLock, claimants)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID externalItemId = UUID.randomUUID();
        when(anchor.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, colorId, UUID.randomUUID(), externalItemId}));
        when(analysisLock.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        when(claimants.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("SELECT inspection.goods_id")) return anchor;
            if (sql.contains("SELECT analysis.id")) return analysisLock;
            if (sql.contains("SELECT allocation.id")) return claimants;
            throw new AssertionError("unexpected SQL: " + sql);
        });
        InventoryMutationLock inventoryLock = mock(InventoryMutationLock.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class), inventoryLock);

        service.attributeInspectionPass(
                "PURCHASE", UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), BigDecimal.ONE, UUID.randomUUID());

        org.mockito.InOrder order =
                org.mockito.Mockito.inOrder(inventoryLock, analysisLock, claimants);
        order.verify(inventoryLock).lock(new InventoryKey(goodsId, colorId));
        order.verify(analysisLock).getResultList();
        order.verify(claimants).getResultList();
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(3)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues().get(1))
                .contains("ORDER BY analysis.id")
                .contains("FOR UPDATE OF analysis");
        assertThat(sql.getAllValues().get(2))
                .contains("FOR UPDATE OF action, allocation");
    }

    @Test
    void planPrelockLocksInventoryBeforeTheSourceAnalysisHeader() {
        EntityManager em = mock(EntityManager.class);
        Query source = mock(Query.class);
        Query dimensions = mock(Query.class);
        Query analysisHeader = mock(Query.class);
        for (Query query : List.of(source, dimensions, analysisHeader)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        UUID analysisId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        when(source.getResultList()).thenReturn(List.of(analysisId));
        when(dimensions.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, colorId}));
        when(analysisHeader.getResultList()).thenReturn(List.of(analysisId));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("SELECT material_analysis_id")) return source;
            if (sql.contains("SELECT dimension.goods_id")) return dimensions;
            if (sql.contains("FROM production_material_analyses")) {
                return analysisHeader;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });
        InventoryMutationLock inventoryLock = mock(InventoryMutationLock.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class), inventoryLock);

        assertThat(service.lockPlanningPackageInventoryDimensions(
                UUID.randomUUID())).isEqualTo(analysisId);

        org.mockito.InOrder order =
                org.mockito.Mockito.inOrder(inventoryLock, analysisHeader);
        order.verify(inventoryLock).lockAll(any());
        order.verify(analysisHeader).getResultList();
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(4)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues().get(2)).contains("FOR UPDATE");
    }

    @Test
    void planPrelockFailsClosedWhenDimensionsChangeBeforeAnalysisLock() {
        EntityManager em = mock(EntityManager.class);
        Query source = mock(Query.class);
        Query dimensions = mock(Query.class);
        Query analysisHeader = mock(Query.class);
        for (Query query : List.of(source, dimensions, analysisHeader)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        UUID analysisId = UUID.randomUUID();
        UUID firstGoods = UUID.randomUUID();
        UUID addedGoods = UUID.randomUUID();
        when(source.getResultList()).thenReturn(List.of(analysisId));
        when(dimensions.getResultList()).thenReturn(
                List.<Object[]>of(new Object[]{firstGoods, null}),
                List.<Object[]>of(
                        new Object[]{firstGoods, null},
                        new Object[]{addedGoods, null}));
        when(analysisHeader.getResultList()).thenReturn(List.of(analysisId));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("SELECT material_analysis_id")) return source;
            if (sql.contains("SELECT dimension.goods_id")) return dimensions;
            if (sql.contains("FROM production_material_analyses")) {
                return analysisHeader;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });
        InventoryMutationLock inventoryLock = mock(InventoryMutationLock.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class), inventoryLock);

        ApiException error = assertThrows(ApiException.class, () ->
                service.lockPlanningPackageInventoryDimensions(UUID.randomUUID()));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("库存维度已并发变化");
        verify(inventoryLock, org.mockito.Mockito.times(1)).lockAll(any());
        verify(dimensions, org.mockito.Mockito.times(2)).getResultList();
    }

    @Test
    void legacyV298TransferStillConsumesExternalAllocationCapacity() {
        EntityManager em = mock(EntityManager.class);
        Query capacity = mock(Query.class);
        when(capacity.setParameter(anyString(), any())).thenReturn(capacity);
        when(capacity.getSingleResult()).thenReturn(new BigDecimal("7"));
        when(em.createNativeQuery(anyString())).thenReturn(capacity);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class));

        BigDecimal attributed = service.legacyAttributed(
                UUID.randomUUID(), "PURCHASE_REQUEST_ITEM", UUID.randomUUID());

        assertThat(attributed).isEqualByComparingTo("7");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("release_reason = 'TRANSFERRED_TO_PLAN'")
                .contains("THEN reservation.qty");
    }
}
