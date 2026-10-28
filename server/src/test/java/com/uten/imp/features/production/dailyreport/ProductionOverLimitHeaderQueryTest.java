package com.uten.imp.features.production.dailyreport;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.Map;
import java.util.Set;
import java.util.List;
import java.util.UUID;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ProductionOverLimitHeaderQueryTest {
    @Test void typedHeadersUseTheSameDisplayedBatchFactAndOwnerPredicateForCountAndPage() {
        var em=mock(EntityManager.class);var access=mock(ProductionDocumentAccessPolicy.class);
        var membership=mock(ProductionWorkshopMembership.class);UUID owner=UUID.randomUUID();
        when(access.hasAuthority(ProductionOverLimitDispositionService.APPROVE)).thenReturn(true);
        when(access.nativeReadScope("plan.maker_id","owners")).thenReturn(new NativeReadScope("plan.maker_id IN (:owners)","owners",Set.of(owner)));
        Query rows=mock(Query.class,RETURNS_SELF),count=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenAnswer(call->call.<String>getArgument(0).startsWith("SELECT COUNT(*)")?count:rows);
        when(rows.getResultList()).thenReturn(List.of());when(count.getSingleResult()).thenReturn(201L);
        var service=new ProductionOverLimitDispositionService(em,access,membership,null,null,null,null,null);
        var result=service.list("PENDING",2,50,"actual","desc",Map.of("search.within","=1100.0001","search.goodsName","毛坯"));
        var sql=org.mockito.ArgumentCaptor.forClass(String.class);verify(em,times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(value->assertThat(value).contains("plan.maker_id IN (:owners)",
            "request.status IN('PENDING','HELD','RETURNED')","piece.output_batch_id=item.output_batch_id","SUM(snapshot.qty)")
            .doesNotContain("NOT piece.is_deleted"));
        assertThat(sql.getAllValues().getLast()).contains("ORDER BY request.actual_batch_qty DESC NULLS LAST");
        for(Query query:List.of(rows,count))verify(query).setParameter("owners",Set.of(owner));
        for(Query query:List.of(rows,count))verify(query).setParameter(anyString(),eq(new BigDecimal("1100.0001")));
        verify(rows).setFirstResult(50);verify(rows).setMaxResults(50);
        assertThat(result.getTotal()).isEqualTo(201);
    }
}
