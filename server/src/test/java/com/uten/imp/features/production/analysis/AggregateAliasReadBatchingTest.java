package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AggregateAliasReadBatchingTest {
    @Test void disjointSourceSubtreesAreCapturedInOneReadWithoutChangingParentRelease() {
        EntityManager em=mock(EntityManager.class);Query query=query();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        List<AggregateMaterialOrderContracts.GroupPreview> groups=new ArrayList<>();
        List<MaterialAnalysisContracts.MaterialView> parents=new ArrayList<>();List<Object[]> children=new ArrayList<>();
        for(int i=0;i<100;i++) {
            UUID parent=UUID.randomUUID();
            groups.add(group(parent));
            var material=mock(MaterialAnalysisContracts.MaterialView.class);
            when(material.materialLineId()).thenReturn(parent);when(material.planningUncoveredQty()).thenReturn(new BigDecimal("2"));
            parents.add(material);
            children.add(new Object[]{UUID.randomUUID(),new BigDecimal("2"),new BigDecimal("2"),parent,
                    BigDecimal.ONE,"PER_UNIT",BigDecimal.ONE,true,false,BigDecimal.ZERO});
        }
        when(query.getResultList()).thenReturn(children);
        var view=mock(MaterialAnalysisContracts.AnalysisView.class);when(view.flatMaterials()).thenReturn(parents);when(view.products()).thenReturn(List.of());
        Map<UUID,?> result=ReflectionTestUtils.invokeMethod(service(em),"captureSourceCapacities",groups,view);
        assertThat(result).hasSize(100);
        assertThat(result.values()).allSatisfy(snapshot->{
            assertThat((BigDecimal)ReflectionTestUtils.getField(snapshot,"parentReleased")).isEqualByComparingTo("1");
            assertThat((BigDecimal)ReflectionTestUtils.getField(snapshot,"parentRetained")).isEqualByComparingTo("1");
        });
        verify(em,times(1)).createNativeQuery(anyString());verify(query,times(1)).getResultList();
    }

    @Test void aHundredNewBatchesReadTargetsAndExactSourceBindingsOnlyOnceEach() throws Exception {
        EntityManager em=mock(EntityManager.class);Query targets=query(),sources=query();
        when(targets.getResultList()).thenReturn(List.of());when(sources.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(call->((String)call.getArgument(0)).contains("requested_parents AS")?sources:targets);
        List<Object> requests=new ArrayList<>();
        for(int i=0;i<100;i++)requests.add(request(null));
        Map<UUID,?> result=ReflectionTestUtils.invokeMethod(service(em),"readAliasSnapshots",requests);
        assertThat(result).hasSize(100);
        var sql=ArgumentCaptor.forClass(String.class);verify(em,times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).anySatisfy(statement->assertThat(statement)
                .contains("allocation.action_id=batch.action_id","allocation.analysis_material_id=requested.parent_id",
                        "allocation.external_item_id=batch.anchor_analysis_item_id","invalid_binding"));
        verify(targets,times(1)).getResultList();verify(sources,times(1)).getResultList();
    }

    @Test void aSourceWithoutItsActualBatchAllocationCannotBeSilentlyDropped() throws Exception {
        EntityManager em=mock(EntityManager.class);Query targets=query(),sources=query();
        when(targets.getResultList()).thenReturn(List.of());
        when(sources.getResultList()).thenReturn(Collections.singletonList(new Object[]{null,null,null,null,null,null,null,null,UUID.randomUUID(),true}));
        when(em.createNativeQuery(anyString())).thenAnswer(call->((String)call.getArgument(0)).contains("requested_parents AS")?sources:targets);
        var service=service(em);var requests=List.of(request(null));
        assertThatThrownBy(()->ReflectionTestUtils.invokeMethod(service,"readAliasSnapshots",requests))
                .isInstanceOf(ApiException.class).hasMessageContaining("真实父件分配");
    }

    @Test void aReusedPlanStillRequiresExactlyOneEffectiveOutputLine() throws Exception {
        EntityManager em=mock(EntityManager.class);Query plans=query();UUID plan=UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenReturn(plans);
        when(plans.getResultList()).thenReturn(Collections.singletonList(new Object[]{plan,2L,BigDecimal.ONE}));
        var service=service(em);var requests=List.of(request(plan));
        assertThatThrownBy(()->ReflectionTestUtils.invokeMethod(service,"readAliasSnapshots",requests))
                .isInstanceOf(ApiException.class).hasMessageContaining("一条有效明细");
        verify(em,times(1)).createNativeQuery(anyString());
    }

    private static Object request(UUID plan) throws Exception {
        var batchType=Class.forName(AggregateMaterialOrderWriteService.class.getName()+"$Batch");
        var batchConstructor=batchType.getDeclaredConstructors()[0];batchConstructor.setAccessible(true);
        Object batch=batchConstructor.newInstance(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),plan,"MAKE",1L);
        var constructor=Class.forName(AggregateMaterialOrderWriteService.class.getName()+"$AliasReadRequest").getDeclaredConstructors()[0];constructor.setAccessible(true);
        return constructor.newInstance(batch,group(UUID.randomUUID()));
    }
    private static AggregateMaterialOrderContracts.GroupPreview group(UUID parent) {
        var group=mock(AggregateMaterialOrderContracts.GroupPreview.class);
        when(group.sources()).thenReturn(List.of(new AggregateMaterialOrderContracts.SourcePreview(parent,UUID.randomUUID(),"source",1,null,
                new BigDecimal("2"),new BigDecimal("2"),BigDecimal.ONE,BigDecimal.ZERO)));
        return group;
    }
    private static Query query(){Query query=mock(Query.class);when(query.setParameter(anyString(),any())).thenReturn(query);return query;}
    private static AggregateMaterialOrderWriteService service(EntityManager em) {
        var service=mock(AggregateMaterialOrderWriteService.class,CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service,"em",em);ReflectionTestUtils.setField(service,"mapper",new ObjectMapper());return service;
    }
}
