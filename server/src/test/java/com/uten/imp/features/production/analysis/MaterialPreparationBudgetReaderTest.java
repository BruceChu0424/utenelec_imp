package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MaterialPreparationBudgetReaderTest {
    @Test void repeatedBomOccurrencesShareOnePoolAndCannotSpendPrivatePegs() {
        EntityManager em=mock(EntityManager.class);
        Query future=query(), own=query(), aliases=query();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql=call.getArgument(0);
            return sql.contains("WITH private_plans") ? own : sql.contains("jsonb_array_elements") ? aliases : future;
        });
        UUID analysis=UUID.randomUUID(), main=UUID.randomUUID(), leaf=UUID.randomUUID(), other=UUID.randomUUID();
        UUID goods=UUID.randomUUID(), unit=UUID.randomUUID(), a=UUID.randomUUID(), b=UUID.randomUUID();
        UUID source=UUID.randomUUID(),sourceItem=UUID.randomUUID();
        when(future.getResultList()).thenReturn(List.of(
                new Object[]{a,"EXTERNAL_PUBLIC",source,sourceItem,new BigDecimal("90"),false},
                new Object[]{b,"EXTERNAL_PUBLIC",source,sourceItem,new BigDecimal("90"),true}));
        when(own.getResultList()).thenReturn(Collections.singletonList(new Object[]{a,new BigDecimal("4")}));
        when(aliases.getResultList()).thenReturn(Collections.singletonList(new Object[]{a,new BigDecimal("2")}));
        var breakdown=List.of(warehouse(leaf,"12","2"),warehouse(other,"500","0"));
        var facts=new MaterialPreparationBudgetReader(em).read(analysis,main,
                List.of(material(a,goods,unit,breakdown),material(b,goods,unit,breakdown)),Set.of(leaf));
        String key=facts.poolKeyByMaterial().get(a);
        assertThat(facts.poolKeyByMaterial().get(b)).isEqualTo(key);
        assertThat(facts.sharedQtyByPoolKey().get(key)).isEqualByComparingTo("100");
        assertThat(facts.slicesByMaterial().get(a)).filteredOn(slice->!slice.adoptable())
                .extracting(slice->slice.availableQty()).containsExactly(new BigDecimal("90"));
        assertThat(facts.slicesByMaterial().get(b)).allMatch(slice->slice.adoptable());
        assertThat(facts.slicesByMaterial().get(a)).extracting(slice->slice.key())
                .containsExactlyElementsOf(facts.slicesByMaterial().get(b).stream().map(slice->slice.key()).toList());
        assertThat(facts.privateMakePendingByMaterial()).containsOnlyKeys(a);
        assertThat(facts.outgoingInheritedPendingByMaterial().get(a)).isEqualByComparingTo("2");
        verify(em,times(3)).createNativeQuery(anyString());
    }

    @Test void emptyAnalysisDoesNotQueryOrInventAPlanningPool() {
        EntityManager em=mock(EntityManager.class);
        var facts=new MaterialPreparationBudgetReader(em).read(UUID.randomUUID(),UUID.randomUUID(),List.of(),Set.of());
        assertThat(facts.sharedQtyByPoolKey()).isEmpty();
        verifyNoInteractions(em);
    }

    private Query query() {
        Query query=mock(Query.class);
        when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        return query;
    }
    private MaterialView material(UUID id,UUID goods,UUID unit,List<WarehouseBreakdown> warehouses) {
        MaterialView row=mock(MaterialView.class);
        when(row.materialLineId()).thenReturn(id);when(row.goodsId()).thenReturn(goods);
        when(row.unitId()).thenReturn(unit);when(row.warehouseBreakdown()).thenReturn(warehouses);
        return row;
    }
    private WarehouseBreakdown warehouse(UUID id,String available,String own) {
        return new WarehouseBreakdown(id,"W","Warehouse",BigDecimal.ZERO,BigDecimal.ZERO,
                new BigDecimal(available),new BigDecimal(own),BigDecimal.ZERO,BigDecimal.ZERO,
                BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,null);
    }
}
