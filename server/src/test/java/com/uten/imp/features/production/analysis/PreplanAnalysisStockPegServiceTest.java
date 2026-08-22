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
import org.springframework.beans.factory.ObjectProvider;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verifyNoInteractions;

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
                mock(InventoryMutationLock.class),
                mock(PreplanStockEntitlementService.class),
                mock(ObjectProvider.class));

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
                mock(InventoryMutationLock.class),
                mock(PreplanStockEntitlementService.class),
                mock(ObjectProvider.class));
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
        Query empty = mock(Query.class);
        when(empty.setParameter(anyString(), any())).thenReturn(empty);
        when(empty.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(invocation ->
                ((String) invocation.getArgument(0)).contains(
                        "SELECT r.id, r.qty")
                        ? rows : empty);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class),
                mock(PreplanStockEntitlementService.class),
                mock(ObjectProvider.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForSupplyItems(
                        UUID.randomUUID(), List.of(UUID.randomUUID()), null));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("未恢复正式转移").contains("RESTORE");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).anySatisfy(value -> assertThat(value)
                .contains("r.status = :effective")
                .contains("r.release_reason = 'TRANSFERRED_TO_PLAN'")
                .contains("FOR UPDATE OF r"));
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
                mock(SecurityContextCurrentUser.class), inventoryLock,
                mock(PreplanStockEntitlementService.class),
                mock(ObjectProvider.class));

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
    void finishedInboundHonorsFormalMakeCommitmentBeforePreplanExactPegging() {
        EntityManager em = mock(EntityManager.class);
        Query context = mock(Query.class);
        Query formalCommitment = mock(Query.class);
        for (Query query : List.of(context, formalCommitment)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        UUID parentMaterialId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        when(context.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                analysisId, analysisItemId, "MAKE_COMPONENT",
                parentMaterialId, "ACTIVE"}));
        when(formalCommitment.getSingleResult()).thenReturn(BigDecimal.TEN);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM production_plans plan")) return context;
            if (sql.contains("FROM production_material_supply_pegs peg")) {
                return formalCommitment;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class),
                mock(PreplanStockEntitlementService.class),
                mock(ObjectProvider.class));

        service.pegFinishedInbound(
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                List.of(new com.uten.imp.application.port.PreplanAnalysisPegPort
                        .FinishedInboundSlice(
                        UUID.randomUUID(), planItemId, goodsId, colorId,
                        BigDecimal.TEN)));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).noneMatch(value ->
                value.contains("INSERT INTO stock_reservations"));
    }

    @Test
    void analysisCancellationFailsClosedWhileReallocationIsNotClosed() {
        EntityManager em = mock(EntityManager.class);
        Query relations = mock(Query.class);
        when(relations.setParameter(anyString(), any())).thenReturn(relations);
        when(relations.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        when(em.createNativeQuery(anyString())).thenReturn(relations);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class),
                mock(PreplanStockEntitlementService.class),
                mock(ObjectProvider.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForAnalysis(
                        UUID.randomUUID(), "取消分析", "cancel-analysis-0001"));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("跨分析让料").contains("先撤销");
        verify(relations, never()).executeUpdate();
    }

    @Test
    void receiptReleaseFailsClosedWhenBeneficiaryDiffersFromOrigin() {
        EntityManager em = mock(EntityManager.class);
        Query transferred = mock(Query.class);
        Query releaseScope = mock(Query.class);
        Query relations = mock(Query.class);
        Query foreignBeneficiary = mock(Query.class);
        for (Query query : List.of(
                transferred, releaseScope, relations, foreignBeneficiary)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        UUID reservationId = UUID.randomUUID();
        when(transferred.getResultList()).thenReturn(List.of());
        when(releaseScope.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{reservationId, BigDecimal.TEN, BigDecimal.ZERO,
                        BigDecimal.ZERO, UUID.randomUUID(), UUID.randomUUID(),
                        (short) 0, null}));
        when(relations.getResultList()).thenReturn(List.of());
        when(foreignBeneficiary.getResultList()).thenReturn(List.of(reservationId));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("SELECT r.id, r.qty")) return releaseScope;
            if (sql.contains("release_reason = 'TRANSFERRED_TO_PLAN'")) {
                return transferred;
            }
            if (sql.contains("JOIN preplan_stock_entitlement_events event")) {
                return relations;
            }
            if (sql.contains("JOIN preplan_analysis_stock_exact_pegs exact_peg")) {
                return foreignBeneficiary;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });
        PreplanStockEntitlementService entitlement =
                mock(PreplanStockEntitlementService.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class), entitlement,
                mock(ObjectProvider.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForReceipt("PURCHASE", UUID.randomUUID()));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage())
                .contains("其他分析当前受益权益")
                .contains("先显式撤销让料");
        verify(entitlement, never()).appendReleaseForReservation(
                any(), any(), anyString());
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
                mock(InventoryMutationLock.class),
                mock(PreplanStockEntitlementService.class),
                mock(ObjectProvider.class));

        BigDecimal attributed = service.legacyAttributed(
                UUID.randomUUID(), "PURCHASE_REQUEST_ITEM", UUID.randomUUID());

        assertThat(attributed).isEqualByComparingTo("7");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("release_reason = 'TRANSFERRED_TO_PLAN'")
                .contains("THEN reservation.qty");
    }
    @Test
    void activeFormalizationBlocksAnalysisCancellationBeforeAnyWrite() {
        UUID analysisId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        InventoryMutationLock inventoryLock =
                mock(InventoryMutationLock.class);
        PreplanStockEntitlementService entitlement =
                mock(PreplanStockEntitlementService.class);
        doThrow(new ApiException(
                ErrorCode.CONFLICT,
                "该分析的正式需求库存尚未完成RESTORE"))
                .when(entitlement)
                .requireNoActiveFormalizationForBeneficiary(
                        analysisId, true);
        PreplanAnalysisStockPegService service =
                new PreplanAnalysisStockPegService(
                        em, mock(TxSessionVars.class),
                        mock(SecurityContextCurrentUser.class),
                        inventoryLock, entitlement,
                        mock(ObjectProvider.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForAnalysis(
                        analysisId, "取消分析", "cancel-active-formal-1"));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("RESTORE");
        verify(entitlement).requireNoActiveFormalizationForBeneficiary(
                analysisId, true);
        verify(entitlement, never()).appendReleaseForBeneficiaryAnalysis(
                any(), any(), anyString());
        verifyNoInteractions(em, inventoryLock);
    }

    @Test
    void replayedSourceOriginDoesNotAdvancePartialPriorityTwice() {
        @SuppressWarnings("unchecked")
        ObjectProvider<PreplanOriginEntitlementHook> hooks =
                mock(ObjectProvider.class);
        PreplanAnalysisStockPegService service =
                new PreplanAnalysisStockPegService(
                        mock(EntityManager.class), mock(TxSessionVars.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(InventoryMutationLock.class),
                        mock(PreplanStockEntitlementService.class), hooks);

        service.applyOriginPriority(
                new PreplanStockEntitlementService.OriginAppendResult(
                        UUID.randomUUID(), false));

        verifyNoInteractions(hooks);
    }

    @Test
    void replayedBorrowerOriginDoesNotAttemptSecondPriorityTransferOrConflict() {
        @SuppressWarnings("unchecked")
        ObjectProvider<PreplanOriginEntitlementHook> hooks =
                mock(ObjectProvider.class);
        PreplanAnalysisStockPegService service =
                new PreplanAnalysisStockPegService(
                        mock(EntityManager.class), mock(TxSessionVars.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(InventoryMutationLock.class),
                        mock(PreplanStockEntitlementService.class), hooks);

        service.applyOriginPriority(
                new PreplanStockEntitlementService.OriginAppendResult(
                        UUID.randomUUID(), false));

        verifyNoInteractions(hooks);
    }
    @Test
    void exactAttributionUsesImmutablePegQtyWhileSourceRemainsValid() {
        UUID allocationId = UUID.randomUUID();
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(new BigDecimal("7"));
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        PreplanAnalysisStockPegService service =
                new PreplanAnalysisStockPegService(
                        em, mock(TxSessionVars.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(InventoryMutationLock.class),
                        mock(PreplanStockEntitlementService.class),
                        mock(ObjectProvider.class));

        BigDecimal attributed = service.exactAttributed(allocationId);

        assertThat(attributed).isEqualByComparingTo("7");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("SUM(peg.qty)")
                .contains("procurement_inspection_items inspection")
                .contains("inspection.status <> 'REVERSED'")
                .contains("stock_document.status = 1")
                .contains("stock_document.is_deleted = FALSE")
                .doesNotContain("reservation.released_qty")
                .doesNotContain("release_reason");
        verify(query).setParameter("allocationId", allocationId);
    }


}
