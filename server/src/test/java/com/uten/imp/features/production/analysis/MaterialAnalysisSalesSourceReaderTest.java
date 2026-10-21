package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MaterialAnalysisSalesSourceReaderTest {
    @Test void masterFactsKeepTheirIdentityAndDefaultDeliveryAndValidateWhenUsed() {
        EntityManager em=mock(EntityManager.class);Query query=query(em);
        UUID valid=UUID.randomUUID(),unconfirmed=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID();
        LocalDate date=LocalDate.of(2026,10,30);
        when(query.getResultList()).thenReturn(List.of(row(unconfirmed,goods,unit,date,false),row(valid,goods,unit,date,true)));
        var snapshot=new MaterialAnalysisSalesSourceReader(em).read(List.of(unconfirmed,valid,valid));
        var source=snapshot.require(valid);
        assertThat(source.goodsId()).isEqualTo(goods);assertThat(source.unitId()).isEqualTo(unit);assertThat(source.deliveryDate()).isEqualTo(date);
        assertThatThrownBy(()->snapshot.require(unconfirmed)).isInstanceOf(ApiException.class).hasMessageContaining("财务确认");
        assertThatThrownBy(()->snapshot.require(UUID.randomUUID())).isInstanceOf(ApiException.class).hasMessage("销售订单行不存在");
        assertThatThrownBy(()->snapshot.require(null)).isInstanceOf(ApiException.class).hasMessage("销售订单行不存在");
        verify(em).createNativeQuery(anyString());
    }

    @Test void moreThanOneRequestBatchIsBoundedAndAnEmptyReadNeverQueries() {
        EntityManager em=mock(EntityManager.class);Query query=query(em);List<Integer> sizes=new ArrayList<>();
        when(query.setParameter(eq("ids"),any())).thenAnswer(call->{sizes.add(((Collection<?>)call.getArgument(1)).size());return query;});
        var reader=new MaterialAnalysisSalesSourceReader(em);
        reader.read(List.of());verifyNoInteractions(em);
        reader.read(java.util.stream.IntStream.range(0,600).mapToObj(index->UUID.randomUUID()).toList());
        assertThat(sizes).containsExactly(256,256,88);verify(em,times(3)).createNativeQuery(anyString());
    }

    @Test void activeAnalysisDiscoveryBatchesSalesIdsAndNeverTouchesManualNullReferences() {
        EntityManager em=mock(EntityManager.class);Query query=query(em);
        var reader=new MaterialAnalysisSalesSourceReader(em);
        assertThat(reader.activeAnalyses(Collections.singletonList(null))).isEmpty();verifyNoInteractions(em);
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.of(first,second));
        assertThat(reader.activeAnalyses(List.of(UUID.randomUUID(),UUID.randomUUID()))).containsExactly(first,second);
        verify(em).createNativeQuery(anyString());
    }

    @Test void aLaterCommandRechecksFinanceAndInvalidUnitsInsteadOfReusingCachedAuthority() {
        EntityManager em=mock(EntityManager.class);Query query=query(em);UUID id=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID();
        when(query.getResultList()).thenReturn(Collections.singletonList(row(id,goods,unit,null,true)),
                Collections.singletonList(row(id,goods,unit,null,false)),Collections.singletonList(row(id,goods,null,null,true)));
        var reader=new MaterialAnalysisSalesSourceReader(em);
        assertThat(reader.read(List.of(id)).require(id).goodsId()).isEqualTo(goods);
        assertThatThrownBy(()->reader.read(List.of(id)).require(id)).isInstanceOf(ApiException.class).hasMessageContaining("财务确认");
        assertThatThrownBy(()->reader.read(List.of(id)).require(id)).isInstanceOf(ApiException.class).hasMessageContaining("有效单位");
    }

    @Test void stoppedClosedDeletedAndUnapprovedSalesFactsRemainIneligible() {
        EntityManager em=mock(EntityManager.class);Query query=query(em);UUID id=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID();
        for(int flag:List.of(5,6,7,8,9)) {
            Object[] row=row(id,goods,unit,null,true);
            if(flag==5) row[flag]=0; else row[flag]=true;
            when(query.getResultList()).thenReturn(Collections.singletonList(row));
            var snapshot=new MaterialAnalysisSalesSourceReader(em).read(List.of(id));
            assertThatThrownBy(()->snapshot.require(id)).isInstanceOf(ApiException.class).hasMessageContaining("未审核、已中止、已关闭或已删除");
        }
    }

    private static Query query(EntityManager em) {
        Query query=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(List.of());return query;
    }
    private static Object[] row(UUID id,UUID goods,UUID unit,LocalDate date,boolean finance) {
        return new Object[]{id,goods,null,unit,date,1,false,false,false,false,finance};
    }
}
