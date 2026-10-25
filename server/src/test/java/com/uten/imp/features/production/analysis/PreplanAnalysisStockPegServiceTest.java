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
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.ObjectProvider;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.inOrder;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;

class PreplanAnalysisStockPegServiceTest {

    private interface OriginHooks extends ObjectProvider<PreplanOriginEntitlementHook> {}

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
                mock(OriginHooks.class));

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
                mock(OriginHooks.class));
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

    @ParameterizedTest
    @ValueSource(strings = {"TRANSFERRED_TO_PLAN", "TRANSFERRED_TO_SUBCONTRACT"})
    void actionCancellationNeverOverwritesAnyTransferredToPlanMarker(String transferReason) {
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
                        transferReason},
                new Object[]{UUID.randomUUID(), BigDecimal.TEN, BigDecimal.ZERO,
                        BigDecimal.TEN, goodsId, colorId, (short) 1,
                        transferReason}));
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
                mock(OriginHooks.class));

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
    void warehouseStockInLocksInventoryThenClaimantAnalysesThenActions() {
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
        // V474 锚点行 12 列：goods/color/order_item/external_item + 预留列 +
        // order_id + 基本量与 exact/shared 预算（0 占位：本用例 claimants 为空，
        // 预算只做形状存在，不进入分摊）。
        when(anchor.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, colorId, UUID.randomUUID(), externalItemId,
                        0, null, 0, UUID.randomUUID(),
                        BigDecimal.ONE, BigDecimal.ZERO, BigDecimal.ZERO,
                        BigDecimal.ZERO}));
        when(analysisLock.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        when(claimants.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            // V463：订货行逐来源展开后 SQL 前缀为 SELECT DISTINCT，匹配列名而非前缀。
            if (sql.contains("inspection.goods_id")) return anchor;
            if (sql.contains("SELECT analysis.id")) return analysisLock;
            if (sql.contains("SELECT allocation.id")) return claimants;
            throw new AssertionError("unexpected SQL: " + sql);
        });
        InventoryMutationLock inventoryLock = mock(InventoryMutationLock.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class), inventoryLock,
                mock(PreplanStockEntitlementService.class),
                mock(OriginHooks.class));

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
        assertFinishedInboundFormalCommitment(false);
    }

    @Test
    void finishedInboundRejectsUnprovenCancelledParentBeforeUsingFormalCommitment() {
        assertFinishedInboundFormalCommitment(true);
    }

    private void assertFinishedInboundFormalCommitment(boolean cancelledParent) {
        EntityManager em = mock(EntityManager.class);
        Query context = mock(Query.class);
        Query formalCommitment = mock(Query.class);
        Query privateBudget = mock(Query.class);
        Query publicOutputs = mock(Query.class);
        Query cancelledParentGuard = mock(Query.class);
        when(publicOutputs.getResultList()).thenReturn(List.of());
        when(cancelledParentGuard.getSingleResult()).thenReturn(cancelledParent);
        for (Query query : List.of(context, formalCommitment, privateBudget, publicOutputs, cancelledParentGuard)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        UUID parentMaterialId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID stockDocumentId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        when(privateBudget.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{planItemId, BigDecimal.TEN}));
        when(context.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                analysisId, analysisItemId, "MAKE_COMPONENT",
                parentMaterialId, "ACTIVE"}));
        when(formalCommitment.getSingleResult()).thenReturn(BigDecimal.TEN);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (isPrivateMakeBudgetQuery(sql)) return privateBudget;
            if (isPublicOutputQuery(sql)) return publicOutputs;
            if (sql.contains("SELECT EXISTS(SELECT 1 FROM production_material_analysis_materials material")
                    && sql.contains("parent.anchor_analysis_item_id=material.analysis_item_id")
                    && sql.contains("action.status='CANCELLED'")) return cancelledParentGuard;
            if (isOriginalDemandContextQuery(sql)) return context;
            if (sql.startsWith("SELECT COALESCE(SUM(GREATEST(")
                    && sql.contains("FROM production_material_supply_pegs peg")) {
                assertThat(sql)
                        .contains("peg.allocated_qty - peg.consumed_qty - peg.released_qty")
                        .contains("peg.supply_type = 'PRODUCTION_PLAN_ITEM'")
                        .contains("peg.supply_item_id = :planItemId")
                        .contains("peg.status <> 'REVERSED'");
                return formalCommitment;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });
        InventoryMutationLock inventoryLock = mock(InventoryMutationLock.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                inventoryLock,
                mock(PreplanStockEntitlementService.class),
                mock(OriginHooks.class));

        Runnable receipt = () -> service.pegFinishedInbound(
                stockDocumentId, planId, UUID.randomUUID(),
                List.of(new com.uten.imp.application.port.PreplanAnalysisPegPort
                        .FinishedInboundSlice(
                        UUID.randomUUID(), planItemId, goodsId, colorId,
                        BigDecimal.TEN)));
        if (cancelledParent) {
            ApiException error = assertThrows(ApiException.class, receipt::run);
            assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
            assertThat(error.getMessage()).contains("原共享父批次已撤回").contains("原始私有来源");
            verify(privateBudget).setParameter("document", stockDocumentId);
            verify(privateBudget).setParameter("items", List.of(planItemId));
            verify(context).setParameter("planId", planId);
            verify(cancelledParentGuard).setParameter("material", parentMaterialId);
            verifyNoInteractions(inventoryLock);
            verify(formalCommitment, never()).getSingleResult();
            verify(em, never()).createNativeQuery(org.mockito.ArgumentMatchers.startsWith("INSERT"));
            return;
        }
        receipt.run();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        verify(privateBudget).getResultList();
        verify(privateBudget).setParameter("document", stockDocumentId);
        verify(privateBudget).setParameter("items", List.of(planItemId));
        verify(context).getResultList();
        verify(context).setParameter("planId", planId);
        verify(publicOutputs).setParameter("document", stockDocumentId);
        verify(publicOutputs).setParameter("documentId", stockDocumentId);
        verify(cancelledParentGuard).setParameter("material", parentMaterialId);
        verify(formalCommitment).getSingleResult();
        verify(formalCommitment).setParameter("planItemId", planItemId);
        var order = inOrder(privateBudget, publicOutputs, context, cancelledParentGuard, formalCommitment);
        order.verify(privateBudget).getResultList();
        order.verify(publicOutputs, org.mockito.Mockito.times(2)).getResultList();
        order.verify(context).getResultList();
        order.verify(cancelledParentGuard).getSingleResult();
        order.verify(formalCommitment).getSingleResult();
        assertThat(sql.getAllValues()).noneMatch(value ->
                value.contains("INSERT INTO stock_reservations"));
    }

    @Test
    void explicitlyPublicOutputCannotBeReservedByTheOriginalAnalysis() {
        EntityManager em = mock(EntityManager.class);
        Query privateBudget = mock(Query.class);
        Query publicOutputs = mock(Query.class);
        Query alreadyClaimed = mock(Query.class);
        Query claims = mock(Query.class);
        UUID stockItem = UUID.randomUUID();
        UUID planItem = UUID.randomUUID(), goods = UUID.randomUUID();
        UUID stockDocumentId = UUID.randomUUID();
        for (Query query : List.of(privateBudget, publicOutputs, alreadyClaimed, claims)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        // Explicit public identity wins even when the source has unused private quota.
        when(privateBudget.getResultList()).thenReturn(List.<Object[]>of(new Object[]{planItem, BigDecimal.TEN}));
        when(publicOutputs.getResultList()).thenReturn(List.of(stockItem));
        when(alreadyClaimed.getSingleResult()).thenReturn(BigDecimal.ZERO);
        when(claims.getResultList()).thenReturn(List.of());
        List<String> statements = new java.util.ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0); statements.add(sql);
            if (isPrivateMakeBudgetQuery(sql)) return privateBudget;
            if (isPublicOutputQuery(sql)) return publicOutputs;
            if (sql.startsWith("SELECT COALESCE(SUM(qty),0) FROM preplan_analysis_stock_exact_pegs")) {
                assertThat(sql).contains("source_stock_document_item_id=:item AND make_public_claim_id IS NOT NULL");
                return alreadyClaimed;
            }
            if (sql.startsWith("SELECT claim.id,claim.target_analysis_id,claim.target_material_id,")) {
                assertNativeSources(sql, "stock_documents");
                assertThat(sql)
                        .contains("FROM preplan_make_public_claims claim")
                        .contains("analysis.id=claim.target_analysis_id")
                        .contains("NOT analysis.is_deleted AND analysis.status<>'CANCELLED'")
                        .contains("claim.source_plan_item_id=:planItem")
                        .contains("previous.source_stock_document_item_id=:stockItem")
                        .contains("FOR UPDATE OF claim");
                return claims;
            }
            throw new AssertionError("Public output must not enter original-analysis pegging: " + sql);
        });
        InventoryMutationLock inventory = mock(InventoryMutationLock.class);
        PreplanStockEntitlementService entitlement = mock(PreplanStockEntitlementService.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class),
                inventory, entitlement, mock(OriginHooks.class));

        service.pegFinishedInbound(stockDocumentId, UUID.randomUUID(), UUID.randomUUID(),
                List.of(new com.uten.imp.application.port.PreplanAnalysisPegPort.FinishedInboundSlice(
                        stockItem, planItem, goods, null, BigDecimal.TEN)));

        verify(inventory).lock(new InventoryKey(goods, null));
        verify(privateBudget).setParameter("document", stockDocumentId);
        verify(privateBudget).setParameter("items", List.of(planItem));
        verify(publicOutputs).setParameter("document", stockDocumentId);
        verify(alreadyClaimed).setParameter("item", stockItem);
        verify(claims).setParameter("planItem", planItem);
        verify(claims).setParameter("document", stockDocumentId);
        verify(claims).setParameter("stockItem", stockItem);
        verify(claims).getResultList();
        verifyNoInteractions(entitlement);
        assertThat(statements).noneMatch(sql -> sql.startsWith("SELECT plan.material_analysis_id,")
                || sql.contains("INSERT INTO stock_reservations"));
        verify(publicOutputs, never()).executeUpdate();
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
                mock(OriginHooks.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForAnalysis(
                        UUID.randomUUID(), "取消分析", "cancel-analysis-0001"));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("跨分析让料").contains("先撤销");
        verify(relations, never()).executeUpdate();
    }

    @Test
    void analysisCancellationCannotReleaseMaterialAlreadyHandedToSubcontractDraw() {
        EntityManager em = mock(EntityManager.class);
        Query empty = mock(Query.class);
        Query custody = mock(Query.class);
        for (Query query : List.of(empty, custody)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        when(empty.getResultList()).thenReturn(List.of());
        when(custody.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        when(em.createNativeQuery(anyString())).thenAnswer(call ->
                ((String) call.getArgument(0)).contains("FROM subcontract_component_stock_handoffs handoff")
                        ? custody : empty);
        PreplanStockEntitlementService entitlement = mock(PreplanStockEntitlementService.class);
        PreplanAnalysisStockPegService service = new PreplanAnalysisStockPegService(
                em, mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class),
                mock(InventoryMutationLock.class), entitlement, mock(OriginHooks.class));

        ApiException error = assertThrows(ApiException.class, () ->
                service.releaseForAnalysis(UUID.randomUUID(), "取消", "cancel-subcontract-custody"));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        // ADR-143 §4.2: 交接给委外领料的专属批次只能先撤回未发领料或发料红冲后才能放。
        assertThat(error.getMessage()).contains("物料已交给委外领料").contains("撤回").contains("发料红冲");
        verify(entitlement, never()).appendReleaseForBeneficiaryAnalysis(any(), any(), anyString());
        verify(custody, never()).executeUpdate();
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
                mock(OriginHooks.class));

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
                mock(OriginHooks.class));

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
                        mock(OriginHooks.class));

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
        ObjectProvider<PreplanOriginEntitlementHook> hooks =
                mock(OriginHooks.class);
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
        ObjectProvider<PreplanOriginEntitlementHook> hooks =
                mock(OriginHooks.class);
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
    void allBatchSourcesFinishPriorityReallocationBeforeAnyTaskCanPrepareMaterial() {
        ObjectProvider<PreplanOriginEntitlementHook> hooks = mock(OriginHooks.class);
        PreplanOriginEntitlementHook priority = mock(PreplanOriginEntitlementHook.class);
        PreplanOriginEntitlementHook readiness = mock(PreplanOriginEntitlementHook.class);
        when(hooks.orderedStream()).thenReturn(java.util.stream.Stream.of(priority, readiness));
        var service = new PreplanAnalysisStockPegService(mock(EntityManager.class), mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class), mock(InventoryMutationLock.class),
                mock(PreplanStockEntitlementService.class), hooks);
        UUID first = UUID.randomUUID(), second = UUID.randomUUID(), replay = UUID.randomUUID();
        service.applyOriginPriority(List.of(
                new PreplanStockEntitlementService.OriginAppendResult(first, true),
                new PreplanStockEntitlementService.OriginAppendResult(replay, false),
                new PreplanStockEntitlementService.OriginAppendResult(second, true)));
        var order = inOrder(priority, readiness);
        order.verify(priority).applyPriorityForOriginEvent(first);
        order.verify(priority).applyPriorityForOriginEvent(second);
        order.verify(readiness).applyPriorityForOriginEvent(first);
        order.verify(readiness).applyPriorityForOriginEvent(second);
        order.verifyNoMoreInteractions();
        verifyNoMoreInteractions(priority, readiness);
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
                        mock(OriginHooks.class));

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


    private static boolean isPrivateMakeBudgetQuery(String sql) {
        if (!sql.startsWith("SELECT item.id,GREATEST(item.qty*COALESCE(item.unit_rate,1)")) return false;
        assertNativeSources(sql, "production_plan_items", "stock_document_items", "stock_documents");
        assertThat(sql)
                .contains("source.planned_public_qty")
                .contains("stock.upstream_item_id=item.id AND stock.bill_type='FINISHED_IN'")
                .contains("NOT stock.is_deleted AND NOT doc.is_deleted AND doc.status=1")
                .contains("doc.id<>:document AND NOT fn_finished_in_is_public_output(stock.id)")
                .contains("fn_preplan_make_public_supply_sources(NULL::uuid,item.id)")
                .contains("WHERE item.id IN(:items) AND NOT item.is_deleted");
        return true;
    }

    private static boolean isPublicOutputQuery(String sql) {
        if (!sql.startsWith("SELECT id FROM ") || !sql.contains("fn_finished_in_is_public_output(id)")) return false;
        assertNativeSources(sql, "stock_document_items");
        assertThat((sql.contains("WHERE doc_id=:document") && sql.contains("AND NOT is_deleted"))
                || sql.contains("WHERE doc_id = :documentId AND fn_finished_in_is_public_output(id)"))
                .as("Public output identity must be scoped to the current stock document")
                .isTrue();
        return true;
    }

    private static boolean isOriginalDemandContextQuery(String sql) {
        if (!sql.startsWith("SELECT plan.material_analysis_id,")) return false;
        assertNativeSources(sql, "production_plans");
        assertThat(sql)
                .contains("analysis.id = plan.material_analysis_id")
                .contains("analysis.is_deleted = FALSE")
                .contains("item.id = plan.material_analysis_item_id")
                .contains("item.analysis_id = plan.material_analysis_id")
                .contains("item.is_deleted = FALSE")
                .contains("WHERE plan.id = :planId")
                .contains("plan.is_deleted = FALSE")
                .contains("plan.material_analysis_id IS NOT NULL")
                .contains("plan.material_analysis_item_id IS NOT NULL")
                .contains("FOR UPDATE OF analysis, item");
        return true;
    }

    private static void assertNativeSources(String sql, String... tables) {
        for (String table : tables) {
            assertThat(sql).contains("(SELECT * FROM " + table
                    + " archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL"
                    + " AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL"
                    + " AND NOT fn_imported_business_document('" + table + "',archive_origin.id))");
        }
    }
}
