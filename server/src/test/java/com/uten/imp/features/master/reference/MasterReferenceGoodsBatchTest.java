package com.uten.imp.features.master.reference;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MasterReferenceGoodsBatchTest {
    private final EntityManager em=mock(EntityManager.class);
    private final OwnerVisibility owners=mock(OwnerVisibility.class);
    private final Map<UUID,UUID> facts=new HashMap<>();
    private final List<Integer> sizes=new ArrayList<>();
    private MasterReferenceValidationAdapter adapter(boolean enabled) {
        var query=mock(Query.class);var selected=new AtomicReference<List<UUID>>();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(eq("ids"),any())).thenAnswer(call->{
            @SuppressWarnings("unchecked") List<UUID> ids=call.getArgument(1);
            selected.set(ids);sizes.add(ids.size());return query;
        });
        when(query.getResultList()).thenAnswer(call->selected.get().stream().filter(facts::containsKey).map(id->new Object[]{id,facts.get(id)}).toList());
        var result=new MasterReferenceValidationAdapter(em,owners,mock(ClientAccessPolicy.class));
        ReflectionTestUtils.setField(result,"goodsOwnerScopeEnabled",enabled);return result;
    }
    @Test void distinct401ReferencesUseThreeBoundedQueriesAndOneOriginalOwnerAuthority() {
        UUID owner=UUID.randomUUID();var ids=new ArrayList<UUID>();
        for(int i=0;i<401;i++){UUID id=UUID.randomUUID();ids.add(id);facts.put(id,i==0?null:owner);}ids.add(ids.getFirst());
        when(owners.evaluate("goods","goods:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(owner)));
        adapter(true).requireVisibleGoodsBatch(ids);
        assertThat(sizes).containsExactly(200,200,1);verify(owners,times(1)).evaluate("goods","goods:view:all");
        var sql=ArgumentCaptor.forClass(String.class);verify(em,times(3)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(value->assertThat(value).contains("g.id IN (:ids)").doesNotContain("is_deleted","status","auto_created"));
    }
    @Test void publicOwnerAndHistoricalLifecycleStayReadableButRevokedOwnerIsNotCached() {
        UUID owner=UUID.randomUUID(),id=UUID.randomUUID(),publicId=UUID.randomUUID();facts.put(id,owner);facts.put(publicId,null);
        when(owners.evaluate("goods","goods:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(owner)),new OwnerVisibility.OwnerScope(false,Set.of()));
        var target=adapter(true);target.requireVisibleGoodsBatch(List.of(id,publicId));
        assertThatThrownBy(()->target.requireVisibleGoodsBatch(List.of(id,publicId))).isInstanceOf(ApiException.class).extracting("code").isEqualTo(ErrorCode.NOT_FOUND);
        verify(owners,times(2)).evaluate("goods","goods:view:all");
    }
    @Test void absentOrNullReferenceFailsClosedAndEmptyBatchDoesNotQuery() {
        var target=adapter(false);target.requireVisibleGoodsBatch(List.of());verifyNoInteractions(em);
        assertThatThrownBy(()->target.requireVisibleGoodsBatch(Collections.singletonList(null))).isInstanceOf(ApiException.class).extracting("code").isEqualTo(ErrorCode.NOT_FOUND);
        assertThatThrownBy(()->target.requireVisibleGoodsBatch(List.of(UUID.randomUUID()))).isInstanceOf(ApiException.class).extracting("code").isEqualTo(ErrorCode.NOT_FOUND);
    }
    @Test void theOriginalDisabledOwnerScopeFlagDoesNotInventAStrongerPermission() {
        UUID id=UUID.randomUUID();facts.put(id,UUID.randomUUID());adapter(false).requireVisibleGoodsBatch(List.of(id));verifyNoInteractions(owners);
    }
}
