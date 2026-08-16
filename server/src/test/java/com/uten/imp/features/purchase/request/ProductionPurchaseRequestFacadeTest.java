package com.uten.imp.features.purchase.request;

import com.uten.imp.common.docnumber.DocNumberService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionPurchaseRequestFacadeTest {

    @Test
    void generatedDraftKeepsThePlanningWarehouse() {
        PurchaseRequestRepository requestRepo =
                mock(PurchaseRequestRepository.class);
        PurchaseRequestItemRepository itemRepo =
                mock(PurchaseRequestItemRepository.class);
        DocNumberService numberService = mock(DocNumberService.class);
        when(numberService.nextNumber(any())).thenReturn("CS-TEST");
        EntityManager entityManager = mock(EntityManager.class);
        UUID goodsId = UUID.randomUUID();
        stubMasterSnapshot(entityManager, goodsId);
        ProductionPurchaseRequestFacade facade =
                new ProductionPurchaseRequestFacade(
                        requestRepo,
                        itemRepo,
                        numberService,
                        entityManager,
                        mock(com.uten.imp.application.port.OrganizationReferencePort.class));

        UUID warehouseId = UUID.randomUUID();
        facade.createProductionDraft(
                "PP-TEST",
                null,
                LocalDate.of(2026, 8, 7),
                warehouseId,
                List.of(new ProductionPurchaseRequestFacade.DraftLine(
                        UUID.randomUUID(),
                        goodsId,
                        null,
                        UUID.randomUUID(),
                        BigDecimal.ONE,
                        LocalDate.of(2026, 8, 6),
                        "execution shortage")),
                UUID.randomUUID(),
                UUID.randomUUID());

        ArgumentCaptor<PurchaseRequest> request =
                ArgumentCaptor.forClass(PurchaseRequest.class);
        verify(requestRepo, atLeastOnce()).save(request.capture());
        assertThat(request.getValue().getWarehouseId())
                .isEqualTo(warehouseId);
        ArgumentCaptor<PurchaseRequestItem> item =
                ArgumentCaptor.forClass(PurchaseRequestItem.class);
        verify(itemRepo).save(item.capture());
        assertThat(item.getValue().getGoodsCodeSnapshot()).isEqualTo("G-TEST");
        assertThat(item.getValue().getGoodsSnapshotSource())
                .isEqualTo("MASTER_AT_APPROVAL");
        assertThat(item.getValue().getGoodsSnapshotLockedAt()).isNotNull();
    }

    private static void stubMasterSnapshot(EntityManager em, UUID goodsId) {
        // 货品主档快照查询：先给所有原生查询一个空默认桩，再用更精确的匹配器覆盖快照查询
        // （Mockito 后声明的更具体桩优先生效）；销售订单谱系回溯等其它查询得到空结果。
        Query empty = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(empty);
        when(empty.setParameter(anyString(), any())).thenReturn(empty);
        when(empty.getResultList()).thenReturn(List.of());
        Query query = mock(Query.class);
        when(em.createNativeQuery(org.mockito.ArgumentMatchers.argThat(sql ->
                sql != null && sql.contains("SELECT goods.id, goods.id, goods.code, goods.name"))))
                .thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, goodsId, "G-TEST", "测试货品"}));
    }
}
