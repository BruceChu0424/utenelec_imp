package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class MaterialAnalysisCommandBatchLookupTest {

    @Test
    void repeatedMaterialsAcrossHundredsOfProductsUseOneBomLookup() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        UUID componentParent = UUID.randomUUID();
        UUID leaf = UUID.randomUUID();
        UUID otherParent = UUID.randomUUID();
        List<UUID> productMaterials = new ArrayList<>();
        for (int product = 0; product < 500; product++) {
            productMaterials.addAll(List.of(componentParent, leaf, otherParent));
        }
        when(em.createNativeQuery(anyString(), eq(UUID.class))).thenReturn(query);
        when(query.setParameter(eq("goodsIds"), any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(componentParent, otherParent));

        Set<UUID> parents = service(em).activeBomParentIds(productMaterials);

        assertThat(parents).containsExactlyInAnyOrder(componentParent, otherParent)
                .doesNotContain(leaf);
        verify(em, times(1)).createNativeQuery(anyString(), eq(UUID.class));
        ArgumentCaptor<Object> boundIds = ArgumentCaptor.forClass(Object.class);
        verify(query).setParameter(eq("goodsIds"), boundIds.capture());
        assertThat(boundIds.getValue()).isEqualTo(
                List.of(componentParent, leaf, otherParent).stream().sorted().toList());
    }

    @Test
    void emptyBomCandidateBatchSkipsLookup() {
        EntityManager em = mock(EntityManager.class);

        assertThat(service(em).activeBomParentIds(List.of())).isEmpty();

        verifyNoInteractions(em);
    }

    @Test
    void unmatchedGoodsAreNotClassifiedAsBomParents() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        UUID leaf = UUID.randomUUID();
        when(em.createNativeQuery(anyString(), eq(UUID.class))).thenReturn(query);
        when(query.setParameter(eq("goodsIds"), any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());

        assertThat(service(em).activeBomParentIds(List.of(leaf, leaf))).isEmpty();
        verify(query).setParameter("goodsIds", List.of(leaf));
    }

    private static MaterialAnalysisCommandService service(EntityManager em) {
        return new MaterialAnalysisCommandService(
                em, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
    }
}
