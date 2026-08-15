package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductionGoodsWorkshopPreferenceServiceTest {

    @Test
    void learnsOneSelectionWhenEverySegmentForTheGoodsUsesOneWorkshop() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(1);
        UUID goodsId = UUID.randomUUID();
        UUID workshopId = UUID.randomUUID();
        UUID actorId = UUID.randomUUID();

        new ProductionGoodsWorkshopPreferenceService(em)
                .learnFromConfirmedSegments(
                        List.of(
                                segment(goodsId, workshopId),
                                segment(goodsId, workshopId)),
                        actorId);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        verify(query).setParameter("goodsId", goodsId);
        verify(query).setParameter("workshopId", workshopId);
        verify(query).setParameter("selectedBy", actorId);
        verify(query).executeUpdate();
        assertThat(normalize(sql.getValue()))
                .contains("on conflict (goods_id) do update")
                .contains("selection_count = production_goods_workshop_preferences .selection_count + 1")
                .contains("d.is_deleted = false")
                .contains("production_department.code = 'dept_prod'")
                .contains("production_department.is_deleted = false")
                .contains("g.is_deleted = false");
    }

    @Test
    void skipsLearningWhenOneGoodsHasMultipleOrMissingWorkshops() {
        EntityManager em = mock(EntityManager.class);
        UUID firstGoods = UUID.randomUUID();
        UUID secondGoods = UUID.randomUUID();
        UUID firstWorkshop = UUID.randomUUID();
        UUID secondWorkshop = UUID.randomUUID();

        new ProductionGoodsWorkshopPreferenceService(em)
                .learnFromConfirmedSegments(
                        List.of(
                                segment(firstGoods, firstWorkshop),
                                segment(firstGoods, secondWorkshop),
                                segment(secondGoods, firstWorkshop),
                                segment(secondGoods, null)),
                        UUID.randomUUID());

        verifyNoInteractions(em);
    }

    @Test
    void emptyInputAndMissingActorNeverWrite() {
        EntityManager em = mock(EntityManager.class);
        ProductionGoodsWorkshopPreferenceService service =
                new ProductionGoodsWorkshopPreferenceService(em);

        service.learnFromConfirmedSegments(List.of(), UUID.randomUUID());
        service.learnFromConfirmedSegments(
                List.of(segment(UUID.randomUUID(), UUID.randomUUID())), null);

        verify(em, never()).createNativeQuery(anyString());
    }

    @Test
    void readsOnlyActiveDirectProductionWorkshopPreferences() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        UUID goodsId = UUID.randomUUID();
        UUID workshopId = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, workshopId, "注塑车间"}));
        Set<UUID> goodsIds = Set.of(goodsId);

        List<GoodsWorkshopPreferenceView> result =
                new ProductionGoodsWorkshopPreferenceService(em)
                        .findValidByGoodsIds(goodsIds);

        assertThat(result).containsExactly(new GoodsWorkshopPreferenceView(
                goodsId, workshopId, "注塑车间"));
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        verify(query).setParameter("goodsIds", goodsIds);
        assertThat(normalize(sql.getValue()))
                .contains("from production_goods_workshop_preferences preference")
                .contains("g.is_deleted = false")
                .contains("workshop.is_deleted = false")
                .contains("production_department.id = workshop.parent_id")
                .contains("production_department.code = 'dept_prod'")
                .contains("production_department.is_deleted = false");
    }

    @Test
    void emptyPreferenceLookupNeverQueries() {
        EntityManager em = mock(EntityManager.class);
        ProductionGoodsWorkshopPreferenceService service =
                new ProductionGoodsWorkshopPreferenceService(em);

        assertThat(service.findValidByGoodsIds(Set.of())).isEmpty();
        assertThat(service.findValidByGoodsIds(null)).isEmpty();

        verifyNoInteractions(em);
    }

    @Test
    void learningRequiresTheOuterConfirmationTransaction() throws Exception {
        Transactional transaction =
                ProductionGoodsWorkshopPreferenceService.class
                        .getDeclaredMethod(
                                "learnFromConfirmedSegments",
                                List.class,
                                UUID.class)
                        .getAnnotation(Transactional.class);

        assertThat(transaction.propagation())
                .isEqualTo(Propagation.MANDATORY);

        Transactional selectionTransaction =
                ProductionGoodsWorkshopPreferenceService.class
                        .getDeclaredMethod(
                                "learnSelection",
                                UUID.class, UUID.class, UUID.class)
                        .getAnnotation(Transactional.class);
        assertThat(selectionTransaction.propagation())
                .isEqualTo(Propagation.MANDATORY);

        Transactional lookupTransaction =
                ProductionGoodsWorkshopPreferenceService.class
                        .getDeclaredMethod("findValidByGoodsIds", Set.class)
                        .getAnnotation(Transactional.class);
        assertThat(lookupTransaction.readOnly()).isTrue();
    }

    private static ProductionExecutionSegment segment(
            UUID goodsId,
            UUID workshopId) {
        ProductionExecutionSegment segment = new ProductionExecutionSegment();
        segment.setProductGoodsId(goodsId);
        segment.setWorkshopDepartmentId(workshopId);
        return segment;
    }

    private static String normalize(String value) {
        return value.toLowerCase().replaceAll("\\s+", " ").trim();
    }
}
