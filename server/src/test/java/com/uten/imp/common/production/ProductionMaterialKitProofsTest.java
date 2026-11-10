package com.uten.imp.common.production;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionMaterialKitProofsTest {
    @Test void directLotRequestUsesItsTargetSegmentInsideTheAlreadyLockedGraph() {
        UUID document=UUID.randomUUID(),segment=UUID.randomUUID();var em=mock(EntityManager.class);
        var graph=query();var capture=query();when(graph.getResultList()).thenReturn(Collections.singletonList(new Object[]{segment,true}));
        when(em.createNativeQuery(anyString())).thenReturn(graph,capture);
        ProductionMaterialKitProofs.captureReturnDocument(em,document,List.of());
        verify(graph).setParameter("document",document);verify(capture).setParameter("segment",segment);
        var sql=ArgumentCaptor.forClass(String.class);verify(em,times(2)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().getFirst().contains("plan_draw_links"));
        assertTrue(sql.getAllValues().getFirst().contains("production_planning_packages"));
        assertFalse(sql.getAllValues().getFirst().contains("FOR UPDATE"));
    }
    @Test void stockAndDirectTargetsAreUnionedAndCheckedBeforeAnyCapture() {
        UUID document=UUID.randomUUID(),sourceItem=UUID.randomUUID(),first=UUID.randomUUID(),second=UUID.randomUUID();
        var em=mock(EntityManager.class);var graph=query();var capture=query();
        when(graph.getResultList()).thenReturn(List.of(new Object[]{first,true},new Object[]{second,true}));
        when(em.createNativeQuery(anyString())).thenReturn(graph,capture);
        ProductionMaterialKitProofs.captureReturnDocument(em,document,Arrays.asList(sourceItem,sourceItem,null));
        verify(graph).setParameter("items",List.of(sourceItem));
        verify(capture).setParameter("segment",first);verify(capture).setParameter("segment",second);
        verify(capture,times(2)).getResultList();
    }
    @Test void anUnlinkedSourceRejectsTheWholeCheckpointBatchWithoutAddingLocksOrFacts() {
        var em=mock(EntityManager.class);var graph=query();
        when(graph.getResultList()).thenReturn(List.of(new Object[]{UUID.randomUUID(),true},new Object[]{UUID.randomUUID(),false}));
        when(em.createNativeQuery(anyString())).thenReturn(graph);
        var error=assertThrows(ApiException.class,()->ProductionMaterialKitProofs.captureReturnDocument(em,UUID.randomUUID(),List.of()));
        assertTrue(error.getMessage().contains("已锁定的计划图"));
        verify(em,times(1)).createNativeQuery(anyString());
    }
    private static Query query(){var result=mock(Query.class);when(result.setParameter(anyString(),any())).thenReturn(result);return result;}
}
