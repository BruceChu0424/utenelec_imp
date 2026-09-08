package com.uten.imp.features.procurement;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade;
import com.uten.imp.features.purchase.request.PurchaseRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestItem;
import com.uten.imp.features.purchase.request.PurchaseRequestItemRepository;
import com.uten.imp.features.purchase.request.PurchaseRequestRepository;
import com.uten.imp.features.subcontract.application.ProductionSubcontractRequestFacade;
import com.uten.imp.features.subcontract.application.SubcontractApplication;
import com.uten.imp.features.subcontract.application.SubcontractApplicationItem;
import com.uten.imp.features.subcontract.application.SubcontractApplicationItemRepository;
import com.uten.imp.features.subcontract.application.SubcontractApplicationRepository;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionDemandRequestReleaseTest {

    @Test
    void approvedProductionPurchaseDemandRequiresExplicitReverseAndKeepsHistory() {
        PurchaseRequestRepository requestRepo = mock(PurchaseRequestRepository.class);
        PurchaseRequestItemRepository itemRepo = mock(PurchaseRequestItemRepository.class);
        DocNumberService numbers = mock(DocNumberService.class);
        EntityManager em = mock(EntityManager.class);
        Query query = emptyLinkedQuantityQuery(em);
        UUID goodsId = UUID.randomUUID();
        stubMasterSnapshot(em, goodsId);
        when(numbers.nextNumber(any())).thenReturn("CS-PLAN");
        ProductionPurchaseRequestFacade facade = new ProductionPurchaseRequestFacade(
                requestRepo, itemRepo, numbers, em,
                mock(com.uten.imp.application.port.OrganizationReferencePort.class),
                mock(com.uten.imp.application.concurrency.FulfillmentMutationLocks.class));
        UUID applicantEmployeeId = UUID.randomUUID();

        facade.createProductionDraft(
                "PP-1",
                null,
                LocalDate.of(2026, 8, 20),
                UUID.randomUUID(),
                List.of(new ProductionPurchaseRequestFacade.DraftLine(
                        UUID.randomUUID(), goodsId, null, UUID.randomUUID(),
                        new BigDecimal("12"), LocalDate.of(2026, 8, 18), "shortage")),
                applicantEmployeeId,
                UUID.randomUUID());

        ArgumentCaptor<PurchaseRequest> header = ArgumentCaptor.forClass(PurchaseRequest.class);
        verify(requestRepo, atLeastOnce()).save(header.capture());
        ArgumentCaptor<PurchaseRequestItem> line = ArgumentCaptor.forClass(PurchaseRequestItem.class);
        verify(itemRepo).save(line.capture());
        assertThat(header.getValue().getStatus()).isEqualTo((short) 1);
        assertThat(header.getValue().getApplicantId()).isEqualTo(applicantEmployeeId);
        assertThat(header.getValue().getTotalOriginal()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(header.getValue().getTotalLocal()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(line.getValue().getPrice()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(line.getValue().getAmountOriginal()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(line.getValue().getAmountLocal()).isEqualByComparingTo(BigDecimal.ZERO);

        when(em.find(PurchaseRequest.class, header.getValue().getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(header.getValue());
        assertThatThrownBy(() -> facade.cancelGeneratedDraft(
                header.getValue().getId(),
                ProductionPurchaseRequestFacade.LifecycleAction.CANCEL))
                .isInstanceOf(ApiException.class);
        assertThat(header.getValue().getStatus()).isEqualTo((short) 1);
        assertThat(header.getValue().isDeleted()).isFalse();
        facade.cancelGeneratedDraft(
                header.getValue().getId(),
                ProductionPurchaseRequestFacade.LifecycleAction.REVERSE);
        assertThat(header.getValue().getStatus()).isEqualTo((short) -1);
        assertThat(header.getValue().isClosed()).isTrue();
        assertThat(header.getValue().isDeleted()).isFalse();
        verify(query, atLeastOnce())
                .setParameter("requestId", header.getValue().getId());
    }

    @Test
    void approvedProductionSubcontractDemandRequiresExplicitReverseAndKeepsHistory() {
        SubcontractApplicationRepository applicationRepo = mock(SubcontractApplicationRepository.class);
        SubcontractApplicationItemRepository itemRepo = mock(SubcontractApplicationItemRepository.class);
        DocNumberService numbers = mock(DocNumberService.class);
        EntityManager em = mock(EntityManager.class);
        Query query = emptyLinkedQuantityQuery(em);
        UUID goodsId = UUID.randomUUID();
        stubMasterSnapshot(em, goodsId);
        when(numbers.nextNumber(any())).thenReturn("WS-PLAN");
        ProductionSubcontractRequestFacade facade = new ProductionSubcontractRequestFacade(
                applicationRepo, itemRepo, numbers, em,
                mock(com.uten.imp.application.concurrency.FulfillmentMutationLocks.class));
        UUID applicantEmployeeId = UUID.randomUUID();

        facade.createProductionDraft(
                "PP-2",
                null,
                LocalDate.of(2026, 8, 20),
                UUID.randomUUID(),
                List.of(new ProductionSubcontractRequestPort.DraftLine(
                        UUID.randomUUID(), goodsId, null, UUID.randomUUID(),
                        new BigDecimal("8"), LocalDate.of(2026, 8, 19), "shortage")),
                applicantEmployeeId,
                UUID.randomUUID());

        ArgumentCaptor<SubcontractApplication> header =
                ArgumentCaptor.forClass(SubcontractApplication.class);
        verify(applicationRepo, atLeastOnce()).save(header.capture());
        ArgumentCaptor<SubcontractApplicationItem> line =
                ArgumentCaptor.forClass(SubcontractApplicationItem.class);
        verify(itemRepo).save(line.capture());
        assertThat(header.getValue().getStatus()).isEqualTo((short) 1);
        assertThat(header.getValue().getApplicantId()).isEqualTo(applicantEmployeeId);
        assertThat(header.getValue().getSupplierId()).isNull();
        assertThat(header.getValue().getTotalOriginal()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(header.getValue().getTotalLocal()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(line.getValue().getPrice()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(line.getValue().getAmountOriginal()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(line.getValue().getAmountLocal()).isEqualByComparingTo(BigDecimal.ZERO);

        when(em.find(
                SubcontractApplication.class,
                header.getValue().getId(),
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(header.getValue());
        assertThatThrownBy(() -> facade.closeGeneratedDraft(
                header.getValue().getId(),
                ProductionSubcontractRequestPort.LifecycleAction.CANCEL))
                .isInstanceOf(ApiException.class);
        assertThat(header.getValue().getStatus()).isEqualTo((short) 1);
        assertThat(header.getValue().isDeleted()).isFalse();
        facade.closeGeneratedDraft(
                header.getValue().getId(),
                ProductionSubcontractRequestPort.LifecycleAction.REVERSE);
        assertThat(header.getValue().getStatus()).isEqualTo((short) -1);
        assertThat(header.getValue().isClosed()).isTrue();
        assertThat(header.getValue().isDeleted()).isFalse();
        verify(query, atLeastOnce())
                .setParameter("applicationId", header.getValue().getId());
    }

    private static Query emptyLinkedQuantityQuery(EntityManager em) {
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        return query;
    }

    private static void stubMasterSnapshot(EntityManager em, UUID goodsId) {
        Query query = mock(Query.class);
        when(em.createNativeQuery(argThat(
                sql -> sql != null && sql.contains("FROM goods"))))
                .thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, goodsId, "G-TEST", "测试货品"}));
    }
}
