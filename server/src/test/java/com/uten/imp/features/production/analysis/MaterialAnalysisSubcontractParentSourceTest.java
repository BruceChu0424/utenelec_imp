package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MaterialAnalysisSubcontractParentSourceTest {
    @Test void eachRootUsesItsOwnNonzeroLossRatherThanItsChildOrAStoredParentHint() throws Exception {
        UUID first=UUID.randomUUID(),second=UUID.randomUUID(),child=UUID.randomUUID(),wrong=UUID.randomUUID();
        var firstRow=row(1,null,child);
        var secondRow=row(1,wrong,child);
        var wire=wire(Map.of(first,new BigDecimal("7.5"),second,new BigDecimal("11.25"),
                child,new BigDecimal("99"),wrong,new BigDecimal("63")));
        var rules=rules(wire,List.of(
                target("source-a|child",MaterialAnalysisService.materialParentGoodsId(firstRow,source(first))),
                target("source-b|child",MaterialAnalysisService.materialParentGoodsId(secondRow,source(second)))));

        assertThat(wire.selected().get()).containsExactlyInAnyOrderElementsOf(Set.of(first,second));
        assertThat(required(rules.get("source-a|child"))).isEqualByComparingTo("228.4375");
        assertThat(required(rules.get("source-b|child"))).isEqualByComparingTo("236.4063");
        verify(wire.query(),times(1)).setParameter(eq("ids"),any());
    }

    @Test void aDeeperEdgeUsesItsIntermediateParentLossWithoutBorrowingTheTopSource() throws Exception {
        UUID root=UUID.randomUUID(),parent=UUID.randomUUID(),child=UUID.randomUUID();
        var wire=wire(Map.of(root,new BigDecimal("63"),parent,new BigDecimal("12.5"),child,new BigDecimal("99")));
        var rules=rules(wire,List.of(target("source|parent/child",
                MaterialAnalysisService.materialParentGoodsId(row(2,parent,child),source(root)))));

        assertThat(wire.selected().get()).containsExactly(parent);
        assertThat(required(rules.get("source|parent/child"))).isEqualByComparingTo("239.0625");
    }

    private static BigDecimal required(SubcontractMaterialSupplyRequirement rule) {
        return rule.required(new BigDecimal("100"),new BigDecimal("2.125"),
                MaterialConsumptionMath.PER_UNIT,BigDecimal.ONE,true);
    }

    private static MaterialAnalysisService.MaterialRow row(int depth,UUID parent,UUID child) {
        var row=mock(MaterialAnalysisService.MaterialRow.class);
        when(row.depth()).thenReturn(depth);
        when(row.parentGoodsId()).thenReturn(parent);
        when(row.goodsId()).thenReturn(child);
        return row;
    }

    private static MaterialAnalysisService.SourceLine source(UUID goods) {
        var source=mock(MaterialAnalysisService.SourceLine.class);
        when(source.goodsId()).thenReturn(goods);
        return source;
    }

    private record Wire(MaterialAnalysisService service,Query query,AtomicReference<Collection<UUID>> selected) { }

    private static Wire wire(Map<UUID,BigDecimal> goodsLosses) {
        EntityManager em=mock(EntityManager.class);
        Query query=mock(Query.class);
        var selected=new AtomicReference<Collection<UUID>>(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(eq("ids"),any())).thenAnswer(call->{
            Collection<?> ids=call.getArgument(1);
            assertThat(ids).doesNotContainNull();
            selected.set(ids.stream().map(UUID.class::cast).toList());
            return query;
        });
        when(query.getResultList()).thenAnswer(call->{
            List<Object[]> rows=new ArrayList<>();
            for(UUID id:selected.get())if(goodsLosses.containsKey(id))rows.add(new Object[]{id,goodsLosses.get(id)});
            return rows;
        });
        var service=new MaterialAnalysisService(em,null,null,null,null,null,null,null,null,null);
        return new Wire(service,query,selected);
    }

    private static Object target(String key,UUID parent) throws ReflectiveOperationException {
        var type=Class.forName(MaterialAnalysisService.class.getName()+"$SubcontractSupplyTarget");
        var constructor=type.getDeclaredConstructor(String.class,UUID.class);
        constructor.setAccessible(true);
        return constructor.newInstance(key,parent);
    }

    private static Map<String,SubcontractMaterialSupplyRequirement> rules(Wire wire,List<Object> targets) {
        return ReflectionTestUtils.invokeMethod(wire.service(),"subcontractSupplyRules",targets,List.of());
    }
}
